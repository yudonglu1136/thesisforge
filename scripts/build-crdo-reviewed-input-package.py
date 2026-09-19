#!/usr/bin/env python3
"""Build an unapproved CRDO evidence package; apply only a separately reviewed copy.

All outputs are new, private candidate files. Never connects to a production DB.
The frozen source cutoff remains September 5, even when the review occurs later.
"""
import argparse
import copy
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from bs4 import BeautifulSoup
from guru_reviewed_input_corrections import apply_reviewed_input_corrections

OPERATING = {"revenue_m": "RevenueFromContractWithCustomerExcludingAssessedTax",
             "gross_profit_m": "GrossProfit", "operating_income_m": "OperatingIncomeLoss",
             "net_income_m": "NetIncomeLoss"}
CASH = {"cfo_m": "cfoM", "capex_m": "capexM", "fcf_after_capex_m": None}


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def load(path):
    return json.loads(path.read_text())


def evidence(ev, period_by_url):
    result = copy.deepcopy(ev)
    result.setdefault("periodEndDate", period_by_url[ev["url"]])
    if result["periodEndDate"] > result["availableDate"]:
        raise ValueError("Source evidence cannot postdate its publication")
    return result


def operating_component(doc, field, start, end):
    tag = "us-gaap:" + OPERATING[field]
    facts = [f for f in doc["aggregateFacts"] if f["tag"] == tag and f.get("start") == start and f["end"] == end]
    if facts:
        if {f["unit"] for f in facts} != {"iso4217:USD"} or len({f["value"] for f in facts}) != 1:
            raise ValueError("Operating financial source value/unit conflict")
        f = facts[0]
        return {"url": doc["url"], "availableDate": doc["filed"], "periodStartDate": start,
                "periodEndDate": end, "sha256": doc["sha256"], "valueM": f["value"] / 1e6,
                "locator": f"{tag} context={f['context']}; USD thousands"}
    # Original untagged S-1 tables, independently read; no interpolation.
    manual = {("2020-05-01", "2021-04-30"): [58.697, 38.278, -25.234, -27.511],
              ("2021-05-01", "2021-10-31"): [37.151, 21.134, -15.184, -16.677]}
    if not doc["form"].startswith("S-1") or (start, end) not in manual:
        raise ValueError(f"Missing original operating fact: {doc['filed']} {field} {start} {end}")
    raw = Path(doc["localPath"]).read_bytes()
    if sha(raw) != doc["sha256"]:
        raise ValueError("Frozen filing changed")
    tables = [t.get_text(" ", strip=True) for t in BeautifulSoup(raw, "html.parser").find_all("table")]
    prefix = "Year Ended April 30, 2020 2021 Revenue:" if end == "2021-04-30" else "Six Months Ended October 31, 2020 2021 Revenue:"
    table = next(t for t in tables if t.startswith(prefix) and "Gross profit" in t and "Total operating expenses" in t)
    values = manual[(start, end)]
    for value in values:
        if f"{round(abs(value) * 1000):,}" not in table:
            raise ValueError(f"Manual original S-1 operating table changed: {doc['filed']} {end} {value}; {table}")
    return {"url": doc["url"], "availableDate": doc["filed"], "periodStartDate": start,
            "periodEndDate": end, "sha256": doc["sha256"], "valueM": values[list(OPERATING).index(field)],
            "locator": f"Consolidated operations table; {field}; {start} to {end}; USD thousands"}


def read_rows(source):
    conn = sqlite3.connect(source.resolve(strict=True).as_uri() + "?mode=ro", uri=True)
    conn.row_factory = sqlite3.Row
    rows = [dict(r) for r in conn.execute("SELECT * FROM pit_financial_periods WHERE ticker='CRDO' ORDER BY available_at,dimension")]
    conn.close()
    return rows


