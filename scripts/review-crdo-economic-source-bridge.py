#!/usr/bin/env python3
"""Create auditable CRDO cash/share bridge from frozen original SEC filings.

Only scoped currency evidence may be appended to a NEW source-copy. This does
not approve an issuer profile, grant claims completeness, or publish a model.
"""
from __future__ import annotations
import argparse
from datetime import date
import hashlib
import json
from pathlib import Path
import sqlite3

VERSION = "crdo-economic-source-bridge-v1-2026-09-06"
TAGS = {"cfoM": "us-gaap:NetCashProvidedByUsedInOperatingActivities",
        "capexM": "us-gaap:PaymentsToAcquirePropertyPlantAndEquipment",
        "sbcM": "us-gaap:ShareBasedCompensation",
        "licensePaymentsM": "crdo:PaymentsForRecordedUnconditionalPurchaseObligation"}


def digest(raw):
    return hashlib.sha256(raw).hexdigest()


def evidence(doc, fact, locator=None):
    return {"url": doc["url"], "availableDate": doc["filed"],
            "periodEndDate": fact.get("end"), "periodStartDate": fact.get("start"),
            "locator": locator or f"{fact.get('tag')} context={fact.get('context')}",
            "sha256": doc["sha256"], "valueM": fact["value"] / 1e6}


def fact(doc, tag, end, *, start=None, instant=False):
    rows = [f for f in doc["aggregateFacts"] if f["tag"] == tag and f.get("end") == end
            and (not instant or f.get("start") is None)
            and (start is None or f.get("start") == start)]
    if not rows:
        return None
    if len({(f["value"], f.get("start"), f["unit"]) for f in rows}) != 1:
        raise ValueError(f"Conflicting source values: {doc['filed']} {tag} {end}")
    return rows[0]


def cashflow_zero(doc, start, end):
    """Reviewed absence, not an assumed missing number: full financing table."""
    candidates = [t for t in doc["tableText"] if "Cash flows from financing activities:" in t
                  and "Cash flows from operating activities:" in t]
    if len(candidates) != 1:
        raise ValueError("Absent license requires one complete cash flow table")
    section = candidates[0].split("Cash flows from financing activities:")[1].split("Effect of exchange rate")[0]
    if "licens" in section.lower() or "debt" in section.lower() or "obligation" in section.lower():
        raise ValueError("Unmapped financing amount cannot become zero")
    # The first four public SEC CF statements have only equity issuance,
    # issuance costs and repurchases in financing; the original complete
    # statement is retained for independent review of the absence.
    if doc["filed"] not in {"2022-03-10", "2022-06-08", "2022-09-01", "2022-12-01"}:
        raise ValueError("No reviewed absent-license policy for this filing")
    return {"tag": "reviewed_financing_section_no_license_payment", "value": 0,
            "unit": "iso4217:USD", "start": start, "end": end,
            "context": "complete cash flow financing section; no license or debt payments",
            "reviewedEvidence": section}


def cash(doc, end):
    first = fact(doc, TAGS["cfoM"], end)
    if first is None:
        raise ValueError(f"Missing CFO: {doc['filed']}/{end}")
    result = {"start": first["start"], "end": end, "evidence": []}
    for key, tag in TAGS.items():
        f = fact(doc, tag, end, start=first["start"])
        if f is None and key == "licensePaymentsM":
            f = cashflow_zero(doc, first["start"], end)
        if f is None:
            raise ValueError(f"Missing {key}: {doc['filed']}/{end}")
        result[key] = f["value"] / 1e6
        result["evidence"].append(evidence(doc, f))
    return result


def manual_s1_cash(doc, end):
    # Read and tie out the original untagged S-1 cash-flow tables. These values
    # are not imported retrospectively into a public modeled pre-IPO node.
    choices = {"2021-04-30": {"start": "2020-05-01", "cfoM": -42.361, "capexM": 6.056, "sbcM": 2.570},
               "2021-10-31": {"start": "2021-05-01", "cfoM": -34.919, "capexM": 4.985, "sbcM": 2.382}}
    values = choices[end]
    table = next(t for t in doc["tableText"] if "Cash flows from operating activities:" in t
                 and ("Years ended April 30" if end == "2021-04-30" else "Six months ended October 31") in t)
    for value in [values["cfoM"], values["capexM"], values["sbcM"]]:
        assert f"{round(abs(value)*1000):,}" in table
    result = {**values, "end": end, "licensePaymentsM": 0, "evidence": []}
    for key in TAGS:
        result["evidence"].append(evidence(doc, {"value": result[key]*1e6, "start": values["start"], "end": end},
                    f"Consolidated cash-flow table ({end}); {key}; USD thousands; full financing section reviewed"))
    return result


