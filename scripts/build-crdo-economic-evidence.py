#!/usr/bin/env python3
"""Build a frozen, CRDO-only source evidence pack; never writes model/runtime data."""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import sqlite3
import time
import requests
from bs4 import BeautifulSoup

VERSION = "crdo-economic-evidence-v1-2026-09-06"
CIK = "0001807794"
USER_AGENT = "Guru Intelligence data engineering luyudong1136@gmail.com"


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def read_db(path):
    db = sqlite3.connect(Path(path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)
    db.row_factory = sqlite3.Row
    return db


def filings(submission, cutoff):
    assert str(submission["cik"]).zfill(10) == CIK
    recent = submission["filings"]["recent"]
    result = []
    for i, form in enumerate(recent["form"]):
        if form not in {"10-Q", "10-K", "S-1", "S-1/A"}:
            continue
        if not "2022-01-01" <= recent["filingDate"][i] <= cutoff:
            continue
        accession = recent["accessionNumber"][i]
        document = recent["primaryDocument"][i]
        assert "/" not in document and ".." not in document
        result.append({"form": form, "filed": recent["filingDate"][i],
                       "accession": accession, "document": document,
                       "url": f"https://www.sec.gov/Archives/edgar/data/1807794/{accession.replace('-', '')}/{document}"})
    return sorted(result, key=lambda item: (item["filed"], item["accession"]))


def get_document(filing, cache, fetch):
    path = cache / filing["accession"] / filing["document"]
    if not path.exists():
        if not fetch:
            raise ValueError(f"Missing frozen filing: {filing['accession']}")
        time.sleep(.15)
        response = requests.get(filing["url"], headers={"User-Agent": USER_AGENT}, timeout=45)
        response.raise_for_status()
        if "<html" not in response.text.lower() or "undeclared automated tool" in response.text.lower():
            raise ValueError("SEC response is not an issuer HTML document")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(response.content)
    raw = path.read_bytes()
    return raw, path


def parse_ix(raw):
    soup = BeautifulSoup(raw, "html.parser")
    contexts = {}
    units = {}
    for element in soup.find_all(lambda x: x.name and x.name.lower() == "xbrli:context"):
        def inner(name):
            el = element.find(lambda x: x.name and x.name.lower().split(":")[-1] == name)
            return el.get_text(strip=True) if el else None
        contexts[element["id"]] = {"start": inner("startdate"), "end": inner("enddate") or inner("instant"),
                                  "dimensions": bool(element.find(lambda x: x.name and x.name.lower().split(":")[-1] in {"explicitmember", "typedmember"}))}
    for element in soup.find_all(lambda x: x.name and x.name.lower() == "xbrli:unit"):
        units[element["id"]] = element.get_text(strip=True)
    facts = []
    for el in soup.find_all(lambda x: x.name and x.name.lower() == "ix:nonfraction"):
        raw_value = el.get_text("", strip=True).replace(",", "").replace("\u2212", "-")
        try:
            value = 0.0 if raw_value in {"—", "–", "-"} else float(raw_value.replace("(", "-").replace(")", ""))
        except ValueError:
            continue
        if el.get("sign") == "-":
            value = -abs(value)
        value *= 10 ** int(el.get("scale", "0"))
        if el.get("contextref") not in contexts:
            raise ValueError("Inline numeric fact references a missing context")
        if el.get("unitref") not in units:
            raise ValueError("Inline numeric fact references a missing unit")
        context = contexts[el.get("contextref")]
        facts.append({"tag": el.get("name"), "value": value, "unit": units.get(el.get("unitref")),
                      "context": el.get("contextref"), **context, "decimals": el.get("decimals")})
    return soup, facts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--submission", type=Path, required=True)
    parser.add_argument("--cache", type=Path, required=True)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--as-of", default="2026-09-05")
    parser.add_argument("--fetch", action="store_true")
    args = parser.parse_args()
    if args.out.exists():
        raise ValueError("Evidence outputs are immutable; choose a new output")
    submission = json.loads(args.submission.read_text())
    documents = []
    for filing in filings(submission, args.as_of):
        raw, path = get_document(filing, args.cache, args.fetch)
        soup, facts = parse_ix(raw)
        documents.append({**filing, "sha256": sha(raw), "localPath": str(path.resolve()),
                          "aggregateFacts": [f for f in facts if not f.get("dimensions")],
                          "customFacts": [f for f in facts if f.get("tag", "").startswith("crdo:")],
                          "tableText": [table.get_text(" ", strip=True) for table in soup.find_all("table")
                                        if any(term in table.get_text(" ", strip=True).lower() for term in
                                               ["technology licens", "contingent consideration", "cash flows from", "ordinary shares issued"])],
                          "currencyParagraphs": [el.get_text(" ", strip=True) for el in soup.find_all(["p", "div"])
                                                 if len(el.get_text(" ", strip=True)) < 3000 and
                                                 any(term in el.get_text(" ", strip=True).lower() for term in
                                                     ["united states dollar", "u.s. dollar", "us dollar", "functional currency"])],
                          })
        print(f"Captured {filing['filed']} {filing['form']}: {len(facts)} inline facts", flush=True)
    with read_db(args.source) as db:
        financials = [dict(r) for r in db.execute("SELECT * FROM pit_financial_periods WHERE ticker='CRDO' ORDER BY available_at, dimension")]
        guidance = [dict(r) for r in db.execute("SELECT * FROM pit_guidance_events WHERE ticker='CRDO' ORDER BY observed_at,id")]
    evidence = {"version": VERSION, "ticker": "CRDO", "cik": CIK, "cutoff": args.as_of,
                "status": "source_capture_pending_economic_review", "documents": documents,
                "financials": financials, "guidance": guidance}
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(evidence, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"output": str(args.out), "documents": len(documents), "sha256": sha(args.out.read_bytes())}))


if __name__ == "__main__":
    main()
