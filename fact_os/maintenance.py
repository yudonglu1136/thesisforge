"""Reclaim obsolete derived generations; raw vendor history is never deleted."""
from collections import defaultdict
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import time

from .contracts import TABLES
from .store import Store, now

HEX64 = re.compile(r'^[a-f0-9]{64}$')
SAFE_DIR_NAME = re.compile(r'^[A-Za-z0-9._\-]{1,128}$')


def _tree_stats_and_verify_no_symlinks(target, allowed_parent):
    allowed = Path(allowed_parent).resolve()
    resolved = Path(target).resolve()
    if Path(target).is_symlink() or resolved == allowed or not resolved.is_relative_to(allowed):
        raise ValueError('unsafe_retention_target')
    files = []
    dirs = []
    logical_bytes = 0
    for base, subdirs, names in os.walk(resolved, followlinks=False):
        base_path = Path(base)
        for name in subdirs:
            sub = base_path / name
            if sub.is_symlink():
                raise ValueError('symlink_in_retention_target')
            dirs.append(sub)
        for name in names:
            item = base_path / name
            if item.is_symlink():
                raise ValueError('symlink_in_retention_target')
            stat = item.stat()
            logical_bytes += stat.st_size
            files.append(item)
    return files, dirs, logical_bytes


def _safe_remove_tree(target, allowed_parent):
    files, dirs, logical_bytes = _tree_stats_and_verify_no_symlinks(target, allowed_parent)
    resolved = Path(target).resolve()
    resolved.chmod(resolved.stat().st_mode | 0o700)
    for directory in dirs:
        directory.chmod(directory.stat().st_mode | 0o700)
    for item in files:
        item.chmod(item.stat().st_mode | 0o200)
        item.unlink()
    for directory in sorted(dirs, key=lambda p: len(p.parts), reverse=True):
        directory.rmdir()
    resolved.parent.chmod(resolved.parent.stat().st_mode | 0o200)
    resolved.rmdir()
    return len(files), logical_bytes


def _newest_mtime(directory):
    latest = directory.stat().st_mtime
    for base, _, names in os.walk(directory, followlinks=False):
        base_path = Path(base)
        for name in names:
            item = base_path / name
            if not item.is_symlink():
                try:
                    latest = max(latest, item.stat().st_mtime)
                except FileNotFoundError:
                    continue
    return latest


def _collect_unreferenced_locked(store, db, *, retention_days=7, apply=False, excluded_pins=()):
    excluded = {Path(p).resolve() for p in excluded_pins}
    referenced = {str(p) for (p,) in db.execute('SELECT path FROM partitions').fetchall()}
    # Pipeline/rollback/saved-research pins outlive an individual RPC.
    # Invalid pins fail closed; never guess that a broken reference is unused.
    for pin in (store.root / 'sync/snapshot-pins').glob('*.json'):
        if pin.resolve() in excluded:
            continue
        value = json.loads(pin.read_text())
        if not isinstance(value.get('paths'), list):
            raise ValueError('invalid_snapshot_pin')
        referenced.update(value['paths'])
    groups = defaultdict(list)
    for table in TABLES:
        directory = store.root / 'parquet' / table
        if not directory.is_dir() or directory.is_symlink():
            continue
        for path in directory.glob('*.parquet'):
            match = re.fullmatch(r'(\d+)-[a-f0-9]{32}\.parquet', path.name)
            if not match or path.is_symlink() or not path.is_file():
                continue
            groups[(table, match[1])].append(path)
    cutoff = time.time() - retention_days * 86400
    candidates = []
    for files in groups.values():
        files.sort(key=lambda p: p.stat().st_mtime, reverse=True)
        # Keep at least two generations even after retention expires.
        for path in files[2:]:
            relative = str(path.relative_to(store.root))
            stat = path.stat()
            if relative not in referenced and stat.st_mtime < cutoff:
                candidates.append({'path': relative, 'bytes': stat.st_size})
    if apply:
        for entry in candidates:
            (store.root / entry['path']).unlink()
    return {
        'status': 'collected' if apply else 'dry_run',
        'deleted_files': len(candidates) if apply else 0,
        'reclaimable_bytes': sum(item['bytes'] for item in candidates),
        'raw_history_preserved': True,
        'candidates': candidates,
    }


