#!/usr/bin/env python3
"""Read-only disk/duplicate evidence for public Fact OS files, never raw rows.

Does not connect to a source, open private databases, or delete anything. Hashes
content-addressed raw archives and same-size Parquet candidates. Different raw
snapshots and retained rollback generations are not duplicate database records.
"""
from __future__ import annotations

import argparse
from collections import defaultdict
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import time

ROOT = Path(__file__).resolve().parents[1]
RAW_NAME = re.compile(r"[a-z_]+(?:-sync)?-([a-f0-9]{64})\.(?:zip|csv)$")
PARQUET_NAME = re.compile(r"(\d+)-[a-f0-9]{32}\.parquet$")


def digest(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(4 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def files_under(root):
    files, symlinks = [], 0
    for base, dirs, names in os.walk(root, followlinks=False):
        symlinks += sum((Path(base) / name).is_symlink() for name in dirs)
        dirs[:] = [name for name in dirs if not (Path(base) / name).is_symlink()]
        for name in names:
            path = Path(base) / name
            if path.is_symlink():
                symlinks += 1
            elif path.is_file():
                stat = path.stat()
                files.append((path, stat.st_size, getattr(stat, "st_blocks", 0) * 512, stat.st_mtime_ns))
    return files, symlinks


def totals(entries):
    seen=set();allocated=0
    for path,_,blocks,_ in entries:
        stat=path.stat();identity=(stat.st_dev,stat.st_ino)
        if identity not in seen:allocated+=blocks;seen.add(identity)
    return {"files": len(entries), "logical_bytes": sum(row[1] for row in entries),
            "allocated_bytes": allocated,"unique_file_inodes":len(seen)}


def duplicate_contents(entries):
    by_size = defaultdict(list)
    for path, size, *_ in entries:
        by_size[size].append(path)
    groups = []
    for size, paths in by_size.items():
        if len(paths) < 2:
            continue
        by_hash = defaultdict(list)
        for path in paths:
            by_hash[digest(path)].append(path)
        for checksum, equal in by_hash.items():
            if len(equal) > 1:
                groups.append({"sha256": checksum, "files": len(equal),
                               "logical_excess_bytes": size * (len(equal) - 1)})
    return {"groups": groups, "group_count": len(groups),
            "logical_excess_bytes": sum(group["logical_excess_bytes"] for group in groups)}


@contextmanager
def reader_lease(root):
    with (root / "sync/readers.lock").open("a") as lease:
        fcntl.flock(lease, fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(lease, fcntl.LOCK_UN)


def audit(root):
    """Pin manifest under GC reader lease; concurrent writers are detected."""
    with reader_lease(root):
        manifest_path = root / "manifests/catalog.json"
        initial_manifest = manifest_path.read_bytes()
        catalog = json.loads(initial_manifest)
        referenced = {part["path"] for info in catalog["datasets"].values()
                      for part in info["partitions"]}
        pinned=set()
        for pin in (root/'sync/snapshot-pins').glob('*.json'):
            value=json.loads(pin.read_text())
            if not isinstance(value.get('paths'),list):raise ValueError('invalid_snapshot_pin')
            pinned.update(value['paths'])
        initial, symlinks = files_under(root)
        parts = defaultdict(list)
        for entry in initial:
            parts[entry[0].relative_to(root).parts[0]].append(entry)
        raw = [entry for entry in parts["raw"] if RAW_NAME.fullmatch(entry[0].name)]
        invalid_raw_hash = []
        for path, *_ in raw:
            if digest(path) != RAW_NAME.fullmatch(path.name).group(1):
                # Only canonical filenames are emitted; never read metadata URLs.
                invalid_raw_hash.append(path.name)
        parquet = [entry for entry in parts["parquet"] if PARQUET_NAME.fullmatch(entry[0].name)]
        current = [entry for entry in parquet if str(entry[0].relative_to(root)) in referenced]
        retained = [entry for entry in parquet if str(entry[0].relative_to(root)) not in referenced]
        present = {str(entry[0].relative_to(root)) for entry in parquet}
        by_partition = defaultdict(list)
        for entry in parquet:
            by_partition[(entry[0].parent.name, PARQUET_NAME.fullmatch(entry[0].name).group(1))].append(entry)
        reclaimable = []
        cutoff_ns = int((time.time() - 7 * 86400) * 1e9)
        for generations in by_partition.values():
            generations.sort(key=lambda entry: entry[3], reverse=True)
            reclaimable.extend(entry for entry in generations[2:]
                               if str(entry[0].relative_to(root)) not in referenced|pinned and entry[3] < cutoff_ns)
        raw_duplicates = duplicate_contents(raw)
        parquet_duplicates = duplicate_contents(parquet)
        final, _ = files_under(root)
        stamp = lambda entries: {(str(path.relative_to(root)), size, mtime) for path, size, _, mtime in entries}
        stable_manifest = manifest_path.read_bytes() == initial_manifest
        stable_files = stamp(initial) == stamp(final)
        return {
            "observed_at": datetime.now(timezone.utc).isoformat(), "root": str(root),
            "scope": "public Fact OS files only; no source requests, credentials, private records or deletion",
            "total": totals(initial), "by_directory": {name: totals(entries) for name, entries in sorted(parts.items())},
            "symlinks_skipped": symlinks,
            "source_generation": {"catalog_sha256": hashlib.sha256(initial_manifest).hexdigest(),
                                  "manifest_stable": stable_manifest, "file_inventory_stable": stable_files},
            "raw": {"content_addressed": totals(raw), "checksum_mismatches": invalid_raw_hash,
                    "byte_identical_duplicates": raw_duplicates,
                    "policy": "Preserve all raw snapshots forever. ZIP and CSV may intentionally overlap rows; database uniqueness is audited separately."},
            "parquet": {"current_manifest_references": totals(current), "retained_unreferenced": totals(retained),
                        "missing_manifest_paths": sorted(referenced - present),
                        "snapshot_pinned_paths":len(pinned),
                        "byte_identical_duplicates": parquet_duplicates,
                        "dry_run_gc_eligible": totals(reclaimable), "gc_retention_days": 7,
                        "gc_minimum_generations_per_partition": 2,
                        "policy": "Only manifest-referenced partitions are queried; rollback generations do not duplicate query rows."},
            "deleted_files": 0,
            "passed": (stable_manifest and stable_files and not invalid_raw_hash
                       and not (referenced - present) and not raw_duplicates["group_count"]),
        }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT / "data/fact_os")
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = audit(args.root.resolve())
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(json.dumps({"output": str(args.output), "passed": result["passed"],
                      "total_bytes": result["total"]["logical_bytes"],
                      "raw_duplicate_bytes": result["raw"]["byte_identical_duplicates"]["logical_excess_bytes"],
                      "retained_parquet_bytes": result["parquet"]["retained_unreferenced"]["logical_bytes"]}))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
