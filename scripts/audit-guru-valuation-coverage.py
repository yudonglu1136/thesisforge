#!/usr/bin/env python3
"""Read-only Guru/valuation/PIT reconciliation. Never creates a valuation.

The public security master is a historical top-60 selected-book universe, not
the complete live holdings database. Its scope is deliberately in every report.
Licensed financial/price observations stay local; this report emits availability
and identity metadata only, never provider financial amounts or prices.
"""
from __future__ import annotations

import argparse
import collections
import datetime as dt
import hashlib
import json
import re
import sqlite3
from pathlib import Path

import pyarrow.dataset as ds


def read_snapshots(database):
    if not database.is_file():
        raise FileNotFoundError(database)
    connection = sqlite3.connect(f"{database.resolve().as_uri()}?mode=ro", uri=True)
    try:
        return {ticker: json.loads(payload) for ticker, payload in connection.execute(
            "SELECT ticker,payload_json FROM valuation_ticker_snapshots"
        )}
    finally:
        connection.close()


def classify(security, metadata, has_financials, has_prices, covered):
    if covered:
        return "covered"
    if security.get("securityType2") in {"ETP", "Mutual Fund"} or (
        security.get("providerValidation", {}).get("instrumentType") in {"ETF", "MUTUALFUND"}
    ):
        return "fund_not_operating_company"
    if not metadata:
        return "missing_exact_local_identity"
    if not has_financials:
        return "missing_local_pit_financials"
    if not has_prices:
        return "missing_local_price_history"
    return "needs_economic_profile_and_official_guidance_review"


def audit(database, root, master_path, sec_path, as_of):
    master = json.loads(master_path.read_text())
    sec = json.loads(sec_path.read_text())
    snapshots = read_snapshots(database)
    covered = set(snapshots)
    for snapshot in snapshots.values():
        # Only explicit released aliases, never fuzzy name matches.
        covered.update(str(a).upper() for a in snapshot.get("aliases", []) if isinstance(a, str))
    securities = master["securities"]
    tickers = sorted({s["ticker"] for s in securities})
    metadata_rows = ds.dataset(root / "tickers", format="parquet", partitioning="hive").to_table(
        filter=ds.field("ticker").isin(tickers) & (ds.field("table") == "SF1")
    ).to_pylist()
    metadata_by_ticker = collections.defaultdict(list)
    for row in metadata_rows:
        metadata_by_ticker[row["ticker"]].append(row)
    fundamentals = ds.dataset(root / "fundamentals", format="parquet", partitioning="hive")
    cutoff = "datekey" if "datekey" in fundamentals.schema.names else "date"
    rows = fundamentals.to_table(columns=["ticker", "dimension", cutoff], filter=(
        ds.field("ticker").isin(tickers) & ds.field("dimension").isin(["ARQ", "ART"])
        & (ds.field(cutoff) <= as_of)
    )).to_pylist()
    availability = collections.defaultdict(list)
    for row in rows:
        availability[row["ticker"]].append(row[cutoff].isoformat())
    prices = ds.dataset(root / "prices", format="parquet", partitioning="hive").to_table(
        columns=["ticker", "date"], filter=ds.field("ticker").isin(tickers)
        & (ds.field("date") <= as_of) & (ds.field("close") > 0)
    ).to_pylist()
    price_dates = collections.defaultdict(list)
    for row in prices:
        price_dates[row["ticker"]].append(row["date"].isoformat())
    observations = {row["cusip"]: row for row in sec["cusips"]}
    latest_report = sec["window"]["endReportDate"]
    result = []
    for security in securities:
        ticker = security["ticker"]
        matches = [row for row in metadata_by_ticker[ticker]
                   if security["cusip"] in re.findall(r"[A-Z0-9]{9}", row.get("cusips") or "")]
        # A recycled symbol may be in local data but is not the same security.
        identities = {row.get("permaticker") for row in matches}
        metadata = max(matches, key=lambda r: str(r.get("lastupdated"))) if len(identities) == 1 else None
        observation = observations.get(security["cusip"], {})
        record = {
            "ticker": ticker, "cusip": security["cusip"], "name": security["name"],
            "securityType": security.get("securityType2"),
            "inLatestSelectedBook": security.get("lastReportDate") == latest_report,
            "lastReportDate": security.get("lastReportDate"),
            "managerIds": observation.get("managerIds", []),
            "maxHistoricalSelectedWeightPpm": observation.get("maxSelectedWeightPpm"),
            "status": classify(security, metadata, bool(availability[ticker]), bool(price_dates[ticker]), ticker in covered),
            "localIdentityMatch": metadata is not None,
            "lastFinancialAvailableAt": max(availability[ticker], default=None),
            "lastPositivePriceDate": max(price_dates[ticker], default=None),
            "reportingCurrency": metadata.get("currency") if metadata else None,
            "industry": metadata.get("industry") if metadata else None,
            "sector": metadata.get("sector") if metadata else None,
            "secFilings": metadata.get("secfilings") if metadata else None,
            "guidanceReview": "not_reviewed_in_this_inventory",
        }
        result.append(record)
    result.sort(key=lambda r: (not r["inLatestSelectedBook"], r["status"] == "covered", -(r["maxHistoricalSelectedWeightPpm"] or 0), r["ticker"]))
    latest = [r for r in result if r["inLatestSelectedBook"]]
    latest_unresolved = [r for r in sec["cusips"] if r.get("lastReportDate") == latest_report
                         and r["cusip"] not in {s["cusip"] for s in securities}]
    return {
        "schemaVersion": 1, "asOf": as_of.isoformat(),
        "scope": sec["holdingSelectionPolicy"], "latestReportDate": latest_report,
        "limitations": ["Public manifest covers historical top-60 selected common-long holdings per filing, not the complete live Guru book.",
                        "Local financial presence is not proof of an audited/modelable valuation or verified management guidance.",
                        "Manager IDs and maximum weights are historical observations, not an assertion of current manager ownership."],
        "securityMasterSha256": hashlib.sha256(master_path.read_bytes()).hexdigest(),
        "releasedValuationTickers": len(snapshots),
        "summary": dict(collections.Counter(r["status"] for r in result)),
        "latestSelectedBookSummary": dict(collections.Counter(r["status"] for r in latest)),
        "latestSelectedUnresolvedCusips": len(latest_unresolved),
        "securities": result,
        "unresolvedLatestSelected": [{k:r.get(k) for k in ("cusip", "issuerNames", "managerIds", "lastReportDate")} for r in latest_unresolved],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--jansen-root", type=Path, required=True)
    parser.add_argument("--security-master", type=Path, default=Path("server/config/guru-security-master.json"))
    parser.add_argument("--sec-manifest", type=Path, default=Path("server/config/guru-sec-cusip-manifest.json"))
    parser.add_argument("--as-of", type=dt.date.fromisoformat, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = audit(args.database, args.jansen_root, args.security_master, args.sec_manifest, args.as_of)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps({k:v for k,v in report.items() if k not in {"securities", "unresolvedLatestSelected"}}, indent=2))


if __name__ == "__main__":
    main()
