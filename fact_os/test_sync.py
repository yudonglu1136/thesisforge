"""Deterministic provider-protocol regression tests; never access the network."""
import csv
import io
import gzip
import json
from collections import Counter
from datetime import date, timedelta
import tempfile
import unittest
import zipfile
from pathlib import Path
from unittest.mock import patch

import httpx

from .store import Store
from .sync import Synchronizer, UpstreamError
from .sync_plan import bounded_date_windows

DDL='CREATE TABLE IF NOT EXISTS "stocks" ("ticker" TEXT,"date" TEXT,"close" REAL,"closeadj" REAL,"closeunadj" REAL,"lastupdated" TEXT,PRIMARY KEY ("ticker","date"));'
FIELDS=['ticker','date','close','closeadj','closeunadj','lastupdated']

class SyncTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory();self.root=Path(self.temp.name)
        self.store=Store(self.root/'facts');self.store.install_contract('stocks',DDL)
        self.original={'ticker':'ABC','date':'2000-01-03','close':4,'closeadj':3,'closeunadj':8,'lastupdated':'2024-01-01'}
        self.seed=self.root/'seed.csv'
        with self.seed.open('w',newline='') as f:
            w=csv.DictWriter(f,fieldnames=FIELDS);w.writeheader();w.writerow(self.original)
        self.store.ingest('stocks',self.seed,scope='verified_full_bulk')
        self.sync=Synchronizer(self.store,'private-test-credential')
        self.requests=[]
        self.format=patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':'json'})
        self.format.start()
    def tearDown(self):self.format.stop();self.sync.close();self.temp.cleanup()
    def mock(self,handler):
        self.sync.http.close()
        def handle(request):
            self.requests.append(request)
            self.assertNotIn('private-test-credential',str(request.url))
            return handler(request)
        self.sync.http=httpx.Client(transport=httpx.MockTransport(handle),headers={'x-api-key':'private-test-credential'})
    def provider(self,source,fields=FIELDS,transform=None):
        """Serve the exact native query, including complete-query discovery.

        Unlike the former OFFSET mock, unrelated date windows return no rows.
        Mutation hooks run AFTER filtering to simulate a misbehaving upstream.
        """
        occurrences=Counter()
        def handler(req):
            query=req.url.params
            self.assertNotIn('skip',query);self.assertNotIn('offset',query)
            signature=tuple(sorted(query.multi_items()))
            occurrences[signature]+=1
            tickers=query['ticker'].split(',') if 'ticker' in query else None
            rows=[dict(row) for row in source
                if query['from']<=row['date']<=query['to']
                and (tickers is None or row['ticker'] in tickers)
                and ('ticker.gt' not in query or row['ticker']>query['ticker.gt'])
                and ('ticker.gte' not in query or row['ticker']>=query['ticker.gte'])
                and ('ticker.lt' not in query or row['ticker']<query['ticker.lt'])
                and ('ticker.lte' not in query or row['ticker']<=query['ticker.lte'])
                and ('lastupdated.gte' not in query or row.get('lastupdated','')>=query['lastupdated.gte'])
                and ('lastupdated.lte' not in query or row.get('lastupdated','')<=query['lastupdated.lte'])]
            selected=query['fields'].split(',') if 'fields' in query else fields
            if 'fields' in query:
                rows=[dict(zip(selected,values)) for values in
                    sorted({tuple(row[field] for field in selected) for row in rows})]
            rows=rows[:int(query['limit'])]
            if transform is not None:rows=transform(req,rows,occurrences[signature])
            if query['format']=='csv':
                text=io.StringIO();writer=csv.DictWriter(text,fieldnames=selected);writer.writeheader()
                writer.writerows(rows)
                return httpx.Response(200,text=text.getvalue())
            return httpx.Response(200,json={'count':len(rows),'data':rows})
        self.mock(handler)
    def test_sync_twice_is_idempotent_and_keeps_older_history(self):
        row={**self.original,'date':'2024-01-03','lastupdated':'2024-01-03','close':5}
        self.provider([row])
        first=self.sync.sync('stocks');second=self.sync.sync('stocks')
        self.assertEqual(first['local_rows'],2)
        self.assertEqual(second['status'],'unchanged')
        self.assertEqual(self.store.status()[0]['row_count'],2)
        self.assertEqual(len(list((self.store.root/'raw').glob('*sync*.csv'))),1)
        self.assertEqual(self.requests[0].url.params['from'],'1900-01-01')
    def test_entitlement_loss_preserves_history_and_watermark(self):
        before=self.store.status()
        self.mock(lambda req:httpx.Response(403))
        with self.assertRaisesRegex(UpstreamError,'local history retained'):self.sync.sync('stocks')
        self.assertEqual(self.store.status(),before)
    def test_gzip_query_stream_is_decoded_only_once(self):
        def compressed(req):
            rows=[self.original] if req.url.params['from']<=self.original['date']<=req.url.params['to'] else []
            body=gzip.compress(json.dumps({'count':len(rows),'data':rows}).encode())
            return httpx.Response(200,content=body,headers={'content-encoding':'gzip'})
        self.mock(compressed)
        self.assertEqual(self.sync.sync('stocks')['local_rows'],1)
        self.assertEqual(self.sync.sync('stocks')['status'],'unchanged')
    def test_slow_stream_time_budget_does_not_publish(self):
        before=self.store.status();ticks=iter(range(0,100000,121))
        self.mock(lambda req:httpx.Response(200,json={'count':0,'data':[]}))
        with patch('fact_os.sync.time.monotonic',side_effect=lambda:next(ticks)):
            with self.assertRaisesRegex(UpstreamError,'total time budget'):
                self.sync.sync('stocks')
        self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_read_timeout_splits_date_scope_without_dropping_records(self):
        def slow_parent(req,rows,_occurrence):
            span=date.fromisoformat(req.url.params['to'])-date.fromisoformat(req.url.params['from'])
            if rows and span.days>10:
                raise httpx.ReadTimeout('simulated slow window',request=req)
            return rows
        self.provider([self.original],transform=slow_parent)
        result=self.sync.sync('stocks')
        self.assertEqual(result['local_rows'],1)
        leaves=[req for req in self.requests if req.url.params['from']<=self.original['date']<=req.url.params['to']
            and (date.fromisoformat(req.url.params['to'])-date.fromisoformat(req.url.params['from'])).days<=10]
        self.assertGreaterEqual(len(leaves),2) # complete extraction and verification
    def test_price_small_windows_keep_revisions_before_local_history(self):
        earlier={**self.original,'date':'1998-01-05'}
        self.provider([earlier,self.original])
        result=self.sync.sync('stocks')
        self.assertEqual(result['input_rows'],2)
        self.assertEqual(result['local_rows'],2)
        self.assertEqual(result['min_date'],'1998-01-05')
        self.assertTrue(any(req.url.params['from']<='1998-01-05'<=req.url.params['to'] for req in self.requests))
        for req in self.requests:
            if req.url.params['from']>='2000-01-03':
                self.assertLessEqual((date.fromisoformat(req.url.params['to'])-date.fromisoformat(req.url.params['from'])).days,30)
    def test_verification_read_timeout_cannot_publish_partial_extract(self):
        before=self.store.status()
        def interrupted_check(req,rows,occurrence):
            if rows and occurrence>=2:
                raise httpx.ReadTimeout('simulated verification timeout',request=req)
            return rows
        self.provider([self.original],transform=interrupted_check)
        with patch('fact_os.sync.time.sleep'):
            with self.assertRaisesRegex(UpstreamError,'read timeout'):
                self.sync.sync('stocks')
        self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_empty_response_does_not_advance_watermark(self):
        before=self.store.status()
        self.mock(lambda req:httpx.Response(200,json={'count':0,'data':[]}))
        self.assertFalse(self.sync.sync('stocks')['watermark_advanced'])
        after=self.store.status()
        for field in ('watermark','min_date','max_date','row_count','backfill_complete'):
            self.assertEqual(after[0][field],before[0][field])
        self.assertGreaterEqual(after[0]['last_success'],before[0]['last_success'])
    def test_future_effective_date_does_not_skip_recent_updates(self):
        ddl='CREATE TABLE IF NOT EXISTS "events" ("ticker" TEXT,"date" TEXT,"eventcodes" TEXT,PRIMARY KEY ("ticker","date"));'
        self.store.install_contract('events',ddl)
        seed=self.root/'events.csv';seed.write_text('ticker,date,eventcodes\nABC,2100-01-01,1\n')
        self.store.ingest('events',seed,scope='verified_full_bulk')
        self.mock(lambda req:httpx.Response(200,json={'count':0,'data':[]}))
        self.sync.sync('events')
        # Network requests run concurrently; their arrival order is not the
        # deterministic order in which complete extracts are published.
        windows=sorted(set((req.url.params['from'],req.url.params['to']) for req in self.requests))
        self.assertEqual(windows[0][0],(date.today()-timedelta(days=14)).isoformat())
        self.assertEqual(windows[-1][1],'2100-01-01')
        self.assertGreater(len(windows),1)
        self.assertEqual(windows,bounded_date_windows(windows[0][0],'2100-01-01'))
        for start,end in windows:self.assertEqual(bounded_date_windows(start,end),[(start,end)])
    def test_daily_native_one_year_horizon_cannot_hide_old_revisions(self):
        fields=['ticker','date','marketcap','lastupdated']
        self.store.install_contract('daily','CREATE TABLE IF NOT EXISTS "daily" ("ticker" TEXT,"date" TEXT,"marketcap" REAL,"lastupdated" TEXT,PRIMARY KEY ("ticker","date"));')
        seed=self.root/'daily.csv'
        seed.write_text('ticker,date,marketcap,lastupdated\nOLD,1997-01-02,1,2026-09-18\n')
        self.store.ingest('daily',seed,scope='verified_full_bulk')
        rows=[{'ticker':'ABC','date':f'{year}-06-01','marketcap':year,'lastupdated':'2026-09-18'}
            for year in (2000,2001,2002,2003,2012)]
        def native_horizon(req,records,_occurrence):
            # Native DAILY silently crops broad queries to one trailing year,
            # even when its returned count is below the requested limit.
            cutoff=(date.fromisoformat(req.url.params['to'])-timedelta(days=365)).isoformat()
            return [row for row in records if row['date']>=cutoff]
        self.provider(rows,fields=fields,transform=native_horizon)
        result=self.sync.sync('daily')
        self.assertEqual(result['input_rows'],5)
        self.assertEqual(result['local_rows'],6)
        for req in self.requests:
            self.assertLessEqual((date.fromisoformat(req.url.params['to'])-date.fromisoformat(req.url.params['from'])).days,365)
    def test_mid_pagination_mutation_is_not_published(self):
        def mutate(_req,rows,occurrence):
            return [{**row,'close':999} for row in rows] if occurrence==2 else rows
        before=self.store.status()
        self.provider([self.original],transform=mutate)
        with self.assertRaisesRegex(UpstreamError,'changed during sync'):self.sync.sync('stocks')
        self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'raw').glob('*sync*.csv')))
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_completed_sync_checkpoints_do_not_hide_next_upstream_revision(self):
        self.provider([self.original])
        self.sync.sync('stocks')
        revised={**self.original,'close':9}
        self.provider([revised])
        # Same date/query bounds, but a NEW sync after success: old extracted
        # leaves are not the input snapshot of this run.
        self.assertEqual(self.sync.sync('stocks')['status'],'ingested')
        self.assertEqual(self.store.status()[0]['row_count'],1)

    def test_mutation_invalidates_attempt_not_one_stale_leaf_per_retry(self):
        rows=[{**self.original,'ticker':symbol,'date':f'2000-01-0{day}'}
              for day,symbol in ((3,'AAA'),(4,'BBB'),(5,'CCC'))]
        self.provider(rows,transform=lambda _q,data,n:
                      [{**row,'close':99} for row in data] if n==2 else data)
        with patch.dict('os.environ',{'FACT_OS_SYNC_PAGE_SIZE':'2'}):
            with self.assertRaisesRegex(UpstreamError,'changed during sync'):
                self.sync.sync('stocks')
            self.provider([{**row,'close':99} for row in rows])
            # Every old leaf, including ones not reached by verification, is
            # isolated from the replacement attempt. The gate remains strict.
            self.assertEqual(self.sync.sync('stocks')['local_rows'],4)
    def test_completed_backfill_does_not_download_again(self):
        self.mock(lambda req:self.fail('completed backfill must not redownload'))
        self.assertEqual(self.sync.backfill('stocks')['status'],'already_backfilled')
    def test_csv_large_page_sync_is_idempotent(self):
        self.provider([self.original])
        with patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':'csv','FACT_OS_SYNC_PAGE_SIZE':'100000'}):
            self.sync.sync('stocks');result=self.sync.sync('stocks')
        self.assertEqual(result['status'],'unchanged')
        self.assertEqual(self.requests[0].url.params['limit'],'10000')
    def test_price_csv_uses_bounded_ten_thousand_row_requests(self):
        self.provider([self.original])
        with patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':'csv'}):
            self.sync.sync('stocks')
        self.assertTrue(self.requests)
        self.assertTrue(all(int(req.url.params['limit'])<=10000 for req in self.requests))
    def test_complete_queries_never_use_offset_or_exceed_format_limits(self):
        for fmt,maximum in (('csv',100000),('json',10000)):
            with self.subTest(fmt=fmt):
                self.requests.clear();self.provider([self.original])
                with patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':fmt,'FACT_OS_SYNC_PAGE_SIZE':'1000000'}):
                    self.sync.sync('stocks')
                self.assertTrue(self.requests)
                for req in self.requests:
                    self.assertNotIn('skip',req.url.params);self.assertNotIn('offset',req.url.params)
                    self.assertLessEqual(int(req.url.params['limit']),maximum)
                    self.assertEqual(req.url.params['format'],fmt)
    def test_default_json_preserves_commas_in_string_values(self):
        ddl='CREATE TABLE IF NOT EXISTS "holdings_ticker" ("date" TEXT,"ticker" TEXT,"name" TEXT,PRIMARY KEY ("date","ticker"));'
        self.store.install_contract('holdings_ticker',ddl)
        seed=self.root/'holding.csv';seed.write_text('date,ticker,name\n2026-06-30,ABC,"Example, Inc."\n')
        self.store.ingest('holdings_ticker',seed,scope='verified_full_bulk')
        row={'date':'2026-06-30','ticker':'ABC','name':'Example, Inc.'}
        self.provider([row],fields=['date','ticker','name'])
        with patch.dict('os.environ',{},clear=True):
            self.sync.sync('holdings_ticker');result=self.sync.sync('holdings_ticker')
        self.assertEqual(self.requests[0].url.params['format'],'json')
        self.assertEqual(result['status'],'unchanged')
    def test_json_null_text_remains_null_not_empty_string(self):
        import duckdb
        ddl='CREATE TABLE IF NOT EXISTS "holdings_ticker" ("date" TEXT,"ticker" TEXT,"name" TEXT,PRIMARY KEY ("date","ticker"));'
        self.store.install_contract('holdings_ticker',ddl)
        seed=self.root/'nullable.csv';seed.write_text('date,ticker,name\n2026-06-30,ABC,\\N\n')
        self.store.ingest('holdings_ticker',seed,scope='verified_full_bulk')
        row={'date':'2026-06-30','ticker':'ABC','name':None}
        self.provider([row],fields=['date','ticker','name'])
        self.sync.sync('holdings_ticker')
        with duckdb.connect(str(self.store.path),read_only=True) as db:
            self.assertIsNone(db.execute('SELECT name FROM holdings_ticker').fetchone()[0])
    def test_response_reordering_is_not_a_mutation_or_duplicate_raw_archive(self):
        rows=[self.original,{**self.original,'ticker':'XYZ','close':7}]
        self.provider(rows,transform=lambda _req,data,n:list(reversed(data)) if n%2==0 else data)
        self.sync.sync('stocks');result=self.sync.sync('stocks')
        self.assertEqual(result['status'],'unchanged')
        self.assertEqual(self.store.status()[0]['row_count'],2)
        self.assertEqual(len(list((self.store.root/'raw').glob('*sync*.csv'))),1)
    def test_full_responses_recurse_until_complete_leaves_without_losing_rows(self):
        rows=[{**self.original,'date':f'2000-01-0{day}'} for day in (3,4,5)]
        self.provider(rows)
        with patch.dict('os.environ',{'FACT_OS_SYNC_PAGE_SIZE':'2'}):
            result=self.sync.sync('stocks')
        self.assertEqual(result['local_rows'],3)
        self.assertGreater(result['verified_complete_queries'],result['date_windows'])
        self.assertTrue(any(req.url.params['from']==req.url.params['to'] for req in self.requests))
        self.assertTrue(all('skip' not in req.url.params and 'offset' not in req.url.params for req in self.requests))
    def test_out_of_query_date_is_rejected_without_publication(self):
        before=self.store.status()
        for fmt in ('json','csv'):
            for bound,shift in (('from',-1),('to',1)):
                def outside(req,rows,_n):
                    invalid=(date.fromisoformat(req.url.params[bound])+timedelta(days=shift)).isoformat()
                    return [{**row,'date':invalid} for row in rows]
                self.provider([self.original],transform=outside)
                with self.subTest(fmt=fmt,bound=bound),patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':fmt}):
                    with self.assertRaises(UpstreamError):self.sync.sync('stocks')
                self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'raw').glob('*sync*.csv')))
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_out_of_query_ticker_is_rejected_after_discovery_split(self):
        rows=[self.original,{**self.original,'ticker':'XYZ'}]
        before=self.store.status()
        def outside(req,rows,_n):
            if req.url.params.get('ticker')=='ABC':
                return [{**row,'ticker':'NOT_REQUESTED'} for row in rows]
            return rows
        for fmt in ('json','csv'):
            self.requests.clear();self.provider(rows,transform=outside)
            with self.subTest(fmt=fmt),patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':fmt,'FACT_OS_SYNC_PAGE_SIZE':'2'}):
                with self.assertRaises(UpstreamError):self.sync.sync('stocks')
            self.assertTrue(any(req.url.params.get('ticker')=='ABC' for req in self.requests))
            self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'raw').glob('*sync*.csv')))
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_out_of_query_lastupdated_is_rejected_without_publication(self):
        before=self.store.status()
        for fmt in ('json','csv'):
            for bound,shift in (('lastupdated.gte',-1),('lastupdated.lte',1)):
                def outside(req,rows,_n):
                    invalid=(date.fromisoformat(req.url.params[bound])+timedelta(days=shift)).isoformat()
                    return [{**row,'lastupdated':invalid} for row in rows]
                self.provider([self.original],transform=outside)
                with self.subTest(fmt=fmt,bound=bound),patch.dict('os.environ',{'FACT_OS_SYNC_FORMAT':fmt}):
                    with self.assertRaises(UpstreamError):self.sync.sync('stocks')
                self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'raw').glob('*sync*.csv')))
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_holdings_range_partitions_are_complete_and_out_of_range_rows_are_rejected(self):
        ddl='CREATE TABLE IF NOT EXISTS "holdings_ticker" ("ticker" TEXT,"date" TEXT,"value" REAL,PRIMARY KEY ("ticker","date"));'
        self.store.install_contract('holdings_ticker',ddl)
        seed=self.root/'holdings_ticker.csv'
        seed.write_text('ticker,date,value\nABC,2026-03-31,1\n')
        self.store.ingest('holdings_ticker',seed,scope='verified_full_bulk')
        rows=[{'ticker':ticker,'date':'2026-03-31','value':value}
            for value,ticker in enumerate(('ABC','MNO','XYZ'),1)]
        self.provider(rows,fields=['ticker','date','value'])
        with patch.dict('os.environ',{'FACT_OS_SYNC_PAGE_SIZE':'2'}):
            result=self.sync.sync('holdings_ticker')
        self.assertEqual(result['local_rows'],3)
        self.assertTrue(any('ticker.lte' in req.url.params for req in self.requests))
        before=self.store.status()
        def invalid(req,source,_n):
            if 'ticker.lte' in req.url.params:
                return [{**row,'ticker':'ZZZ'} for row in source]
            return source
        self.provider(rows,fields=['ticker','date','value'],transform=invalid)
        with patch.dict('os.environ',{'FACT_OS_SYNC_PAGE_SIZE':'2'}):
            with self.assertRaisesRegex(UpstreamError,'outside its requested range'):
                self.sync.sync('holdings_ticker')
        self.assertEqual(self.store.status(),before)
        self.assertFalse(list((self.store.root/'staging').glob('*sync*.csv')))
    def test_ticker_metadata_uses_snapshot_not_nullable_updated_filter(self):
        ddl='CREATE TABLE IF NOT EXISTS "tickers" ("table" TEXT,"permaticker" INTEGER,"ticker" TEXT,"lastupdated" TEXT,PRIMARY KEY ("table","permaticker","ticker"));'
        self.store.install_contract('tickers',ddl)
        seed=self.root/'ticker.csv';seed.write_text('table,permaticker,ticker,lastupdated\nSF3B,1,MANAGER,\\N\n')
        self.store.ingest('tickers',seed,scope='verified_full_bulk')
        with patch.object(self.sync,'backfill',return_value={'status':'snapshot_upsert'}) as backfill:
            self.assertEqual(self.sync.sync('tickers')['status'],'snapshot_upsert')
            backfill.assert_called_once_with('tickers',refresh=True)
    def test_concurrent_job_cannot_start_duplicate_transfer(self):
        second=Synchronizer(self.store,'second-test-credential')
        try:
            with self.sync.job_lock():
                with self.assertRaisesRegex(UpstreamError,'another local ingestion job'):
                    second.backfill('stocks')
                # Nested calls in the same worker (metadata sync) are allowed.
                self.assertEqual(self.sync.backfill('stocks')['status'],'already_backfilled')
        finally:second.close()
    def test_signed_get_not_head_and_no_key_sent_to_download_host(self):
        memory=io.BytesIO()
        with zipfile.ZipFile(memory,'w') as z:z.write(self.seed,'stocks.csv')
        data=memory.getvalue();seen=[];client=httpx.Client
        def handler(req):
            seen.append(req)
            self.assertNotEqual(req.method,'HEAD')
            if req.url.host=='api.sharadar.com':
                return httpx.Response(302,headers={'location':'https://download.example/archive.zip'})
            self.assertNotIn('x-api-key',req.headers)
            if req.headers.get('range')=='bytes=0-0':
                return httpx.Response(206,headers={'content-range':f'bytes 0-0/{len(data)}','etag':'test'},content=data[:1])
            return httpx.Response(200,headers={'etag':'test'},content=data)
        transport=httpx.MockTransport(handler)
        self.sync.http.close();self.sync.http=client(transport=transport,headers={'x-api-key':'private-test-credential'})
        with patch('fact_os.sync.httpx.Client',side_effect=lambda **kwargs:client(transport=transport,**kwargs)):
            result=self.sync.backfill('stocks',refresh=True)
        self.assertEqual(result['local_rows'],1)
        self.assertTrue((self.store.root/'manifests/stocks-full-archive.json').exists())
    def test_verified_archive_can_promote_prior_unverified_ingestion(self):
        other=Store(self.root/'other');other.install_contract('stocks',DDL)
        other.ingest('stocks',self.seed)
        self.assertFalse(other.status()[0]['backfill_complete'])
        other.ingest('stocks',self.seed,scope='verified_full_bulk')
        self.assertTrue(other.status()[0]['backfill_complete'])

if __name__=='__main__':unittest.main()
