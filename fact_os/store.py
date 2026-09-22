"""Single-writer immutable Parquet partitions with transactional manifest publication.

Replacing a partition means UNION/UPSERT of old + new keys, never replacing local
history with a remote window. Old generations remain available for rollback.
"""
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import uuid
import zipfile

import duckdb
from .contracts import Contract, ident

def now():
    return datetime.now(timezone.utc).isoformat()

def checksum(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as f:
        for chunk in iter(lambda:f.read(1024 * 1024), b''):
            h.update(chunk)
    return h.hexdigest()

def literal(value):
    return "'" + str(value).replace("'", "''") + "'"

class Store:
    def __init__(self, root):
        self.root = Path(root).resolve()
        for directory in ('raw', 'parquet', 'manifests', 'sync', 'staging'):
            (self.root / directory).mkdir(parents=True, exist_ok=True)
        # Licensed local facts and backup artifacts are private to this user.
        self.root.chmod(0o700)
        self.path = self.root / 'fact_os.duckdb'

    @contextmanager
    def writer(self):
        with (self.root / 'sync/writer.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            db = duckdb.connect(str(self.path))
            try:
                db.execute("SET memory_limit='2GB'; SET threads=2; SET enable_progress_bar=false")
                db.execute('SET temp_directory=' + literal(self.root / 'staging/duckdb'))
                db.execute('''CREATE TABLE IF NOT EXISTS partitions (
                    dataset VARCHAR, bucket INTEGER, path VARCHAR,
                    PRIMARY KEY(dataset,bucket));
                    CREATE TABLE IF NOT EXISTS sync_state (
                    dataset VARCHAR PRIMARY KEY, last_success VARCHAR,
                    watermark DATE, min_date DATE, max_date DATE, row_count BIGINT,
                    last_error VARCHAR, backfill_complete BOOLEAN DEFAULT false);
                    CREATE TABLE IF NOT EXISTS ingest_runs (
                    run_id VARCHAR PRIMARY KEY, dataset VARCHAR, checksum VARCHAR,
                    observed_at VARCHAR, source_path VARCHAR, row_count BIGINT,
                    schema_hash VARCHAR, scope VARCHAR);
                    CREATE TABLE IF NOT EXISTS contracts (
                    dataset VARCHAR PRIMARY KEY, ddl VARCHAR, schema_hash VARCHAR);
                    CREATE TABLE IF NOT EXISTS remote_access (
                    dataset VARCHAR PRIMARY KEY, checked_at VARCHAR,
                    query_status INTEGER, bulk_status INTEGER);
                    CREATE TABLE IF NOT EXISTS quality_summary (
                    dataset VARCHAR PRIMARY KEY, issue_counts VARCHAR,
                    checked_at VARCHAR);
                    CREATE TABLE IF NOT EXISTS partition_checksums (
                    path VARCHAR PRIMARY KEY, sha256 VARCHAR, bytes BIGINT);
                    CREATE TABLE IF NOT EXISTS source_change_events (
                    event_id VARCHAR PRIMARY KEY, run_id VARCHAR, dataset VARCHAR,
                    partitions VARCHAR, kind VARCHAR, status VARCHAR,
                    committed_at VARCHAR, catalog_generation VARCHAR);
                ''')
                db.execute('ALTER TABLE partition_checksums ADD COLUMN IF NOT EXISTS semantic_sha256 VARCHAR')
                yield db
                self._publish_manifest(db)
            finally:
                db.close()
                fcntl.flock(lock, fcntl.LOCK_UN)

    def _publish_manifest(self, db):
        """Readers pin an immutable Parquet generation without opening writer DB."""
        datasets = {}
        for table, ddl in db.execute('SELECT dataset,ddl FROM contracts ORDER BY dataset').fetchall():
            cur = db.execute('SELECT * FROM sync_state WHERE dataset=?', [table])
            names = [c[0] for c in cur.description]
            row = cur.fetchone()
            state = dict(zip(names,row)) if row else None
            if state:
                # Operations are observable separately, never part of fact identity.
                state = {k:v for k,v in state.items() if k not in ('last_success','last_error')}
            parts = []
            for bucket, path in db.execute('SELECT bucket,path FROM partitions WHERE dataset=? ORDER BY bucket',[table]).fetchall():
                physical = db.execute('SELECT sha256,bytes,semantic_sha256 FROM partition_checksums WHERE path=?',[path]).fetchone()
                if not physical or not physical[2]:
                    file = self.root / path
                    contract = Contract.from_ddl(table,ddl)
                    fields = ','.join(f'{ident(c)}:={ident(c)}' for c,_ in contract.columns)
                    # Order-independent source multiset digest: four independent
                    # 64-bit SHA-256 lanes summed in 128-bit accumulators + count.
                    # Neither row order nor ingestion metadata enters identity.
                    sums = ','.join(f"sum(('0x'||substr(h,{offset},16))::UBIGINT)::VARCHAR" for offset in (1,17,33,49))
                    summary = db.execute(f'SELECT count(*),{sums} FROM (SELECT sha256(to_json(struct_pack({fields}))) h FROM read_parquet({literal(file)}))').fetchone()
                    semantic = hashlib.sha256(json.dumps([contract.digest,*summary]).encode()).hexdigest()
                    physical = (checksum(file), file.stat().st_size, semantic)
                    db.execute('INSERT OR REPLACE INTO partition_checksums VALUES (?,?,?,?)',[path,*physical])
                parts.append({'bucket':bucket,'path':path,'sha256':physical[0],'bytes':physical[1],'semanticSha256':physical[2]})
            datasets[table] = {
                'ddl': ddl,
                'partitions': parts,
                'state': state,
            }
            quality = db.execute('SELECT issue_counts FROM quality_summary WHERE dataset=?',[table]).fetchone()
            datasets[table]['quality'] = json.loads(quality[0]) if quality else {}
            datasets[table]['contentVersion'] = hashlib.sha256(json.dumps({
                'schema':ddl,'algorithm':'source-sha256-multiset-v1',
                'partitions':[(p['bucket'],p['semanticSha256']) for p in parts],
                'state':state,'quality':datasets[table]['quality'],
            },sort_keys=True,default=str).encode()).hexdigest()
        payload = json.dumps({'version':1,'datasets':datasets},sort_keys=True,default=str)
        dest = self.root / 'manifests/catalog.json'
        self._atomic_if_changed(dest,payload)
        # Durable catalog first, ACK second. A crash between them is replayable.
        generation = hashlib.sha256(payload.encode()).hexdigest()
        db.execute("UPDATE source_change_events SET status='catalog_published',catalog_generation=? WHERE status='committed'",[generation])
        cur = db.execute('SELECT * FROM sync_state ORDER BY dataset')
        columns = [c[0] for c in cur.description]
        operations = [dict(zip(columns,r)) for r in cur.fetchall()]
        self._atomic_if_changed(self.root/'sync/status.json',json.dumps(operations,sort_keys=True,default=str))

    @staticmethod
    def _atomic_if_changed(dest, payload):
        if dest.exists() and dest.read_text() == payload:
            return
        temp = dest.with_name(dest.name+'-'+uuid.uuid4().hex+'.tmp')
        try:
            with temp.open('w') as f:
                f.write(payload);f.flush();os.fsync(f.fileno())
            temp.replace(dest)
            fd = os.open(dest.parent,os.O_RDONLY)
            try: os.fsync(fd)
            finally: os.close(fd)
        finally:
            temp.unlink(missing_ok=True)

    def recover_catalog(self):
        """Re-publish committed metadata after interruption; never fetch upstream."""
        with self.writer():
            pass

    def install_contract(self, table, ddl):
        contract = Contract.from_ddl(table, ddl)
        with self.writer() as db:
            old = db.execute('SELECT ddl FROM contracts WHERE dataset=?', [table]).fetchone()
            if old:
                previous = Contract.from_ddl(table, old[0])
                if previous.columns != contract.columns or previous.keys != contract.keys:
                    raise ValueError('schema drift: review migration before ingestion')
            db.execute('INSERT OR REPLACE INTO contracts VALUES (?,?,?)', [table, ddl, contract.digest])
        return contract

    def contract(self, table):
        manifest = self.root/'manifests/catalog.json'
        if manifest.exists():
            dataset = json.loads(manifest.read_text())['datasets'].get(table)
            if dataset:
                return Contract.from_ddl(table,dataset['ddl'])
        with duckdb.connect(str(self.path), read_only=True) as db:
            row = db.execute('SELECT ddl FROM contracts WHERE dataset=?', [table]).fetchone()
        if not row:
            raise ValueError('official schema not captured')
        return Contract.from_ddl(table, row[0])

    def record_error(self, table, code):
        with self.writer() as db:
            db.execute('''INSERT INTO sync_state(dataset,last_error) VALUES (?,?)
                ON CONFLICT(dataset) DO UPDATE SET last_error=excluded.last_error''', [table,code])

    def ingest(self, table, path, *, scope='archive_unverified', observed_at=None):
        contract = self.contract(table)
        path = Path(path).resolve()
        digest = checksum(path)
        run = uuid.uuid4().hex
        observed_at = observed_at or now()
        staging = self.root / 'staging' / run
        staging.mkdir()
        csv_path = path
        try:
            if zipfile.is_zipfile(path):
                with zipfile.ZipFile(path) as archive:
                    entries = [x for x in archive.infolist() if x.filename.lower().endswith('.csv')]
                    if len(entries) != 1:
                        raise ValueError('expected exactly one CSV archive member')
                    if entries[0].file_size + 5 * 1024**3 > shutil.disk_usage(self.root).free:
                        raise ValueError('insufficient disk headroom for extraction')
                    csv_path = staging / 'source.csv'
                    with archive.open(entries[0]) as src, csv_path.open('wb') as dst:
                        shutil.copyfileobj(src, dst, 1024*1024)
            with self.writer() as db:
                # A previously seen checksum is not proof of current equality:
                # the source may revise A -> B -> A. Always validate the input
                # and compare it with the currently published partitions.
                needs_repartition = 'date' not in contract.keys and db.execute(
                    'SELECT count(*) FROM partitions WHERE dataset=? AND bucket<>0',[table]).fetchone()[0]>0
                db.execute("CREATE TEMP VIEW landing AS SELECT * FROM read_csv("+literal(csv_path)+", header=true, all_varchar=true, nullstr='\\N')")
                found = [r[0] for r in db.execute('DESCRIBE landing').fetchall()]
                if set(found) != set(dict(contract.columns)):
                    raise ValueError('CSV columns differ from official contract')
                expressions = []
                for col, typ in contract.columns:
                    source = ident(col) if typ=='VARCHAR' else f"NULLIF({ident(col)},'')"
                    expressions.append(f'CAST({source} AS {typ}) AS {ident(col)}')
                db.execute('CREATE TEMP TABLE incoming AS SELECT ' + ','.join(expressions) + ' FROM landing')
                keys = ','.join(map(ident,contract.keys))
                nulls = ' OR '.join(f'{ident(k)} IS NULL' for k in contract.keys)
                if db.execute('SELECT count(*) FROM incoming WHERE '+nulls).fetchone()[0]:
                    raise ValueError('null natural key')
                if db.execute(f'SELECT count(*) FROM (SELECT {keys} FROM incoming GROUP BY {keys} HAVING count(*)>1)').fetchone()[0]:
                    raise ValueError('duplicate source natural keys; no arbitrary winner chosen')
                quality_rules = {}
                if table in ('stocks','funds'):
                    quality_rules = {f'invalid_price:{field}':f'({field} IS NULL OR {field}<=0 OR NOT isfinite({field}))'
                                     for field in ('close','closeadj','closeunadj')}
                if table=='fundamentals':
                    if db.execute("SELECT count(*) FROM incoming WHERE dimension NOT IN ('ARQ','ARY','ART','MRQ','MRY','MRT')").fetchone()[0]:
                        raise ValueError('unsupported fundamental dimension')
                    quality_rules['invalid_pit_period'] = "(dimension LIKE 'AR%' AND reportperiod>date)"
                if quality_rules:
                    # Preserve official records byte-for-value. Source anomalies
                    # are inspectable, never corrected by inventing prices/dates.
                    # Semantic readers independently reject the invalid fact.
                    invalid = ' OR '.join(quality_rules.values())
                    if scope not in ('verified_full_bulk','incremental') and db.execute(
                            'SELECT count(*) FROM incoming WHERE '+invalid).fetchone()[0]:
                        raise ValueError('invalid price' if table in ('stocks','funds') else 'future reporting period at filing date')
                    db.execute("ALTER TABLE incoming ADD COLUMN _quality_issues VARCHAR DEFAULT ''")
                    flags = ','.join(f'CASE WHEN {condition} THEN {literal(issue)} ELSE NULL END'
                                     for issue,condition in quality_rules.items())
                    db.execute("UPDATE incoming SET _quality_issues=concat_ws(';',"+flags+")")
                if table.startswith('holdings'):
                    if db.execute("SELECT count(*) FROM incoming WHERE strftime(date,'%m-%d') NOT IN ('03-31','06-30','09-30','12-31')").fetchone()[0]:
                        raise ValueError('holdings date is not a quarter end')
                count = db.execute('SELECT count(*) FROM incoming').fetchone()[0]
                if not count:
                    raise ValueError('empty ingestion cannot establish coverage')
                date_col = 'date' if 'date' in found else 'lastupdated' if 'lastupdated' in found else None
                # Partition only on an immutable natural-key component. In
                # particular tickers.lastupdated can change across years.
                bucket_expr = 'coalesce(year(date),0)' if 'date' in contract.keys else '0'
                buckets = [r[0] for r in db.execute(f'SELECT DISTINCT {bucket_expr} FROM incoming ORDER BY 1').fetchall()]
                changed_partitions = 0
                changed_buckets = []
                previous_state = db.execute('SELECT backfill_complete FROM sync_state WHERE dataset=?',[table]).fetchone()
                db.execute('BEGIN TRANSACTION')
                try:
                    for bucket in buckets:
                        existing = db.execute('SELECT path FROM partitions WHERE dataset=? AND bucket=?',[table,bucket]).fetchone()
                        all_existing = db.execute('SELECT path FROM partitions WHERE dataset=?',[table]).fetchall() if needs_repartition else []
                        if all_existing:
                            existing=all_existing[0]
                        db.execute(f'CREATE OR REPLACE TEMP TABLE chunk AS SELECT * FROM incoming WHERE {bucket_expr}=?',[bucket])
                        if existing:
                            prior_paths = '['+','.join(literal(self.root / x[0]) for x in all_existing)+']' if all_existing else literal(self.root / existing[0])
                            db.execute('CREATE OR REPLACE TEMP VIEW previous_raw AS SELECT * FROM read_parquet('+prior_paths+', union_by_name=true)')
                            previous_columns = {r[0] for r in db.execute('DESCRIBE previous_raw').fetchall()}
                            extension = ", ''::VARCHAR AS _quality_issues" if quality_rules and '_quality_issues' not in previous_columns else ''
                            db.execute('CREATE OR REPLACE TEMP VIEW previous AS SELECT *'+extension+' FROM previous_raw')
                            cols = ','.join(ident(c) for c,_ in contract.columns)
                            if quality_rules: cols += ',_quality_issues'
                            different = db.execute(f'SELECT count(*) FROM (SELECT {cols} FROM chunk EXCEPT SELECT {cols} FROM previous)').fetchone()[0]
                            if not different and not needs_repartition:
                                continue
                        folder = self.root / 'parquet' / table
                        folder.mkdir(exist_ok=True)
                        dest = folder / f'{bucket}-{run}.parquet'
                        projection = f'SELECT *, {literal(run)} AS _ingestion_run, {literal(observed_at)} AS _observed_at FROM chunk'
                        if existing:
                            equality = ' AND '.join(f'p.{ident(k)}=n.{ident(k)}' for k in contract.keys)
                            previous_projection = ','.join('p.'+ident(c) for c,_ in contract.columns)
                            if quality_rules: previous_projection += ',p._quality_issues'
                            previous_projection += ',p._ingestion_run,p._observed_at'
                            projection += f' UNION ALL SELECT {previous_projection} FROM previous p WHERE NOT EXISTS (SELECT 1 FROM chunk n WHERE {equality})'
                            # Preserve lineage for equal keys even if other rows
                            # in this same partition changed in the observation.
                            same = ' AND '.join(f'p.{ident(c)} IS NOT DISTINCT FROM n.{ident(c)}' for c,_ in contract.columns)
                            if quality_rules: same += ' AND p._quality_issues IS NOT DISTINCT FROM n._quality_issues'
                            chunk_cols = ','.join('n.'+ident(c) for c,_ in contract.columns)
                            if quality_rules: chunk_cols += ',n._quality_issues'
                            projection = (f'SELECT {chunk_cols}, CASE WHEN {same} THEN p._ingestion_run ELSE {literal(run)} END AS _ingestion_run, '
                                f'CASE WHEN {same} THEN p._observed_at ELSE {literal(observed_at)} END AS _observed_at '
                                f'FROM chunk n LEFT JOIN previous p ON {equality} UNION ALL SELECT {previous_projection} '
                                f'FROM previous p WHERE NOT EXISTS (SELECT 1 FROM chunk n WHERE {equality})')
                        db.execute('COPY ('+projection+') TO '+literal(dest)+" (FORMAT PARQUET, COMPRESSION ZSTD)")
                        if needs_repartition:
                            db.execute('DELETE FROM partitions WHERE dataset=?',[table])
                        db.execute('INSERT OR REPLACE INTO partitions VALUES (?,?,?)',[table,bucket,str(dest.relative_to(self.root))])
                        changed_partitions += 1
                        changed_buckets.append(bucket)
                    paths = [str(self.root / r[0]) for r in db.execute('SELECT path FROM partitions WHERE dataset=? ORDER BY bucket',[table]).fetchall()]
                    path_sql = '['+','.join(literal(p) for p in paths)+']'
                    db.execute(f'CREATE OR REPLACE VIEW {ident(table)} AS SELECT * FROM read_parquet({path_sql}, union_by_name=true)')
                    dates = f'min({ident(date_col)}),max({ident(date_col)})' if date_col else 'NULL,NULL'
                    watermark = 'max(lastupdated)' if 'lastupdated' in found else 'NULL'
                    lo,hi,water,rows = db.execute(f'SELECT {dates},{watermark},count(*) FROM {ident(table)}').fetchone()
                    db.execute('''INSERT INTO sync_state VALUES (?,?,?,?,?,?,NULL,?) ON CONFLICT(dataset) DO UPDATE SET
                        last_success=excluded.last_success,watermark=excluded.watermark,min_date=excluded.min_date,
                        max_date=excluded.max_date,row_count=excluded.row_count,last_error=NULL,
                        backfill_complete=sync_state.backfill_complete OR excluded.backfill_complete''',
                        [table,now(),water,lo,hi,rows,scope=='verified_full_bulk'])
                    # Each validated observation gets an audit receipt, even
                    # when facts are unchanged. A no-op receipt never rewrites
                    # Parquet or replaces canonical row _ingestion_run values.
                    db.execute('INSERT INTO ingest_runs VALUES (?,?,?,?,?,?,?,?)',[run,table,digest,observed_at,str(path),count,contract.digest,scope])
                    quality = {issue:db.execute(f'SELECT count(*) FROM {ident(table)} WHERE {condition}').fetchone()[0]
                               for issue,condition in quality_rules.items()}
                    db.execute('INSERT OR REPLACE INTO quality_summary VALUES (?,?,?)',[table,json.dumps(quality),now()])
                    promoted = scope=='verified_full_bulk' and not (previous_state and previous_state[0])
                    if changed_partitions or promoted:
                        db.execute('INSERT INTO source_change_events VALUES (?,?,?,?,?,?,?,NULL)',
                            [run,run,table,json.dumps(changed_buckets),'content' if changed_partitions else 'coverage', 'committed',now()])
                    db.execute('COMMIT')
                    return {'dataset':table,'status':'ingested' if changed_partitions else 'unchanged','input_rows':count,'local_rows':rows,'min_date':str(lo),'max_date':str(hi),'run_id':run,'quality':quality}
                except BaseException:
                    db.execute('ROLLBACK')
                    raise
        finally:
            # Only the explicitly created, disposable extraction is removed.
            extracted = staging / 'source.csv'
            if extracted.exists():
                extracted.unlink()
            staging.rmdir()

    def status(self):
        operations=self.root/'sync/status.json'
        if operations.exists():
            return json.loads(operations.read_text())
        catalog=self.root/'manifests/catalog.json'
        if catalog.exists():
            return [v['state'] for _,v in sorted(json.loads(catalog.read_text())['datasets'].items()) if v.get('state')]
        with self.writer() as db:
            cur = db.execute('SELECT * FROM sync_state ORDER BY dataset')
            return [dict(zip([c[0] for c in cur.description],r)) for r in cur.fetchall()]
