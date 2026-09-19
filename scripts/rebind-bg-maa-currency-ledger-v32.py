#!/usr/bin/env python3
"""Rebind the reviewed BG15/MAA1 ledger to a version-only v32 source replay.

Reads both sources in SQLite read-only mode. Every SQL and parsed JSON field
must be identical except the exact reviewed extraction_version transition.
This does not approve the event's numeric economics and never changes a DB.
"""
import argparse
from contextlib import closing
import copy
import hashlib
import json
from pathlib import Path
import sqlite3

OLD_VERSION = "pit-guidance-rules-v31b-explicit-net-income-per-share-2026-09-06"
NEW_VERSION = "pit-guidance-rules-v32-current-per-share-range-ffo-owner-2026-09-06"


def sha(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def file_sha(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def parse(raw):
    def unique(pairs):
        result = {}
        for key, value in pairs:
            if key in result:
                raise ValueError("Duplicate JSON key: " + key)
            result[key] = value
        return result
    def invalid(value):
        raise ValueError("Non-finite JSON value: " + value)
    return json.loads(raw, object_pairs_hook=unique, parse_constant=invalid)


def canonical(value):
    return json.dumps(value, sort_keys=True, ensure_ascii=False, separators=(",", ":"), allow_nan=False)


def compare(old, new, event):
    """Require full row identity, not a whitelist of a few economic fields."""
    for row in [old, new]:
        if (row["id"], row["ticker"], row["observed_at"]) != (event["sourceId"], event["ticker"], event["observedAt"]):
            raise ValueError("Event identity conflict")
        if row["evidence_excerpt"] != event["originalQuote"] or sha(row["evidence_excerpt"]) != event["originalQuoteSha256"]:
            raise ValueError("Original quote conflict")
    if sha(old["payload_json"]) != event["originalPayloadSha256"]:
        raise ValueError("Original ledger payload hash conflict")
    if old["extraction_version"] != OLD_VERSION or new["extraction_version"] != NEW_VERSION:
        raise ValueError("Unreviewed extraction version transition")
    old_sql = {k: v for k, v in old.items() if k not in {"payload_json", "extraction_version"}}
    new_sql = {k: v for k, v in new.items() if k not in {"payload_json", "extraction_version"}}
    if canonical(old_sql) != canonical(new_sql):
        raise ValueError("SQL source/economic fields conflict")
    old_payload, new_payload = parse(old["payload_json"]), parse(new["payload_json"])
    if old_payload.get("extraction_version") != OLD_VERSION or new_payload.get("extraction_version") != NEW_VERSION:
        raise ValueError("Payload extraction version conflict")
    old_body = {k: v for k, v in old_payload.items() if k != "extraction_version"}
    new_body = {k: v for k, v in new_payload.items() if k != "extraction_version"}
    if canonical(old_body) != canonical(new_body):
        raise ValueError("Payload source/economic fields conflict")
    return dict(sourceId=event["sourceId"], ticker=event["ticker"], observedAt=event["observedAt"],
                priorPayloadSha256=sha(old["payload_json"]), reboundPayloadSha256=sha(new["payload_json"]),
                invariantSqlSha256=sha(canonical(old_sql)), invariantPayloadSha256=sha(canonical(old_body)),
                changedSqlFields=["extraction_version"], changedPayloadFields=["extraction_version"],
                originalQuoteSha256=event["originalQuoteSha256"], economicFieldsExact=True)


def rebind(old_source, new_source, ledger_path, expected_old_sha, expected_new_sha):
    old_source, new_source, ledger_path = [Path(p).resolve(strict=True) for p in [old_source, new_source, ledger_path]]
    if old_source == new_source:
        raise ValueError("Distinct source files required")
    before = [file_sha(p) for p in [old_source, new_source]]
    if before != [expected_old_sha, expected_new_sha]:
        raise ValueError("Source file SHA mismatch")
    ledger = parse(ledger_path.read_text())
    events = ledger["events"]
    if len(events) != 16 or len({e["sourceId"] for e in events}) != 16 or sum(e["ticker"] == "BG" for e in events) != 15 or [e["sourceId"] for e in events if e["ticker"] == "MAA"] != ["0af4b2954039a743afdaeb74"]:
        raise ValueError("Exact reviewed BG15 + MAA1 scope required")
    checks = []
    with closing(sqlite3.connect(old_source.as_uri() + "?mode=ro", uri=True)) as old_db, closing(sqlite3.connect(new_source.as_uri() + "?mode=ro", uri=True)) as new_db:
        for db in [old_db, new_db]:
            db.row_factory = sqlite3.Row
        for event in events:
            rows = [db.execute("SELECT * FROM pit_guidance_events WHERE id=?", (event["sourceId"],)).fetchone() for db in [old_db, new_db]]
            if any(row is None for row in rows):
                raise ValueError("Missing exact event: " + event["sourceId"])
            checks.append(compare(*(dict(row) for row in rows), event))
    if before != [file_sha(p) for p in [old_source, new_source]]:
        raise ValueError("Read-only sources changed during verification")
    report = dict(version="bg15-maa1-v31b-to-v32-currency-ledger-rebinding-v1", oldSource=str(old_source), newSource=str(new_source),
                  oldSourceSha256=before[0], newSourceSha256=before[1], priorLedgerSha256=file_sha(ledger_path),
                  extractionVersionTransition=[OLD_VERSION, NEW_VERSION], events=checks, eventCount=16,
                  allOriginalQuotesExact=True, allEconomicAndReviewFieldsExact=True, sourceFilesUnchanged=True,
                  sourceRowsChanged=0, numericEconomicsApproved=False, releaseAuthorized=False,
                  knownSeparateNumericBlocker="BG dd95e7501f1f02307cf0b918 retains 300m; original CapEx owner is 550m. Currency evidence does not approve this amount.")
    rebound = copy.deepcopy(ledger)
    rebound["version"] = "bg15-maa1-dated-original-currency-v2-rebound-v32-2026-09-06"
    rebound["sourceBinding"] = {k: v for k, v in report.items() if k != "events"}
    for event, check in zip(rebound["events"], checks):
        event["priorOriginalPayloadSha256"] = event["originalPayloadSha256"]
        event["originalPayloadSha256"] = check["reboundPayloadSha256"]
        event["versionOnlyRebinding"] = check
    return rebound, report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ["old-source", "new-source", "ledger", "old-source-sha", "new-source-sha", "output", "report"]:
        parser.add_argument("--" + arg, required=True)
    args = parser.parse_args()
    outputs = [Path(p).absolute() for p in [args.output, args.report]]
    if len(set(outputs)) != 2 or any(p.exists() or p.is_symlink() or not p.name.startswith("currency-lane") for p in outputs):
        raise ValueError("Distinct NEW currency-lane JSON output paths required")
    ledger, report = rebind(args.old_source, args.new_source, args.ledger, args.old_source_sha, args.new_source_sha)
    for path, data in zip(outputs, [ledger, report]):
        with path.open("x") as stream:
            stream.write(json.dumps(data, indent=2, ensure_ascii=False) + "\n")
    print(canonical({k: v for k, v in report.items() if k != "events"}))
