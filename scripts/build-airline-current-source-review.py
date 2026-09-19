#!/usr/bin/env python3
"""Freeze ALK/CPA exact current issuer statements; no model/review approval."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
from pathlib import Path
import re
from bs4 import BeautifulSoup

spec = importlib.util.spec_from_file_location("issuer_source", Path(__file__).with_name("build-usfd-tfx-source-review.py"))
issuer_source = importlib.util.module_from_spec(spec)
spec.loader.exec_module(issuer_source)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--official-cache", required=True, type=Path)
    parser.add_argument("--output-dir", required=True, type=Path)
    args = parser.parse_args()
    target = args.output_dir / "airline-current-source-evidence.json"
    if target.exists(): raise ValueError("Immutable evidence already exists")
    items = []
    for ticker, cik in [("ALK", "0000766421"), ("CPA", "0001345105")]:
        submission = json.loads((args.official_cache / ticker / "submission.json").read_text())
        if str(submission["cik"]).zfill(10) != cik: raise ValueError("CIK identity mismatch")
        recent = submission["filings"]["recent"]
        for i, form in enumerate(recent["form"]):
            date = recent["filingDate"][i]
            if form not in {"10-Q", "10-K", "20-F"} or not "2026-01-01" <= date <= "2026-09-05": continue
            accession, document = recent["accessionNumber"][i], recent["primaryDocument"][i]
            if re.search(r"[/\\]|\.\.", document): raise ValueError("Invalid exact filing document")
            items.append({"ticker": ticker, "cik": cik, "form": form, "filed": date,
                "periodEndDate": recent["reportDate"][i], "accession": accession, "document": document,
                "url": f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}/{document}"})
    for accession, document, date, period in [
        ("0001628280-26-054628", "cpa2q26ex-9911.htm", "2026-08-07", "2026-06-30"),
        ("0001628280-26-035223", "cpa1q26ex-9911.htm", "2026-05-14", "2026-03-31"),
    ]:
        items.append({"ticker": "CPA", "cik": "0001345105", "form": "6-K earnings exhibit",
            "filed": date, "periodEndDate": period, "accession": accession, "document": document,
            "url": f"https://www.sec.gov/Archives/edgar/data/1345105/{accession.replace('-', '')}/{document}"})
    with ThreadPoolExecutor(max_workers=2) as pool:
        documents = list(pool.map(lambda d: issuer_source.fetch_document(d, args.output_dir), items))
    for doc in documents:
        soup = BeautifulSoup(Path(doc["localPath"]).read_bytes(), "html.parser")
        text = re.sub(r"\s+", " ", soup.get_text(" ", strip=True))
        doc["airlineCashTables"] = [t.get_text(" ", strip=True) for t in soup.find_all("table")
            if len(t.get_text()) < 20000 and any(p in t.get_text(" ", strip=True).lower()
                for p in ["finance lease principal", "financing cash flows", "payment of lease liability", "interest paid", "advance payments on aircraft"])]
        doc["airlineCashPassages"] = [text[max(0, m.start()-90):m.end()+550]
            for m in re.finditer(r"finance lease|lease liability|interest paid|interest received|aircraft purchase deposits|pension contributions", text, re.I)
            if "Member" not in text[max(0, m.start()-90):m.end()+550]]
    args.output_dir.mkdir(parents=True, exist_ok=True)
    cpa_periods = {
        "fy2025": {"coefficient": 1, "cfoM": 1150.436, "cashPpeM": 815.726, "cashIntangiblesM": 30.921,
            "netAircraftDepositsM": 106.506, "leasePrincipalM": 59.089,
            "depositFormula": "251.430 advance payments - 144.924 reimbursements"},
        "h12026": {"coefficient": 1, "cfoM": 617.897, "cashPpeM": 375.769, "cashIntangiblesM": 11.823,
            "netAircraftDepositsM": 340.399, "leasePrincipalM": 32.371},
        "h12025": {"coefficient": -1, "cfoM": 484.282, "cashPpeM": 390.502, "cashIntangiblesM": 14.342,
            "netAircraftDepositsM": 60.204, "leasePrincipalM": 28.504},
    }
    cpa_ttm = {field: round(sum(p["coefficient"]*p[field] for p in cpa_periods.values()), 9)
        for field in ["cfoM", "cashPpeM", "cashIntangiblesM", "netAircraftDepositsM", "leasePrincipalM"]}
    cpa_ttm["cashAfterReinvestmentAndLeasesBeforeSbcM"] = round(cpa_ttm["cfoM"]-sum(cpa_ttm[k] for k in
        ["cashPpeM", "cashIntangiblesM", "netAircraftDepositsM", "leasePrincipalM"]), 9)
    artifact = {"schemaVersion": 1, "sourceCutoff": "2026-09-05", "status": "source_evidence_only_no_economic_approval", "documents": documents,
        "reviewFindings": {
            "CPA": {"currentFinancialCoverage": "Official Q1 and Q2 statements exist despite annual-only provider history",
                "periods": cpa_periods, "ttm": cpa_ttm,
                "interestConvention": "FY2025 IFRS cash-flow statement reports 68.167m interest paid and53.763m received within operating cash; do not deduct interest twice.",
                "quotedSharesM": 40.819423, "classASharesM": 29.881298, "classBSharesM": 10.938125,
                "balanceM": {"cash": 266.825, "shortTermInvestments": 996.411, "longTermInvestments": 280.188,
                    "fundedBorrowings": 2271.595, "leaseCurrent": 68.349, "leaseNoncurrent": 224.871,
                    "reportedNetDebtIncludingLeases": 1021.390},
                "managementGuidance": {"fiscalYear": 2026, "capacityAsmGrowth": [0.14, 0.15], "operatingMargin": [0.17, 0.19],
                    "fuelPricePerGallon": 3.60, "loadFactor": 0.87},
                "modelDisposition": "Quarterly source reconstruction is feasible. Positive perpetual FCFE cannot be fabricated by excluding mandatory aircraft deposits or counting borrowings. A cycle/reinvestment forecast is still an explicit analyst judgment. Annual SBC5.694m is known, interim SBC is not separately reported in these abbreviated statements; do not fill missing interim SBC with zero.",
                "genericHistoryApproved": False},
            "ALK": {"sharesM": 111.566970, "providerLaterCoverSharesM": 111.603120,
                "h12026": {"cfoM": 606, "aircraftEquipmentDepositsCashM": 415, "otherCashPpeM": 108,
                    "cashBeforeFinanceLeasePrincipalAndSbcM": 83, "longTermDebtCashPaymentsM": 405,
                    "financeLeasePrincipalM": None, "stockBasedCompensationAndOtherM": 42},
                "fy2025Lease": {"reportedFinanceLeasePrincipalM": 9, "contractual2026FinanceLeasePaymentsM": 193,
                    "leaseConversionNoncashM": 200},
                "balanceM": {"cash": 1064, "marketableSecurities": 1598, "restrictedCurrentCashExcluded": 33,
                    "restrictedNoncurrentCashExcluded": 30, "debtIncludingFinanceLeases": 6235,
                    "operatingLeaseCurrent": 217, "operatingLeaseNoncurrent": 1164},
                "modelDisposition": "Latest interim combines lease/debt payments. Annual9m cash cannot stand in for2026 lease principal following the200m noncash lease conversion and193m contractual2026 payments. Quarterly SBC-and-other42m is not exact recurring SBC; annual standalone SBC69m differs from annual cash-flow combined10m. Keep these distinctions visible before a normalized transportation model.",
                "genericHistoryApproved": False}}}
    target.write_text(json.dumps(artifact, indent=2, sort_keys=True)+"\n")
    print(json.dumps({"output": str(target), "filings": len(documents), "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}))


if __name__ == "__main__": main()
