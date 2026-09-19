#!/usr/bin/env python3
"""Export local AR facts to a NEW compatible PIT source DB; never run/change DCF.

Existing guidance/FX evidence is copied with SQLite backup. Only the financial
projection in the new file is regenerated. Canonical raw facts remain in Fact OS.
Unsupported foreign quoted models stay explicitly blocked rather than guessing
FX or borrowing old financials. This command never accesses any remote provider.
"""
from __future__ import annotations

import argparse
from datetime import date, datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import sqlite3
import sys

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
from fact_os.repository import FactRepository, MissingData


def day(value):
    return value.isoformat() if isinstance(value, date) else str(value) if value is not None else None


def first_visible(rows):
    selected = {}
    for row in rows:
        key = (row["fiscalperiod"], row["dimension"])
        if key not in selected or row["date"] < selected[key]["date"]:
            selected[key] = row
    return sorted(selected.values(), key=lambda row: (row["date"], row["dimension"]))


def build_period(ticker, row):
    match = re.fullmatch(r"(\d{4})-(Q[1-4])", str(row.get("fiscalperiod", "")))
    if not match:
        raise ValueError("invalid fiscal-period label")
    # This export deliberately supports the existing USD-model path only. It is
    # not a place to guess a missing FX rate or alter a model's quoted security.
    fx = row.get("fxusd")
    if fx is None or float(fx) <= 0:
        raise ValueError("missing reported FX conversion")
    def money(local, usd=None):
        value = row.get(usd) if usd and row.get(usd) is not None else None
        if value is None:
            raw = row.get(local)
            value = float(raw) / float(fx) if raw is not None else None
        return value / 1_000_000 if value is not None else None
    shares = next((row.get(k) for k in ("shareswadil", "shareswa", "sharesbas") if row.get(k) is not None), None)
    sharefactor = row.get("sharefactor")
    if shares is not None and sharefactor is None:
        raise ValueError("missing reported share factor")
    cfo, capex = money("ncfo"), money("capex")
    capex = abs(capex) if capex is not None else None
    year, quarter = match.groups()
    return {
        "ticker": ticker, "sourceTicker": row["ticker"], "key": f"{year}::{quarter}",
        "fiscalYear": int(year), "fiscalQuarter": quarter, "label": f"FY{year} {quarter}",
        "asOfDate": day(row["date"]), "periodEndDate": day(row["reportperiod"]),
        "calendarDate": day(row["calendardate"]), "financialStatementCurrency": "USD",
        "sourceDimension": row["dimension"], "revenue_m": money("revenue", "revenueusd"),
        "gross_profit_m": money("gp"), "operating_income_m": money("opinc"),
        "net_income_m": money("netinc", "netinccmnusd"), "cfo_m": cfo, "capex_m": capex,
        "fcf_after_capex_m": cfo-capex if cfo is not None and capex is not None else None,
        "shares_m": float(shares) * float(sharefactor) / 1_000_000 if shares is not None else None,
        "equity_m": money("equity", "equityusd"), "assets_m": money("assets"),
        "cash_m": money("cashneq", "cashnequsd"), "debt_m": money("debt", "debtusd"),
        "sourceRecord": {"dataset": "Sharadar Local Fact OS", "dimension": row["dimension"],
                         "metricsAreTrailingTwelveMonths": row["dimension"] == "ART",
                         "sourceTicker": row["ticker"], "datekey": day(row["date"]),
                         "reportperiod": day(row["reportperiod"]), "calendardate": day(row["calendardate"]),
                         "lastupdatedExcludedFromPitCutoff": day(row.get("lastupdated")),
                         "currency": "USD", "currencyScale": 1,
                         "currencyScaleNote": "Existing USD model exporter conversion: explicit USD field, otherwise reporting amount / reported fxusd",
                         "sharefactor": sharefactor, "selectionPolicy": "earliest date per fiscal period and AR dimension",
                         "provenance": row["provenance"]},
        "sources": {key: {"dataset": "Sharadar Local Fact OS", "filed": day(row["date"]),
                          "end": day(row["reportperiod"]), "dimension": row["dimension"],
                          "form": row["dimension"], "annualOnly": row["dimension"] == "ART", "sourceTicker": row["ticker"]}
                    for key in ("revenue_m", "gross_profit_m", "operating_income_m", "net_income_m", "cfo_m", "capex_m", "shares_m", "equity_m", "assets_m", "cash_m", "debt_m")}}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT / "data/fact_os")
    parser.add_argument("--target-db", type=Path, default=ROOT / "server/data/guru-analysis.sqlite")
    parser.add_argument("--evidence-db", type=Path, default=ROOT / "server/data/valuation-pit-source.sqlite")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--as-of", default=date.today().isoformat())
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output in (args.target_db.resolve(), args.evidence_db.resolve()):
        raise ValueError("Output must be a new file; existing data will not be overwritten")
    with sqlite3.connect(args.target_db.resolve().as_uri() + "?mode=ro", uri=True) as target:
        snapshots = [(ticker, json.loads(payload)) for ticker, payload in target.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker")]
    catalog_path = args.root / "manifests/catalog.json"
    catalog_before = catalog_path.read_bytes()
    repo = FactRepository(args.root)
    periods, coverage = [], []
    try:
        for ticker, snapshot in snapshots:
            source = ticker
            status, note = "missing", None
            selected = []
            if str(snapshot.get("currency") or "USD").upper() != "USD" or ticker.endswith(".L"):
                note = "Non-USD quoted security requires separately verified issuer/security/FX mapping; no old financial fallback."
            else:
                try:
                    rows = repo.get_fundamentals(source, "ARQ", as_of=args.as_of) + repo.get_fundamentals(source, "ART", as_of=args.as_of)
                    selected = [build_period(ticker, row) for row in first_visible(rows)]
                except (MissingData, ValueError) as error:
                    note = str(error)
            arq = sum(row["sourceDimension"] == "ARQ" for row in selected)
            art = sum(row["sourceDimension"] == "ART" for row in selected)
            dates = sorted(row["asOfDate"] for row in selected)
            status = "covered" if arq else "annual_only" if art else "missing"
            coverage.append((ticker, source, status, arq, art, dates[0] if dates else None, dates[-1] if dates else None, note))
            periods.extend(selected)
    finally:
        repo.close()
    if catalog_path.read_bytes() != catalog_before:
        raise RuntimeError("Fact OS generation changed during export; rerun against one stable generation")
    output.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.evidence_db.resolve().as_uri() + "?mode=ro", uri=True) as source, sqlite3.connect(output) as db:
        source.backup(db)
        db.execute("DELETE FROM pit_financial_periods")
        db.execute("DELETE FROM pit_financial_coverage")
        for row in periods:
            db.execute("INSERT INTO pit_financial_periods VALUES (?,?,?,?,?,?,?,?,?,?)", (
                row["ticker"], row["sourceTicker"], f'{row["fiscalYear"]}-{row["fiscalQuarter"]}',
                row["fiscalYear"], row["fiscalQuarter"], row["sourceDimension"], row["asOfDate"],
                row["periodEndDate"], row["financialStatementCurrency"], json.dumps(row, default=str, separators=(",", ":"))))
        db.executemany("INSERT INTO pit_financial_coverage VALUES (?,?,?,?,?,?,?,?,?)", coverage)
        metadata = {"source": "Sharadar Local Fact OS", "source_root": str(args.root.resolve()),
                    "source_fingerprint": hashlib.sha256(catalog_before).hexdigest(),
                    "generated_at": datetime.now(timezone.utc).isoformat(), "as_of": args.as_of,
                    "revision_policy": "earliest AR availability per fiscal period/dimension; MR excluded",
                    "canonical_prices_required": "Existing model rebuild must use FactRepository RAW_CLOSE, not embedded Yahoo prices",
                    "target_ticker_count": str(len(snapshots))}
        db.executemany("INSERT OR REPLACE INTO pit_source_metadata VALUES (?,?)", metadata.items())
        db.commit()
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Candidate export integrity check failed")
    print(json.dumps({"output": str(output), "financial_rows": len(periods), "tickers": len(snapshots),
                      "blockers": [{"ticker": row[0], "status": row[2], "note": row[8]} for row in coverage if row[2] == "missing"],
                      "models_rebuilt": False, "production_changed": False}, indent=2))


if __name__ == "__main__":
    main()
