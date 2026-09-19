#!/usr/bin/env python3
"""Freeze exact USFD/TFX source evidence for a bounded economic review.

Creates private new evidence only. No review approval or valuation is generated.
"""
import argparse
from concurrent.futures import ThreadPoolExecutor
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import requests

spec = importlib.util.spec_from_file_location("crdo_ix", Path(__file__).with_name("build-crdo-economic-evidence.py"))
ix = importlib.util.module_from_spec(spec); spec.loader.exec_module(ix)
IDENTITIES = {"USFD": "0001665918", "TFX": "0000096943"}


def fetch_document(item, output):
    dest = output / "filings" / item["ticker"] / item["accession"] / item["document"]
    if not dest.exists():
        response = requests.get(item["url"], headers={"User-Agent": ix.USER_AGENT}, timeout=45)
        response.raise_for_status()
        if "<html" not in response.text.lower() or "undeclared automated tool" in response.text.lower():
            raise ValueError("Not an issuer HTML filing")
        dest.parent.mkdir(parents=True, exist_ok=True); dest.write_bytes(response.content)
    raw = dest.read_bytes(); soup, facts = ix.parse_ix(raw)
    text = soup.get_text(" ", strip=True)
    tables = [t.get_text(" ", strip=True) for t in soup.find_all("table")]
    selected = [t for t in tables if len(t) < 18000 and any(s in t.lower() for s in ["financing cash flows from finance leases", "financing cash flows", "operating cash flows", "discontinued operations", "series a convertible", "outstanding share options", "total debt", "common stock,", "common shares", "cash flows from operating activities"])]
    passages = []
    for match in re.finditer(r"financ(?:e|ing) leases?|discontinued operations|accelerated share repurchase|preferred stock|preferred shares|contingent consideration", text, re.I):
        excerpt = text[max(0, match.start()-120):match.end()+500]
        if "Member" not in excerpt and excerpt not in passages:
            passages.append(excerpt)
    return {**item, "localPath": str(dest.resolve()), "sha256": hashlib.sha256(raw).hexdigest(),
            "aggregateFacts": [f for f in facts if not f["dimensions"]],
            "dimensionalLeaseFacts": [f for f in facts if f["dimensions"] and any(x in f["tag"].lower() for x in ["lease", "discontinued", "preferred"])],
            "tables": selected, "reviewPassages": passages}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True); parser.add_argument("--official-cache", type=Path, required=True)
    parser.add_argument("--output-dir", type=Path, required=True); parser.add_argument("--start", default="2024-01-01"); parser.add_argument("--as-of", default="2026-09-05")
    args = parser.parse_args()
    out = args.output_dir
    if (out / "evidence.json").exists(): raise ValueError("Evidence outputs are immutable")
    conn = sqlite3.connect(args.source.resolve().as_uri()+"?mode=ro", uri=True); conn.row_factory = sqlite3.Row
    financials = [dict(r) for r in conn.execute("SELECT * FROM pit_financial_periods WHERE ticker IN ('USFD','TFX') ORDER BY ticker,available_at,dimension")]
    guidance = [dict(r) for r in conn.execute("SELECT * FROM pit_guidance_events WHERE ticker IN ('USFD','TFX') ORDER BY ticker,observed_at,id")]
    coverage = {table: [dict(r) for r in conn.execute(f"SELECT * FROM {table} WHERE ticker IN ('USFD','TFX')")] for table in ["pit_financial_coverage", "pit_guidance_coverage", "pit_issuer_review"]}
    conn.close(); filings = []
    for ticker, cik in IDENTITIES.items():
        submission = json.loads((args.official_cache/ticker/"submission.json").read_text())
        if str(submission["cik"]).zfill(10) != cik: raise ValueError("Issuer CIK mismatch")
        recent = submission["filings"]["recent"]
        for i, form in enumerate(recent["form"]):
            filed = recent["filingDate"][i]
            if form not in {"10-Q", "10-K"} or not args.start <= filed <= args.as_of: continue
            accession, document = recent["accessionNumber"][i], recent["primaryDocument"][i]
            if "/" in document or ".." in document: raise ValueError("Unexpected filing document")
            filings.append({"ticker": ticker, "cik": cik, "form": form, "filed": filed, "periodEndDate": recent["reportDate"][i],
                            "accession": accession, "document": document,
                            "url": f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accession.replace('-', '')}/{document}"})
    with ThreadPoolExecutor(max_workers=2) as executor:
        documents = list(executor.map(lambda x: fetch_document(x, out), sorted(filings, key=lambda x:(x["ticker"],x["filed"]))))
    artifact = {"schemaVersion": 1, "status": "source_evidence_only_economic_review_pending", "cutoff": args.as_of,
        "captureStart": args.start, "financials": financials, "guidance": guidance, "coverage": coverage, "documents": documents}
    out.mkdir(parents=True, exist_ok=True); target = out/"evidence.json"
    target.write_text(json.dumps(artifact, indent=2, sort_keys=True)+"\n")
    print(json.dumps({"output":str(target),"filings":len(documents),"financialRows":len(financials),"guidanceRows":len(guidance),"sha256":hashlib.sha256(target.read_bytes()).hexdigest()}))


if __name__ == "__main__": main()
