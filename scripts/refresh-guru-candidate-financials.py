#!/usr/bin/env python3
"""Append new paid PIT financial periods to a NEW private input candidate.

No model, price, active universe or production database writes. New inputs
invalidate the scoped issuer/guidance approval until a fresh review passes.
"""
import argparse
from contextlib import closing
import datetime as dt
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import sys


def module(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


def select_rows(rows, tickers, start, as_of):
    if not tickers or len(set(tickers)) != len(tickers) or any(
        not re.fullmatch(r"[A-Z0-9][A-Z0-9.-]{0,19}", t) for t in tickers
    ):
        raise ValueError("An exact nonempty uppercase ticker scope is required")
    if dt.date.fromisoformat(start) > dt.date.fromisoformat(as_of):
        raise ValueError("Invalid PIT window")
    occurrences, selected = {}, {}
    for raw in rows:
        row = dict(raw)
        if row.get("ticker") not in tickers or row.get("dimension") not in {"ARQ", "ART"}:
            raise ValueError("Unexpected security or non-PIT dimension")
        date = str(row.get("date", ""))
        end = str(row.get("reportperiod", ""))
        dt.date.fromisoformat(date)
        dt.date.fromisoformat(end)
        if not start <= date <= as_of or end > date or not re.fullmatch(r"20\d{2}-Q[1-4]", str(row.get("fiscalperiod", ""))):
            raise ValueError("Out-of-window or invalid financial period")
        key = (row["ticker"], row["fiscalperiod"], row["dimension"])
        identity = (*key, date)
        canonical = json.dumps(row, sort_keys=True, separators=(",", ":"))
        if identity in occurrences and occurrences[identity] != canonical:
            raise ValueError("Conflicting same-date PIT observations")
        occurrences[identity] = canonical
        if key not in selected or date < selected[key]["date"]:
            selected[key] = row
    return [selected[k] for k in sorted(selected)]


def fetch_scoped_rows(client, api, tickers, start, as_of):
    """Respect the paid endpoint's 200-character ticker parameter limit.

    Validate every response against its actual batch, not just the wider union,
    and finish all requests before opening any destination database.
    """
    select_rows([], tickers, start, as_of)
    batches, batch = [], []
    for ticker in tickers:
        if batch and (len(batch) >= 20 or len(",".join([*batch, ticker])) > 180):
            batches.append(batch)
            batch = []
        batch.append(ticker)
    if batch:
        batches.append(batch)
    result = []
    for batch in batches:
        rows = api.normalized_rows(client, "fundamentals", {
            "ticker": ",".join(batch), "dimension": "ARQ,ART",
            "date.gte": start, "date.lte": as_of,
        })
        select_rows(rows, batch, start, as_of)
        result.extend(rows)
    return result


def refresh_candidate(source_path, output_path, companies, rows, tickers, start, as_of):
    source_path = Path(source_path).resolve(strict=True)
    output_path = Path(output_path).resolve()
    if output_path.exists() or output_path == source_path:
        raise FileExistsError("Refusing to overwrite any source or existing output")
    selected = select_rows(rows, tickers, start, as_of)
    by_ticker = {c["ticker"]: c for c in companies}
    builder = module("guru_refresh_builder", "build-pit-valuation-source.py")
    api = module("guru_refresh_api", "refresh-pit-from-sharadar-api.py")
    prepared = []
    skipped = 0
    with closing(sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True)) as source:
        for ticker in tickers:
            company = by_ticker.get(ticker, {})
            if (company.get("sourceTicker") != ticker or company.get("currency") != "USD"
                    or company.get("reportingCurrency") != "USD" or not company.get("cik")):
                raise ValueError("This bounded refresher requires an exact USD/USD issuer identity; no FX or alias inference")
            if not source.execute("SELECT 1 FROM pit_issuer_review WHERE ticker=?", (ticker,)).fetchone():
                raise ValueError("Not an existing gated input candidate")
            if not source.execute("SELECT 1 FROM pit_guidance_coverage WHERE ticker=?", (ticker,)).fetchone():
                raise ValueError("Missing guidance review gate")
            if not source.execute("SELECT 1 FROM pit_financial_coverage WHERE ticker=?", (ticker,)).fetchone():
                raise ValueError("Missing financial coverage record")
        for raw in selected:
            ticker = raw["ticker"]
            prior = source.execute("SELECT available_at FROM pit_financial_periods WHERE ticker=? AND fiscal_period=? AND dimension=?",
                                   (ticker, raw["fiscalperiod"], raw["dimension"])).fetchone()
            if prior:
                # Never replace a retained historical observation with a later
                # restatement. An earlier/changed same-date row needs review.
                if raw["date"] <= prior[0]:
                    raise ValueError("Existing same/earlier observation requires explicit reconciliation")
                skipped += 1
                continue
            row = api.normalize_fundamental_row(raw)
            period = builder.build_period(ticker, ticker, row, identity=by_ticker[ticker])
            period["currencyReviewStatus"] = "pending_currency"
            period["sourceRecord"].update({
                "candidateReviewStatus": "pending_economic_review",
                "currencyIdentityBasis": "Candidate identity only; dated statement-currency audit required",
                "shareCountPolicy": "Unreviewed provider denominator; reconcile period-end versus cover-date shares before model consumption.",
                "incrementalProvider": "Sharadar paid fundamentals API",
                "incrementalAsOf": as_of,
            })
            prepared.append((raw, period))
        output_path.parent.mkdir(parents=True, exist_ok=True)
        # Exclusive reservation makes accidental replacement impossible.
        output_path.touch(mode=0o600, exist_ok=False)
        with closing(sqlite3.connect(output_path)) as dst:
            source.backup(dst)
    updated = sorted({r["ticker"] for r, _ in prepared})
    result = {
        "status": "inputs_only_release_blocked", "tickers": tickers,
        "asOf": as_of, "fromDate": start, "providerRows": len(rows),
        "newFinancialRows": len(prepared), "retainedLaterRestatementsSkipped": skipped,
        "updatedTickers": updated, "modelRowsAdded": 0, "priceRowsChanged": 0,
        "rawInputSha256": hashlib.sha256(json.dumps(rows, sort_keys=True, separators=(",", ":")).encode()).hexdigest(),
    }
    with closing(sqlite3.connect(output_path)) as dst:
        with dst:
            for raw, p in prepared:
                dst.execute("INSERT INTO pit_raw_financial_review VALUES(?,?,?,?,?)", (
                    raw["ticker"], raw["fiscalperiod"], raw["dimension"], raw["date"], json.dumps(raw, sort_keys=True)))
                dst.execute("INSERT INTO pit_financial_periods VALUES(?,?,?,?,?,?,?,?,?,?)", (
                    p["ticker"], p["sourceTicker"], raw["fiscalperiod"], p["fiscalYear"], p["fiscalQuarter"],
                    p["sourceDimension"], p["asOfDate"], p["periodEndDate"], p["financialStatementCurrency"],
                    json.dumps(p, separators=(",", ":"))))
            for ticker in updated:
                totals = dst.execute("SELECT SUM(dimension='ARQ'),SUM(dimension='ART'),MIN(available_at),MAX(available_at) FROM pit_financial_periods WHERE ticker=?", (ticker,)).fetchone()
                dst.execute("UPDATE pit_financial_coverage SET arq_periods=?,art_periods=?,first_available_at=?,last_available_at=?,note=? WHERE ticker=?",
                            (*totals, "New paid financial inputs only; economic review and source tie-out required", ticker))
                dst.execute("UPDATE pit_issuer_review SET status='pending_economic_review',reason=? WHERE ticker=?",
                            ("New financial period added; review dated currency, shares, claims, cash flow and model fit", ticker))
                dst.execute("UPDATE pit_guidance_coverage SET status='official_guidance_review_incomplete',note=? WHERE ticker=?",
                            ("Re-run scoped official review against the updated financial periods before model consumption", ticker))
            dst.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('guru_scoped_financial_refresh',?)", (json.dumps(result, sort_keys=True),))
        if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Candidate integrity failed; do not consume output")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-db", "output-db", "identities", "jansen-project"):
        parser.add_argument("--" + name, type=Path, required=True)
    for name in ("tickers", "from-date", "as-of"):
        parser.add_argument("--" + name, required=True)
    args = parser.parse_args()
    tickers = args.tickers.split(",")
    select_rows([], tickers, args.from_date, args.as_of)
    if dt.date.fromisoformat(args.as_of) > dt.datetime.now(dt.timezone.utc).date():
        raise ValueError("Future cutoff is not allowed")
    if args.output_db.exists():
        raise FileExistsError("Output already exists")
    sys.path.insert(0, str(args.jansen_project))
    from modern_us.sharadar import SharadarClient
    api = module("guru_refresh_api", "refresh-pit-from-sharadar-api.py")
    rows = fetch_scoped_rows(SharadarClient(retries=1, timeout_seconds=30), api,
                             tickers, args.from_date, args.as_of)
    result = refresh_candidate(args.source_db, args.output_db,
                               json.loads(args.identities.read_text())["companies"],
                               rows, tickers, args.from_date, args.as_of)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
