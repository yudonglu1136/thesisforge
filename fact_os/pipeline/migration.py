"""Audited authority handoff; no user database or credentials enter the bundle."""
import json
from pathlib import Path
import shutil
from ..store import Store,checksum,now
from ..contracts import ident
from .contracts import digest,encode
from .cli import ingestion_lock

METADATA=('partitions','sync_state','ingest_runs','contracts','remote_access','quality_summary','partition_checksums','source_change_events')


def export_authority(store):
    with ingestion_lock(store),store.writer() as db:
        store._publish_manifest(db)
        tables={}
        for table in METADATA:
            cur=db.execute('SELECT * FROM '+ident(table))
            tables[table]={'columns':[column[0] for column in cur.description],
                          'rows':[[str(v) if hasattr(v,'isoformat') else v for v in row] for row in cur.fetchall()]}
        files=[]
        for name in ('raw','parquet','manifests'):
            for file in sorted((store.root/name).rglob('*')):
                if file.is_symlink(): raise ValueError('authority_symlink_not_allowed')
                if not file.is_file():continue
                if file.name.endswith(('.tmp','.part')):continue
                files.append({'path':str(file.relative_to(store.root)),'sha256':checksum(file),'bytes':file.stat().st_size})
        total=sum(f['bytes'] for f in files)
        core={'schemaVersion':1,'metadata':tables,'files':files,'bytes':total,'privateDataExcluded':True}
        payload={**core,'migrationId':digest(core),'exportedAt':now(),
                 'capacity':{'sourceFreeBytes':shutil.disk_usage(store.root).free,'targetMinimumFreeBytes':max(total*3,40*1024**3)}}
        directory=store.root/'audit/authority-transfer';directory.mkdir(parents=True,exist_ok=True)
        file=directory/(payload['migrationId']+'.json')
        Store._atomic_if_changed(file,encode(payload).decode())
        return file,payload


def restore_metadata(store,manifest):
    if manifest.get('schemaVersion')!=1 or manifest.get('privateDataExcluded') is not True: raise ValueError('migration_schema_invalid')
    core={key:manifest[key] for key in ('schemaVersion','metadata','files','bytes','privateDataExcluded')}
    if digest(core)!=manifest['migrationId']: raise ValueError('migration_identity_invalid')
    if set(manifest['metadata'])!=set(METADATA): raise ValueError('migration_metadata_allowlist')
    for entry in manifest['files']:
        relative=Path(entry['path']);file=(store.root/relative).resolve()
        if relative.parts[0] not in ('raw','parquet','manifests') or not file.is_relative_to(store.root): raise ValueError('migration_path_escape')
        if file.stat().st_size!=entry['bytes'] or checksum(file)!=entry['sha256']: raise ValueError('migration_file_mismatch')
    receipt=store.root/'sync/authority-import.json'
    with ingestion_lock(store),store.writer() as db:
        if receipt.exists():
            if json.loads(receipt.read_text())['migrationId']!=manifest['migrationId']: raise ValueError('authority_already_initialized')
            return {'status':'already_imported','migrationId':manifest['migrationId']}
        # Resume after commit/receipt crash only if all metadata is identical.
        db.execute('BEGIN TRANSACTION')
        try:
            for table,data in manifest['metadata'].items():
                columns=[r[1] for r in db.execute('PRAGMA table_info('+ident(table)+')').fetchall()]
                if columns!=data['columns']: raise ValueError('migration_metadata_schema_mismatch')
                if db.execute('SELECT count(*) FROM '+ident(table)).fetchone()[0]:
                    old=[[str(v) if hasattr(v,'isoformat') else v for v in row] for row in db.execute('SELECT * FROM '+ident(table)).fetchall()]
                    if sorted(map(encode,old))!=sorted(map(encode,data['rows'])): raise ValueError('authority_target_not_empty')
                elif data['rows']:
                    db.executemany('INSERT INTO '+ident(table)+' VALUES ('+','.join('?' for _ in columns)+')',data['rows'])
            db.execute('COMMIT')
        except BaseException:
            db.execute('ROLLBACK');raise
        Store._atomic_if_changed(receipt,encode({'migrationId':manifest['migrationId'],'importedAt':now(),'filesVerified':len(manifest['files'])}).decode())
    return {'status':'imported','migrationId':manifest['migrationId']}
