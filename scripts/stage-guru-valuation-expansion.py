#!/usr/bin/env python3
"""Stage missing Guru financial/price inputs into NEW, private candidate files.

This is not a valuation release. Every company remains locked pending an
economic/share-class/currency review. Official management evidence can then be
collected against this bounded scope without touching the released 533 tickers.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import importlib.util
import json
import re
import sqlite3
from pathlib import Path

import pyarrow.dataset as ds


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    result = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(result)
    return result


CURRENT_VISIBLE_SCOPE = "exact_cusip_current_visible_targets_not_latest_selected_book"


def validated_current_visible_targets(inventory):
    """Recheck original occurrence and SF1/SEP evidence, not candidate flags."""
    binding = inventory.get("sourceVisibilityBinding", {})
    if inventory.get("status") != "private_staging_candidates_only" or inventory.get("economicApproval") is not False:
        raise ValueError("Current-visible staging must remain private and economically unapproved")
    raw = Path(binding["path"]).read_bytes()
    if hashlib.sha256(raw).hexdigest() != binding.get("sha256"):
        raise ValueError("Current-visible source SHA256 mismatch")
    visible = json.loads(raw)
    cutoff = dt.date.fromisoformat(inventory["asOf"])
    if visible.get("asOf") != cutoff.isoformat():
        raise ValueError("Current-visible source date does not match inventory")
    scope = visible["currentQuarterAndLatestSnapshotInventory"]
    missing = set(scope["missingTickers"])
    if len(missing) != scope["missingValuationTargets"] or scope["releasedValuationTargets"] + len(missing) != scope["uniqueClickableTargets"]:
        raise ValueError("Current-visible coverage denominator is inconsistent")
    # Same scope as the source audit: current nonconditional surfaces, plus the
    # latest dated position exposure. A historical exposure is not identity proof.
    dates = visible.get("dataCuts", {}).get("exposureReportDates", [])
    latest_exposure = max((d for d in dates if dt.date.fromisoformat(d) <= cutoff), default=None)
    current = {}
    for occurrence in visible["occurrences"]:
        if not occurrence.get("rendered") or not occurrence.get("clickable") or occurrence.get("conditional"):
            continue
        date = occurrence.get("reportDate")
        if date and dt.date.fromisoformat(date) > cutoff:
            raise ValueError("Future occurrence in current-visible source")
        if occurrence["surface"].startswith("exposure.") and (latest_exposure is None or date != latest_exposure):
            continue
        current.setdefault(occurrence["target"], set()).add(occurrence.get("cusip"))
    targets = []
    for row in inventory["securities"]:
        ticker, cusip = row["ticker"], row["cusip"]
        evidence = row.get("currentVisibleEvidence", {})
        if (row.get("inCurrentVisibleTarget") is not True or row.get("inLatestSelectedBook") is not False
                or row.get("reviewStatus") != "unreviewed" or row.get("economicModelAuthorized") is not False
                or row.get("status") != "needs_economic_profile_and_official_guidance_review"):
            raise ValueError(f"Current-visible candidate flags invalid: {ticker}")
        if (ticker not in missing or not re.fullmatch(r"[A-Z0-9]{9}", cusip)
                or cusip not in current.get(ticker, set())):
            raise ValueError(f"No exact current missing ticker/CUSIP occurrence: {ticker}")
        if (evidence.get("sourcePath") != binding["path"] or evidence.get("sourceSha256") != binding["sha256"]
                or evidence.get("inventoryKey") != "currentQuarterAndLatestSnapshotInventory"
                or evidence.get("ticker") != ticker or evidence.get("cusip") != cusip):
            raise ValueError(f"Current-visible evidence binding mismatch: {ticker}")
        records = row.get("sourceMetadataRecords", [])
        digest = hashlib.sha256(json.dumps(records, sort_keys=True, default=str).encode()).hexdigest()
        if not records or digest != evidence.get("metadataSha256"):
            raise ValueError(f"Original metadata SHA256 mismatch: {ticker}")
        if any(r.get("ticker") != ticker or r.get("table") not in {"SF1", "SEP"} for r in records):
            raise ValueError(f"Foreign ticker/table in metadata: {ticker}")
        matched = [r for r in records if cusip in re.findall(r"[A-Z0-9]{9}", r.get("cusips") or "")]
        if ({r.get("table") for r in matched} != {"SF1", "SEP"}
                or len({r.get("permaticker") for r in matched}) != 1
                or any(not r.get("permaticker") or r.get("isdelisted") != "N" for r in matched)):
            raise ValueError(f"Incomplete, delisted or ambiguous SF1/SEP identity: {ticker}")
        for record in matched:
            if "Common Stock" not in (record.get("category") or ""):
                raise ValueError(f"Non-operating security requires a separate method: {ticker}")
            if record.get("lastupdated") and dt.date.fromisoformat(record["lastupdated"]) > cutoff:
                raise ValueError(f"Future identity metadata: {ticker}")
            cik = re.search(r"CIK=(\d+)", record.get("secfilings") or "", re.I)
            if not cik or cik.group(1).zfill(10) != row.get("cik"):
                raise ValueError(f"CIK mismatch in original metadata: {ticker}")
            expected = row["reportingCurrency"] if record["table"] == "SF1" else row.get("quoteCurrency")
            if not expected or record.get("currency") != expected:
                raise ValueError(f"Currency mismatch in original metadata: {ticker}")
        # This staging normalizer currently produces USD money. Non-USD quoted
        # classes require an explicit additional conversion implementation.
        if row.get("quoteCurrency") != "USD":
            raise ValueError(f"Non-USD quoted security not supported by this staging lane: {ticker}")
        targets.append(row)
    return targets


def select_staging_targets(inventory, tickers=None):
    """Only exact-identity missing coverage can enter this private staging lane."""
    if inventory.get("scope") == CURRENT_VISIBLE_SCOPE:
        targets = validated_current_visible_targets(inventory)
    else:
        targets = [r for r in inventory["securities"] if r["inLatestSelectedBook"]
                   and r["status"] == "needs_economic_profile_and_official_guidance_review"]
    if tickers:
        requested = {s.strip().upper() for s in tickers.split(",") if s.strip()}
        absent = requested - {r["ticker"] for r in targets}
        if absent:
            raise ValueError(f"Not in exact-identity missing coverage set: {sorted(absent)}")
        targets = [r for r in targets if r["ticker"] in requested]
    by_ticker = {r["ticker"]: r for r in targets}
    if len(by_ticker) != len(targets):
        raise ValueError("Duplicate ticker/share-class identity requires manual resolution")
    if not by_ticker:
        raise ValueError("No eligible missing-coverage securities; no candidate files created")
    return by_ticker


def pending_company_identity(ticker, identity):
    cik_match = re.search(r"CIK=(\d+)", identity.get("secFilings") or "", re.I)
    if not cik_match:
        raise ValueError(f"Missing issuer CIK: {ticker}")
    if identity.get("cik") and identity["cik"] != cik_match[1].zfill(10):
        raise ValueError(f"Conflicting issuer CIK: {ticker}")
    if identity.get("quoteCurrency", "USD") != "USD":
        raise ValueError(f"Non-USD quote needs a separate conversion: {ticker}")
    return {"ticker": ticker, "sourceTicker": ticker, "priceTicker": ticker, "name": identity["name"],
            "cik": cik_match[1].zfill(10), "cusip": identity["cusip"], "currency": "USD",
            "reportingCurrency": identity["reportingCurrency"], "reviewStatus": "unreviewed",
            "reason": "Pending historical issuer currency, security-factor, cash-flow, guidance and economic-profile audit"}


def stage_financial_period(source, builder, ticker, row, company, fx_book, fx_errors):
    """Persist original PIT money before any conversion, including blocked FX."""
    source.execute("INSERT INTO pit_raw_financial_review VALUES(?,?,?,?,?)", (
        ticker, row["fiscalperiod"], row["dimension"], row["datekey"].isoformat(),
        json.dumps(row, default=str, separators=(",", ":"))))
    if company["reportingCurrency"] in fx_errors:
        return None
    period = builder.build_period(ticker, ticker, row, fx_rate_book=fx_book, identity=company)
    period["sourceRecord"]["candidateReviewStatus"] = "pending_economic_review"
    period["sourceRecord"]["currencyIdentityBasis"] = "Exact-CUSIP local SF1 metadata; historical currency validation pending"
    source.execute("INSERT INTO pit_financial_periods VALUES(?,?,?,?,?,?,?,?,?,?)", (
        ticker, ticker, row["fiscalperiod"], period["fiscalYear"], period["fiscalQuarter"], row["dimension"],
        period["asOfDate"], period["periodEndDate"], period["financialStatementCurrency"], json.dumps(period, separators=(",", ":"))))
    return period


def insert_candidate_review_gates(source, ticker, company):
    # Financial coverage is input availability, never permission to publish.
    source.execute("INSERT INTO pit_issuer_review VALUES(?,?,?)", (ticker, "pending_economic_review", company["reason"]))
    source.execute("INSERT INTO pit_guidance_coverage VALUES(?,0,0,0,0,'official_guidance_review_incomplete',?)", (ticker, "Official filings must be reviewed; no fabricated guidance"))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--jansen-root", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    parser.add_argument("--tickers", help="Optional explicit subset of source-bound missing stocks")
    args = parser.parse_args()
    builder = module("pit_builder", "build-pit-valuation-source.py")
    extractor = module("pit_extractor", "extract-pit-management-guidance.py")
    inventory = json.loads(args.inventory.read_text())
    cutoff = dt.date.fromisoformat(inventory["asOf"])
    by_ticker = select_staging_targets(inventory, args.tickers)
    targets = list(by_ticker.values())
    args.output_dir.mkdir(parents=True, exist_ok=True)
    source_path = args.output_dir / "candidate-source.sqlite"
    target_path = args.output_dir / "candidate-metadata.sqlite"
    manifest_path = args.output_dir / "candidate-identities.json"
    for path in (source_path, target_path, manifest_path):
        if path.exists():
            raise FileExistsError(f"Refusing to replace existing candidate: {path}")
    dataset = ds.dataset(args.jansen_root / "fundamentals", format="parquet", partitioning="hive")
    date_field = next(k for k in builder.PIT_CUTOFF_FIELD_CANDIDATES if k in dataset.schema.names)
    rows = dataset.to_table(columns=[*builder.SOURCE_COLUMNS, date_field], filter=(
        ds.field("ticker").isin(list(by_ticker)) & ds.field("dimension").isin(["ARQ", "ART"])
        & (ds.field(date_field) <= cutoff)
    )).to_pylist()
    raw_by_ticker = {t: [] for t in by_ticker}
    for row in rows:
        row["datekey"] = row[date_field]
        raw_by_ticker[row["ticker"]].append(row)
    selected = {t: builder.first_visible_rows(r) for t, r in raw_by_ticker.items()}
    fx_book = builder.FxRateBook([])
    fx_errors = {}
    # Unsupported ECB currencies remain blocked, with no provider-FX fallback.
    for currency in sorted({r["reportingCurrency"] for r in targets} - {"USD", "EUR"}):
        dates = [r["datekey"] for t, rows in selected.items() if by_ticker[t]["reportingCurrency"] == currency for r in rows]
        try:
            if currency in {"PEN", "KZT"}:
                raise ValueError("Currency is not in the ECB daily reference currency set; separate approved official FX source required")
            book = builder.rate_book_for_range(min(dates), max(dates), currencies=("USD", currency),
                cache_path=args.output_dir / "ecb-reference-fx.json")
            fx_book = builder.FxRateBook([*fx_book.rows, *book.rows])
            print(json.dumps({"phase": "official_fx", "currency": currency, "status": "available"}), flush=True)
        except Exception as error:
            fx_errors[currency] = str(error)
            print(json.dumps({"phase": "official_fx", "currency": currency, "status": "blocked", "reason": str(error)}), flush=True)
    if any(r["reportingCurrency"] == "EUR" for r in targets):
        dates = [r["datekey"] for t, rows in selected.items() if by_ticker[t]["reportingCurrency"] == "EUR" for r in rows]
        book = builder.rate_book_for_range(min(dates), max(dates), currencies=("USD",),
            cache_path=args.output_dir / "ecb-reference-fx.json")
        fx_book = builder.FxRateBook([*fx_book.rows, *book.rows])
    # Deduplicate reference rates collected across currency requests.
    fx_book = builder.FxRateBook(list({(r["currency"], r["rate_date"]): r for r in fx_book.rows}.values()))
    prices = ds.dataset(args.jansen_root / "prices", format="parquet", partitioning="hive").to_table(
        columns=["ticker", "date", "close"], filter=ds.field("ticker").isin(list(by_ticker))
        & (ds.field("date") <= cutoff) & (ds.field("close") > 0)
    ).to_pylist()
    price_by_ticker = {t: [] for t in by_ticker}
    for row in prices:
        price_by_ticker[row["ticker"]].append({"date": row["date"].isoformat(), "close": row["close"], "source": "jansen-sharadar-sep-split-adjusted"})
    source = builder.create_database(source_path)
    extractor.ensure_schema(source)
    source.execute("CREATE TABLE pit_issuer_review(ticker TEXT PRIMARY KEY,status TEXT NOT NULL,reason TEXT NOT NULL)")
    source.execute("CREATE TABLE pit_raw_financial_review(ticker TEXT,fiscal_period TEXT,dimension TEXT,available_at TEXT,payload_json TEXT,PRIMARY KEY(ticker,fiscal_period,dimension))")
    target = sqlite3.connect(target_path)
    target.executescript("CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT); CREATE TABLE valuation_snapshots(id TEXT PRIMARY KEY,generated_at TEXT,payload_json TEXT);")
    generated_at = dt.datetime.now(dt.timezone.utc).isoformat()
    companies, statuses = [], {}
    normalized_count = 0
    for ticker, identity in by_ticker.items():
        company = pending_company_identity(ticker, identity)
        companies.append(company)
        periods = []
        for row in selected[ticker]:
            period = stage_financial_period(source, builder, ticker, row, company, fx_book, fx_errors)
            if period is not None:
                periods.append(period)
        count_arq = sum(p["sourceDimension"] == "ARQ" for p in periods)
        count_art = len(periods) - count_arq
        status = "covered" if count_arq else "annual_only" if count_art else "external_required"
        statuses[status] = statuses.get(status, 0) + 1
        normalized_count += len(periods)
        dates = sorted(p["asOfDate"] for p in periods)
        source.execute("INSERT INTO pit_financial_coverage VALUES(?,?,?,?,?,?,?,?)", (ticker, ticker, status, count_arq, count_art, dates[0] if dates else None, dates[-1] if dates else None, "INPUTS ONLY, locked pending economic review; " + fx_errors.get(company["reportingCurrency"], "")))
        insert_candidate_review_gates(source, ticker, company)
        history = sorted(price_by_ticker[ticker], key=lambda p: p["date"])
        if not history:
            raise ValueError(f"Missing positive quoted-price history: {ticker}")
        snapshot = {**company, "key": ticker.lower(), "sector": identity["sector"], "industry": identity["industry"],
                    "priceHistory": history, "history": [], "latest": {"latestPrice": history[-1]["close"], "latestPriceDate": history[-1]["date"]}}
        target.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?,?)", (ticker, generated_at, json.dumps(snapshot, separators=(",", ":"))))
    source.executemany("INSERT INTO pit_source_metadata VALUES(?,?)", {
        "source": "Candidate-only Guru local ARQ/ART expansion", "generated_at": generated_at,
        "as_of_cutoff": cutoff.isoformat(), "source_fingerprint": builder.source_fingerprint(args.jansen_root),
        "target_ticker_count": str(len(companies)), "review_policy": "Every issuer remains locked until economic/source/claims review passes"
    }.items())
    builder.replace_sqlite_rates(source, fx_book, generated_at)
    source.commit()
    target.commit()
    for connection in (source, target):
        if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Candidate integrity failure")
        connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        connection.close()
    manifest_path.write_text(json.dumps({"schemaVersion": 1, "asOf": cutoff.isoformat(), "companies": companies}, indent=2) + "\n")
    result = {"status": "staged_not_released", "companies": len(companies), "normalizedFinancialRows": normalized_count,
              "rawPitRows": sum(len(r) for r in selected.values()), "financialAvailability": statuses, "fxBlockers": fx_errors,
              "issuerReview": "All pending; no fair values generated", "sourceDatabase": str(source_path), "targetMetadata": str(target_path)}
    (args.output_dir / "stage-summary.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2), flush=True)


if __name__ == "__main__":
    main()
