"""The only Fact OS module permitted to access upstream HTTP endpoints."""
import csv
from contextlib import contextmanager
from concurrent.futures import ThreadPoolExecutor
from datetime import date, timedelta
import hashlib
import fcntl
from functools import wraps
import io
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
import time
import uuid
import zipfile

import httpx
import duckdb
import gzip
import random
from .contracts import TABLES
from .store import Store, now, checksum
from .sync_plan import bounded_date_windows, price_date_windows

BASE = 'https://api.sharadar.com/v1.0'

class UpstreamError(RuntimeError):
    pass

def serialized_job(method):
    @wraps(method)
    def run(self,*args,**kwargs):
        with self.job_lock():
            return method(self,*args,**kwargs)
    return run

def disposable_sync_stage(method):
    @wraps(method)
    def run(self,*args,**kwargs):
        self._sync_stage = None
        try: return method(self,*args,**kwargs)
        finally:
            path=self._sync_stage
            # This is only the incomplete CSV created by this invocation. Raw
            # licensed archives and successfully published inputs are retained.
            if path is not None and path.parent==self.store.root/'staging' and path.exists():path.unlink()
            self._sync_stage = None
    return run

def load_key(env_file=None):
    key = os.environ.get('SHARADAR_API_KEY')
    if not key and env_file:
        for line in Path(env_file).read_text().splitlines():
            if line.strip().startswith('SHARADAR_API_KEY='):
                key = line.split('=',1)[1].strip().strip('\"\'')
    if not key or key=='test-api-key':
        raise UpstreamError('paid SHARADAR_API_KEY is required; public sample key rejected')
    return key