def combine(items, policy, end):
    result = {key: round(sum(multiplier*item[key] for multiplier, item in items), 9) for key in TAGS}
    result["economicCashAfterLicenseAndSbcM"] = round(result["cfoM"] - result["capexM"] - result["licensePaymentsM"] - result["sbcM"], 9)
    result["derivation"] = policy
    result["periodEndDate"] = end
    result["evidence"] = [{**ev, "multiplier": multiplier} for multiplier, item in items for ev in item["evidence"]]
    return result


def currency_evidence(doc):
    if doc["form"].startswith("S-1"):
        wording = next(p for p in doc["currencyParagraphs"] if "Our results of operations are denominated in U.S. dollars" in p)
        return {"currency": "USD", "availableAt": doc["filed"], "url": doc["url"], "sha256": doc["sha256"],
                "locator": "Foreign-currency risk disclosure; results of operations denomination",
                "evidenceExcerpt": "Our results of operations are denominated in U.S. dollars.",
                "basis": "explicit_issuer_reporting_currency_not_sales_currency"}
    aggregate = [f for f in doc["aggregateFacts"] if f["tag"] in {TAGS["cfoM"], "us-gaap:Assets", "us-gaap:StockholdersEquity", "us-gaap:RevenueFromContractWithCustomerExcludingAssessedTax"}]
    units = {f["unit"] for f in aggregate}
    if units != {"iso4217:USD"} or len({f["tag"] for f in aggregate}) < 3:
        raise ValueError("Currency does not reconcile across 3 whole-company concepts")
    return {"currency": "USD", "availableAt": doc["filed"], "url": doc["url"], "sha256": doc["sha256"],
            "basis": "exact_inline_xbrl_whole_company_statement_units", "concepts": sorted({f["tag"] for f in aggregate})}