def balance_bridge(doc, end, payload):
    """Period-end source evidence, not a missing-debt-tag-equals-zero shortcut."""
    raw = Path(doc["localPath"]).read_bytes()
    if sha(raw) != doc["sha256"]:
        raise ValueError("Frozen balance-sheet filing changed")
    soup = BeautifulSoup(raw, "html.parser")
    text = soup.get_text(" ", strip=True)
    tables = [t.get_text(" ", strip=True) for t in soup.find_all("table")]
    balance = next(t for t in tables if "Total assets" in t and "Cash and cash equivalents" in t and "Total liabilities" in t and len(t) < 15000)
    liabilities = re.split("Current Liabilities:", balance, flags=re.I)[1].split("Total liabilities")[0]
    cashflows = next(t for t in tables if "Cash flows from financing activities:" in t and "Cash flows from operating activities:" in t)
    financing = cashflows.split("Cash flows from financing activities:")[1].split("Effect of exchange rate")[0]
    # Full primary sections reviewed: only operating liabilities/leases and
    # technology-license obligations, not borrowed financing principal. Current
    # and comparative convertible preferred shares converted at IPO are equity.
    if re.search(r"\b(?:loans?|borrowings?|notes payable|bonds payable|funded debt|credit facilit(?:y|ies)|finance lease)\b", liabilities + financing, re.I):
        raise ValueError("Unmapped funded financing or finance lease requires explicit review")
    if re.search(r"restricted cash|restricted investments|pledged|outstanding borrowings|credit facility|line of credit", text, re.I):
        raise ValueError("Potential encumbrance/borrowing requires explicit line-item review")
    result = {"reportedCashM": payload["cash_m"], "reportedDebtM": payload["debt_m"], "fundedDebtM": 0, "evidence": []}
    for name, tag in [("cashEquivalentsM", "CashAndCashEquivalentsAtCarryingValue"),
                      ("unrestrictedShortTermInvestmentsM", "ShortTermInvestments"),
                      ("operatingLeaseCurrentM", "OperatingLeaseLiabilityCurrent"),
                      ("operatingLeaseNoncurrentM", "OperatingLeaseLiabilityNoncurrent")]:
        facts = [f for f in doc["aggregateFacts"] if f["tag"] == "us-gaap:" + tag and f["end"] == end and not f.get("start")]
        if not facts:
            if name != "unrestrictedShortTermInvestmentsM" or doc["filed"] not in {"2022-03-10", "2022-06-08", "2022-09-01"} or "Short-term investments" in balance:
                raise ValueError("No reviewed exact balance-sheet amount")
            result[name] = 0
            locator = "Full current-assets balance sheet: no short-term investment balance; IPO-era financing/cash notes independently reviewed"
        else:
            if len({f["value"] for f in facts}) != 1 or {f["unit"] for f in facts} != {"iso4217:USD"}:
                raise ValueError("Conflicting balance-sheet fact or currency")
            result[name] = facts[0]["value"] / 1e6
            locator = f"us-gaap:{tag} context={facts[0]['context']}; period-end USD thousands"
        result["evidence"].append({"url": doc["url"], "availableDate": doc["filed"], "periodEndDate": end,
                                   "sha256": doc["sha256"], "locator": locator})
    if abs(result["reportedCashM"] - result["cashEquivalentsM"]) > 1e-8 or abs(result["reportedDebtM"] - result["operatingLeaseNoncurrentM"]) > 1e-8:
        raise ValueError("Provider cash/debt do not exactly reconcile to original cash/noncurrent operating lease")
    if result["unrestrictedShortTermInvestmentsM"] and not re.search(r"Short-term investments:?\s+Certificates? of deposit", text, re.I):
        # Initial September2022 investment disclosure uses policy prose rather
        # than the later expanded fair-value table.
        if not re.search(r"short.term investments.{0,180}certificates? of deposit", text, re.I):
            raise ValueError(f"Investment instrument type not independently established: {doc['filed']}")
    result["fundedDebtBasis"] = ("Reviewed full primary balance-sheet liability section, financing cash-flow section and notes: no funded borrowing or finance-lease balance. "
        "Provider debt equals exactly noncurrent operating leases; rent is already an operating cash expense. Technology-license payment obligations remain operating reinvestment in the cash bridge, not an additional net-debt deduction. "
        "This is a reviewed absence of disclosed funded borrowing, not missing-field imputation.")
    result["investmentAvailabilityBasis"] = ("Reported current short-term investments are certificates of deposit, not strategic equity investments. "
        "Full cash/investment and liquidity notes disclose no pledge, restriction or encumbrance on these balances. Treated as available financial liquidity at carrying value/maturity; held-to-maturity classification is not a legal restriction. "
        "No short-term investment balance is present in the first three public statements; those exact zeroes are separately evidenced.")
    result["evidence"].append({"url": doc["url"], "availableDate": doc["filed"], "periodEndDate": end, "sha256": doc["sha256"],
        "locator": "Complete balance-sheet liabilities, financing cash flows, investment/fair-value and liquidity notes; operating lease versus funded financing and investment encumbrance review"})
    return result


