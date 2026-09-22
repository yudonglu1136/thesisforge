"""Freeze a catalog using hardlinks, not a database copy. Retained pins fence GC."""
import json
import os
from pathlib import Path
from ..store import checksum, Store
from .contracts import InputSnapshot, digest, encode, record


def freeze(store, *, code_version, configs=None):
    # writer first, then catalog recovery/publication. Never copy writer views.
    with store.writer() as db:
        store._publish_manifest(db)
        catalog_path=store.root/'manifests/catalog.json'
        payload=catalog_path.read_bytes()
        catalog=json.loads(payload)
        snapshot_id=digest({'catalog':checksum(catalog_path),'config':configs or {},'code':code_version})
        root=store.root/'snapshots'/snapshot_id
        root.mkdir(parents=True,exist_ok=True)
        from .registry import PROJECT
        for task_configs in (configs or {}).values():
            for relative,expected in task_configs.items():
                source=(PROJECT/relative).resolve()
                if not source.is_relative_to(PROJECT) or checksum(source)!=expected:raise ValueError('frozen_config_changed')
                target=root/'config'/relative;target.parent.mkdir(parents=True,exist_ok=True)
                Store._atomic_if_changed(target,source.read_text())
        inputs={}
        for name,item in catalog['datasets'].items():
            state=item.get('state') or {}
            parts=item.get('partitions',[])
            inputs[name]={'contentVersion':item['contentVersion'],'schema':digest(item['ddl']),
                'status':'ready' if state.get('backfill_complete') and parts else 'incomplete',
                'partitions':parts,'sourceAsOf':state.get('max_date'),'coverage':state}
            for part in parts:
                relative=Path(part['path']); source=(store.root/relative).resolve()
                if relative.is_absolute() or not source.is_relative_to(store.root/'parquet'):
                    raise ValueError('snapshot_partition_escape')
                target=root/relative
                target.parent.mkdir(parents=True,exist_ok=True)
                if not target.exists(): os.link(source,target)
                if target.stat().st_size!=part['bytes']: raise ValueError('snapshot_size_mismatch')
        (root/'manifests').mkdir(exist_ok=True)
        Store._atomic_if_changed(root/'manifests/catalog.json',payload.decode())
        snapshot=InputSnapshot(snapshot_id,str(root),{k:v['schema'] for k,v in inputs.items()},inputs,configs or {},code_version)
        Store._atomic_if_changed(root/'snapshot.json',encode(record(snapshot)).decode())
        pins=store.root/'sync/snapshot-pins'
        pins.mkdir(exist_ok=True)
        Store._atomic_if_changed(pins/(snapshot_id+'.json'),encode({'snapshotId':snapshot_id,
            'reason':'pipeline-replay-and-rollback','paths':[p['path'] for i in inputs.values() for p in i['partitions']]}).decode())
    return snapshot


def load(root):
    root=Path(root).resolve()
    value=json.loads((root/'snapshot.json').read_text())
    # The original worker absolute path is operational, not input identity.
    value['root']=str(root)
    return InputSnapshot(**value)