def collect_unreferenced(store, *, retention_days=7, apply=False):
    if retention_days < 1:
        raise ValueError('at least one day of rollback retention is required')
    # Writer excludes a concurrent commit; reader lease excludes older pinned
    # catalogs. No active reader can lose a Parquet file during its query.
    (store.root / 'sync').mkdir(parents=True, exist_ok=True)
    with store.writer() as db, (store.root / 'sync/readers.lock').open('a') as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {'status': 'readers_active', 'deleted_files': 0, 'candidates': []}
        try:
            return _collect_unreferenced_locked(store, db, retention_days=retention_days, apply=apply)
        finally:
            fcntl.flock(lease, fcntl.LOCK_UN)


def _protected_run_references(store, db, *, min_runs):
    protected_snapshots = set()
    protected_derived = set()
    protected_generations = set()
    receipts = []

    latest_path = store.root / 'audit/pipeline/latest.json'
    if latest_path.is_file() and not latest_path.is_symlink():
        try:
            receipts.append(json.loads(latest_path.read_text()))
        except Exception:
            pass

    has_runs = False
    try:
        row = db.execute(
            "SELECT count(*) FROM information_schema.tables WHERE table_name='pipeline_runs'"
        ).fetchone()
        has_runs = bool(row and row[0])
    except Exception:
        has_runs = False

    if has_runs:
        queries = (
            "SELECT snapshot_id, receipt FROM pipeline_runs "
            "WHERE status='running' OR publication_status IN ('uploading','installing')",
            f"SELECT snapshot_id, receipt FROM pipeline_runs "
            f"WHERE publication_status IN ('verified','staged_not_activated') "
            f"ORDER BY COALESCE(updated_at, started_at) DESC, scheduled_for DESC LIMIT {int(min_runs)}",
            f"SELECT snapshot_id, receipt FROM pipeline_runs "
            f"WHERE status IN ('succeeded','no_change') "
            f"ORDER BY COALESCE(updated_at, started_at) DESC, scheduled_for DESC LIMIT {int(min_runs)}",
        )
        for sql in queries:
            for snapshot_id, raw_receipt in db.execute(sql).fetchall():
                if snapshot_id:
                    protected_snapshots.add(str(snapshot_id))
                if raw_receipt:
                    try:
                        receipts.append(json.loads(raw_receipt))
                    except Exception:
                        continue

    for receipt in receipts:
        if not isinstance(receipt, dict):
            continue
        if receipt.get('snapshotId'):
            protected_snapshots.add(str(receipt['snapshotId']))
        for task_id, item in (receipt.get('tasks') or {}).items():
            if not isinstance(item, dict):
                continue
            if item.get('artifactId'):
                protected_derived.add((str(task_id), str(item['artifactId'])))
                protected_generations.add(str(item['artifactId']))
            for entry in item.get('files') or ():
                rel = Path(entry.get('path', ''))
                if len(rel.parts) >= 3 and rel.parts[0] == 'derived' and rel.parts[1] == 'pipeline':
                    protected_derived.add((rel.parts[2], rel.parts[3] if len(rel.parts) >= 4 else ''))
        for group_id, item in (receipt.get('groups') or {}).items():
            if not isinstance(item, dict):
                continue
            if item.get('generationId'):
                protected_generations.add(str(item['generationId']))
                protected_derived.add((str(group_id), str(item['generationId'])))
            for entry in item.get('files') or ():
                rel = Path(entry.get('path', ''))
                if len(rel.parts) >= 4 and rel.parts[0] == 'derived' and rel.parts[1] == 'pipeline':
                    protected_derived.add((rel.parts[2], rel.parts[3]))
                elif len(rel.parts) >= 2 and rel.parts[0] == 'snapshots':
                    protected_snapshots.add(rel.parts[1])
    return protected_snapshots, protected_derived, protected_generations


