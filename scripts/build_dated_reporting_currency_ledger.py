#!/usr/bin/env python3
"""Read-only DB inspection and independent, dated SEC statement-unit evidence.

Never modifies source financials, guidance, normalized amounts, FX, or databases.
CompanyFacts only supplies whole-entity standard-taxonomy facts (SEC API policy).
The ledger records an inference from multiple explicitly monetary statement
concepts within one filing, not a quote-currency or currencyScale=1 assumption.
"""
from __future__ import annotations

import argparse
from collections import Counter, defaultdict
from contextlib import closing
from datetime import date
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
import time

import requests

VERSION = "sec-dated-reporting-currency-evidence-v2-2026-09-05"
SEC_USER_AGENT = "Guru Intelligence data engineering luyudong1136@gmail.com"
FORMS = {"10-K", "10-Q", "20-F", "40-F", "6-K", "10-K/A", "10-Q/A", "20-F/A", "40-F/A", "6-K/A"}
# No segment/product-only revenue, net EPS, share counts, cash-per-share or custom tags.
CONCEPTS = {
    "us-gaap": {
        "RevenueFromContractWithCustomerExcludingAssessedTax": "revenue",
        "RevenueFromContractWithCustomerIncludingAssessedTax": "revenue",
        "Revenues": "revenue", "SalesRevenueNet": "revenue",
        "NetCashProvidedByUsedInOperatingActivities": "operating_cash",
        "CashAndCashEquivalentsAtCarryingValue": "cash_balance",
        "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents": "cash_balance",
        "Assets": "total_assets",
        "StockholdersEquity": "total_equity",
        "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest": "total_equity",
    },
    "ifrs-full": {
        "Revenue": "revenue", "CashFlowsFromUsedInOperatingActivities": "operating_cash",
        "CashAndCashEquivalents": "cash_balance",
        "Assets": "total_assets", "Equity": "total_equity",
    },
}
CURRENCIES = set("USD EUR GBP CAD CHF JPY CNY HKD AUD NZD SEK NOK DKK MXN BRL INR KRW TWD SGD ZAR ILS TRY PLN CZK HUF CLP COP PEN ARS PHP IDR MYR THB SAR AED QAR ISK RUB KZT".split())


def valid_date(value):
    try:
        return isinstance(value, str) and date.fromisoformat(value).isoformat() == value
    except ValueError:
        return False


