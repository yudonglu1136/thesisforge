#!/usr/bin/env python3
"""Create private, current-only USFD/TFX economic input review candidates.

No production, review-state or financial-source mutation. Each original source is
hashed and the arithmetic is reproducible. An analyst reserve is never relabeled
as issuer-reported cash. This file intentionally does not approve historical PIT
nodes or create a market-price-targeting model.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re

from bs4 import BeautifulSoup

spec = importlib.util.spec_from_file_location("issuer_source_review", Path(__file__).with_name("build-usfd-tfx-source-review.py"))
source_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(source_module)


def normalize(text):
    return re.sub(r"\s+", " ", text).strip()


def fact(doc, tag, start, end):
    rows = [f for f in doc["aggregateFacts"] if f["tag"] == tag and f["start"] == start and f["end"] == end]
    values = {f["value"] for f in rows}
    if len(values) != 1:
        raise ValueError(f"Missing/ambiguous exact source fact {doc['ticker']} {tag} {start} {end}")
    return next(iter(values)) / 1e6


def source(doc, locator):
    raw = Path(doc["localPath"]).read_bytes()
    if hashlib.sha256(raw).hexdigest() != doc["sha256"]:
        raise ValueError("Source hash changed")
    return {"url": doc["url"], "availableDate": doc["filed"], "periodEndDate": doc["periodEndDate"],
            "sha256": doc["sha256"], "localPath": doc["localPath"], "locator": locator}


def passage(doc, pattern):
    text = normalize(BeautifulSoup(Path(doc["localPath"]).read_bytes(), "html.parser").get_text(" ", strip=True))
    match = re.search(pattern, text)
    if not match:
        raise ValueError(f"Reviewed source passage changed: {doc['ticker']} {pattern}")
    return match.group()


def ttm(periods, key):
    return round(sum(p["coefficient"] * p[key] for p in periods.values()), 9)


def dcf(cash_m, shares_m, growth, ke, terminal_growth):
    if len(growth) != 5 or ke <= terminal_growth or shares_m <= 0:
        raise ValueError("Invalid five-year equity DCF assumptions")
    cash = cash_m
    forecasts = []
    for t, rate in enumerate(growth, 1):
        cash *= 1 + rate
        forecasts.append({"t": t, "fcfeM": cash, "pvM": cash / (1 + ke) ** t})
    terminal = cash * (1 + terminal_growth) / (ke - terminal_growth)
    explicit = sum(x["pvM"] for x in forecasts)
    terminal_pv = terminal / (1 + ke) ** 5
    return {"forecasts": forecasts, "pvExplicitM": explicit, "terminalM": terminal,
            "pvTerminalM": terminal_pv, "equityValueM": explicit + terminal_pv,
            "valuePerShare": (explicit + terminal_pv) / shares_m,
            "terminalWeight": terminal_pv / (explicit + terminal_pv)}


def find_doc(evidence, ticker, filed):
    rows = [d for d in evidence["documents"] if d["ticker"] == ticker and d["filed"] == filed]
    if len(rows) != 1:
        raise ValueError("Exact original filing missing")
    return rows[0]


def raw_latest(evidence, ticker):
    rows = [r for r in evidence["financials"] if r["ticker"] == ticker and r["dimension"] == "ART"]
    row = max(rows, key=lambda r: r["available_at"])
    return {"payloadSha256": hashlib.sha256(row["payload_json"].encode()).hexdigest(),
            "payload": json.loads(row["payload_json"])}


def cached_source(cache, ticker, accession, document, filed, period_end, locator):
    path = (cache / ticker / accession / document).resolve()
    raw = path.read_bytes()
    return {"url": f"https://www.sec.gov/Archives/edgar/data/{1665918 if ticker == 'USFD' else 96943}/{accession}/{document}",
            "availableDate": filed, "periodEndDate": period_end, "sha256": hashlib.sha256(raw).hexdigest(),
            "localPath": str(path), "locator": locator}


def build_usfd(evidence, cache):
    annual = find_doc(evidence, "USFD", "2026-02-12")
    interim = find_doc(evidence, "USFD", "2026-08-06")
    q1 = find_doc(evidence, "USFD", "2026-05-07")
    prior = find_doc(evidence, "USFD", "2025-08-07")
    periods = {}
    for key, doc, start, end, sign, lease in [
        ("fy2025", annual, "2024-12-29", "2025-12-27", 1, 120),
        ("h12026", interim, "2025-12-28", "2026-06-27", 1, 63),
        ("h12025", interim, "2024-12-29", "2025-06-28", -1, 77),
    ]:
        periods[key] = {"sourceId": "fy2025" if doc is annual else "h12026", "coefficient": sign,
            "periodStartDate": start, "periodEndDate": end,
            "cfoM": fact(doc, "us-gaap:NetCashProvidedByUsedInOperatingActivities", start, end),
            "cashPpeM": fact(doc, "us-gaap:PaymentsToAcquirePropertyPlantAndEquipment", start, end),
            "sbcM": fact(doc, "us-gaap:ShareBasedCompensation", start, end),
            "leasePrincipalM": lease,
            "leasePrincipalBasis": "audited_lease_note_cash_payment_table" if doc is annual else "reported_mda_scheduled_finance_lease_cash_payments"}
    if fact(annual, "us-gaap:FinanceLeasePrincipalPayments", "2024-12-29", "2025-12-27") != 120:
        raise ValueError("USFD annual audited lease cash does not match")
    quoted = {
        "fy2025Mda": passage(annual, r"Financing Activities Cash flows used in financing activities in fiscal year 2025 included .*?financing leases\."),
        "h12026Mda": passage(interim, r"Financing Activities Cash flows used in financing activities in the 26 weeks ended June 27, 2026 included .*?financing leases\."),
        "h12025Mda": passage(prior, r"Financing Activities Cash flows used in financing activities in the 26 weeks ended June 28, 2025 included .*?financing leases\."),
        "q12026Mda": passage(q1, r"Financing Activities Cash flows used in financing activities in the 13 weeks ended March 28, 2026 included .*?financing leases\."),
        "optionServiceCost": passage(annual, r"There was no unrecognized compensation expense related to unvested Options expected to vest as of December 27, 2025\."),
    }
    for key, needle in [("fy2025Mda", "$110 million"), ("h12026Mda", "$63 million"), ("h12025Mda", "$77 million"), ("q12026Mda", "$35 million")]:
        if needle not in quoted[key]: raise ValueError("Reviewed USFD narrative cash changed")
    option_table = passage(annual, r"Outstanding as of December 27, 2025 1,289,340 15,493 1,304,833 .*?Vested and exercisable as of December 27, 2025 1,289,340 15,493 1,304,833 .*?3\.6")
    # Unlike the annual note, interim narratives and debt roll-forward do not
    # fully reconcile. Preserve both observations; the difference is a reserve.
    cash = ttm(periods, "cfoM") - ttm(periods, "cashPpeM") - ttm(periods, "sbcM") - ttm(periods, "leasePrincipalM")
    shares = fact(interim, "us-gaap:CommonStockSharesOutstanding", None, "2026-06-27")
    if abs(cash - 748) > 1e-9 or shares != 216.3: raise ValueError("USFD source bridge changed")
    scenarios = {
        "bear": {"growthRates": [0.02] * 5, "ke": 0.11, "terminalGrowth": 0.02},
        "base": {"growthRates": [0.08, 0.07, 0.06, 0.04, 0.03], "ke": 0.10, "terminalGrowth": 0.025},
        "bull": {"growthRates": [0.12, 0.10, 0.08, 0.06, 0.04], "ke": 0.09, "terminalGrowth": 0.025},
    }
    sensitivity = []
    for name, scenario in scenarios.items():
        for reserve in [0, 20]:
            for extra_shares in [0, 1.304833]:
                sensitivity.append({"scenario": name, "analystLeaseReconciliationReserveM": reserve,
                    "cashFlowM": cash-reserve, "legacyOptionFullDeliveryStressM": extra_shares,
                    "sharesM": shares+extra_shares,
                    **dcf(cash-reserve, shares+extra_shares, scenario["growthRates"], scenario["ke"], scenario["terminalGrowth"])})
    guide = cached_source(cache, "USFD", "000166591826000043", "usfd06272026ex991.htm", "2026-08-06", "2026-06-27", "Full-year 2026 outlook; company earnings-growth guidance, not FCFE growth")
    guide_text = normalize(BeautifulSoup(Path(guide["localPath"]).read_bytes(), "html.parser").get_text(" ", strip=True))
    for token in ["4%", "6%", "9%", "13%", "18%", "24%"]:
        if token not in guide_text: raise ValueError("USFD official growth guidance changed")
    return {
        "ticker": "USFD", "cik": "1665918", "candidateStatus": "source_reviewed_current_scenario_root_model_review_pending",
        "genericHistoryApproved": False, "periodEndDate": "2026-06-27", "financialAvailableDate": "2026-08-06",
        "fiscalPeriod": "2026-Q2", "reportingCurrency": "USD", "quoteCurrency": "USD", "securityFactor": 1,
        "profileRationale": "Low-margin foodservice distribution, not consumer brand economics. A standalone after-interest/tax cash-flow scenario avoids selecting a high-margin profile to force a positive result.",
        "sources": {"fy2025": source(annual, "Cash-flow statement; note 10 debt; note 16 share-based awards; lease cash table"),
            "h12026": source(interim, "Cash flows p4; period-end common shares; debt note; MD&A Financing Activities"),
            "h12025Original": source(prior, "Debt note; cash-flow statement; MD&A Financing Activities"),
            "q12026": source(q1, "MD&A Financing Activities"), "guidance": guide},
        "periods": periods, "sourceTtm": {"revenueM": 40133, "cfoM": 1369, "capexM": 421, "rawFcfM": 948, "providerSharesM": 216.330723},
        "shareObservations": [{"periodEndDate": "2026-06-27", "sourceId": "h12026", "outstanding": 216300000, "sourcePrecisionShares": 100000}],
        "cashBridge": {"providerCfoLessCashCapexM": 948, "officialCfoLessCashCapexM": 946,
            "officialCashCapexM": 423, "capexSourceCorrectionM": 2, "sbcM": 92, "leasePrincipalM": 106,
            "beforeAnalystReserveM": 748, "analystLeaseReconciliationReserveM": 20, "afterAnalystReserveM": 728,
            "reserveBasis": "analyst_reconciliation_reserve_not_reported_expense",
            "rangeM": {"low": 728, "high": 748},
            "formula": "1369 - (410 + 174 - 161) - (83 + 54 - 45) - (120 + 63 - 77) - optional 20"},
        "leaseReconciliation": {"officialNarratives": quoted,
            "fy2025": {"auditedLeaseNoteM": 120, "mdaScheduledLeaseM": 110, "differenceM": 10, "disposition": "Prefer dedicated audited lease cash table; preserve inconsistent MD&A."},
            "h12025": {"mdaScheduledLeaseM": 77, "aggregateDebtAndLeasePrincipalM": 4303, "debtBorrowingsM": 4069,
                "fundedPrincipalChangeEstimateM": -177, "impliedLeasePrincipalEstimateM": 57,
                "differenceM": 20, "formula": "4303 - 4069 + (-177) = 57",
                "estimateBasis": "Debt note: ABL 48-223=-175; 2024 term loan gross principal (715+8)-(717+8)=-2; other disclosed gross balances unchanged. All USD amounts rounded to millions. This inference is not a separately reported lease payment.",
                "disposition": "Reserve the 20 difference in TTM cash as an analyst sensitivity; no silent overwrite of 77."}},
        "balanceSheet": {"cashM": 56, "providerDebtM": 5405, "debtIncludingFinanceLeasesM": 5237,
            "financeLeaseObligationsM": 591, "fundedDebtExcludingFinanceLeasesM": 4646,
            "noncurrentOperatingLeaseM": 168, "extraDebtOrCashAdjustmentToFcfe": 0,
            "warning": "Do not deduct 5405 from an already after-interest FCFE DCF. It includes noncurrent operating leases whose cash is already in CFO."},
        "claims": {"sourceId": "fy2025", "legacyVestedOptionsAt2025End": 1304833, "weightedStrike": 26.55,
            "unrecognizedLegacyOptionCostM": 0, "exactCurrentOptionCount": None,
            "stressBasis": "Use zero versus full delivery of all last-year vested options with no exercise proceeds. This is a conservative legacy-award stress, not a claim of exact current diluted shares or all newly granted awards.",
            "sourceTable": option_table},
        "managementGuidance": {"sourceId": "guidance", "fiscalYear": 2026, "salesGrowth": [0.04, 0.06], "adjustedEbitdaGrowth": [0.09, 0.13], "adjustedEpsGrowth": [0.18, 0.24],
            "cashCapexM": [400, 440], "cashCapexSourceId": "h12026", "fcfeGuidance": None,
            "interpretation": "Growth in adjusted EBITDA/EPS is not FCFE guidance. Do not label the model's cash-growth forecast as management guidance."},
        "conventions": {"cash": "After interest and tax CFO, less cash capex, financing lease principal and recurring SBC once. No noncash leased-asset addition is deducted as cash.",
            "claims": "Cash-equivalent recurring SBC replaces an extra charge for unvested award dilution. Legacy vested options receive the separate explicit denominator stress only.",
            "other": "No extra dividend, buyback, new debt funding, cash balance or net-debt adjustment. Hold nominal debt financing policy stable in forecast; mandatory refinancing and covenant risk enter scenarios, not automatic recurring borrowings."},
        "scenarios": scenarios, "diagnosticSensitivity": sensitivity,
        "assumptionRationale": "Analyst USD nominal cost of equity 9%-11%, not asserted CAPM measurements. Five rolling forecast years, t=1..5 year-end discounting. 2%-12% starting FCFE growth deliberately differs from management adjusted EPS growth; mature terminal growth 2%-2.5%. No market price input.",
        "remainingScope": ["Root independent model review required", "No 2016-2025 historical profile/cash/guidance approval", "New current option count not separately disclosed; show legacy full-delivery stress", "Lease conflict reserve is an estimate and must remain visible"],
        "preservedRaw": raw_latest(evidence, "USFD"),
    }


def build_tfx(evidence, cache, output):
    annual = find_doc(evidence, "TFX", "2026-02-27")
    interim = find_doc(evidence, "TFX", "2026-08-06")
    q1 = find_doc(evidence, "TFX", "2026-05-07")
    periods = {}
    for key, doc, start, end, sign in [
        ("fy2025", annual, "2025-01-01", "2025-12-31", 1),
        ("h12026", interim, "2026-01-01", "2026-06-30", 1),
        ("h12025", interim, "2025-01-01", "2025-06-29", -1),
    ]:
        periods[key] = {"sourceId": "fy2025" if doc is annual else "h12026", "coefficient": sign,
            "periodStartDate": start, "periodEndDate": end,
            "continuingCfoM": fact(doc, "us-gaap:NetCashProvidedByUsedInOperatingActivitiesContinuingOperations", start, end),
            "continuingCashPpeM": fact(doc, "us-gaap:PaymentsToAcquirePropertyPlantAndEquipment", start, end),
            "continuingSbcM": fact(doc, "us-gaap:ShareBasedCompensation", start, end)}
    financial = {"cfoM": ttm(periods, "continuingCfoM"), "cashPpeM": ttm(periods, "continuingCashPpeM"), "sbcM": ttm(periods, "continuingSbcM")}
    financial["fcfeDiagnosticM"] = round(financial["cfoM"]-financial["cashPpeM"]-financial["sbcM"], 9)
    if financial != {"cfoM": 244.537, "cashPpeM": 76.14, "sbcM": 25.59, "fcfeDiagnosticM": 142.807}:
        raise ValueError("TFX source bridge changed")
    # Freeze supplemental dated primary documents. These are not historical
    # facts before the filing date and cannot amend an earlier PIT node.
    events = {}
    for key, accession, document, date in [
        ("oemProForma", "0000096943-26-000087", "ex991to8-5x2026reoemprofor.htm", "2026-08-05"),
        ("asr", "0000096943-26-000097", "tfx-20260807.htm", "2026-08-07"),
    ]:
        item = {"ticker": "TFX", "cik": "0000096943", "form": "8-K/A" if key == "oemProForma" else "8-K", "filed": date,
            "periodEndDate": "2026-03-31" if key == "oemProForma" else "2026-08-07", "accession": accession, "document": document,
            "url": f"https://www.sec.gov/Archives/edgar/data/96943/{accession.replace('-', '')}/{document}"}
        doc = source_module.fetch_document(item, output)
        events[key] = source(doc, "Original dated disclosure; not a restatement of June 30 actual balances")
    issued_treasury = passage(interim, r"Balance at June 30, 2026 48,203 .*?5,831 .*?2,904,534")
    litigation = passage(interim, r"In April 2026, we entered into a settlement agreement .*?we received \$ 25\.0 million .*?six months ended June 30, 2026\.")
    remaining_sale = passage(interim, r"The combined total consideration from the Strategic Divestitures is \$ 2\.0 billion in cash, consisting of expected proceeds of \$ 1\.5 billion for our OEM business and \$ 530 million for our Acute Care and IU businesses\.")
    guide = cached_source(cache, "TFX", "000009694326000091", "ex991to8-6x2026req2earning.htm", "2026-08-06", "2026-06-30", "Continuing-operations GAAP revenue and GAAP/adjusted EPS outlook reconciliation")
    return {"ticker": "TFX", "candidateStatus": "continuing_source_bridge_reviewed_transaction_model_pending",
        "genericHistoryApproved": False, "reportingCurrency": "USD", "quoteCurrency": "USD", "securityFactor": 1,
        "periodEndDate": "2026-06-30", "financialAvailableDate": "2026-08-06", "sources": {
            "fy2025": source(annual, "Continuing/discontinued cash-flow statement and recast continuing operations"),
            "h12026": source(interim, "Continuing/discontinued cash-flow statement; equity roll-forward; fair-value claims note"),
            "q12026": source(q1, "Continuing CFO used only to derive Q2, not total cash"), "guidance": guide, **events},
        "periods": periods, "continuingTtm": financial,
        "recurringCashNormalization": {"oneTimeLitigationReceiptM": 25, "sourceId": "h12026", "evidence": litigation,
            "fullCashReceiptReserveM": 25, "analystAfterTaxReceiptReserveM": 19.25, "analystMarginalTaxRate": 0.23,
            "cashAfterNonrecurringReceiptRangeM": {"low": 117.807, "high": 123.557},
            "cashAfterReceiptAndPostDebtInterestRangeM": {"low": 139.367, "high": 145.117},
            "rule": "142.807m is only a source-reconciled diagnostic, not normalized recurring FCFE: it includes the 25m litigation receipt. Show a full-cash subtraction versus 23% analyst tax-effect sensitivity. Do not claim exact tax paid on the receipt. The 21.560m post-debt interest uplift is a separate issuer pro forma assumption."},
        "continuingQ2": {"cfoM": round(138.559-46.662, 9), "cashPpeM": round(32.825-18.791, 9),
            "sbcM": round(12.182-6.742, 9), "netIncomeM": 41.762, "discontinuedNetIncomeM": 57.931, "consolidatedNetIncomeM": 99.693},
        "shareObservations": [{"periodEndDate": "2026-06-30", "sourceId": "h12026", "issued": 48203000, "treasury": 5831000,
            "outstanding": 42372000, "sourcePrecisionShares": 1000, "evidence": issued_treasury}],
        "providerDifferencesM": {"cfo": round(244.537-403.196, 9), "capex": round(76.14-63.422, 9),
            "fcfBeforeSbc": round(244.537-76.14-339.774, 9), "netIncomeQ2": round(41.762-99.693, 9)},
        "balanceAndClaims": {"cashM": 300.159, "restrictedCashExcludedM": 16.760, "discontinuedCashExcludedM": 47.368,
            "fundedDebtM": 2808.009, "providerDebtM": 2872.549, "noncurrentOperatingLeaseM": 64.540,
            "contingentConsiderationM": 47.412, "contingentConsiderationCashPaymentsH12026M": 0.107,
            "claimsRule": "Do not use the mislabeled inline tag as the amount: the visible balance-sheet operating lease row is 64.540m, while fair-value acquisition consideration is 47.412m. Deduct future acquisition claims once, not every past cash payment again."},
        "postPeriodOemBridge": {"eventDate": "2026-08-03", "sourceAvailableDate": "2026-08-05", "sourceId": "oemProForma",
            "purchasePriceM": 1500, "estimatedTaxM": 236.4, "estimatedTransactionCostsM": 18.8,
            "reportedAfterTaxProceedsM": 1244.9, "reportedNetCashAfterRequiredDebtPaydownM": 544.873,
            "mandatoryDebtPaydownM": 700, "annualPretaxInterestReductionM": 28, "annualAfterTaxInterestReductionM": 21.56,
            "interestBasis": "Issuer pro forma assumes 4% on 700m; 23% blended marginal tax. These are pro forma assumptions, not a newly reported recurring cash receipt.",
            "temporaryAncillaryAgreementAnnualAfterTaxIncomeM": 6.783, "maximumAgreementMonths": 24,
            "normalizationRule": "Do not capitalize temporary transition services in perpetuity. Whole-company value also requires unsold Acute Care/IU economics or a separately labeled value-zero lower-bound assumption.",
            "roundingNote": "Rounded table 1500-236.4-18.8=1244.8 versus reported1244.9; use precise544.873 residual from pro forma balance sheet and flag source rounding, not fabricated precision."},
        "remainingDisposal": {"sourceId": "h12026", "AcuteCareAndIuContractGrossProceedsM": 530,
            "expectedClosing": "2026-Q4", "closedBySourceCutoff": False, "evidence": remaining_sale,
            "rangePolicy": "Remaining business is not intrinsically worthless. If an analyst uses 0 to 530m before taxes/closing risk as a transparent gross-value sensitivity, label the lower endpoint conservative exclusion and the upper endpoint gross contractual proceeds, not reviewed net cash."},
        "postPeriodAsr": {"sourceId": "asr", "agreementDate": "2026-08-07", "scheduledPaymentDate": "2026-08-10", "cashM": 250,
            "initialDeliveryFractionOfCash": 0.8, "finalShares": None,
            "rule": "Initial delivery is based on Aug6 close; final amount depends on future VWAP. Never combine post-payment cash with pre-ASR shares and call it exact. Pre-ASR snapshot as of Aug6 is independently date-valid; Sept5 scenario must reconcile known cash and actual observed shares or disclose a range."},
        "managementGuidance": {"sourceId": "guidance", "fiscalYear": 2026, "continuingGaapRevenueM": [2260, 2280],
            "continuingGaapDilutedEps": [2.54, 2.84], "continuingAdjustedDilutedEps": [6.90, 7.20],
            "proFormaAdjustedConstantCurrencyGrowth": [0.035, 0.045],
            "gaapToAdjustedEpsBridge": {"restructuring": 0.98, "acquisitionIntegrationDivestiture": 0.73, "other": -0.42,
                "erp": 0.31, "mdr": 0.02, "intangibleAmortization": 2.74}, "fcfeGuidance": None,
            "warning": "Do not treat adjusted EPS as GAAP NI or issuer FCFE. Net revenue guidance excludes discontinued businesses."},
        "remainingScope": ["Standalone current scenario still requires dated OEM/ASR cash-and-shares policy", "Unsold Acute Care/IU must be valued separately or explicitly excluded as a lower bound", "Existing awards and acquisition-claim double-count review", "Do not approve mixed original historical provider rows"],
        "preservedRaw": raw_latest(evidence, "TFX")}


def validate_candidate(candidate, cutoff):
    if candidate.get("genericHistoryApproved") is not False:
        raise ValueError("Current review must never approve historical models")
    for src in candidate["sources"].values():
        if src["availableDate"] > cutoff:
            raise ValueError("Future source")
        if hashlib.sha256(Path(src["localPath"]).read_bytes()).hexdigest() != src["sha256"]:
            raise ValueError("Source hash mismatch")
    if candidate["ticker"] == "USFD":
        for row in candidate["diagnosticSensitivity"]:
            s = candidate["scenarios"][row["scenario"]]
            expected = dcf(row["cashFlowM"], row["sharesM"], s["growthRates"], s["ke"], s["terminalGrowth"])
            if abs(row["valuePerShare"]-expected["valuePerShare"]) > 1e-12: raise ValueError("DCF arithmetic changed")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--evidence", required=True, type=Path)
    parser.add_argument("--official-cache", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    target = args.output_dir / "usfd-tfx-current-review-candidates.json"
    if target.exists(): raise ValueError("Immutable review output already exists")
    evidence = json.loads(args.evidence.read_text())
    candidates = [build_usfd(evidence, args.official_cache), build_tfx(evidence, args.official_cache, args.output_dir)]
    for candidate in candidates: validate_candidate(candidate, evidence["cutoff"])
    artifact = {"schemaVersion": 1, "status": "private_current_only_candidates_not_release_approval", "sourceCutoff": evidence["cutoff"],
        "reviewedAt": "2026-09-06", "evidenceBundleSha256": hashlib.sha256(args.evidence.read_bytes()).hexdigest(),
        "companies": candidates}
    args.output_dir.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(artifact, indent=2, sort_keys=True)+"\n")
    print(json.dumps({"output": str(target), "sha256": hashlib.sha256(target.read_bytes()).hexdigest(),
        "USFD": candidates[0]["cashBridge"], "TFX": candidates[1]["continuingTtm"]}))


if __name__ == "__main__": main()
