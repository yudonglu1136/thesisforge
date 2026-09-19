#!/usr/bin/env python3
"""Freeze reviewed-date paid SPOT ART input and exact comparison quote privately."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sqlite3
import sys
import pyarrow.dataset as ds


def canonical(value):
    # JS JSON.stringify-compatible for the original endpoint's primitive rows.
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"), default=str)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-db", "fx", "jansen-project", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError("Immutable input exists")
    with sqlite3.connect(f"{args.source_db.resolve().as_uri()}?mode=ro", uri=True) as db:
        result = db.execute("SELECT payload_json FROM pit_financial_periods WHERE ticker='SPOT' AND dimension='ART' ORDER BY available_at DESC LIMIT 1").fetchone()
        if not result:
            raise ValueError("No paid ART input")
        financial = json.loads(result[0])
        financial_payload_sha = hashlib.sha256(result[0].encode()).hexdigest()
    if financial.get("periodEndDate") != "2026-06-30" or financial.get("asOfDate") != "2026-08-04":
        raise ValueError("Not the independently reviewed SPOT period")
    sys.path.insert(0, str(args.jansen_project.resolve()))
    from modern_us.sharadar import SharadarClient
    spec = importlib.util.spec_from_file_location("paid", Path(__file__).with_name("refresh-pit-from-sharadar-api.py"))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    rows = helper.normalized_rows(SharadarClient(timeout_seconds=30, retries=1), "stocks", {
        "ticker": "SPOT", "date.gte": "2026-09-04", "date.lte": "2026-09-04"})
    if len(rows) != 1 or rows[0].get("ticker") != "SPOT" or rows[0].get("date") != "2026-09-04" or not rows[0].get("close", 0) > 0:
        raise ValueError("No unique original paid SPOT Sep 4 close")
    table = ds.dataset(args.jansen_project / "data/sharadar/parquet/tickers", format="parquet", partitioning="hive")
    records = table.to_table(filter=(ds.field("ticker") == "SPOT") & (ds.field("table") == "SEP")).to_pylist()
    if len(records) != 1 or records[0].get("currency") != "USD" or "1639920" not in records[0].get("secfilings", ""):
        raise ValueError("Original quoted-security metadata is ambiguous")
    result = {"schemaVersion": 1, "status": "private_current_inputs_not_release", "asOfDate": "2026-09-05",
        "input": {"ticker": "SPOT", "asOfDate": "2026-09-05", "financial": financial, "fxRecords": json.loads(args.fx.read_text())["rates"]},
        "quote": {"originalRecord": rows[0], "source": "sharadar-paid-api-split-adjusted", "priceSymbol": "SPOT",
            "quoteCurrency": "USD", "quotedSecurityMetadata": records[0], "comparisonOnly": True},
        "sourceBindings": {"financialPayloadSha256": financial_payload_sha,
            "originalPriceSha256": hashlib.sha256(canonical(rows[0]).encode()).hexdigest(),
            "originalMetadataSha256": hashlib.sha256(canonical(records[0]).encode()).hexdigest(),
            "fxFileSha256": hashlib.sha256(args.fx.read_bytes()).hexdigest()},
        "historicalApproval": False, "productionWrites": 0}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    raw = json.dumps(result, indent=2, default=str) + "\n"
    args.output.write_text(raw)
    print(json.dumps({"path": str(args.output.resolve()), "sha256": hashlib.sha256(raw.encode()).hexdigest(), "ticker": "SPOT", "priceDate": "2026-09-04", "comparisonOnly": True}))


if __name__ == "__main__":
    main()