def build(source, capture, bridge, claims):
    if bridge["cutoff"] != "2026-09-05" or claims["cutoff"] != "2026-09-05":
        raise ValueError("Unexpected source cutoff")
    rows = read_rows(source)
    if len(rows) != 42:
        raise ValueError("Expected exactly 42 original CRDO rows")
    by_key = {(r["fiscal_period"], r["dimension"]): r for r in rows}
    docs = {d["url"]: d for d in capture["documents"]}
    period_by_date = {r["available_at"]: r["report_period"] for r in rows}
    period_by_url = {d["url"]: period_by_date[d["filed"]] for d in capture["documents"]}
    claims_by_date = {p["availableDate"]: p for p in claims["periods"]}
    corrections, periods = [], []
    for p in bridge["periods"]:
        base = {k: p[k] for k in ["fiscalPeriod", "periodEndDate", "availableDate", "currency"]}
        if p.get("status") == "non_modelable":
            periods.append({**base, "status": "non_modelable", "reason": p["reason"],
                            "evidence": [evidence(ev, period_by_url) for ev in p["evidence"]]})
            continue
        fiscal = p["fiscalPeriod"]
        source_hashes = {d: sha(by_key[(fiscal, d)]["payload_json"].encode()) for d in ["ARQ", "ART"]}
        share_ev = p["shareEvidence"]
        common = {"fiscalPeriod": fiscal, "periodEndDate": p["periodEndDate"], "currency": "USD",
                  "expectedRecordAvailableDate": p["availableDate"], "sourceAvailableDate": p["availableDate"],
                  "sourceUrl": share_ev["url"], "sourceSha256": share_ev["sha256"],
                  "expectedOriginalPayloadSha256ByDimension": source_hashes}
        corrections.append({**common, "id": f"CRDO-{fiscal}-period-end-common-shares-v1",
                            "field": "shares_m", "unit": "million_common_shares", "dimensions": ["ARQ", "ART"],
                            "value": p["periodEndSharesM"], "expectedOriginalValue": p["sourceShareCountM"],
                            "sourceLocator": share_ev["locator"], "sourcePrecisionShares": 1000,
                            "reason": "Replace later cover-date count with the exact period-end common shares; preserve provider values and quoted-security factor 1."})
        c = claims_by_date[p["availableDate"]]
        node = {**base, "quarter": {}, "ttm": {}}
        node["balanceNormalization"] = balance_bridge(docs[share_ev["url"]], p["periodEndDate"], json.loads(by_key[(fiscal, "ARQ")]["payload_json"]))
        originals = {}
        for window, dimension in [("quarter", "ARQ"), ("ttm", "ART")]:
            payload = json.loads(by_key[(fiscal, dimension)]["payload_json"])
            cash = p[window]
            cash_evidence = [evidence(ev, period_by_url) for ev in cash["evidence"]]
            node[window] = {**{key: cash[key] for key in ["cfoM", "capexM", "sbcM", "licensePaymentsM"]},
                            "evidence": cash_evidence, "sourceDerivation": cash["derivation"]}
            operating_values = {}
            for field in [*CASH, *OPERATING]:
                if field in OPERATING:
                    components = [{**operating_component(docs[ev["url"]], field, ev["periodStartDate"], ev["periodEndDate"]),
                                   "multiplier": ev["multiplier"]} for ev in cash_evidence[::4]]
                    value = round(sum(ev["multiplier"] * ev["valueM"] for ev in components), 9)
                    operating_values[field] = value
                else:
                    indexes = [0] if field == "cfo_m" else [1] if field == "capex_m" else [0, 1]
                    components = [{**ev, "multiplier": ev["multiplier"] * (-1 if field == "fcf_after_capex_m" and i % 4 == 1 else 1)}
                                  for i, ev in enumerate(cash_evidence) if i % 4 in indexes]
                    value = round(sum(ev["multiplier"] * ev["valueM"] for ev in components), 9)
                if payload[field] is None:
                    if dimension != "ART" or fiscal not in {"2022-Q3", "2023-Q1"}:
                        raise ValueError("Unexpected missing financial value requires separate review")
                    corrections.append({**common, "id": f"CRDO-{fiscal}-{field}-original-sec-reconstruction-v1",
                        "field": field, "unit": "million_reporting_currency", "dimensions": [dimension],
                        "expectedOriginalValue": None, "value": value, "sourcePrecisionM": .001,
                        "sourceLocator": f"{field}; {cash['derivation']}; exact dated USD-thousands components below",
                        "sourceComponents": [{**ev, "currency": "USD"} for ev in components],
                        "precisionPolicy": "Every reported component is in USD thousands. Derivation retains 0.001m precision; no tolerance permits altering a non-null provider value.",
                        "reason": "The provider ART field is null. Reconstruct only this exact period from original dated statements; preserve null and complete original payload, no generic fallback."})
                elif abs(payload[field] - value) > 1e-8:
                    raise ValueError(f"Non-null source value mismatch requires new review: {fiscal}/{dimension}/{field}: {payload[field]} vs {value}")
            originals[window] = operating_values
        opts = c["employeeOptions"]
        facts = opts["facts"]
        count = next(f["value"] / 1e6 for f in facts if f["tag"].endswith("OptionsOutstandingNumber"))
        strike = next(f["value"] for f in facts if f["tag"].endswith("OptionsOutstandingWeightedAverageExercisePrice"))
        unrecognized = opts["unrecognizedOptionCompensation"]
        estimate = unrecognized["status"] == "analyst_straight_line_estimate_not_reported_actual"
        option = {"id": f"CRDO-{fiscal}-employee-options", "basis": "outstanding_employee_option_with_unrecognized_compensation_credit", "countM": count,
                  "strike": strike, "currency": "USD", "unrecognizedCompensationCostM": unrecognized["amountM"],
                  "compensationCreditBasis": "analyst_straight_line_estimate" if estimate else "reported",
                  "compensationCreditRangeM": {"low": 0 if estimate else unrecognized["amountM"],
                                              "high": unrecognized.get("lastReportedAmountM", unrecognized["amountM"])},
                  "evidence": [evidence(ev, period_by_url) for ev in opts["evidence"] + unrecognized["evidence"]]}
        if estimate:
            option["estimateRationale"] = (f"Analyst straight-line carry of {unrecognized['lastReportedAmountM']}m unrecognized option cost disclosed at "
                f"{unrecognized['lastReportedAsOf']}, over {unrecognized['weightedAverageRemainingYears']} weighted-average years; no subsequent option grants in reviewed rollforwards. "
                "Not a reported interim balance or a certification of vested count. Sensitivity ranges from zero to prior disclosed cost.")
        warrant = c["customerWarrant"]
        node["optionClaims"] = [option, {"id": f"CRDO-{fiscal}-amazon-customer-warrant", "basis": "vested_customer_warrant", "countM": warrant["vestedUnexercisedCountM"],
            "strike": warrant["strike"], "currency": "USD", "evidence": [evidence(ev, period_by_url) for ev in warrant["evidence"]]}]
        contingent = c["acquisitionContingentConsideration"]
        node["otherEquityClaimsM"] = contingent["totalM"]
        node["claimsEvidence"] = [evidence(ev, period_by_url) for ev in contingent["evidence"]]
        node["fixedClaimsBasis"] = contingent["valuationLabel"]
        contra = c["customerWarrantContraRevenue"]
        node["warrantNormalization"] = {"quarterContraRevenueM": contra["quarter"]["amountM"],
            "ttmContraRevenueM": contra["ttm"]["amountM"], "taxRate": .21,
            "taxRateBasis": "analyst_marginal_tax_rate_not_reported",
            "quarterReportedOperatingFinancials": originals["quarter"], "ttmReportedOperatingFinancials": originals["ttm"],
            "evidence": [evidence(ev, period_by_url) for w in ["quarter", "ttm"] for ev in contra[w]["evidence"]]}
        periods.append(node)
    if len(periods) != 21 or len(corrections) != 33:
        raise ValueError("Expected 21 periods, 19 share corrections and 14 missing ART monetary corrections")
    return {"schemaVersion": 1, "asOf": "2026-09-06", "sourceCutoff": "2026-09-05", "status": "draft_root_review_required",
        "sourceDatabaseSha256": sha(source.read_bytes()), "sourceFinancialRows": 42,
        "companies": [{"ticker": "CRDO", "sourceTicker": "CRDO", "priceTicker": "CRDO", "cik": "0001807794",
            "name": "Credo Technology Group Holding Ltd", "currency": "USD", "reportingCurrency": "USD",
            "publicTradingStartedAt": "2022-01-27", "reviewStatus": "unreviewed", "reviewedAt": "2026-09-06",
            "valuationProfile": "semiconductor_growth",
            "profileRationale": "Fabless high-speed semiconductor/connectivity business: growth profile with dated revenue guidance, reported operating cash less cash capex, technology-license reinvestment and recurring SBC; separate existing option/customer-warrant/acquisition claims. Raw financials are not replaced by price-derived targets.",
            "identityReviewStatus": "reviewed",
            "security": {"type": "ordinary_share", "ordinarySharesPerQuotedSecurity": 1, "exchange": "Nasdaq"},
            "identityEvidence": [{"source": "Credo original SEC Form 10-Q cover and ordinary-share balance sheet", "url": capture["documents"][-1]["url"],
                "availableDate": capture["documents"][-1]["filed"], "sha256": capture["documents"][-1]["sha256"],
                "locator": "CIK 1807794; cover: ordinary shares, trading symbol CRDO, Nasdaq; balance-sheet common shares",
                "evidence": "Credo Technology Group Holding Ltd; CIK 0001807794; listed ordinary shares trade as CRDO, not ADR units. Each quoted ordinary share is one issuer ordinary share; no conversion ratio applied."},
                {"source": "Issuer IPO pricing announcement", "url": "https://www.globenewswire.com/news-release/2022/01/27/2373939/0/en/Credo-announces-pricing-of-initial-public-offering.html",
                 "availableDate": "2022-01-27", "locator": "Nasdaq trading commencement announcement",
                 "evidence": "Issuer announced ordinary shares were expected to begin trading on Nasdaq under CRDO on January 27, 2022. Earlier January 3/18 registration statements precede a public quoted security."}],
            "inputCorrections": corrections,
            "economicReview": {"releaseBlockers": ["root_model_review_pending"],
                "methodology": "Draft: reported CFO minus cash capex, technology-license financing payments and recurring SBC once. Normalize customer-warrant contra revenue before separate vested claims; options with unrecognized compensation credit. No market price is a valuation input."},
            "economicInputReview": {"status": "draft", "cashFlowConvention": "reported_cfo_less_cash_capex_licenses_and_sbc", "periods": periods}}]}


