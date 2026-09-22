"""Operational state in the existing metadata DuckDB; no network in transactions."""
import json
from ..store import now
from .contracts import encode


class Ledger:
    def __init__(self,store):
        self.store=store
        with store.writer() as db:
            db.execute('''CREATE TABLE IF NOT EXISTS pipeline_runs(
              run_id VARCHAR PRIMARY KEY, profile VARCHAR, scheduled_for VARCHAR,
              snapshot_id VARCHAR, status VARCHAR, publication_status VARCHAR,
              started_at VARCHAR, updated_at VARCHAR, receipt VARCHAR);
              CREATE TABLE IF NOT EXISTS pipeline_tasks(
              task_id VARCHAR,input_fingerprint VARCHAR,status VARCHAR,attempt INTEGER,
              run_id VARCHAR,result VARCHAR,updated_at VARCHAR,
              PRIMARY KEY(task_id,input_fingerprint));
              CREATE TABLE IF NOT EXISTS publication_attempts(
              run_id VARCHAR,group_id VARCHAR,generation_id VARCHAR,status VARCHAR,
              receipt VARCHAR,updated_at VARCHAR,PRIMARY KEY(run_id,group_id));''')
            db.execute('''CREATE TABLE IF NOT EXISTS pipeline_source_events(
              event_id VARCHAR,run_id VARCHAR,snapshot_id VARCHAR,status VARCHAR,
              PRIMARY KEY(event_id,run_id));''')

    def existing_run(self,run_id):
        with self.store.writer() as db:
            row=db.execute('SELECT snapshot_id FROM pipeline_runs WHERE run_id=?',[run_id]).fetchone()
            return row[0] if row else None

    def record_events(self,run_id,snapshot_id,status):
        with self.store.writer() as db:
            if status=='planned':
                db.execute('''INSERT OR IGNORE INTO pipeline_source_events
                    SELECT event_id,?,?,? FROM source_change_events
                    WHERE status='catalog_published' AND event_id NOT IN
                    (SELECT event_id FROM pipeline_source_events WHERE status='succeeded')''',
                    [run_id,snapshot_id,status])
            else:
                db.execute('UPDATE pipeline_source_events SET status=? WHERE run_id=?',[status,run_id])

    def publication(self,receipt,status,details):
        with self.store.writer() as db:
            for group,item in receipt.get('groups',{}).items():
                db.execute('''INSERT INTO publication_attempts VALUES (?,?,?,?,?,?)
                    ON CONFLICT(run_id,group_id) DO UPDATE SET status=excluded.status,
                    receipt=excluded.receipt,updated_at=excluded.updated_at''',
                    [receipt['runId'],group,item['generationId'],status,encode(details).decode(),now()])
            db.execute('UPDATE pipeline_runs SET publication_status=?,updated_at=? WHERE run_id=?',
                       [status,now(),receipt['runId']])

    def results(self):
        with self.store.writer() as db:
            return {(task,fp):json.loads(result) for task,fp,result in db.execute(
                "SELECT task_id,input_fingerprint,result FROM pipeline_tasks WHERE status='succeeded'").fetchall() if result}

    def run(self,run_id,profile,scheduled_for,snapshot_id,status,receipt=None):
        with self.store.writer() as db:
            db.execute('''INSERT INTO pipeline_runs VALUES (?,?,?,?,?,'pending',?,?,?)
                ON CONFLICT(run_id) DO UPDATE SET status=excluded.status,updated_at=excluded.updated_at,receipt=excluded.receipt''',
                [run_id,profile,scheduled_for,snapshot_id,status,now(),now(),encode(receipt).decode() if receipt else None])

    def task(self,run_id,task_id,fingerprint,status,result=None):
        with self.store.writer() as db:
            db.execute('''INSERT INTO pipeline_tasks VALUES (?,?,?,1,?,?,?)
                ON CONFLICT(task_id,input_fingerprint) DO UPDATE SET status=excluded.status,
                attempt=pipeline_tasks.attempt+CASE WHEN excluded.status='running' THEN 1 ELSE 0 END,
                run_id=excluded.run_id,result=excluded.result,updated_at=excluded.updated_at''',
                [task_id,fingerprint,status,run_id,encode(result).decode() if result else None,now()])

    def status(self):
        with self.store.writer() as db:
            cur=db.execute('SELECT * FROM pipeline_runs ORDER BY started_at DESC LIMIT 30')
            columns=[x[0] for x in cur.description]
            return [dict(zip(columns,row)) for row in cur.fetchall()]
