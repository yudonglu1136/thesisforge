#!/usr/bin/env python3
"""Verify the existing rollback backup and original SQLite without row payloads.

Both databases are opened read-only. The only write is a new audit JSON receipt;
this does not create another backup or open a per-user portfolio database.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sqlite3

ROOT = Path(__file__).resolve().parents[1]


def header_differences(original, backup):
    if len(original) != 100 or len(backup) != 100:
        raise ValueError("Expected two complete 100-byte SQLite headers")
    changed = [i for i in range(100) if original[i] != backup[i]]
    # File change counter, schema cookie, version-valid-for, writer version.
    allowed = set(range(24, 28)) | set(range(40, 44)) | set(range(92, 100))
    return changed, set(changed) <= allowed


def digest(path, offset=0):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        stream.seek(offset)
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def inspect(path):
    with sqlite3.connect(path.as_uri() + "?mode=ro", uri=True) as db:
        integrity = [row[0] for row in db.execute("PRAGMA integrity_check")]
        names = [row[0] for row in db.execute(
            "SELECT name FROM sqlite_master WHERE type='table' "
            "AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        counts = {name: db.execute('SELECT count(*) FROM "' + name.replace('"', '""') + '"').fetchone()[0]
                  for name in names}
    return {"path": str(path), "bytes": path.stat().st_size,
            "sha256": digest(path), "integrity_check": integrity,
            "bytes_after_header_sha256": digest(path, 100),
            "table_counts": counts}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    output = args.output.resolve()
    output.relative_to(ROOT / "data/fact_os/audit")
    if output.exists():
        raise SystemExit("Refusing to overwrite an existing audit receipt")
    directory = ROOT / "data/fact_os/legacy_backup"
    recorded = json.loads((directory / "backup.json").read_text())
    original = inspect(ROOT / "server/data/guru-analysis.sqlite")
    backup = inspect(directory / "guru-analysis.before-fact-os.sqlite")
    with Path(original["path"]).open("rb") as stream:
        original_header = stream.read(100)
    with Path(backup["path"]).open("rb") as stream:
        backup_header = stream.read(100)
    changed_header_offsets, valid_header_metadata = header_differences(original_header, backup_header)
    # sqlite3.backup may change the file change counter, schema cookie,
    # version-valid-for number and SQLite writer version. They are file-header
    # metadata, not changed table contents. All other bytes must match here.
    assertions = {
        "original_integrity_ok": original["integrity_check"] == ["ok"],
        "backup_integrity_ok": backup["integrity_check"] == ["ok"],
        "backup_hash_unchanged": backup["sha256"] == recorded["sha256"],
        "backup_bytes_unchanged": backup["bytes"] == recorded["bytes"],
        "all_original_table_counts_preserved": original["table_counts"] == recorded["table_counts"],
        "all_backup_table_counts_preserved": backup["table_counts"] == recorded["table_counts"],
        "original_data_pages_match_consistent_backup": original["bytes_after_header_sha256"] == backup["bytes_after_header_sha256"],
        "only_backup_header_metadata_differs": valid_header_metadata,
    }
    result = {"generated_at": datetime.now(timezone.utc).isoformat(),
              "scope": "Read-only original application SQLite and pre-existing consistent backup; no private row contents or per-user databases",
              "original": original, "backup": backup,
              "header_difference_offsets": changed_header_offsets,
              "header_note": "SQLite backup API can change header counters and writer-version metadata; physical whole-file equality is not required. The initial backup checksum remains required and all bytes after the 100-byte file header are compared.",
              "assertions": assertions, "passed": all(assertions.values()),
              "data_writes": 0}
    with output.open("x") as stream:
        json.dump(result, stream, indent=2)
        stream.write("\n")
    print(json.dumps(result, indent=2))
    return 0 if result["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