class Synchronizer:
    def __init__(self, store, key, *, progress=None):
        self.store, self.key = store, key
        self.progress = progress
        self._job_depth = 0
        self.http = httpx.Client(timeout=httpx.Timeout(30,connect=15),follow_redirects=False,
            headers={'x-api-key':key})

    def close(self):
        self.http.close()

    @contextmanager
    def job_lock(self):
        """Serialize transfers as well as publication; readers remain lock-free."""
        if self._job_depth:
            self._job_depth += 1
            try: yield
            finally: self._job_depth -= 1
            return
        with (self.store.root/'sync/ingestion-job.lock').open('a') as lock:
            try: fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            except BlockingIOError:
                raise UpstreamError('another local ingestion job is running; no duplicate transfer started') from None
            self._job_depth = 1
            try: yield
            finally:
                self._job_depth = 0
                fcntl.flock(lock,fcntl.LOCK_UN)

    def _segmented_download(self, download, url, target, identity, offset, length):
        """Bounded resumable GET ranges; credentials never leave API client."""
        workers=max(1,min(16,int(os.environ.get('FACT_OS_DOWNLOAD_WORKERS','8'))))
        block=8*1024*1024
        identity_hash=hashlib.sha256(json.dumps(identity,sort_keys=True).encode()).hexdigest()[:20]
        folder=target.with_name(target.name+'.'+identity_hash+'.chunks')
        folder.mkdir(exist_ok=True)
        ranges=[(start,min(start+block,length)-1) for start in range(offset,length,block)]
        def fetch_range(bounds):
            start,end=bounds
            dest=folder/f'{start}-{end}.chunk'
            if dest.exists() and dest.stat().st_size==end-start+1:return dest
            temp=dest.with_suffix('.partial')
            for attempt in range(3):
                try:
                    with download.stream('GET',url,headers={'Range':f'bytes={start}-{end}'}) as response:
                        expected=f'bytes {start}-{end}/{length}'
                        if response.status_code!=206 or response.headers.get('content-range')!=expected:
                            raise UpstreamError(f'bulk range rejected: HTTP {response.status_code}')
                        if identity['etag'] and response.headers.get('etag')!=identity['etag']:
                            raise UpstreamError('bulk object changed during transfer')
                        with temp.open('wb') as f:
                            for chunk in response.iter_bytes(256*1024):f.write(chunk)
                            f.flush();os.fsync(f.fileno())
                    if temp.stat().st_size!=end-start+1:raise UpstreamError('incomplete bulk range')
                    temp.replace(dest)
                    return dest
                except httpx.HTTPError:
                    if attempt==2:raise
            raise UpstreamError('bulk range retries exhausted')
        with ThreadPoolExecutor(max_workers=workers) as pool:
            with target.open('ab' if offset else 'wb') as f:
                for start in range(0,len(ranges),workers):
                    # Do not enqueue the whole archive: interruption waits for
                    # at most one bounded batch, and verified chunks resume.
                    for piece in pool.map(fetch_range,ranges[start:start+workers]):
                        with piece.open('rb') as src:shutil.copyfileobj(src,f,1024*1024)
                        f.flush();os.fsync(f.fileno())
                        piece.unlink()
        # Only verified temporary byte chunks are discarded, never raw archives.
        if not any(folder.iterdir()):folder.rmdir()

    def inspect(self, tables=TABLES):
        results=[]
        for table in tables:
            try:
                schema=self.http.get(BASE+'/schema/'+table,params={'format':'sqlite'})
                if schema.status_code!=200:
                    raise UpstreamError(f'schema HTTP {schema.status_code}')
                self.store.install_contract(table,schema.text)
                query=self.http.get(BASE+'/data/'+table,params={'format':'json','limit':1})
                with self.http.stream('GET',BASE+'/data/'+table,params={'years':'full'}) as bulk:
                    status=bulk.status_code
                with self.store.writer() as db:
                    db.execute('INSERT OR REPLACE INTO remote_access VALUES (?,?,?,?)',[table,now(),query.status_code,status])
                results.append({'dataset':table,'query_status':query.status_code,'full_bulk_status':status})
            except (httpx.HTTPError,UpstreamError,ValueError) as e:
                # Never include exception URLs, API key, headers or response bodies.
                results.append({'dataset':table,'error':type(e).__name__})
        return results

    @serialized_job
    def backfill(self, table, *, refresh=False):
        # An interrupted verified download remains in raw/. A successful ZIP is
        # content-addressed before publication. No shorter fallback is attempted.
        target=self.store.root/'raw'/f'{table}-full.zip.part'
        meta=self.store.root/'raw'/f'{table}-full.resume.json'
        state=next((s for s in self.store.status() if s['dataset']==table),None)
        if state and state['backfill_complete'] and not refresh:
            return {'dataset':table,'status':'already_backfilled','local_rows':state['row_count']}
        raw_manifest=self.store.root/'manifests'/f'{table}-full-archive.json'
        if raw_manifest.exists() and not refresh:
            saved_archive=json.loads(raw_manifest.read_text())
            archive=self.store.root/saved_archive['path']
            if archive.exists() and checksum(archive)==saved_archive['sha256']:
                return self.store.ingest(table,archive,scope='verified_full_bulk',observed_at=saved_archive['downloaded_at'])
        with self.http.stream('GET',BASE+'/data/'+table,params={'years':'full'}) as response:
            if response.status_code not in (301,302,303,307,308):
                raise UpstreamError(f'full history unavailable: HTTP {response.status_code}')
            url=response.headers.get('location','')
        # Signed URL is used transiently and never persisted/logged.
        if not url.startswith('https://'):
            raise UpstreamError('invalid bulk redirect')
        with httpx.Client(timeout=120,follow_redirects=True,limits=httpx.Limits(max_connections=16)) as download:
            # The pre-signed URL authorizes GET, not HEAD. A HEAD request to
            # the same valid URL is denied by the object store. Read one byte
            # and derive the total size from Content-Range instead.
            with download.stream('GET',url,headers={'Range':'bytes=0-0'}) as probe:
                if probe.status_code not in (200,206):
                    raise UpstreamError(f'bulk metadata HTTP {probe.status_code}')
                match=re.fullmatch(r'bytes 0-0/(\d+)',probe.headers.get('content-range',''))
                if probe.status_code==206 and not match:
                    raise UpstreamError('invalid bulk metadata range')
                identity={'etag':probe.headers.get('etag'),
                    'length':match[1] if match else probe.headers.get('content-length')}
                next(probe.iter_bytes(chunk_size=1),b'')
            length=int(identity['length'] or 0)
            if length<=0 or length+5*1024**3>shutil.disk_usage(self.store.root).free:
                raise UpstreamError('bulk length unavailable or insufficient disk headroom')
            saved=json.loads(meta.read_text()) if meta.exists() else None
            offset=target.stat().st_size if target.exists() and identity['etag'] and saved==identity else 0
            meta.write_text(json.dumps(identity))
            if offset>length:raise UpstreamError('partial download exceeds verified source length')
            if length>=32*1024*1024 and match:
                self._segmented_download(download,url,target,identity,offset,length)
            elif offset<length:
                with download.stream('GET',url,headers={'Range':f'bytes={offset}-'} if offset else {}) as stream:
                    if stream.status_code not in (200,206):
                        raise UpstreamError(f'bulk transfer HTTP {stream.status_code}')
                    if offset and stream.status_code==200:
                        offset=0
                    elif offset and not stream.headers.get('content-range','').startswith(f'bytes {offset}-'):
                        raise UpstreamError('incorrect resumed download range')
                    with target.open('ab' if offset else 'wb') as file:
                        for chunk in stream.iter_bytes(1024*1024):
                            file.write(chunk)
                        file.flush();os.fsync(file.fileno())
        if target.stat().st_size!=length or not zipfile.is_zipfile(target):
            raise UpstreamError('incomplete or invalid full-history archive')
        digest=checksum(target)
        final=self.store.root/'raw'/f'{table}-{digest}.zip'
        target.replace(final)
        manifest={'dataset':table,'source':'Sharadar','endpoint':BASE+'/data/'+table,
            'history':'full','downloaded_at':now(),'sha256':digest,'bytes':length,
            'etag':identity['etag'],'path':str(final.relative_to(self.store.root)),
            'scope':'verified_full_bulk'}
        temporary=raw_manifest.with_suffix('.tmp')
        temporary.write_text(json.dumps(manifest,sort_keys=True));temporary.replace(raw_manifest)
        result=self.store.ingest(table,final,scope='verified_full_bulk')
        return result

    @serialized_job
    @disposable_sync_stage
    def sync(self,table,quarters=3,overlap_days=14):
        states={s['dataset']:s for s in self.store.status()}
        state=states.get(table)
        if not state or not state['backfill_complete']:
            raise UpstreamError('validated full backfill required before daily sync')
        contract=self.store.contract(table)
        columns=dict(contract.columns)
        if table in ('descriptions','tickers'):
            # Investor rows have NULL lastupdated: a timestamp filter silently
            # loses new/renamed investors. These small metadata snapshots need
            # full UPSERT refresh, not historical fact-table redownloads.
            # Ingestion still UPSERTs; disappearance is never interpreted as delete.
            return self.backfill(table,refresh=True)
        # String-heavy CSV endpoints currently fail to escape some issuer
        # names. Use JSON there. Numeric tables permit complete unpaginated
        # 100k-row CSV extracts; full responses are recursively partitioned,
        # NEVER treated as proof that the requested scope is complete.
        numeric_tables={'stocks','funds','daily','holdings','metrics'}
        response_format=os.environ.get('FACT_OS_SYNC_FORMAT') or ('csv' if table in numeric_tables else 'json')
        if response_format not in ('csv','json'):raise ValueError('sync format must be csv or json')
        # Historical price adjustments can touch millions of old rows. The
        # native API's 100k price responses stall even when a 10k request for
        # the SAME scope succeeds. Keep price responses small and recursively
        # split every full response; a smaller limit is never a coverage cap.
        default_size=10000 if response_format=='json' or table in ('stocks','funds','daily') else 100000
        page_size=max(1,min(default_size,int(os.environ.get('FACT_OS_SYNC_PAGE_SIZE',str(default_size)))))
        params={'format':response_format,'limit':page_size,'from':'1900-01-01','to':date.today().isoformat()}
        if table in ('tickers','descriptions'):
            # from/to refer to lastpricedate, not publication or updated date;
            # filtering them would drop unpriced securities/investor identities.
            params.pop('from');params.pop('to')
        if 'lastupdated' in columns and state['watermark']:
            params['lastupdated.gte']=(date.fromisoformat(str(state['watermark']))-timedelta(days=overlap_days)).isoformat()
            params['lastupdated.lte']=date.today().isoformat()
            # Completeness uses bounded SETS, not updated-time OFFSET pages.
            # Forced lastupdated ordering timed out in live early-price probes;
            # default ordering returned the same complete set. Every complete
            # leaf is key-sorted, hashed and fetched again before publication.
        elif table.startswith('holdings'):
            if not 1<=quarters<=12: raise ValueError('quarters must be between 1 and 12')
            last=date.fromisoformat(str(state['max_date']))
            index=last.year*4+(last.month-1)//3-(quarters-1)
            year,q=divmod(index,4)
            # Start of earliest refreshed quarter includes the complete quarter.
            params['from']=date(year,q*3+1,1).isoformat()
            params['sort']='date.asc'
        elif table not in ('tickers','descriptions') and state['max_date']:
            anchor=min(date.fromisoformat(str(state['max_date'])),date.today())
            params['from']=(anchor-timedelta(days=overlap_days)).isoformat()
            if table in ('actions','sp500','events'):
                # Effective dates may be announced ahead of today. Preserve
                # these observations without pretending they have a known PIT
                # publication time. Their future dates must not skip today.
                # The native endpoint silently returns an empty set for year
                # 9999. Use a bounded announcement horizon; a previously stored
                # future observation is always included in the refresh.
                params['to']=max(date.today()+timedelta(days=366),
                    date.fromisoformat(str(state['max_date']))).isoformat()
        # Broad native queries silently clip a >5-year date range. Disjoint
        # four-year windows retain older revised records, including AR/MR data
        # and dividend/split adjustments to historical prices.
        # DAILY has a tighter implicit native query horizon than SF1/prices:
        # a four-year request can silently return only its last year, below the
        # requested limit. Split that table into calendar years BEFORE fetching.
        windows=bounded_date_windows(params['from'],params['to'],years=1 if table=='daily' else 4)
        if table in ('stocks','funds'):
            # Daily adjustments revise decades of prices. Start with small
            # windows over stored history rather than timing out at every
            # saturated 4y/2y/1y parent. Earlier dates remain fully covered;
            # local min_date controls granularity, NEVER the history cutoff.
            windows=price_date_windows(params['from'],params['to'],state['min_date'])
        if table.startswith('holdings'):
            # Quarterly facts can only occur at quarter ends. Begin with these
            # exact days instead of repeatedly bisecting long empty intervals.
            first=date.fromisoformat(params['from']);last=date.fromisoformat(params['to'])
            windows=[(d.isoformat(),d.isoformat()) for year in range(first.year,last.year+1)
                for month,day in ((3,31),(6,30),(9,30),(12,31))
                if first <= (d:=date(year,month,day)) <= last]
        # Staged complete extracts are not visible until ALL scopes validate.
        dest=self.store.root/'staging'/f'{table}-sync-{uuid.uuid4().hex}.csv'
        self._sync_stage=dest
        queries=[]
        def page_rows(response,fmt,fields,limit):
            if fmt=='csv':
                reader=csv.DictReader(io.StringIO(response.text.lstrip('\ufeff')))
                if not reader.fieldnames or set(reader.fieldnames)!=set(fields):
                    raise UpstreamError('query CSV schema drift')
                rows=list(reader)
            else:
                payload=response.json()
                rows=payload.get('data') if isinstance(payload,dict) else None
                if not isinstance(rows,list):raise UpstreamError('unexpected upstream response')
                if payload.get('count',len(rows))!=len(rows):raise UpstreamError('query count mismatch')
            if len(rows)>limit:raise UpstreamError('query exceeded requested page size')
            for row in rows:
                if set(row)!=set(fields):raise UpstreamError('query schema drift')
            return rows
        from .extract import complete_queries, canonical_rows_hash, ExtractionError, SplitQueryRequired
        def request(dataset,query,fields,*,split_read_timeout=False):
            for attempt in range(4):
                retry_after=0
                try:
                    if self.progress and os.environ.get('FACT_OS_SYNC_TRACE')=='1':
                        # Only public query bounds, never headers, URLs or keys.
                        self.progress({'phase':'query_start','dataset':dataset,'attempt':attempt+1,
                            'scope':{key:query[key] for key in ('from','to','ticker','ticker.gt','ticker.lte',
                                'format','limit','fields','sort') if key in query}})
                    started=time.monotonic()
                    with self.http.stream('GET',BASE+'/data/'+dataset,params=query) as upstream:
                        if upstream.status_code==200:
                            chunks=[];received=0
                            for chunk in upstream.iter_bytes():
                                if time.monotonic()-started>120:
                                    raise UpstreamError('query exceeded its total time budget; local history retained')
                                received+=len(chunk)
                                if received>128*1024*1024:
                                    raise UpstreamError('query exceeded its bounded response size; local history retained')
                                chunks.append(chunk)
                            # iter_bytes already decoded transport compression.
                            # Do not copy Content-Encoding and decompress twice.
                            response=httpx.Response(200,content=b''.join(chunks))
                        else:
                            response=httpx.Response(upstream.status_code)
                            try: retry_after=min(60,max(0,float(upstream.headers.get('retry-after','0'))))
                            except ValueError: retry_after=0
                    if response.status_code==200:
                        rows=page_rows(response,query['format'],fields,query['limit'])
                        allowed=set(query['ticker'].split(',')) if 'ticker' in query else None
                        for row in rows:
                            if 'date' in row and not query['from']<=str(row['date'])<=query['to']:
                                raise UpstreamError('query returned a record outside its date window')
                            if allowed is not None and row.get('ticker') not in allowed:
                                raise UpstreamError('query returned a ticker outside its requested scope')
                            ticker=row.get('ticker')
                            for operator,predicate in (
                                    ('gt',lambda a,b:a>b),('gte',lambda a,b:a>=b),
                                    ('lt',lambda a,b:a<b),('lte',lambda a,b:a<=b)):
                                bound=query.get('ticker.'+operator)
                                if bound is not None and (not isinstance(ticker,str) or not predicate(ticker,bound)):
                                    raise UpstreamError('query returned a ticker outside its requested range')
                            if 'lastupdated' in row and 'lastupdated.gte' in query:
                                if not query['lastupdated.gte']<=str(row['lastupdated'])<=query['lastupdated.lte']:
                                    raise UpstreamError('query returned a record outside its update window')
                        return rows
                    if response.status_code not in (429,500,502,503,504) or attempt==3:
                        raise UpstreamError(f'sync HTTP {response.status_code}; local history retained')
                except httpx.ReadTimeout:
                    # Some otherwise valid historical windows time out even
                    # at small limits. Retry those as two disjoint date scopes
                    # instead of repeatedly issuing the same slow query. Only
                    # extraction can handle this signal; a verification timeout
                    # still aborts publication. Never turn a timeout into [].
                    if split_read_timeout and query['from']<query['to']:
                        raise SplitQueryRequired('historical query timed out; split its date range') from None
                    if attempt==3:raise UpstreamError('sync read timeout; local history retained') from None
                except httpx.TransportError:
                    if attempt==3:raise UpstreamError('sync transport failed; local history retained') from None
                time.sleep(max(retry_after,min(8,2**attempt))+random.uniform(0,.5))
            raise UpstreamError('sync retry limit reached')
        checkpoint_dir=self.store.root/'sync/extract-checkpoints'/table
        checkpoint_dir.mkdir(parents=True,exist_ok=True)
        # Checkpoints resume ONE interrupted extraction, not every future run
        # of the same historical leaf. SF3 has no lastupdated filter, so an old
        # leaf otherwise makes each legitimate revision fail one retry at a
        # time. Keep prior checkpoints intact for diagnostics; never touch raw.
        attempt_path=checkpoint_dir/'attempt.json'
        context={'query':params,'schema':contract.digest,'lastSuccess':state.get('last_success')}
        attempt=json.loads(attempt_path.read_text()) if attempt_path.exists() else None
        if not attempt or attempt.get('context')!=context:
            attempt={'context':context,'id':uuid.uuid4().hex}
            Store._atomic_if_changed(attempt_path,json.dumps(attempt,sort_keys=True))
        attempt_id=attempt['id']
        def checkpoint_path(query):
            identity=hashlib.sha256(json.dumps({'query':query,'schema':contract.digest,'attempt':attempt_id},sort_keys=True).encode()).hexdigest()
            return checkpoint_dir/(identity+'.json.gz')
        def fetch(query):
            checkpoint=checkpoint_path(query)
            if checkpoint.exists():
                value=json.loads(gzip.decompress(checkpoint.read_bytes()))
                if value['schema']!=contract.digest or value['query']!=query or canonical_rows_hash(value['rows'],contract.keys)!=value['sha256']:
                    raise UpstreamError('extract checkpoint integrity failed; local history retained')
                return value['rows']
            rows=request(table,query,columns,split_read_timeout=True)
            # Saturated scopes are not complete and cannot become checkpoints.
            # These rows are ALWAYS re-fetched by verify() before ingestion.
            if len(rows)<query['limit']:
                payload={'schema':contract.digest,'query':query,'sha256':canonical_rows_hash(rows,contract.keys),'rows':rows}
                temporary=checkpoint.with_name(checkpoint.name+'.'+uuid.uuid4().hex+'.tmp')
                with temporary.open('wb') as stream:
                    stream.write(gzip.compress(json.dumps(payload,separators=(',',':')).encode(),mtime=0));stream.flush();os.fsync(stream.fileno())
                temporary.replace(checkpoint)
            return rows
        discoveries=[]
        def read_universe(dataset,query):
            rows=request(dataset,query,['ticker'])
            if len(rows)>=100000 or not rows or any(not row['ticker'] for row in rows):
                raise UpstreamError('cannot establish complete current ticker universe')
            return [{'ticker':ticker} for ticker in sorted({r['ticker'] for r in rows})]
        def discover(query):
            if 'ticker' not in columns:
                raise UpstreamError('single-day extract exceeds safe limit; unsupported partition key')
            # SF3A supplies the COMPLETE security universe of that quarter,
            # including new names not present in yesterday's local master.
            # Reading ticker from SF3 itself would repeat millions of holdings.
            dataset='holdings_ticker' if table=='holdings' else table
            discovery={**query,'format':'csv','limit':100000,'fields':'ticker'}
            if dataset!=table:
                discovery.pop('securitytype',None);discovery.pop('investorid',None)
            rows=read_universe(dataset,discovery)
            expected=canonical_rows_hash(rows,('ticker',))
            if canonical_rows_hash(read_universe(dataset,discovery),('ticker',))!=expected:
                raise UpstreamError('ticker universe changed during sync; local history retained')
            discoveries.append((dataset,discovery,expected))
            return [r['ticker'] for r in rows]
        workers=max(1,min(3,int(os.environ.get('FACT_OS_SYNC_WORKERS','3'))))
        last_progress=time.monotonic()
        def progress(phase,total):
            nonlocal last_progress
            if self.progress and time.monotonic()-last_progress>=30:
                self.progress({'phase':phase,'dataset':table,'complete_queries':len(queries),'input_rows':total})
                last_progress=time.monotonic()
        with dest.open('w',newline='') as file:
            writer=csv.DictWriter(file,fieldnames=list(columns));writer.writeheader()
            total=0
            try:
                for query,rows in complete_queries(params,fetch,page_size,discover,
                        workers=workers,date_windows=windows,
                        ticker_ranges=table in ('holdings','holdings_ticker')):
                    queries.append((query,canonical_rows_hash(rows,contract.keys)))
                    # Stable order avoids raw-file duplication when an API
                    # returns the same complete set in a different order.
                    rows.sort(key=lambda row:tuple(str(row[key]) for key in contract.keys))
                    writer.writerows({key:('\\N' if value is None else value)
                        for key,value in row.items()} for row in rows)
                    total+=len(rows);progress('complete_extracts',total)
            except ExtractionError as e:raise UpstreamError(str(e)) from None
            file.flush();os.fsync(file.fileno())
        # Verify entire leaf SETS, not unstable OFFSET pages. Ties on the one
        # vendor sort field may reorder records without representing a change.
        def verify(entry):
            query,expected=entry
            observed=canonical_rows_hash(request(table,query,columns),contract.keys)
            if observed!=expected:
                # Every leaf belongs to the invalidated snapshot, including
                # leaves not reached by verification. The next attempt must
                # fetch a coherent new set, then pass the same strict gate.
                Store._atomic_if_changed(attempt_path,json.dumps(
                    {'context':context,'id':uuid.uuid4().hex,'invalidatedAttempt':attempt_id},sort_keys=True))
                scope={key:query[key] for key in ('from','to','ticker','ticker.gt','ticker.lte') if key in query}
                raise UpstreamError('upstream changed during sync; local history retained: '+
                    json.dumps({'table':table,'scope':scope,'expected':expected[:12],'observed':observed[:12]},sort_keys=True))
        with ThreadPoolExecutor(max_workers=workers) as pool:
            for start in range(0,len(queries),workers):
                list(pool.map(verify,queries[start:start+workers]));progress('verify_extracts',total)
        # New symbols appearing after discovery must not fall outside every
        # leaf and nevertheless allow this run to advance its watermark.
        for dataset,query,expected in discoveries:
            if canonical_rows_hash(read_universe(dataset,query),('ticker',))!=expected:
                raise UpstreamError('ticker universe changed during sync; local history retained')
        if total==0:
            # An empty response cannot truncate local data or advance a watermark.
            dest.unlink() # disposable empty response, not historical data
            with self.store.writer() as db:
                db.execute('UPDATE sync_state SET last_success=?,last_error=NULL WHERE dataset=?',[now(),table])
            return {'dataset':table,'status':'no_rows','watermark_advanced':False}
        # Partition boundaries can shift as the end date advances. Normalize
        # the combined extract globally so identical data has one raw object,
        # regardless of how the provider ordered rows or we subdivided it.
        from .store import literal
        from .contracts import ident
        with tempfile.TemporaryDirectory(dir=self.store.root/'staging',prefix='normalize-') as temporary:
            ordered=Path(temporary)/'ordered.csv'
            with duckdb.connect(':memory:') as db:
                db.execute("SET memory_limit='512MB'; SET threads=2; SET enable_progress_bar=false")
                db.execute('SET temp_directory='+literal(Path(temporary)/'spill'))
                db.execute('COPY (SELECT * FROM read_csv('+literal(dest)+
                    ",header=true,all_varchar=true,nullstr='\\N') ORDER BY "+
                    ','.join(ident(key) for key in contract.keys)+') TO '+literal(ordered)+
                    " (FORMAT CSV,HEADER true,NULL '\\N')")
            ordered.replace(dest)
        digest=checksum(dest)
        canonical=self.store.root/'raw'/f'{table}-sync-{digest}.csv'
        if canonical.exists():dest.unlink()
        else:dest.replace(canonical)
        result=self.store.ingest(table,canonical,scope='incremental')
        result.update({'verified_complete_queries':len(queries),'date_windows':len(windows)})
        return result
