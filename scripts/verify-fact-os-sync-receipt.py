#!/usr/bin/env python3
"""Bind a live two-pass sync receipt to unchanged local engine source files.

Capture with --output at run start, then verify using --baseline and a different
--output after completion. Never reads credentials or calls the upstream API.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fact_os.contracts import TABLES

FILES = [f"fact_os/{name}.py" for name in
         ("sync", "extract", "store", "sync_plan", "pagination", "contracts")]
FILES += ["scripts/verify-fact-os-live-sync.py"]


def fingerprints(root):
    result = {}
    for name in FILES:
        path = root / name
        stat = path.stat()
        result[name] = {"sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                        "mtime_ns": stat.st_mtime_ns, "bytes": stat.st_size}
    return result


def validate_receipt(receipt, expected=TABLES):
    expected = set(expected)
    errors = []
    if not receipt.get("finished_at"):
        errors.append("not_finished")
    if receipt.get("errors"):
        errors.append("upstream_errors")
    assertions = receipt.get("assertions", {})
    required = {"no_history_shrink", "second_pass_same_row_counts", "second_pass_same_date_coverage", "all_syncs_succeeded"}
    if not required.issubset(assertions) or any(assertions.get(name) is not True for name in required):
        errors.append("missing_or_failed_assertions")
    passes = receipt.get("passes", [])
    if len(passes) != 2 or [record.get("pass") for record in passes] != [1, 2]:
        errors.append("two_complete_passes_required")
        return errors
    for record in passes:
        results = record.get("results", [])
        if len(results) != len(expected) or {row.get("dataset") for row in results} != expected:
            errors.append(f"pass_{record['pass']}_table_set_incomplete")
        # This acceptance run rechecks known nonempty, fully backfilled tables.
        # An empty response may be safe operationally, but cannot prove that a
        # provider query with a formerly false-empty range was actually correct.
        if any(row.get("error") or row.get("status") not in {"ingested", "unchanged"} for row in results):
            errors.append(f"pass_{record['pass']}_result_not_successful")
        if any(record.get("after", {}).get(table, {}).get("last_error") for table in expected):
            errors.append(f"pass_{record['pass']}_unresolved_sync_error")
    try:
        first, second = (record["after"] for record in passes)
        before = receipt["before"]
        for table in expected:
            a, b, prior = first[table], second[table], before[table]
            if a["row_count"] != b["row_count"] or (a["min_date"], a["max_date"]) != (b["min_date"], b["max_date"]):
                errors.append(f"{table}:not_idempotent_counts_or_dates")
            if b["row_count"] < prior["row_count"] or (prior["min_date"] and (not b["min_date"] or b["min_date"] > prior["min_date"])):
                errors.append(f"{table}:history_shrunk")
    except (KeyError, TypeError):
        errors.append("missing_before_or_after_state")
    return errors


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--baseline", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    # The live runner checkpoints after its first table. Capture code immediately
    # even before that receipt exists, but do not claim a start-time check yet.
    data = args.receipt.read_bytes() if args.receipt.exists() else None
    if data is None and args.baseline:
        raise SystemExit("Final verification requires the live receipt.")
    receipt = json.loads(data) if data is not None else {}
    code = fingerprints(ROOT)
    started_ns = int(datetime.fromisoformat(receipt["started_at"]).timestamp() * 1e9) if receipt else None
    errors = [f"source_changed_after_run_start:{name}" for name, value in code.items()
              if started_ns is not None and value["mtime_ns"] > started_ns]
    output = {"captured_at": datetime.now(timezone.utc).isoformat(), "receipt": str(args.receipt),
              "receipt_started_at": receipt.get("started_at"), "source_files": code,
              "phase": "final_verification" if args.baseline else "running_fingerprint",
              "receipt_pending": data is None,
              "receipt_sha256": hashlib.sha256(data).hexdigest() if data is not None else None}
    if args.baseline:
        baseline = json.loads(args.baseline.read_text())
        if ((baseline["receipt_started_at"] is not None and baseline["receipt_started_at"] != receipt["started_at"])
                or baseline["source_files"] != code or baseline["receipt"] != str(args.receipt)):
            errors.append("run_or_engine_changed_since_capture")
        errors.extend(validate_receipt(receipt))
    output.update({"passed": (not errors) if data is not None else None, "errors": errors})
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as stream:
        json.dump(output, stream, indent=2)
        stream.write("\n")
    print(json.dumps({"output": str(args.output), "phase": output["phase"], "passed": output["passed"], "errors": errors}))
    return 0 if data is None or output["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
