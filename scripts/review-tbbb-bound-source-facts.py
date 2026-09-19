#!/usr/bin/env python3
"""Reconcile TBBB configured financial observations to frozen official rows.

This is a narrow current-date source check; no historical model is approved.
"""
import argparse
import csv
import hashlib
import io
import json
from pathlib import Path
import re
import xml.etree.ElementTree as ET

from bs4 import BeautifulSoup
from pypdf import PdfReader

ROOT = Path(__file__).resolve().parents[1]

LABELS = {
    "revenue": r"Total revenue", "cfo": r"Net cash flows provided by operating activities",
    "ppePurchases": r"Purchase of property", "ppeDisposals": r"Sale of property",
    "intangibleCapex": r"Additions to intangible", "leasePrincipal": r"Principal payments on lease",
    "leaseInterest": r"Interest payments on leases", "otherDebtInterest": r"Interest payment on debt",
    "supplierFinanceInflow": r"Finance obtained through supplier finance",
    "supplierFinanceRepayment": r"Payments made on supplier finance",
    "sbc": r"Share-based payments? expense", "otherDebtPrincipal": r"Payment of debt",
}


def sha(raw): return hashlib.sha256(raw).hexdigest()


def reconcile_financial_rows(economic, documents):
    facts = []
    for period in economic["financialPeriods"]:
        source = economic["sources"][period["sourceId"]]
        document = documents[source["url"]]
        raw = Path(document["path"]).read_bytes()
        if sha(raw) != document["sha256"]: raise ValueError("Source bytes changed")
        soup = BeautifulSoup(raw, "html.parser")
        rows = [" ".join(r.get_text(" ", strip=True).split()) for r in soup.find_all("tr")]
        for metric, expected in period["values"].items():
            token = f"{expected:,}"
            matches = [r for r in rows if len(r) < 2500 and re.search(LABELS[metric], r, re.I) and
                       re.search(r"(?<![\d,])"+re.escape(token)+r"(?![\d,])", r)]
            if not matches: raise ValueError(f"No exact financial source row: {period['id']} {metric} {token}")
            facts.append({"periodId": period["id"], "periodStartDate": period["periodStartDate"],
                          "periodEndDate": period["periodEndDate"], "availableDate": source["availableDate"],
                          "metric": metric, "value": expected, "unit": "MXN_thousand",
                          "sourceRow": min(matches, key=len), "url": source["url"],
                          "sourceSha256": document["sha256"],
                          "comparativePolicy": "current_node_uses_comparative_as_published_in_current_source_not_historical_restating"})
    return facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--binding", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    args = parser.parse_args()
    if args.output.exists(): raise ValueError("Immutable source review output already exists")
    binding = json.loads(args.binding.read_text())
    documents = {d["url"]: d for d in binding["documents"]}
    by_id = {ref["sourceId"]: d for d in binding["documents"] for ref in d["configReferences"]}
    economic = json.loads((ROOT/"server/config/tbbb-economic-evidence.json").read_text())
    underwriting = json.loads((ROOT/"server/config/tbbb-underwriting-2026-09-05.json").read_text())
    facts = reconcile_financial_rows(economic, documents)
    assertions = []

    def text_assert(source_id, pattern, meaning):
        d = by_id[source_id]
        match = re.search(pattern, d["visibleText"], re.I)
        if not match: raise ValueError("Missing reviewed source passage: "+meaning)
        assertions.append({"sourceId": source_id, "url": d["url"], "availableDate": d["availableDate"],
                           "sourceSha256": d["sha256"], "meaning": meaning,
                           "passage": d["visibleText"][max(0,match.start()-80):match.end()+180]})

    text_assert("fy2025", r"total revenue is forecast to grow by 29% to 32%", "March 2026 issued FY2026 total revenue guidance; not asserted Q2 reaffirmed")
    text_assert("q1budget", r"5,250,000.{0,100}3,555,000.{0,110}490,000", "FY2026 capital program and expansion allocations")
    text_assert("q1budget", r"1,089,705.{0,130}706,574", "Q1 mixed deployment differs from cash PPE")
    text_assert("q1notes", r"New leases 1,142,031 77,078 151,915 1,371,024", "Q1 equipment noncash lease additions separated from premises leases")
    text_assert("annual2025", r"New leases 3,750,785 124,981 427,990 4,303,756", "FY2025 equipment noncash lease additions")
    text_assert("annual2025", r"holders of our Class A common shares are entitled to dividends and other distributions, pari passu with our Class B common shares and Class C common shares", "all three classes have same economic dividend rights")
    text_assert("annual2025", r"Promissory Notes and Convertible Notes was repaid in full in 2024", "legacy preferred-ranking promissory and convertible note claims repaid; not deducted as current claims")
    text_assert("annual2025", r"may resolve to amend our memorandum and articles of association.{0,100}preferred shares", "authorized future preferred issuance is a governance risk, not a reported current preferred claim")
    text_assert("h12026", r"77,938,244.{0,100}5,210,000.{0,100}38,039,530.{0,100}121,187,774", "June all-class issued share count")
    text_assert("h12026", r"4,374,993.{0,100}4,224,960", "LEP and Bolton delayed delivery counts")
    text_assert("h12026", r"37,640,312.{0,220}4,082,500.{0,250}535,664", "gross options and unvested post-IPO RSUs before illustrative market-priced treasury-stock offset")
    text_assert("h12026", r"held \$236 million in U.S. dollar-denominated short-term bank deposits", "reported rounded USD bank deposit balance kept in USD")
    text_assert("grants", r"Granted during the year 2,860,000", "FY2025 gross new option count is historical anchor, not promised future awards")
    text_assert("grants", r"Granted during the year 541,000", "FY2025 gross RSU grant count")
    text_assert("countryPremium", r"Last updated: January 5, 2026", "risk premium table has explicit dated author vintage")
    text_assert("countryPremium", r"Mexico Baa2 1.62% 2.46% 6.69%", "Mexico CRP 2.46 and total ERP 6.69; mature ERP difference 4.23")
    text_assert("countryPremium", r"United States Aa1 0.23% 0.23% 4.46%", "US Treasury credit adjustment 0.23")
    text_assert("fed", r"2 percent", "long-run USD inflation analyst assumption anchored to official target")

    d = by_id["banxico"]
    pages = [" ".join(p.extract_text().split()) for p in PdfReader(d["path"]).pages]
    if "June 25, 2026" not in pages[0] or "second quarter of 2027" not in pages[0] or \
       "3.6 3.7 4.1 4.0 3.8 3.5 3.2 3.0 3.0 3.0 3.0 3.0" not in pages[1]:
        raise ValueError("Banxico target/date evidence mismatch")
    assertions.append({"sourceId": "banxico", "url": d["url"], "availableDate": d["availableDate"],
                       "sourceSha256": d["sha256"], "meaning": "Issuer-published English translation; headline forecast reaches 3.0 in Q2 2027, visual table inspected; Spanish original controls",
                       "page": 2, "passage": "Current (06/25/2026) headline CPI: Q1 2027 3.2; Q2 2027 3.0. Forecast, not current inflation or a market forward."})

    macro = []
    for source_id, currency, expected in [("ecbMxn", "MXN", 19.6401), ("ecbUsd", "USD", 1.1622)]:
        d = by_id[source_id]
        rows = list(csv.DictReader(io.StringIO(Path(d["path"]).read_text())))
        row = next(r for r in rows if r["TIME_PERIOD"] == "2026-09-04")
        if row["CURRENCY"] != currency or row["CURRENCY_DENOM"] != "EUR" or float(row["OBS_VALUE"]) != expected:
            raise ValueError("Wrong ECB unit/date/value")
        macro.append({"sourceId": source_id, "sourceSha256": d["sha256"], "sourceRow": row})
    d = by_id["treasury"]
    tree = ET.fromstring(Path(d["path"]).read_bytes())
    props = [x for x in tree.iter() if x.tag.endswith("}properties")]
    row = next({e.tag.split("}")[-1]: e.text for e in x} for x in props
               if any(e.tag.endswith("}NEW_DATE") and e.text.startswith("2026-09-04") for e in x))
    if float(row["BC_10YEAR"]) != 4.78: raise ValueError("Wrong Treasury date/tenor/rate")
    macro.append({"sourceId": "treasury", "sourceSha256": d["sha256"], "sourceRow": row,
                  "captureVsObservation": "Feed retrieved September 6; only pre-cutoff September 4 observation used"})
    saved_input_path = ROOT/"output/guru-valuation-expansion-2026-09-05/tbbb-unapproved-scenarios.json"
    saved_input = json.loads(saved_input_path.read_text())["scenarios"][0]["input"]
    growth_source = {"2023-12-31": "growth_fy2024", "2024-03-31": "growth_q12024", "2024-06-30": "h12024",
                     "2024-09-30": "growth_q32024", "2024-12-31": "growth_fy2024", "2025-03-31": "growth_q12025",
                     "2025-06-30": "growth_q22025", "2025-09-30": "growth_q32025", "2025-12-31": "fy2025",
                     "2026-03-31": "growth_q12026", "2026-06-30": "h12026"}
    growth_facts = []
    for observation in saved_input["financialTrendEvidence"]["observations"]:
        for role, point in [("current", observation), ("comparator", observation["comparator"])]:
            source_id = growth_source[point["periodEndDate"]]
            d = by_id[source_id]
            expected_k = round(point["revenueM"] * 1000)
            soup = BeautifulSoup(Path(d["path"]).read_bytes(), "html.parser")
            candidates = [" ".join(tr.get_text(" ", strip=True).split()) for tr in soup.find_all("tr")]
            rows = [t for t in candidates if len(t) < 2000 and "total revenue" in t.lower() and f"{expected_k:,}" in t]
            if not rows: raise ValueError(f"Growth revenue cannot be corroborated: {point['periodEndDate']} {expected_k}")
            growth_facts.append({"observationPeriod": observation["periodEndDate"], "role": role,
                                 "periodEndDate": point["periodEndDate"], "revenueM": point["revenueM"],
                                 "currency": "MXN", "rawValueK": expected_k, "rawUnit": "MXN_thousand",
                                 "sourceRow": min(rows, key=len), "url": d["url"], "sourceSha256": d["sha256"],
                                 "sourceAvailableDate": d["availableDate"], "providerAvailableDate": point["availableDate"],
                                 "scope": "official_numeric_corroboration_for_current_model_not_proof_of_original_provider_datekey"})
    result = {"schemaVersion": "tbbb-current-source-fact-review-v1", "sourceCutoff": "2026-09-05",
              "status": "exact_cash_rows_claims_guidance_and_macro_reconciled_current_scope_only",
              "bindingPath": str(args.binding.resolve()), "bindingSha256": sha(args.binding.read_bytes()),
              "financialFacts": facts, "sourcePassageChecks": assertions, "macroObservations": macro,
              "growthFacts": growth_facts, "savedInputFileSha256": sha(saved_input_path.read_bytes()),
              "omittedGrowthSlots": [{"fiscalPeriod": "2024-Q3", "reason": "missing_positive_like_for_like_revenue_in_latest_eight_period_window"}],
              "reviewJudgments": [
                  "No preference/NCI line in current equity statements; A/B/C equity share rights pari passu. Future preferred issuance authority not mistaken for outstanding preferred capital.",
                  "Operating supplier invoices already leave CFO when bank pays; gross supplier repayment not charged again. Net actual H1 cash borrowing retained once and cancels FY-minus-H1.",
                  "Full-share option upper bound includes time value conservatively; no exercise proceeds and no second cash SBC charge. Does not pretend exact tranche option valuation.",
                  "Bank deposits not operating cash; operating cash reserved separately, no interest credited, December availability and covenant risk remain explicit analyst assumptions.",
                  "FY2024 other-assets change differs by MXN 0.001m between March earnings release (418.647) and April annual (418.646); selected March source matches configured scenario anchor exactly.",
                  "TTM PPE disposal FY+H1-comparator is negative MXN 0.363m in source; retained and flagged. No silent zero; this diagnostic cash bridge does not set the forward capital budget.",
                  "Capital-financing ratio, working-capital scalability, future grants, beta, risk premium, FX parity and terminal growth are analyst judgments, not issuer promises."
              ], "historicalEconomicApproval": False, "productionWrites": 0}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True)+"\n")
    print(json.dumps({"output": str(args.output.resolve()), "financialRows": len(facts), "passageChecks": len(assertions),
                      "macroObservations": len(macro), "growthFacts": len(growth_facts), "sha256": sha(args.output.read_bytes())}))


if __name__ == "__main__": main()
