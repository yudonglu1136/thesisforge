import json
from pathlib import Path
from ..store import checksum
from ..contracts import TABLES


def validate_api_read(value):
    """Actual API-user probe must demonstrate coverage and useful company data."""
    responses=value.get('result',[])
    if not value.get('ok') or len(responses)!=2 or any(not r.get('ok') for r in responses):
        raise ValueError('actual_api_uid_read_failed')
    coverage={row.get('dataset'):row for row in responses[0].get('result',[])}
    if any(not coverage.get(table,{}).get('locally_available') or
           not coverage.get(table,{}).get('backfill_complete') for table in TABLES):
        raise ValueError('actual_api_coverage_incomplete')
    if not responses[1].get('result',{}).get('companies'):
        raise ValueError('actual_api_company_index_empty')
    return True


def file_record(path,root):
    path,root=Path(path).resolve(),Path(root).resolve()
    if not path.is_relative_to(root) or not path.is_file(): raise ValueError('artifact_path_invalid')
    return {'path':str(path.relative_to(root)),'sha256':checksum(path),'bytes':path.stat().st_size}


def verify_files(root,files):
    root=Path(root).resolve()
    if not files: raise ValueError('empty_artifact')
    for item in files:
        path=(root/item['path']).resolve()
        if not path.is_relative_to(root) or path.is_symlink() or not path.is_file(): raise ValueError('artifact_file_missing_or_escape')
        if path.stat().st_size!=item['bytes'] or checksum(path)!=item['sha256']: raise ValueError('artifact_checksum_mismatch')


def validate_canonical(root,required):
    root=Path(root)
    catalog=json.loads((root/'manifests/catalog.json').read_text())
    if catalog.get('version')!=1: raise ValueError('canonical_schema_unsupported')
    for table in required:
        item=catalog.get('datasets',{}).get(table,{})
        if not item.get('state',{}).get('backfill_complete') or not item.get('partitions'):
            raise ValueError('canonical_required_incomplete:'+table)
    # No ignored missing partitions even for optional catalog entries.
    files=[p for item in catalog['datasets'].values() for p in item['partitions']]
    verify_files(root,files)
    from ..repository import FactRepository
    with FactRepository(root) as repo:
        coverage=repo.get_coverage()
    return {'schema':'pass','physicalChecksums':'pass','repositoryOpen':'pass','coverage':coverage}
