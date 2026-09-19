#!/usr/bin/env python3
"""Recover missing raw-archive sidecars from recorded local evidence only.

No HTTP, keys, signed URLs or data rewriting. Requires one exact verified-full
ingestion, matching content-addressed path/SHA/length, a saved resume identity,
and recorded successful bulk redirect. Never invents a download completion time.
"""
from __future__ import annotations

import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sys
import zipfile

import duckdb

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fact_os.contracts import TABLES
from fact_os.store import checksum


def local_evidence(root):
    # Close the read-only catalog promptly: full ingestion may need the writer.
    with duckdb.connect(str(root / "fact_os.duckdb"), read_only=True) as db:
        columns = ("dataset", "run_id", "checksum", "observed_at", "source_path", "row_count", "schema_hash", "scope")
        rows = [dict(zip(columns, row)) for row in db.execute(
            "SELECT dataset,run_id,checksum,observed_at,source_path,row_count,schema_hash,scope FROM ingest_runs WHERE scope='verified_full_bulk' ORDER BY observed_at").fetchall()]
        access = {row[0]: dict(zip(("dataset", "checked_at", "query_status", "bulk_status"), row))
                  for row in db.execute("SELECT dataset,checked_at,query_status,bulk_status FROM remote_access").fetchall()}
    return rows, access


def recover_one(root, table, runs, access, *, write=False):
    root = root.resolve()
    candidates = [row for row in runs if row["dataset"] == table]
    if len(candidates) != 1:
        raise ValueError(f"{table}: expected one exact verified-full ingestion; found {len(candidates)}")
    run = candidates[0]
    if run["scope"] != "verified_full_bulk":
        raise ValueError(f"{table}: ingestion was not verified full history")
    digest = str(run["checksum"])
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError(f"{table}: invalid recorded checksum")
    archive = Path(run["source_path"]).resolve()
    expected = root / "raw" / f"{table}-{digest}.zip"
    if archive != expected or not archive.is_file():
        raise ValueError(f"{table}: exact recorded archive missing or not the expected content-addressed path")
    resume_path = root / "raw" / f"{table}-full.resume.json"
    resume_bytes = resume_path.read_bytes()
    resume = json.loads(resume_bytes)
    length = int(resume.get("length") or 0)
    if not resume.get("etag") or length <= 0 or archive.stat().st_size != length:
        raise ValueError(f"{table}: saved resume identity/length does not match the archive")
    remote = access.get(table)
    if not remote or remote["bulk_status"] not in (301, 302, 303, 307, 308):
        raise ValueError(f"{table}: recorded full-bulk redirect evidence missing")
    if checksum(archive) != digest:
        raise ValueError(f"{table}: local archive checksum mismatch")
    if not zipfile.is_zipfile(archive):
        raise ValueError(f"{table}: archive is not a ZIP")
    with zipfile.ZipFile(archive) as zipped:
        members = [entry for entry in zipped.infolist() if entry.filename.lower().endswith(".csv")]
        if len(members) != 1:
            raise ValueError(f"{table}: expected exactly one CSV member")
        member = members[0]
        zip_metadata = {"csv_member": member.filename, "uncompressed_bytes": member.file_size,
                        "compressed_bytes": member.compress_size, "crc32": f"{member.CRC:08x}"}
    metadata = {
        "metadata_version": 1, "dataset": table, "source": "Sharadar",
        "endpoint": f"https://api.sharadar.com/v1.0/data/{table}", "history": "full",
        "scope": run["scope"], "path": str(archive.relative_to(root)),
        "sha256": digest, "bytes": length, "etag": resume["etag"],
        "download_completed_at": None,
        "ingestion": {key: value for key, value in run.items() if key != "source_path"},
        "recorded_access": remote, "archive_structure": zip_metadata,
        "resume_evidence": {"path": str(resume_path.relative_to(root)),
                            "sha256": hashlib.sha256(resume_bytes).hexdigest()},
        "recovered_at": datetime.now(timezone.utc).isoformat(),
        "verification": {"network_used": False, "archive_rewritten": False,
                         "sha256_matches_verified_ingestion": True,
                         "bytes_match_resume_length": True,
                         "basis": "Recorded verified-full ingestion plus exact archive SHA/path, saved resume ETag/length and recorded bulk redirect. ETag is recorded evidence, not recomputed from file bytes. Exact transfer completion time was not separately recorded."},
    }
    output = archive.with_suffix(".metadata.json")
    if output.exists():
        previous = json.loads(output.read_text())
        expected_metadata = {key: value for key, value in metadata.items() if key != "recovered_at"}
        previous_metadata = {key: value for key, value in previous.items() if key != "recovered_at"}
        if previous_metadata != expected_metadata:
            raise ValueError(f"{table}: existing metadata differs; refusing overwrite")
        status = "existing_verified"
    elif write:
        with output.open("x") as destination:
            json.dump(metadata, destination, indent=2, default=str)
            destination.write("\n")
        output.chmod(0o600)
        status = "recovered"
    else:
        status = "validated_not_written"
    return {"dataset": table, "status": status, "metadata": str(output.relative_to(root)),
            "sha256": digest, "bytes": length, "row_count": run["row_count"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT / "data/fact_os")
    parser.add_argument("--tables", choices=TABLES, nargs="+", required=True)
    parser.add_argument("--write", action="store_true", help="Write only new metadata sidecars; no archive/catalog changes")
    args = parser.parse_args()
    runs, access = local_evidence(args.root.resolve())
    results = [recover_one(args.root, table, runs, access, write=args.write) for table in args.tables]
    print(json.dumps({"network_used": False, "data_modified": False, "archives": results}, indent=2))


if __name__ == "__main__":
    main()