def bridge(capture):
    docs = capture["documents"]
    rows = [r for r in capture["financials"] if r["dimension"] == "ARQ"]
    by_date = {d["filed"]: d for d in docs}
    currency = [currency_evidence(d) for d in docs]
    result = []
    for row in rows:
        end, available, fiscal = row["report_period"], row["available_at"], row["fiscal_period"]
        doc = by_date[available]
        raw = json.loads(row["payload_json"])
        if doc["form"].startswith("S-1"):
            result.append({"fiscalPeriod": fiscal, "periodEndDate": end, "availableDate": available,
                           "status": "non_modelable", "reason": "pre_ipo_registration_statement_no_public_quoted_security",
                           "currency": "USD", "currencyEvidence": currency_evidence(doc),
                           "evidence": [{"url": doc["url"], "availableDate": available, "sha256": doc["sha256"],
                                         "locator": "S-1 cover: initial public offering; no prior public market"}]})
            continue
        ytd = cash(doc, end)
        quarter_number = int(fiscal[-1])
        if quarter_number == 1:
            quarter = combine([(1, ytd)], "reported three-month cash-flow statement", end)
        else:
            prior_row = rows[rows.index(row)-1]
            prior_doc = by_date[prior_row["available_at"]]
            prior = manual_s1_cash(prior_doc, prior_row["report_period"]) if prior_doc["form"].startswith("S-1") else cash(prior_doc, prior_row["report_period"])
            if prior["start"] != ytd["start"]:
                raise ValueError("Quarter YTD subtraction does not share same fiscal start")
            quarter = combine([(1, ytd), (-1, prior)], "current fiscal YTD minus prior disclosed fiscal YTD", end)
        if quarter_number == 4:
            ttm = combine([(1,ytd)], "reported full fiscal year cash-flow statement", end)
        else:
            fiscal_start = date.fromisoformat(ytd["start"])
            prior_year_end = date.fromordinal(fiscal_start.toordinal()-1).isoformat()
            prior_year_docs = [d for d in docs if d["filed"]<=available and d["form"] == "10-K" and fact(d,TAGS["cfoM"],prior_year_end)]
            annual = cash(prior_year_docs[0],prior_year_end) if prior_year_docs else manual_s1_cash(docs[0],prior_year_end)
            comparison = [f for f in doc["aggregateFacts"] if f["tag"] == TAGS["cfoM"] and f.get("start")
                          and f["end"]<ytd["start"] and abs((date.fromisoformat(f["end"])-date.fromisoformat(f["start"])).days
                              -(date.fromisoformat(ytd["end"])-date.fromisoformat(ytd["start"])).days)<20]
            comparison_ends = {f["end"] for f in comparison}
            if len(comparison_ends) != 1:
                raise ValueError("Missing or ambiguous same-duration prior-year comparison")
            prior_ytd = cash(doc,next(iter(comparison_ends)))
            ttm = combine([(1,ytd),(1,annual),(-1,prior_ytd)], "current fiscal YTD + prior full FY - current-filing prior-year YTD comparator", end)
        shares = fact(doc,"us-gaap:CommonStockSharesOutstanding",end,instant=True)
        cover = [f for f in doc["aggregateFacts"] if f["tag"]=="dei:EntityCommonStockSharesOutstanding"]
        if shares is None or shares["unit"]!="xbrli:shares":
            raise ValueError("No exact period-end ordinary shares")
        for key, field in [("cfoM","cfo_m"),("capexM","capex_m")]:
            if abs(quarter[key]-raw[field]) > .0011:
                raise ValueError(f"Source quarter mismatch {fiscal} {key}: {quarter[key]} versus {raw[field]}")
        art_row = next(r for r in capture["financials"] if r["dimension"]=="ART" and r["fiscal_period"]==fiscal)
        art = json.loads(art_row["payload_json"])
        for key, field in [("cfoM","cfo_m"),("capexM","capex_m")]:
            if art[field] is not None and abs(ttm[key]-art[field]) > .0011:
                raise ValueError(f"Source TTM mismatch {fiscal} {key}: {ttm[key]} versus {art[field]}")
        ttm["rawProviderCfoM"] = art["cfo_m"]
        ttm["rawProviderCapexM"] = art["capex_m"]
        ttm["providerMissingFilledFromOriginalSec"] = art["cfo_m"] is None or art["capex_m"] is None
        cash_balance = fact(doc,"us-gaap:CashAndCashEquivalentsAtCarryingValue",end,instant=True)
        short_term = fact(doc,"us-gaap:ShortTermInvestments",end,instant=True)
        options = [f for f in doc["aggregateFacts"] if f["tag"] in {
            "us-gaap:ShareBasedCompensationArrangementByShareBasedPaymentAwardOptionsOutstandingNumber",
            "us-gaap:ShareBasedCompensationArrangementByShareBasedPaymentAwardOptionsOutstandingWeightedAverageExercisePrice"} and f["end"]==end and f.get("start") is None]
        result.append({"fiscalPeriod": fiscal, "periodEndDate": end, "availableDate": available, "currency": "USD",
                       "status": "cash_share_source_bridge_reviewed_claims_pending", "quarter": quarter, "ttm": ttm,
                       "periodEndSharesM": shares["value"]/1e6, "sourceShareCountM": raw["shares_m"],
                       "shareEvidence": evidence(doc,shares), "coverShareEvidence": [evidence(doc,f) for f in cover],
                       "cashAndEquivalentsM": cash_balance["value"]/1e6 if cash_balance else None,
                       "shortTermInvestmentsM": short_term["value"]/1e6 if short_term else None,
                       "cashEvidence": [evidence(doc,f) for f in [cash_balance,short_term] if f],
                       "optionFacts": options, "otherEquityClaimsM": None,
                       "claimsStatus": "existing_options_customer_warrants_acquisition_claims_require_model_treatment"})
    resolved = []
    for event in capture["guidance"]:
        payload = json.loads(event["payload_json"])
        if payload.get("amount") is None or payload.get("currency") is not None:
            continue
        eligible = [ev for ev in currency if ev["availableAt"]<=event["observed_at"]]
        if not eligible:
            raise ValueError(f"No dated guidance currency for {event['id']}")
        ev = eligible[-1]
        if (date.fromisoformat(event["observed_at"])-date.fromisoformat(ev["availableAt"])).days>180:
            raise ValueError("Dated currency is stale")
        resolved.append({"id":event["id"],"observedAt":event["observed_at"],"currency":"USD","evidence":ev,
                         "originalCurrency":payload.get("currency"),"previousResolution":payload.get("currency_resolution"),
                         "sourceQuoteSha256":digest(event["evidence_excerpt"].encode())})
    return {"version":VERSION,"ticker":"CRDO","cik":capture["cik"],"cutoff":capture["cutoff"],
            "status":"source_bridge_complete_claims_model_pending","cashFlowConvention":"reported_cfo_less_cash_capex_licenses_and_sbc",
            "classification":"Analyst economic expense proxy; source actuals retained. SBC charged once in cash-flow bridge, not GAAP EPS again.",
            "currencyEvidence":currency,"periods":result,"guidanceCurrencyResolutions":resolved,
            "claimsCaveat":"SBC cash-equivalent expense does not automatically settle already vested options or customer warrants. Claims not zero-filled.",
            "inputCaptureSha256":capture.get("_captureSha256")}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--capture",type=Path,required=True);parser.add_argument("--out",type=Path,required=True)
    parser.add_argument("--source",type=Path);parser.add_argument("--currency-copy",type=Path)
    args=parser.parse_args()
    if args.out.exists() or (args.currency_copy and args.currency_copy.exists()):
        raise ValueError("Outputs are immutable; choose new paths")
    raw=args.capture.read_bytes();capture=json.loads(raw);capture["_captureSha256"]=digest(raw)
    output=bridge(capture)
    if args.currency_copy:
        assert args.source
        args.currency_copy.parent.mkdir(parents=True,exist_ok=True)
        source=sqlite3.connect(args.source.resolve(strict=True).as_uri()+"?mode=ro",uri=True)
        target=sqlite3.connect(args.currency_copy)
        source.backup(target);source.close()
        by_date={ev["availableAt"]:ev for ev in output["currencyEvidence"]}
        resolutions={ev["id"]:ev for ev in output["guidanceCurrencyResolutions"]}
        with target:
            for fiscal,dimension,available,payload_json in target.execute("SELECT fiscal_period,dimension,available_at,payload_json FROM pit_financial_periods WHERE ticker='CRDO'").fetchall():
                payload=json.loads(payload_json);ev=by_date[available]
                payload["reportingCurrency"]="USD";payload["reportingCurrencyEvidence"]={"status":"resolved","currency":"USD","basis":"independently_reviewed_original_sec_statement","evidence":[ev]}
                target.execute("UPDATE pit_financial_periods SET payload_json=? WHERE ticker='CRDO' AND fiscal_period=? AND dimension=? AND available_at=?",(json.dumps(payload,separators=(',',':')),fiscal,dimension,available))
            for event_id,payload_json in target.execute("SELECT id,payload_json FROM pit_guidance_events WHERE ticker='CRDO'").fetchall():
                if event_id not in resolutions:continue
                payload=json.loads(payload_json);resolution=resolutions[event_id]
                payload['currency_resolution']={"status":"dated_issuer_reporting_currency","currency":"USD","originalQuotedCurrency":None,"evidence":[resolution['evidence']],"policy":"Exact prior-or-same-date primary SEC statement units or explicit S-1 denomination; original source quote unchanged."}
                target.execute("UPDATE pit_guidance_events SET payload_json=? WHERE ticker='CRDO' AND id=?",(json.dumps(payload,separators=(',',':')),event_id))
        assert target.execute("PRAGMA integrity_check").fetchone()[0]=="ok"
        target.close()
        output["currencyCandidate"]=str(args.currency_copy.resolve())
        output["currencyCandidatePolicy"]="Only CRDO payload reportingCurrency/reportingCurrencyEvidence and guidance currency_resolution changed; issuer/coverage/model statuses untouched."
    args.out.parent.mkdir(parents=True,exist_ok=True);args.out.write_text(json.dumps(output,indent=2,sort_keys=True)+"\n")
    print(json.dumps({"output":str(args.out),"sha256":digest(args.out.read_bytes()),"periods":len(output["periods"]),"guidanceCurrencyResolutions":len(output["guidanceCurrencyResolutions"])}))


if __name__=="__main__":main()
