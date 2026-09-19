#!/usr/bin/env python3
"""Replace conflicting Yahoo snapshot points with independently read paid close.

COPY ONLY. Never changes price_points, valuation model results, financials,
generated_at, or any snapshot field other than priceHistory and explicitly named
comparisonPriceSourceEvidence. Original snapshot payloads and conflicting raw
price rows are archived. Fixed same-series tolerance is never widened.
"""
import argparse
from contextlib import closing
import datetime as dt
import gzip
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import subprocess

VERSION = "paid-original-comparison-only-repair-v1-2026-09-06"
PARQUET_SOURCE = "jansen-sharadar-sep-split-adjusted"
API_SOURCE = "sharadar-paid-api-split-adjusted"


def sha_bytes(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def file_sha(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as file:
        for block in iter(lambda: file.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def equal(a, b):
    return all(isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v) for v in [a, b]) and abs(a-b) <= 1e-7 * max(1, abs(a), abs(b))


def validate_original(row, key, cutoff):
    if (row.get("ticker"), row.get("date")) != key:
        raise ValueError("Original vendor security/date mismatch")
    date = dt.date.fromisoformat(row["date"])
    vintage = dt.date.fromisoformat(row.get("lastupdated") or "")
    if date > dt.date.fromisoformat(cutoff) or vintage > dt.date.fromisoformat(cutoff):
        raise ValueError("Original vendor observation/adjustment vintage is later than source cutoff")
    price = row.get("close")
    if isinstance(price, bool) or not isinstance(price, (float, int)) or not math.isfinite(price) or price <= 0:
        raise ValueError("Original vendor close must be positive and finite")
    return row


def original_paid_rows(parquet_path, raw_api_path, keys, cutoff):
    import pyarrow.dataset as ds
    dataset = ds.dataset(parquet_path, format="parquet", partitioning="hive")
    filt = ds.field("ticker").isin(sorted({k[0] for k in keys})) & ds.field("date").isin([dt.date.fromisoformat(v) for v in sorted({k[1] for k in keys})])
    columns = ["ticker", "date", "open", "high", "low", "close", "volume", "closeadj", "closeunadj", "lastupdated"]
    originals = {}
    for row in dataset.to_table(columns=columns, filter=filt).to_pylist():
        row = {k: v.isoformat() if isinstance(v, dt.date) else v for k, v in row.items()}
        key = (row["ticker"], row["date"])
        if key not in keys:
            continue
        validate_original(row, key, cutoff)
        if key in originals:
            raise ValueError("Duplicate original parquet security/date row")
        originals[key] = {"row": row, "source": PARQUET_SOURCE, "origin": str(Path(parquet_path).resolve()), "rawRowSha256": sha_bytes(json.dumps(row, sort_keys=True, separators=(",", ":")))}
    if raw_api_path:
        raw = json.loads(Path(raw_api_path).read_text())
        raw_hash = file_sha(raw_api_path)
        api_seen = set()
        for batch in raw["batches"]:
            if batch["httpStatus"] != 200 or batch["endpoint"] != "https://api.sharadar.com/v1.0/data/stocks":
                raise ValueError("Not a successful original paid stocks response")
            payload = batch["response"]
            # The stock endpoint's actual response schema, not an alternate
            # caller-supplied normalized price file or adjusted-close field.
            table = payload.get("datatable") or payload
            values = table.get("data") or table.get("rows") or []
            columns = [c["name"] if isinstance(c, dict) else c for c in table.get("columns", [])]
            if not values or (not columns and not all(isinstance(value, dict) for value in values)):
                raise ValueError("Unsupported original stock response schema")
            for value in values:
                row = dict(zip(columns, value)) if isinstance(value, list) else dict(value)
                key = (row.get("ticker"), row.get("date"))
                if key not in keys:
                    raise ValueError("Paid API returned an out-of-scope price")
                if key in api_seen:
                    raise ValueError("Duplicate original API security/date row")
                api_seen.add(key)
                validate_original(row, key, cutoff)
                if key in originals:
                    if not equal(originals[key]["row"]["close"], row["close"]):
                        raise ValueError("Original paid same-series conflict; dated review required")
                    continue
                originals[key] = {"row": row, "source": API_SOURCE, "origin": str(Path(raw_api_path).resolve()),
                    "rawResponseSha256": raw_hash, "request": batch["request"], "retrievedAt": raw["fetchedAt"],
                    "rawRowSha256": sha_bytes(json.dumps(row, sort_keys=True, separators=(",", ":")))}
    missing = keys - set(originals)
    if missing:
        raise ValueError(f"Missing independently read same-day paid prices: {sorted(missing)}")
    return originals


def repair_snapshot(snapshot, conflicts, originals, cutoff):
    if snapshot.get("currency") != "USD":
        raise ValueError("US paid dataset must not be used for non-USD quoted securities")
    result = dict(snapshot)
    history = list(snapshot.get("priceHistory") or [])
    edits = []
    seen = set()
    for conflict in conflicts:
        if conflict["provider"] != "yahoo" or not conflict["importBlocking"]:
            raise ValueError("Only independently replaced blocking Yahoo conflicts are authorized")
        candidates = [point for point in [conflict["left"], conflict["right"]] if point["kind"] == "released_snapshot"]
        if len(candidates) != 1:
            raise ValueError("Unexpected duplicate-snapshot conflict requires separate review")
        point = candidates[0]
        index = point["index"]
        if index in seen:
            raise ValueError("Duplicate repair target")
        seen.add(index)
        original_point = history[index]
        if any(original_point.get(k) != v for k, v in point.items() if k not in {"index", "kind"}):
            raise ValueError("Snapshot point changed since inventory")
        if original_point["source"] not in {"yahoo", "audited-series:yahoo", "audited-series:yahoo_query1_chart"}:
            raise ValueError("Do not relabel existing paid or unknown points")
        evidence = originals[(conflict["priceSymbol"], conflict["date"])]
        row = evidence["row"]
        validate_original(row, (conflict["priceSymbol"], conflict["date"]), cutoff)
        repaired = {key: row.get(key) for key in ["date", "open", "high", "low", "close", "volume"]}
        repaired["source"] = evidence["source"]
        repaired["sourceEvidence"] = {"version": VERSION, "field": "close", "unit": "USD per share",
            "basis": "split_adjusted_ex_cash_dividends_and_spinoffs", "sourceLastUpdated": row["lastupdated"],
            "sourceCutoff": cutoff, "originalRowSha256": evidence["rawRowSha256"], "origin": evidence["origin"],
            "comparisonOnly": True, "priceExcludedFromFairValue": True}
        history[index] = repaired
        edits.append({"date": conflict["date"], "priceSymbol": conflict["priceSymbol"], "snapshotIndex": index,
            "before": original_point, "after": repaired, "originalPaidEvidence": evidence,
            "rawPriceRowsPreserved": [p for p in [conflict["left"], conflict["right"]] if p["kind"] == "raw_price_point"],
            "comparison": "Paid vendor close replaces the snapshot's Yahoo series at this date; original Yahoo rows remain a different provider series, not equivalent numerical corroboration."})
    result["priceHistory"] = history
    result["comparisonPriceSourceEvidence"] = {"version": VERSION, "scope": "only exact original-paid comparison-point replacements",
        "changedDates": [e["date"] for e in edits], "priorMetadata": snapshot.get("comparisonPriceSourceEvidence"),
        "originalPriceSourceMetadata": snapshot.get("priceSource"), "comparisonOnly": True, "priceExcludedFromFairValue": True}
    for key in set(snapshot) | set(result):
        if key not in {"priceHistory", "comparisonPriceSourceEvidence"} and result.get(key) != snapshot.get(key):
            raise ValueError("Non-comparison snapshot field changed")
    return result, edits


def update_candidate_snapshots(target, changes):
    # A model-import seed is not a running application. Preserve the original
    # cache revision rather than letting this offline, comparison-only edit
    # invalidate unrelated runtime state. Only this exact cache-only trigger
    # is temporarily suspended; no economic or validation trigger is bypassed.
    name = "valuation_ticker_snapshots_revision_update"
    trigger = target.execute("SELECT sql FROM sqlite_master WHERE type='trigger' AND name=?", (name,)).fetchone()
    if trigger:
        normalized = re.sub(r"\s+", " ", trigger[0]).strip()
        expected = ("CREATE TRIGGER valuation_ticker_snapshots_revision_update AFTER UPDATE ON valuation_ticker_snapshots BEGIN "
                    "UPDATE cache_revisions SET revision = revision + 1 WHERE scope = 'valuation_ticker_snapshots'; END")
        if normalized != expected:
            raise ValueError("Unreviewed snapshot trigger definition; do not bypass")
    target.execute("BEGIN")
    try:
        if trigger:
            target.execute('DROP TRIGGER "valuation_ticker_snapshots_revision_update"')
        target.executemany("UPDATE valuation_ticker_snapshots SET payload_json=? WHERE ticker=?", changes)
        if trigger:
            target.execute(trigger[0])
        target.commit()
    except Exception:
        target.rollback()
        raise


def run(source_path, output_path, parquet_path, api_path, cutoff, directory):
    source_path = Path(source_path).resolve(strict=True)
    output_path, directory = Path(output_path).absolute(), Path(directory).absolute()
    if output_path.exists() or output_path.is_symlink() or directory.exists() or source_path == output_path.resolve():
        raise FileExistsError("NEW candidate and NEW audit directory required")
    if not output_path.name.startswith("price-lane") or not directory.name.startswith("price-lane"):
        raise ValueError("Private candidate/audit paths must use the price-lane prefix")
    directory.mkdir(parents=True)
    before_hash = file_sha(source_path)
    inventory_script = Path(__file__).with_name("inventory-valuation-comparison-conflicts.mjs")
    def inventory(path, output):
        call = subprocess.run(["node", str(inventory_script), str(path), str(output)], text=True, capture_output=True)
        if call.returncode:
            raise ValueError("Comparison inventory failed: " + call.stderr)
        return json.loads(output.read_text())
    before = inventory(source_path, directory / "inventory-before.json")
    if before["unverified"] or before["invalid"] or any(c["provider"] == "sharadar" for c in before["conflicts"]):
        raise ValueError("Unverified, invalid or existing paid same-series conflict requires a separate dated review")
    conflicts = [c for c in before["conflicts"] if c["importBlocking"]]
    keys = {(r["priceSymbol"], r["date"]) for r in conflicts}
    if not keys:
        raise ValueError("No explicitly inventoried blocking comparison prices to repair")
    originals = original_paid_rows(parquet_path, api_path, keys, cutoff)
    grouped = {}
    for conflict in conflicts:
        grouped.setdefault(conflict["ticker"], []).append(conflict)
    changes, archive = [], []
    with closing(sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True)) as source:
        for ticker, issues in grouped.items():
            row = source.execute("SELECT generated_at,payload_json FROM valuation_ticker_snapshots WHERE ticker=?", (ticker,)).fetchone()
            if row is None:
                raise ValueError("Missing exact original snapshot")
            result, edits = repair_snapshot(json.loads(row[1]), issues, originals, cutoff)
            updated = json.dumps(result, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
            archive.append({"ticker": ticker, "generatedAt": row[0], "originalPayloadJson": row[1], "edits": edits})
            changes.append((updated, ticker))
        fd = os.open(output_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        with closing(sqlite3.connect(output_path)) as target:
            source.backup(target)
            update_candidate_snapshots(target, changes)
            target.execute("ATTACH DATABASE ? AS original", (source_path.as_uri() + "?mode=ro",))
            schema = "SELECT type,name,tbl_name,sql FROM {database}.sqlite_master WHERE name NOT LIKE 'sqlite_%' ORDER BY type,name"
            if target.execute(schema.format(database="main")).fetchall() != target.execute(schema.format(database="original")).fetchall():
                raise ValueError("Candidate schema or trigger definition changed")
            table_names = [r[0] for r in source.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")]
            for table in table_names:
                if table == "valuation_ticker_snapshots":
                    continue
                difference = target.execute(f'SELECT 1 FROM (SELECT * FROM main."{table}" EXCEPT SELECT * FROM original."{table}") LIMIT 1').fetchone()
                reverse = target.execute(f'SELECT 1 FROM (SELECT * FROM original."{table}" EXCEPT SELECT * FROM main."{table}") LIMIT 1').fetchone()
                if difference or reverse:
                    raise ValueError("Non-snapshot table changed: " + table)
                if target.execute(f'SELECT COUNT(*) FROM main."{table}"').fetchone() != target.execute(f'SELECT COUNT(*) FROM original."{table}"').fetchone():
                    raise ValueError("Non-snapshot table row multiplicity changed: " + table)
            original_snapshots = {r[0]: tuple(r[1:]) for r in source.execute("SELECT ticker,generated_at,payload_json FROM valuation_ticker_snapshots")}
            candidate_snapshots = {r[0]: tuple(r[1:]) for r in target.execute("SELECT ticker,generated_at,payload_json FROM valuation_ticker_snapshots")}
            if original_snapshots.keys() != candidate_snapshots.keys():
                raise ValueError("Snapshot security set changed")
            for ticker, (generated_at, payload) in original_snapshots.items():
                candidate_at, candidate_payload = candidate_snapshots[ticker]
                if generated_at != candidate_at:
                    raise ValueError("Snapshot generated_at changed: " + ticker)
                if ticker not in grouped:
                    if payload != candidate_payload:
                        raise ValueError("Unrelated snapshot payload changed: " + ticker)
                    continue
                original_json, candidate_json = json.loads(payload), json.loads(candidate_payload)
                for field in set(original_json) | set(candidate_json):
                    if field not in {"priceHistory", "comparisonPriceSourceEvidence"} and original_json.get(field) != candidate_json.get(field):
                        raise ValueError("Non-price snapshot field changed: " + ticker + "/" + field)
            if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("Candidate integrity failed")
    with gzip.open(directory / "original-snapshots-and-price-evidence.json.gz", "wt", encoding="utf8") as file:
        json.dump(archive, file, separators=(",", ":"), ensure_ascii=False, allow_nan=False)
    after = inventory(output_path, directory / "inventory-after.json")
    if after["summary"]["blocking"] or after["invalid"] or after["unverified"] or after["mergeFailures"]:
        raise ValueError("Candidate still has comparison-price import blockers")
    if file_sha(source_path) != before_hash:
        raise ValueError("Read-only input DB changed during preparation")
    result = {"version": VERSION, "status": "comparison_price_seed_ready_not_model_or_release_approval", "sourceCutoff": cutoff,
        "sourceDb": str(source_path), "sourceSha256": before_hash, "outputDb": str(output_path), "outputSha256": file_sha(output_path),
        "before": before["summary"], "after": after["summary"], "repairedPoints": len(conflicts), "repairedSnapshots": len(changes),
        "allNonSnapshotTablesExact": True, "guruPriceRowsChanged": 0, "valuationModelRowsChanged": 0,
        "snapshotOnlyChangedFields": ["priceHistory", "comparisonPriceSourceEvidence"], "sourceDbUnchanged": True,
        "unrelatedSnapshotsByteExact": True, "snapshotDatesAndSecuritySetExact": True,
        "schemaAndTriggersExact": True, "cacheRevisionsExact": True,
        "actualImporterComparisonMergeVerified": after["summary"]["snapshots"],
        "originalArchive": str(directory / "original-snapshots-and-price-evidence.json.gz"),
        "originalArchiveSha256": file_sha(directory / "original-snapshots-and-price-evidence.json.gz"), "releaseAuthorized": False}
    (directory / "report.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ["source-db", "output-db", "parquet", "audit-dir"]:
        parser.add_argument("--" + key, type=Path, required=True)
    parser.add_argument("--paid-api-raw", type=Path)
    parser.add_argument("--source-cutoff", required=True)
    args = parser.parse_args()
    run(args.source_db, args.output_db, args.parquet, args.paid_api_raw, args.source_cutoff, args.audit_dir)
