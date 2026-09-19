#!/usr/bin/env python3
"""Independently verify resolved ledger claims against cached original SEC facts.

Does not call the ledger builder/resolver. No database or source writes.
"""
from collections import defaultdict, Counter
from datetime import date
import hashlib
import json
from pathlib import Path
import sys

GROUPS = {
    "revenue": {("us-gaap", x) for x in ["RevenueFromContractWithCustomerExcludingAssessedTax", "RevenueFromContractWithCustomerIncludingAssessedTax", "Revenues", "SalesRevenueNet"]} | {("ifrs-full", "Revenue")},
    "operating_cash": {("us-gaap", "NetCashProvidedByUsedInOperatingActivities"), ("ifrs-full", "CashFlowsFromUsedInOperatingActivities")},
    "cash_balance": {("us-gaap", "CashAndCashEquivalentsAtCarryingValue"), ("us-gaap", "CashCashEquivalentsRestrictedCashAndRestrictedCashEquivalents"), ("ifrs-full", "CashAndCashEquivalents")},
    "total_assets": {("us-gaap", "Assets"), ("ifrs-full", "Assets")},
    "total_equity": {("us-gaap", "StockholdersEquity"), ("us-gaap", "StockholdersEquityIncludingPortionAttributableToNoncontrollingInterest"), ("ifrs-full", "Equity")},
}
FORMS = {"10-K", "10-Q", "20-F", "40-F", "6-K", "10-K/A", "10-Q/A", "20-F/A", "40-F/A", "6-K/A"}
CURRENCIES = set("USD EUR GBP CAD CHF JPY CNY HKD AUD NZD SEK NOK DKK MXN BRL INR KRW TWD SGD ZAR ILS TRY PLN CZK HUF CLP COP PEN ARS PHP IDR MYR THB SAR AED QAR ISK RUB KZT".split())


def verify_target(row, issuer, facts_payload):
    errors = []
    if row.get("status") != "resolved":
        return errors
    ticker, target, currency = row["ticker"], row["targetAvailableAt"], row.get("currency")
    if currency not in CURRENCIES:
        return ["unsupported_or_nonmonetary_claimed_currency"]
    if str(facts_payload.get("cik")).lstrip("0") != str(issuer.get("cik")).lstrip("0"):
        return ["original_companyfacts_identity_mismatch"]
    # Independently find eligible whole-entity categories across the raw API.
    observations = []
    for group, concepts in GROUPS.items():
        for taxonomy, concept in concepts:
            for unit, entries in facts_payload.get("facts", {}).get(taxonomy, {}).get(concept, {}).get("units", {}).items():
                for fact in entries:
                    if fact.get("form") not in FORMS or not fact.get("filed") or fact["filed"] > target or not fact.get("end") or fact["end"] > fact["filed"]:
                        continue
                    observations.append((fact["filed"], fact.get("accn"), fact["end"], group, unit, taxonomy, concept, fact))
    if not observations:
        return ["no_original_dated_facts"]
    newest = max(x[0] for x in observations)
    if row.get("availableAt") != newest or (date.fromisoformat(target) - date.fromisoformat(newest)).days > 400:
        errors.append("nonlatest_or_stale_currency_evidence")
    newest_rows = [x for x in observations if x[0] == newest]
    expected_accessions = {x[1] for x in newest_rows}
    declared = row.get("filings", [])
    if {x.get("reference", {}).get("accession") for x in declared} != expected_accessions or len(declared) != len(expected_accessions):
        errors.append("missing_or_duplicate_latest_filing")
    for filing in declared:
        reference = filing.get("reference", {})
        accn = reference.get("accession")
        raw_rows = [x for x in newest_rows if x[1] == accn]
        if not raw_rows:
            errors.append("filing_not_in_original_facts")
            continue
        end = max(x[2] for x in raw_rows)
        raw_rows = [x for x in raw_rows if x[2] == end]
        if {x[4] for x in raw_rows} != {currency} or filing.get("currency") != currency:
            errors.append("currency_or_hidden_conflicting_unit")
        groups = {x[3] for x in raw_rows}
        if len(groups) < 2 or set(filing.get("categories", [])) != groups:
            errors.append("independent_category_requirement")
        expected_url = f"https://www.sec.gov/Archives/edgar/data/{int(issuer['cik'])}/{accn.replace('-', '')}/{accn}-index.html"
        if reference.get("filingDate") != newest or reference.get("reportPeriodEnd") != end or reference.get("filingUrl") != expected_url or reference.get("cik") != issuer["cik"]:
            errors.append("official_filing_reference_mismatch")
        original_by_key = {(x[5], x[6], x[4], json.dumps(x[7], sort_keys=True)) for x in raw_rows}
        proof_groups = set()
        for proof in filing.get("facts", []):
            identity = (proof.get("taxonomy"), proof.get("concept"))
            categories = [g for g, keys in GROUPS.items() if identity in keys]
            if not categories or proof.get("category") != categories[0]:
                errors.append("unapproved_concept_category")
            else:
                proof_groups.add(categories[0])
            key = (*identity, proof.get("unit"), json.dumps(proof.get("fact"), sort_keys=True))
            if key not in original_by_key:
                errors.append("proof_fact_was_changed_or_not_in_original")
        if len(proof_groups) < 2:
            errors.append("missing_two_original_proof_categories")
    return sorted(set(errors))


def audit(ledger):
    if ledger.get("version") != "sec-dated-reporting-currency-evidence-v2-2026-09-05" or ledger.get("asOf") != "2026-09-05":
        return {"status": "blocked", "failures": [{"code": "unsupported_ledger_version_or_freeze"}]}
    by_ticker = defaultdict(list)
    failures = []
    for row in ledger["targets"]:
        if row.get("status") == "resolved":
            if row["targetAvailableAt"] > ledger["asOf"]:
                failures.append({"ticker": row["ticker"], "code": "resolved_target_after_frozen_as_of"})
            by_ticker[row["ticker"]].append(row)
    counts = Counter()
    for ticker, rows in by_ticker.items():
        issuer = ledger["issuers"][ticker]
        try:
            raw = Path(issuer["cachePath"]).read_bytes()
            if hashlib.sha256(raw).hexdigest() != issuer["sha256"]:
                raise ValueError("companyfacts_cache_sha256_mismatch")
            expected_url = f"https://data.sec.gov/api/xbrl/companyfacts/CIK{issuer['cik']}.json"
            if issuer["url"] != expected_url:
                raise ValueError("companyfacts_source_url_mismatch")
            payload = json.loads(raw)
            for row in rows:
                errors = verify_target(row, issuer, payload)
                counts["resolvedClaimsAudited"] += 1
                for error in errors:
                    failures.append({"ticker": ticker, "target": row["targetAvailableAt"], "code": error})
        except Exception as error:
            failures.append({"ticker": ticker, "code": str(error)})
    return {"status": "passed" if not failures else "blocked", "counts": dict(counts), "failures": failures,
            "scope": "independent_original_SEC_fact_verification; blocked ledger targets remain blocked"}


if __name__ == "__main__":
    result = audit(json.loads(Path(sys.argv[1]).read_text()))
    print(json.dumps(result, indent=2))
    sys.exit(0 if result["status"] == "passed" else 2)