def readonly(path):
    return sqlite3.connect(Path(path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)


def explicit_currency(payload):
    record = payload.get("sourceRecord") or {}
    # Deliberately excludes record.currency, modelCurrency, quote currency,
    # currencyScale, provider fxusd and financialStatementCurrency.
    values = [payload.get("reportingCurrency"), payload.get("sourceFinancialStatementCurrency"),
              record.get("reportingCurrency"), record.get("sourceCurrency")]
    currencies = {v for v in values if isinstance(v, str) and v in CURRENCIES}
    return next(iter(currencies)) if len(currencies) == 1 else None


def collect_targets(source_paths, ticker_scope=None, include_reviewed_samples=False):
    targets = defaultdict(lambda: {"financialRows": 0, "sourceDatabases": set()})
    total_rows = 0
    missing_rows = 0
    missing_issuers = set()
    issuer_universe = set()
    for source in source_paths:
        with closing(readonly(source)) as db:
            for ticker, available, raw in db.execute("SELECT ticker,available_at,payload_json FROM pit_financial_periods ORDER BY ticker,available_at"):
                issuer_universe.add(ticker)
                total_rows += 1
                payload = json.loads(raw)
                missing = explicit_currency(payload) is None
                if missing:
                    missing_rows += 1
                    missing_issuers.add(ticker)
                if ticker_scope and ticker not in ticker_scope:
                    continue
                if not missing and not include_reviewed_samples:
                    continue
                if not valid_date(available):
                    raise ValueError(f"Invalid source availability date: {ticker}/{available}")
                target = targets[(ticker, available)]
                target["financialRows"] += 1
                target["sourceDatabases"].add(str(Path(source).resolve()))
    inventory = {"sourceFinancialRows": total_rows, "sourceIssuers": len(issuer_universe),
                 "missingCurrencyRows": missing_rows, "missingCurrencyIssuers": len(missing_issuers),
                 "selectedTargets": len(targets), "selectedIssuers": len({t for t, _ in targets})}
    return targets, inventory


def load_ciks(metadata_path, manifest_paths):
    candidates = defaultdict(set)
    if metadata_path:
        with closing(readonly(metadata_path)) as db:
            for ticker, raw in db.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots"):
                cik = str(json.loads(raw).get("cik", ""))
                if re.fullmatch(r"\d{1,10}", cik) and int(cik) > 0:
                    candidates[ticker].add(cik.zfill(10))
    for path in manifest_paths:
        payload = json.loads(Path(path).read_text())
        for company in payload.get("companies", []):
            cik = str(company.get("cik", ""))
            if re.fullmatch(r"\d{1,10}", cik) and int(cik) > 0:
                for ticker in [company["ticker"], *company.get("aliases", [])]:
                    candidates[ticker].add(cik.zfill(10))
    return {ticker: next(iter(ciks)) for ticker, ciks in candidates.items() if len(ciks) == 1}, {
        ticker: sorted(ciks) for ticker, ciks in candidates.items() if len(ciks) != 1}


def companyfacts_filings(payload, cik):
    if not isinstance(payload, dict) or str(payload.get("cik", "")).lstrip("0") != str(cik).lstrip("0"):
        raise ValueError("CompanyFacts issuer CIK mismatch")
    if not isinstance(payload.get("facts"), dict):
        raise ValueError("Missing CompanyFacts taxonomy schema")
    filings = defaultdict(list)
    for taxonomy, concepts in CONCEPTS.items():
        facts = payload["facts"].get(taxonomy, {})
        for concept, category in concepts.items():
            units = facts.get(concept, {}).get("units", {})
            if not isinstance(units, dict):
                continue
            for unit, observations in units.items():
                if not isinstance(observations, list):
                    continue
                for fact in observations:
                    if not isinstance(fact, dict) or fact.get("form") not in FORMS:
                        continue
                    if not valid_date(fact.get("filed")) or not valid_date(fact.get("end")):
                        continue
                    if not re.fullmatch(r"\d{10}-\d{2}-\d{6}", str(fact.get("accn", ""))):
                        continue
                    if fact["end"] > fact["filed"] or (fact.get("start") and (
                            not valid_date(fact["start"]) or fact["start"] > fact["end"])):
                        continue
                    if isinstance(fact.get("val"), bool) or not isinstance(fact.get("val"), (int, float)) or not math.isfinite(fact["val"]):
                        continue
                    # Preserve original values/units and all original fact dates.
                    filings[(fact["filed"], fact["accn"])].append({
                        "taxonomy": taxonomy, "concept": concept, "category": category,
                        "unit": unit, "fact": dict(fact),
                    })
    return dict(filings)


def resolve_currency(filings, cik, target_date):
    if not valid_date(target_date):
        return {"status": "blocked", "reason": "invalid_target_date"}
    eligible = [(key, facts) for key, facts in filings.items() if key[0] <= target_date]
    if not eligible:
        return {"status": "blocked", "reason": "no_dated_aggregate_statement_facts"}
    latest_date = max(key[0] for key, _ in eligible)
    if (date.fromisoformat(target_date) - date.fromisoformat(latest_date)).days > 400:
        return {"status": "blocked", "reason": "statement_currency_evidence_older_than_400_days", "latestFilingDate": latest_date}
    latest = [(key, facts) for key, facts in eligible if key[0] == latest_date]
    resolved = []
    for (filed, accn), facts in latest:
        # Only the newest represented reporting period in this filing; never
        # confuse old historical convenience translations with current totals.
        end = max(row["fact"]["end"] for row in facts)
        current = [row for row in facts if row["fact"]["end"] == end]
        units = {row["unit"] for row in current}
        categories = {row["category"] for row in current}
        reference = {"cik": str(cik).zfill(10), "accession": accn, "filingDate": filed,
                     "reportPeriodEnd": end, "form": current[0]["fact"]["form"],
                     "filingUrl": f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accn.replace('-', '')}/{accn}-index.html"}
        if len(units) != 1:
            return {"status": "blocked", "reason": "conflicting_statement_currencies", "units": sorted(units), "reference": reference, "facts": current}
        unit = next(iter(units))
        if unit not in CURRENCIES:
            return {"status": "blocked", "reason": "unsupported_or_nonmonetary_statement_unit", "units": sorted(units), "reference": reference}
        if len(categories) < 2:
            return {"status": "blocked", "reason": "insufficient_independent_statement_concepts", "categories": sorted(categories), "reference": reference}
        # Bound evidence volume to one fact per concept/category at latest end.
        unique = {}
        for row in sorted(current, key=lambda x: (x["taxonomy"], x["concept"], x["fact"].get("start", ""))):
            unique[(row["taxonomy"], row["concept"])] = row
        resolved.append({"currency": unit, "reference": reference, "facts": list(unique.values()), "categories": sorted(categories)})
    if len({row["currency"] for row in resolved}) != 1:
        return {"status": "blocked", "reason": "same_day_filing_currency_conflict", "filings": resolved}
    return {"status": "resolved", "currency": resolved[0]["currency"], "availableAt": latest_date,
            "basis": "whole_entity_SEC_XBRL_multiple_statement_categories_same_filing_same_latest_period_unit",
            "filings": resolved}


def fetch_facts(session, cik, cache_dir, offline=False):
    path = Path(cache_dir) / f"CIK{str(cik).zfill(10)}.json"
    url = f"https://data.sec.gov/api/xbrl/companyfacts/CIK{str(cik).zfill(10)}.json"
    if path.exists():
        raw = path.read_bytes()
    else:
        if offline:
            raise ValueError("public_companyfacts_cache_missing_offline")
        response = session.get(url, timeout=30)
        response.raise_for_status()
        raw = response.content
        payload = json.loads(raw)
        companyfacts_filings(payload, cik)  # Validate identity before cache write.
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        time.sleep(0.36)
    payload = json.loads(raw)
    filings = companyfacts_filings(payload, cik)
    return filings, {"url": url, "cachePath": str(path.resolve()), "sha256": hashlib.sha256(raw).hexdigest(),
                     "issuerName": payload.get("entityName"), "cik": str(cik).zfill(10)}


def run(args):
    targets, inventory = collect_targets(args.source_db, set(args.tickers.split(",")) if args.tickers else None,
                                         args.include_reviewed_samples)
    ciks, conflicts = load_ciks(args.metadata_db, args.manifest)
    output = Path(args.output).resolve()
    if output.exists():
        raise FileExistsError("Refusing to overwrite an existing evidence ledger")
    by_ticker = defaultdict(list)
    for (ticker, target), detail in targets.items():
        by_ticker[ticker].append((target, detail))
    ledger = {"version": VERSION, "status": "independent_currency_evidence_not_release_authorization",
              "inventory": inventory, "sourcePolicy": "Read-only financial source(s) and runtime metadata; no monetary values changed",
              "asOf": args.as_of, "issuers": {}, "targets": []}
    counts = Counter()
    session = requests.Session()
    session.headers.update({"User-Agent": SEC_USER_AGENT, "Accept": "application/json"})
    for ticker in sorted(by_ticker):
        cik = ciks.get(ticker)
        try:
            if ticker in conflicts:
                raise ValueError("conflicting_issuer_cik_identity")
            if not cik:
                raise ValueError("missing_verified_issuer_cik")
            filings, provenance = fetch_facts(session, cik, args.cache_dir, args.offline)
            ledger["issuers"][ticker] = provenance
        except Exception as error:
            filings = None
            ledger["issuers"][ticker] = {"status": "blocked", "reason": str(error), "cik": cik}
        local = Counter()
        for target, detail in sorted(by_ticker[ticker]):
            result = resolve_currency(filings, cik, target) if filings is not None else {
                "status": "blocked", "reason": "companyfacts_unavailable_or_identity_unverified"}
            if target > args.as_of:
                result = {"status": "blocked", "reason": "target_after_frozen_as_of"}
            ledger["targets"].append({"ticker": ticker, "targetAvailableAt": target,
                                      "financialRows": detail["financialRows"], "sourceDatabases": sorted(detail["sourceDatabases"]), **result})
            local[result.get("reason", "resolved")] += 1
            counts[result.get("reason", "resolved")] += 1
        print(json.dumps({"ticker": ticker, "targets": len(by_ticker[ticker]), "counts": dict(local)}), flush=True)
    ledger["summary"] = dict(counts)
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(ledger, separators=(",", ":")) + "\n")
    print(json.dumps({"output": str(output), "inventory": inventory, "summary": dict(counts)}), flush=True)
    return ledger


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-db", type=Path, action="append", required=True)
    parser.add_argument("--metadata-db", type=Path)
    parser.add_argument("--manifest", type=Path, action="append", default=[])
    parser.add_argument("--cache-dir", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--as-of", default="2026-09-05")
    parser.add_argument("--tickers")
    parser.add_argument("--include-reviewed-samples", action="store_true")
    parser.add_argument("--offline", action="store_true")
    args = parser.parse_args()
    if not valid_date(args.as_of):
        parser.error("as-of must be an ISO date")
    run(args)


if __name__ == "__main__":
    main()
