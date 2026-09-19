#!/usr/bin/env python3
"""Bind BG15 and MAA1 exact historical guidance to dated original currency proof.

BG uses its actual predecessor CIK before 2023-11-01, and current-CIK explicit
consolidated USD statement captions after redomestication. MAA uses original
parent-company XBRL units, not the LP or business-segment contexts omitted by
the aggregate CompanyFacts API. Does not modify source inputs.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from bs4 import BeautifulSoup
from validate_bg_maa_currency_primary import validate_maa_original_xml, CONTEXTS


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def text_of(document):
    raw = Path(document["htmlPath"]).read_text()
    if digest(raw) != document["documentSha256"]:
        raise ValueError("Original document hash mismatch")
    return re.sub(r"\s+", " ", BeautifulSoup(raw, "html.parser").get_text(" ", strip=True))


def proof_base(document, evidence_type, quotes):
    text = text_of(document)
    if any(q not in text for q in quotes):
        raise ValueError("Original exact paragraph absent")
    return dict(currency="USD", evidenceType=evidence_type, quotes=quotes,
                availableAt=document["filed"], sourceUrl=document["url"], documentPath=document["htmlPath"],
                documentSha256=document["documentSha256"], form=document["form"], accession=document["accession"],
                cik=document["cik"], inference=False,
                limitations="Currency evidence only; original numeric values, ownership, dates, guidance and model reviews are not changed or approved.")


def build(source, audit, old_contexts, current_contexts):
    selected = [r for r in json.loads(Path(audit).read_text())["failures"] if r["code"] == "guidance_currency_review_incomplete" and r["ticker"] in {"BG", "MAA"}]
    if len(selected) != 16:
        raise ValueError("Expected exact 15 BG and one MAA unresolved events")
    old = [d for g in json.loads(Path(old_contexts).read_text()) for d in g["documents"] if d["form"] == "10-K"]
    current = json.loads(Path(current_contexts).read_text())["documents"]
    bg = next(d for d in current if d["ticker"] == "BG")
    bg_text = text_of(bg)
    income = re.search(r"Consolidated Earnings Data \(Unaudited\).*?\(US\$ in millions, except per share data\)", bg_text)[0]
    balance = re.search(r"Condensed Consolidated Balance Sheets \(Unaudited\).*?\(US\$ in millions\)", bg_text)[0]
    continuity = re.search(r"On November 1, 2023 Bunge Global SA completed.*?Each common share of Bunge Limited was cancelled in exchange for an equal number and par value of registered shares of Bunge Global SA \(the [“\"]registered shares[”\"]\)\.", bg_text)[0]
    current_bg_proof = proof_base(bg, "explicit_consolidated_statement_currency_units", [income, balance, continuity])
    maa = next(d for d in current if d["ticker"] == "MAA" and d["form"] == "10-K")
    maa_text = text_of(maa)
    heading = re.search(r"Mid-America Apartment Communities, Inc\. Consolidated Balance Sheets December 31, 2018 and 2017 \(\s*Dollars in thousands, except share and per share data\)", maa_text)[0]
    maa_proof = proof_base(maa, "dated_parent_statement_xbrl_currency", [heading])
    original = maa["originalXbrl"]
    raw = Path(original["path"]).read_text()
    if digest(raw) != original["sha256"]:
        raise ValueError("Original MAA XBRL changed")
    facts = validate_maa_original_xml(raw)
    fragments = []
    for unit in ["usd", "usdPerShare"]:
        fragment = re.search(rf'<xbrli:unit id="{unit}">.*?</xbrli:unit>', raw, re.S)[0]
        fragments.append(dict(key="unit:" + unit, raw=fragment))
    for context in CONTEXTS:
        fragment = re.search(rf'<xbrli:context id="{context}">.*?</xbrli:context>', raw, re.S)[0]
        fragments.append(dict(key="context:" + context, raw=fragment))
    for name, fact in facts:
        fragment = re.search(rf'<us-gaap:{name}\b[^>]*\bid="{fact.attrib["id"]}"[^>]*>[^<]+</us-gaap:{name}>', raw)[0]
        fragments.append(dict(key="fact:" + name, raw=fragment))
    maa_proof["xbrlStatementEvidence"] = dict(sourceUrl=original["url"], documentPath=original["path"],
        documentSha256=original["sha256"], fragments=fragments, fragmentsSha256=[digest(f["raw"]) for f in fragments],
        unitScope="Exact MAA ParentCompanyMember: aggregate Assets, Revenues, operating cash, and diluted EPS; excludes LP and all business-segment axes.")
    events = []
    with closing(sqlite3.connect(Path(source).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        for item in selected:
            row = db.execute("SELECT * FROM pit_guidance_events WHERE id=? AND ticker=?", (item["sourceId"], item["ticker"])).fetchone()
            if row["ticker"] == "MAA":
                if row["id"] != "0af4b2954039a743afdaeb74":
                    raise ValueError("Unexpected MAA scope")
                proof = maa_proof
            elif row["observed_at"] >= "2023-11-01":
                proof = current_bg_proof
            else:
                candidates = [d for d in old if d["cik"] == "0001144519" and d["filed"] <= row["observed_at"]]
                doc = max(candidates, key=lambda d: d["filed"])
                original_text = text_of(doc)
                sentence = re.search(r"(?:Bunge's|Our) reporting currency is the U\.S\. dollar\.", original_text)[0]
                issuer_title = re.search(r"BUNGE LIMITED(?: AND SUBSIDIARIES)?", original_text, re.I)[0]
                proof = proof_base(doc, "explicit_company_reporting_currency_declaration", [sentence, issuer_title])
            if proof["availableAt"] > row["observed_at"]:
                raise ValueError("Future currency source")
            events.append(dict(ticker=row["ticker"], sourceId=row["id"], observedAt=row["observed_at"],
                originalQuote=row["evidence_excerpt"], originalQuoteSha256=digest(row["evidence_excerpt"]),
                originalPayloadSha256=digest(row["payload_json"]), proof=proof))
    return dict(version="bg15-maa1-dated-original-currency-v1-2026-09-06", events=events, currencyEventsProven=len(events),
                sourceRowsChanged=0, releaseAuthorized=False)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ["source", "audit", "old-contexts", "current-contexts", "output"]:
        parser.add_argument("--" + arg, type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists() or not args.output.name.startswith("currency-lane"):
        raise ValueError("NEW currency-lane ledger required")
    result = build(args.source, args.audit, args.old_contexts, args.current_contexts)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "events"}))
