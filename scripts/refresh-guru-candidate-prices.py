#!/usr/bin/env python3
"""Refresh dated comparison prices in an isolated reviewed-batch candidate only."""
import argparse
import datetime as dt
import importlib.util
import json
import math
from pathlib import Path
import sqlite3
import sys


def validate_prices(rows, tickers, start, end):
    expected = set(tickers)
    if not expected or len(expected) != len(tickers) or any(not t or t != t.upper() for t in tickers):
        raise ValueError("A nonempty exact uppercase security scope is required")
    if dt.date.fromisoformat(start) > dt.date.fromisoformat(end):
        raise ValueError("Invalid observation window")
    seen = set()
    selected = []
    for row in rows:
        ticker, date = str(row.get("ticker", "")).upper(), str(row.get("date", ""))[:10]
        if ticker not in expected or not start <= date <= end:
            raise ValueError("Provider returned an out-of-scope ticker or date")
        dt.date.fromisoformat(date)
        price = row.get("close")
        if isinstance(price, bool) or not isinstance(price, (int, float)) or not math.isfinite(price) or price <= 0:
            raise ValueError(f"Non-positive/non-finite price for {ticker} {date}")
        if (ticker, date) in seen:
            raise ValueError("Duplicate quoted-security price observation")
        seen.add((ticker, date))
        selected.append({**row, "ticker": ticker, "date": date})
    if {r["ticker"] for r in selected} != expected:
        raise ValueError("At least one requested security has no prices")
    return selected


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--preparation", type=Path, required=True)
    parser.add_argument("--from-date", required=True)
    parser.add_argument("--as-of", required=True)
    parser.add_argument("--jansen-project", type=Path, required=True)
    args = parser.parse_args()
    start, end = dt.date.fromisoformat(args.from_date), dt.date.fromisoformat(args.as_of)
    if start > end or end > dt.datetime.now(dt.timezone.utc).date():
        raise ValueError("Invalid observation window")
    preparation = json.loads(args.preparation.read_text())
    target_path = Path(preparation["model"]).resolve(strict=True)
    if preparation.get("status") != "isolated_model_candidate_not_release" or target_path.parent != args.preparation.resolve().parent:
        raise ValueError("Only an isolated prepared candidate is authorized")
    tickers = preparation["tickers"]
    sys.path.insert(0, str(args.jansen_project))
    from modern_us.sharadar import SharadarClient
    spec = importlib.util.spec_from_file_location("paid_rows", Path(__file__).with_name("refresh-pit-from-sharadar-api.py"))
    helper = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(helper)
    client = SharadarClient(timeout_seconds=30, retries=1)
    rows = validate_prices(helper.normalized_rows(client, "stocks", {
        "ticker": ",".join(tickers), "date.gte": start.isoformat(), "date.lte": end.isoformat(),
    }), tickers, start.isoformat(), end.isoformat())
    observed = dt.datetime.now(dt.timezone.utc).isoformat()
    with sqlite3.connect(target_path) as db:
        existing = {r[0] for r in db.execute("SELECT ticker FROM valuation_ticker_snapshots")}
        if existing != set(tickers):
            raise ValueError("Candidate scope changed; refusing to touch other securities")
        db.execute("""CREATE TABLE IF NOT EXISTS price_points(symbol TEXT NOT NULL,date TEXT NOT NULL,
            open REAL,high REAL,low REAL,close REAL,volume REAL,source TEXT,updated_at TEXT,
            PRIMARY KEY(symbol,date))""")
        for row in rows:
            db.execute("""INSERT INTO price_points VALUES(?,?,?,?,?,?,?,'sharadar-paid-api-split-adjusted',?)
                ON CONFLICT(symbol,date) DO UPDATE SET open=excluded.open,high=excluded.high,low=excluded.low,
                close=excluded.close,volume=excluded.volume,source=excluded.source,updated_at=excluded.updated_at""", (
                row["ticker"], row["date"], row.get("open"), row.get("high"), row.get("low"), row["close"], row.get("volume"), observed))
        db.commit()
    result = {"scope": "comparison_prices_only", "tickers": tickers, "rows": len(rows), "observedAt": observed,
              "latestByTicker": {t: max(r["date"] for r in rows if r["ticker"] == t) for t in tickers},
              "fairValueInput": False, "provider": "existing paid Sharadar API"}
    (target_path.parent / "price-refresh.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