def prune_writer_retention(
    store,
    *,
    retention_days=7,
    min_runs=4,
    min_snapshots=4,
    min_task_generations=3,
    apply=False,
):
    """Bound Writer pipeline snapshot-pins, snapshot hardlink trees, derived caches, and Parquet GC.

    Safety guarantees:
    - Holds `store.writer()` and non-blocking `readers.lock` (`LOCK_EX|LOCK_NB`).
    - Never touches `raw/` vendor archives, `derived/ai-insights`, `derived/rule-bootstrap`, or `manifests/`.
    - Preserves all non-pipeline pins (e.g. `saved-research`), all pins/builds within `retention_days`,
      the newest `min_snapshots` pins, `min_runs` verified/staged/succeeded pipeline runs,
      the newest `min_task_generations` directories per derived task, and at least 2 Parquet
      generations per canonical partition.
    """
    if retention_days < 1:
        raise ValueError('at least one day of rollback retention is required')
    if min_runs < 1 or min_snapshots < 1 or min_task_generations < 1:
        raise ValueError('positive_retention_floor_required')
    (store.root / 'sync').mkdir(parents=True, exist_ok=True)
    with store.writer() as db, (store.root / 'sync/readers.lock').open('a') as lease:
        try:
            fcntl.flock(lease, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return {
                'status': 'readers_active',
                'retired_snapshot_pins': 0,
                'deleted_snapshot_dirs': 0,
                'evicted_derived_dirs': 0,
                'deleted_parquet_files': 0,
                'raw_history_preserved': True,
            }
        try:
            free_before = shutil.disk_usage(store.root).free
            cutoff = time.time() - retention_days * 86400
            protected_snapshots, protected_derived, protected_generations = _protected_run_references(
                store, db, min_runs=min_runs
            )

            # 1. Evaluate snapshot-pins (fail closed on malformed pin files).
            pins_dir = store.root / 'sync/snapshot-pins'
            pin_entries = []
            if pins_dir.is_dir():
                if pins_dir.is_symlink():
                    raise ValueError('unsafe_snapshot_pins_symlink')
                for pin in pins_dir.glob('*.json'):
                    if pin.is_symlink():
                        raise ValueError('unsafe_snapshot_pin_symlink')
                    value = json.loads(pin.read_text())
                    if not isinstance(value.get('paths'), list):
                        raise ValueError('invalid_snapshot_pin')
                    snapshot_id = str(value.get('snapshotId') or pin.stem)
                    pin_entries.append((pin.stat().st_mtime, pin, snapshot_id, value))
            pin_entries.sort(key=lambda row: row[0], reverse=True)

            kept_snapshots = set(protected_snapshots)
            retired_pins = []
            pipeline_rank = 0
            for mtime, pin, snapshot_id, value in pin_entries:
                reason = value.get('reason')
                if reason != 'pipeline-replay-and-rollback':
                    kept_snapshots.add(snapshot_id)
                    continue
                keep = (
                    pipeline_rank < min_snapshots
                    or mtime >= cutoff
                    or snapshot_id in protected_snapshots
                )
                pipeline_rank += 1
                if keep:
                    kept_snapshots.add(snapshot_id)
                else:
                    retired_pins.append((mtime, pin, snapshot_id, value))

            if apply and retired_pins:
                audit_dir = store.root / 'audit/pipeline'
                audit_dir.mkdir(parents=True, exist_ok=True)
                archived_payload = {
                    'retiredAt': now(),
                    'retentionDays': retention_days,
                    'retiredCount': len(retired_pins),
                    'keptSnapshotCount': len(kept_snapshots),
                    'pins': [
                        {
                            'snapshotId': sid,
                            'reason': val.get('reason'),
                            'createdAt': val.get('createdAt'),
                            'mtime': mtime,
                            'partitionCount': len(val.get('paths', [])),
                            'paths': val.get('paths', []),
                        }
                        for mtime, _, sid, val in retired_pins
                    ],
                }
                Store._atomic_if_changed(
                    audit_dir / 'retired-snapshot-pins-latest.json',
                    json.dumps(archived_payload, sort_keys=True) + '\n',
                )
                for _, pin, _, _ in retired_pins:
                    pin.unlink()

            # 2. Reclaim unpinned expired snapshot hardlink directories (`snapshots/<64-hex>`).
            snapshots_root = store.root / 'snapshots'
            snapshot_dir_candidates = []
            if snapshots_root.is_dir():
                if snapshots_root.is_symlink():
                    raise ValueError('unsafe_snapshots_root_symlink')
                all_snap_dirs = []
                for entry in snapshots_root.iterdir():
                    if entry.is_symlink():
                        raise ValueError('unsafe_snapshot_dir_symlink')
                    if entry.is_dir() and HEX64.fullmatch(entry.name):
                        all_snap_dirs.append((entry.stat().st_mtime, entry))
                all_snap_dirs.sort(key=lambda row: row[0], reverse=True)
                retired_ids = {sid for _, _, sid, _ in retired_pins}
                for idx, (mtime, entry) in enumerate(all_snap_dirs):
                    pin_exists = (pins_dir / (entry.name + '.json')).exists()
                    will_remain_pinned = pin_exists and (apply or entry.name not in retired_ids)
                    if idx < min_snapshots or mtime >= cutoff or entry.name in kept_snapshots or will_remain_pinned:
                        continue
                    _, _, logical_bytes = _tree_stats_and_verify_no_symlinks(entry, snapshots_root)
                    snapshot_dir_candidates.append((entry, logical_bytes))

            deleted_snapshot_dirs = 0
            if apply:
                for entry, _ in snapshot_dir_candidates:
                    _safe_remove_tree(entry, snapshots_root)
                    deleted_snapshot_dirs += 1

            # 3. Reclaim expired derived pipeline caches (`derived/pipeline/<task>/<fingerprint>`),
            #    plus bounded `derived/rule-parents/<gen>` and `staging/rule-dependencies/<digest>`.
            derived_candidates = []
            pipeline_derived = store.root / 'derived/pipeline'
            if pipeline_derived.is_dir():
                if pipeline_derived.is_symlink():
                    raise ValueError('unsafe_derived_pipeline_symlink')
                for task_dir in sorted(pipeline_derived.iterdir()):
                    if task_dir.is_symlink():
                        raise ValueError('unsafe_derived_task_symlink')
                    if not task_dir.is_dir() or not SAFE_DIR_NAME.fullmatch(task_dir.name):
                        continue
                    builds = []
                    for child in task_dir.iterdir():
                        if child.is_symlink():
                            raise ValueError('unsafe_derived_build_symlink')
                        if child.is_dir() and SAFE_DIR_NAME.fullmatch(child.name):
                            builds.append((_newest_mtime(child), child))
                    builds.sort(key=lambda row: row[0], reverse=True)
                    for idx, (mtime, child) in enumerate(builds):
                        if (
                            idx < min_task_generations
                            or mtime >= cutoff
                            or (task_dir.name, child.name) in protected_derived
                            or child.name in protected_generations
                        ):
                            continue
                        _, _, logical_bytes = _tree_stats_and_verify_no_symlinks(child, task_dir)
                        derived_candidates.append((child, task_dir, logical_bytes))

            for aux_rel in ('derived/rule-parents', 'staging/rule-dependencies'):
                aux_root = store.root / aux_rel
                if not aux_root.is_dir():
                    continue
                if aux_root.is_symlink():
                    raise ValueError('unsafe_auxiliary_cache_symlink')
                entries = []
                for child in aux_root.iterdir():
                    if child.is_symlink():
                        raise ValueError('unsafe_auxiliary_entry_symlink')
                    if child.is_dir() and HEX64.fullmatch(child.name):
                        entries.append((_newest_mtime(child), child))
                entries.sort(key=lambda row: row[0], reverse=True)
                for idx, (mtime, child) in enumerate(entries):
                    if idx < min_task_generations or mtime >= cutoff or child.name in protected_generations:
                        continue
                    _, _, logical_bytes = _tree_stats_and_verify_no_symlinks(child, aux_root)
                    derived_candidates.append((child, aux_root, logical_bytes))

            evicted_derived_dirs = 0
            evicted_derived_logical_bytes = sum(size for _, _, size in derived_candidates)
            if apply:
                for child, parent, _ in derived_candidates:
                    _safe_remove_tree(child, parent)
                    evicted_derived_dirs += 1

            # 4. Run official unreferenced Parquet GC inside the same writer + reader lease.
            parquet_gc = _collect_unreferenced_locked(
                store,
                db,
                retention_days=retention_days,
                apply=apply,
                excluded_pins=() if apply else [pin for _, pin, _, _ in retired_pins],
            )
            free_after = shutil.disk_usage(store.root).free

            report = {
                'status': 'collected' if apply else 'dry_run',
                'checkedAt': now(),
                'retentionDays': retention_days,
                'keptSnapshotPins': len(kept_snapshots),
                'retired_snapshot_pins': len(retired_pins) if apply else 0,
                'retirable_snapshot_pins': len(retired_pins),
                'deleted_snapshot_dirs': deleted_snapshot_dirs,
                'reclaimable_snapshot_dirs': len(snapshot_dir_candidates),
                'evicted_derived_dirs': evicted_derived_dirs,
                'reclaimable_derived_dirs': len(derived_candidates),
                'reclaimable_derived_logical_bytes': evicted_derived_logical_bytes,
                'deleted_parquet_files': parquet_gc['deleted_files'],
                'reclaimable_parquet_bytes': parquet_gc['reclaimable_bytes'],
                'freeBytesBefore': free_before,
                'freeBytesAfter': free_after,
                'reclaimedBytes': max(0, free_after - free_before) if apply else 0,
                'raw_history_preserved': True,
                'candidates': parquet_gc['candidates'],
            }
            if apply:
                audit_dir = store.root / 'audit/pipeline'
                audit_dir.mkdir(parents=True, exist_ok=True)
                summary = {k: v for k, v in report.items() if k != 'candidates'}
                Store._atomic_if_changed(
                    audit_dir / 'retention-latest.json',
                    json.dumps(summary, sort_keys=True) + '\n',
                )
            return report
        finally:
            fcntl.flock(lease, fcntl.LOCK_UN)
