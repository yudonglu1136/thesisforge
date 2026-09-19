#!/usr/bin/env python3
"""Bind TSM's USD outlook to same-day official ranges, not TWD statements.

Read-only evidence generation. This does not repair sequential/YoY extraction,
change issuer reporting currency, modify a source database, or authorize release.
"""
import argparse
from contextlib import closing
import hashlib
import json
import math
from pathlib import Path
import re
import sqlite3
from bs4 import BeautifulSoup

VERSION = "tsm-event-specific-official-usd-evidence-v1-2026-09-06"
QUARTERS = {"first": 1, "second": 2, "third": 3, "fourth": 4}
PATTERN = re.compile(
    r"Based on the Company['’]s current business outlook, management expects the overall performance for "
    r"(?:the )?(first|second|third|fourth) quarter (20\d{2}) to be as follows:\s*(?:[•◼-]\s*)?"
    r"Revenue is expected to be between US\$([\d.]+) billion and US\$([\d.]+) billion", re.I)


def primary_guidance(html):
    soup = BeautifulSoup(html, "html.parser")
    for node in soup(["script", "style"]):
        node.decompose()
    text = re.sub(r"\s+", " ", soup.get_text(" ", strip=True))
    if not re.search(r"\bTSMC\b", text):
        raise ValueError("Not a TSMC source document")
    matches = list(PATTERN.finditer(text))
    if len(matches) != 1:
        raise ValueError("Expected one explicitly scoped primary USD revenue guidance range")
    match = matches[0]
    low, high = float(match[3]), float(match[4])
    if not 0 < low <= high:
        raise ValueError("Invalid primary revenue range")
    return {"quote": match[0], "currency": "USD", "unit": "USD millions", "quarter": QUARTERS[match[1].lower()],
            "year": int(match[2]), "lowM": low * 1000, "highM": high * 1000, "midpointM": (low + high) * 500}


def bind_event(event, document, html):
    if event["ticker"] != "TSM" or event["metric_name"] != "revenue_guidance":
        raise ValueError("Only exact TSM revenue guidance is in scope")
    if event["observed_at"] != document["filed"]:
        raise ValueError("Official evidence must have the same filing date as the original call")
    if not re.fullmatch(r"https://www\.sec\.gov/Archives/edgar/data/1046179/\d{18}/[^/]+\.htm", document["url"]):
        raise ValueError("Official issuer/CIK source mismatch")
    digest = hashlib.sha256(html.encode()).hexdigest()
    if digest != document["sha256"]:
        raise ValueError("Primary document hash mismatch")
    target = primary_guidance(html)
    source_period = re.fullmatch(r"Q([1-4])(20\d{2})", event["fiscal_period"])
    if not source_period:
        raise ValueError("Unexpected original fiscal-period format")
    q, year = int(source_period[1]), int(source_period[2])
    expected = (q + 1, year) if q < 4 else (1, year + 1)
    if (target["quarter"], target["year"]) != expected:
        raise ValueError("Primary guide is not the next quarter owned by this earnings event")
    if not math.isclose(float(event["amount"]), target["midpointM"], rel_tol=1e-12, abs_tol=1e-7):
        raise ValueError("Original amount and primary guidance range disagree")
    quote = event["evidence_excerpt"]
    quarter_words = {"first": 1, "second": 2, "third": 3, "fourth": 4}
    owner = re.search(r"\b(first|second|third|fourth) quarter revenue\b|\bQ([1-4]) revenue\b", quote, re.I)
    if not owner or (quarter_words[owner[1].lower()] if owner[1] else int(owner[2])) != target["quarter"]:
        raise ValueError("Original quote quarter is not the primary source quarter")
    return {"ticker": "TSM", "sourceId": event["id"], "observedAt": event["observed_at"],
            "originalQuote": quote, "originalQuoteSha256": hashlib.sha256(quote.encode()).hexdigest(),
            "originalPayloadSha256": hashlib.sha256(event["payload_json"].encode()).hexdigest(),
            "currency": "USD", "sourceUrl": document["url"], "filingDate": document["filed"],
            "accession": document["accession"], "documentPath": document["textPath"], "documentSha256": digest,
            "primaryGuidance": target, "reportingCurrencyOverride": False,
            "proofScope": "same-event explicit USD forward revenue range; does not assert TSM financial statements are USD",
            "growthBasisReviewRequired": True}


def build(source_path, candidates_path):
    candidates = json.loads(Path(candidates_path).read_text())
    if any(item["errors"] for item in candidates):
        raise ValueError("Primary retrieval had unresolved document errors")
    documents = [d for item in candidates for d in item["documents"] if "presentation" not in d["name"].lower()]
    dates = {d["filed"] for d in documents}
    evidence = []
    with closing(sqlite3.connect(Path(source_path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        rows = db.execute("SELECT * FROM pit_guidance_events WHERE ticker='TSM' AND metric_name='revenue_guidance' AND currency IS NULL AND amount IS NOT NULL ORDER BY observed_at,id").fetchall()
        for row in rows:
            if row["observed_at"] not in dates:
                continue
            # More than one document must agree; no choosing the favorable one.
            bound = [bind_event(dict(row), d, Path(d["textPath"]).read_text()) for d in documents if d["filed"] == row["observed_at"]]
            if len({json.dumps(b["primaryGuidance"], sort_keys=True) for b in bound}) != 1:
                raise ValueError("Conflicting official same-date revenue guidance")
            evidence.append(bound[0])
    if len(evidence) != 10 or len({e["sourceId"] for e in evidence}) != 10:
        raise ValueError("The reviewed source must contain exactly the ten targeted TSM currency cases")
    return {"version": VERSION, "scope": "event-level primary USD guidance evidence only", "sourceDb": str(source_path),
            "releaseAuthorized": False, "currencyClaimsProven": len(evidence), "growthReviewRequired": True, "events": evidence}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-db", required=True)
    parser.add_argument("--candidates", required=True)
    parser.add_argument("--output", required=True)
    options = parser.parse_args()
    output = Path(options.output)
    if output.exists():
        raise FileExistsError(output)
    result = build(options.source_db, options.candidates)
    output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "events"}, indent=2))