def apply_manifest(source, output, manifest):
    if output.exists() or output.resolve() == source.resolve():
        raise ValueError("Choose a new output path; never overwrite a source")
    if sha(source.read_bytes()) != manifest["sourceDatabaseSha256"]:
        raise ValueError("Source DB changed since package review")
    company = next(c for c in manifest["companies"] if c["ticker"] == "CRDO")
    if company.get("economicInputReview", {}).get("status") != "reviewed":
        raise ValueError("Draft economic package cannot prepare an approved candidate")
    rows = read_rows(source)
    corrected = apply_reviewed_input_corrections(company, rows)
    output.parent.mkdir(parents=True, exist_ok=True)
    src = sqlite3.connect(source.resolve().as_uri() + "?mode=ro", uri=True)
    dst = sqlite3.connect(output)
    src.backup(dst); src.close()
    changed = 0
    with dst:
        for before, after in zip(rows, corrected):
            if before["payload_json"] == after["payload_json"]:
                continue
            changed += 1
            dst.execute("UPDATE pit_financial_periods SET payload_json=? WHERE ticker='CRDO' AND fiscal_period=? AND dimension=? AND available_at=?",
                        (after["payload_json"], after["fiscal_period"], after["dimension"], after["available_at"]))
    if changed != 38 or dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise ValueError("Unexpected scoped source correction result")
    dst.close()
    return {"sourceOutput": str(output), "changedFinancialRows": changed, "sha256": sha(output.read_bytes()),
            "policy": "Only 38 CRDO financial payloads changed. Raw provider payload/hash retained. No issuer review, coverage status, model or production release approved by this writer."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--capture", type=Path); parser.add_argument("--bridge", type=Path); parser.add_argument("--claims", type=Path)
    parser.add_argument("--out", type=Path); parser.add_argument("--apply-manifest", type=Path); parser.add_argument("--source-out", type=Path)
    args = parser.parse_args()
    if args.apply_manifest:
        if not args.source_out: parser.error("--source-out is required")
        print(json.dumps(apply_manifest(args.source, args.source_out, load(args.apply_manifest))))
        return
    if not all([args.capture, args.bridge, args.claims, args.out]): parser.error("Draft generation requires capture, bridge, claims and out")
    if args.out.exists(): raise ValueError("Draft outputs are immutable; choose a new path")
    result = build(args.source, load(args.capture), load(args.bridge), load(args.claims))
    result["evidenceArtifactSha256"] = {k: sha(v.read_bytes()) for k, v in [("capture", args.capture), ("bridge", args.bridge), ("claims", args.claims)]}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"manifest": str(args.out), "status": result["status"], "periods": 21, "inputCorrections": 33, "sha256": sha(args.out.read_bytes())}))


if __name__ == "__main__":
    main()
