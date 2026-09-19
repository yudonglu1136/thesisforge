#!/usr/bin/env python3
"""Read-only dated SEC reporting-currency declarations for early guidance.

Only direct company reporting/presentation declarations qualify. Subsidiary
functional currencies, dollar-denominated contracts, quotation currency and later
financial statements are not promoted to company reporting-currency evidence.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from bs4 import BeautifulSoup

VERSION = "ipo-direct-reporting-currency-evidence-v1-2026-09-06"
DECLARATIONS = [
    re.compile(r"(?:The )?(?:functional and )?reporting currency of the Company(?: and its subsidiaries)? is (?:the )?(?:U\.?S\.?|United States) dollar(?:\s*\([‘’\"“”]?USD[‘’\"“”]?\))?", re.I),
    re.compile(r"Our reporting currency and the functional currency of our wholly owned foreign subsidiaries is the U\.S\. dollar", re.I),
    re.compile(r"Shopify reports in U\.S\. dollars and in accordance with U\.S\. GAAP", re.I),
]


def declarations(html):
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style"]):
        tag.decompose()
    text = re.sub(r"\s+", " ", soup.get_text(" ", strip=True))
    return list(dict.fromkeys(m[0] for p in DECLARATIONS for m in p.finditer(text)))


def direct_proof(document, ticker, cik, target_date, html):
    if document["ticker"] != ticker or document["cik"] != cik:
        raise ValueError("Exact issuer/CIK mismatch")
    if document["filed"] > target_date:
        raise ValueError("Later filing cannot resolve earlier guidance currency")
    if not re.fullmatch(rf"https://www\.sec\.gov/Archives/edgar/data/{int(cik)}/\d{{18}}/[^/]+\.htm", document["url"]):
        raise ValueError("Not an exact-issuer official filing URL")
    if hashlib.sha256(html.encode()).hexdigest() != document["documentSha256"]:
        raise ValueError("Official document hash mismatch")
    quotes = declarations(html)
    if not quotes:
        return None
    return {"currency": "USD", "evidenceType": "explicit_company_reporting_currency_declaration",
            "quotes": quotes, "availableAt": document["filed"], "sourceUrl": document["url"],
            "documentPath": document["htmlPath"], "documentSha256": document["documentSha256"],
            "form": document["form"], "accession": document["accession"], "cik": cik,
            "guidancePolicy": "Dated company reporting-currency support for an ambiguous monetary quote; not a model-economics or guidance-scope approval"}


def build(source_path, targets_path, contexts_path):
    targets = json.loads(Path(targets_path).read_text())
    contexts = json.loads(Path(contexts_path).read_text())
    if any(item["errors"] for item in contexts):
        raise ValueError("Primary document retrieval errors must be reviewed")
    documents = [d for item in contexts for d in item["documents"]]
    scope = sorted({d["ticker"] for d in documents})
    ready, blocked = [], []
    with closing(sqlite3.connect(Path(source_path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        for target in targets["targets"]:
            ticker, date = target["ticker"], target["targetAvailableAt"]
            if ticker not in scope:
                continue
            cik = targets["issuers"][ticker]["cik"]
            candidates = []
            for doc in documents:
                if doc["ticker"] == ticker and doc["filed"] <= date:
                    proof = direct_proof(doc, ticker, cik, date, Path(doc["htmlPath"]).read_text())
                    if proof:
                        candidates.append(proof)
            if not candidates:
                blocked.append({"ticker": ticker, "observedAt": date, "eventIds": [e["sourceId"] for e in target["events"]],
                                "reason": "No direct company reporting-currency declaration; foreign subsidiary translation and sales-contract currency retained as supporting research only"})
                continue
            candidates.sort(key=lambda p: p["availableAt"], reverse=True)
            proof = candidates[0]
            for event in target["events"]:
                row = db.execute("SELECT * FROM pit_guidance_events WHERE id=? AND ticker=? AND observed_at=?", (event["sourceId"], ticker, date)).fetchone()
                if not row or hashlib.sha256(row["evidence_excerpt"].encode()).hexdigest() != event["quoteSha256"]:
                    raise ValueError("Target original quotation changed")
                ready.append({"ticker": ticker, "sourceId": event["sourceId"], "observedAt": date,
                              "originalQuote": row["evidence_excerpt"], "originalQuoteSha256": event["quoteSha256"],
                              "originalPayloadSha256": hashlib.sha256(row["payload_json"].encode()).hexdigest(), "proof": proof})
    return {"version": VERSION, "scope": scope, "currencyEventsProven": len(ready), "events": ready,
            "blocked": blocked, "releaseAuthorized": False, "sourceRowsChanged": 0}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-db", required=True)
    parser.add_argument("--targets", required=True)
    parser.add_argument("--contexts", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    output = Path(options.output)
    if output.exists():
        raise FileExistsError(output)
    result = build(options.source_db, options.targets, options.contexts)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "events"}, indent=2))
