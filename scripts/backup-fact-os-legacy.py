#!/usr/bin/env python3
"""One consistent local rollback backup; no per-user portfolio DB is opened."""
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import datetime

ROOT = Path(__file__).resolve().parents[1]
source = ROOT / "server/data/guru-analysis.sqlite"
directory = ROOT / "data/fact_os/legacy_backup"
destination = directory / "guru-analysis.before-fact-os.sqlite"
receipt = directory / "backup.json"


def digest(path):
    result = hashlib.sha256()
    with path.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(chunk)
    return result.hexdigest()


def main():
    directory.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(directory, 0o700)
    if destination.exists():
        if not receipt.exists():
            raise RuntimeError("Backup already exists without its verification receipt; not overwriting")
        existing = json.loads(receipt.read_text())
        if existing["sha256"] != digest(destination):
            raise RuntimeError("Existing backup checksum differs; not overwriting")
        print(json.dumps({**existing, "reused_existing_backup": True}, indent=2))
        return
    partial = destination.with_suffix(".sqlite.partial")
    if partial.exists():
        raise RuntimeError("Interrupted backup exists; inspect before retrying")
    # SQLite backup includes committed WAL and obtains a consistent snapshot.
    with sqlite3.connect(source.as_uri() + "?mode=ro", uri=True) as original, sqlite3.connect(partial) as copy:
        original.backup(copy)
        if copy.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Backup integrity check failed")
        tables = copy.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        counts = {name: copy.execute('SELECT COUNT(*) FROM "' + name.replace('"', '""') + '"').fetchone()[0] for (name,) in tables}
    os.chmod(partial, 0o600)
    partial.rename(destination)
    result = {"created_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
              "source": str(source), "destination": str(destination), "sha256": digest(destination),
              "bytes": destination.stat().st_size, "integrity_check": "ok", "table_counts": counts,
              "private_boundary": "Per-user portfolio databases were not opened or copied. Any legacy NAV already inside the main DB is retained in this private rollback backup."}
    receipt.write_text(json.dumps(result, indent=2))
    os.chmod(receipt, 0o600)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
