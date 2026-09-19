#!/usr/bin/env python3
"""Bind explicitly reviewed IPO consolidation-policy currency inferences.

These are labeled analyst inferences, not literal reporting-currency declarations.
Only explicitly reviewed, hash-bound original prospectuses are eligible. This script
does not change a source DB or claim a whole issuer/model has been approved.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import re
import sqlite3
from bs4 import BeautifulSoup

VERSION = "ipo-reviewed-consolidation-currency-inference-v1-2026-09-06"
REVIEWED = {
    "CRWD": {
        "cik": "0001535527", "date": "2019-06-13", "sha": "43dafa5d3cefb84824354c64a4678b1961a6a46f6599825d7661062df6bc870a",
        "start": "The functional currencies of the Company's foreign subsidiaries are each country's local currency.",
        "end": "have not been material for all periods presented.",
        "basis": "The consolidated financial statements include the accounts of the Company and its wholly owned subsidiaries. All intercompany balances and transactions have been eliminated in consolidation.",
        "title": "CrowdStrike Holdings, Inc.",
        "reason": "The issuer's consolidated accounting policy translates foreign-subsidiary assets and liabilities into USD, translates revenue and expenses at period rates, and records translation adjustments in consolidated OCI. USD is the destination presentation currency of the issuer's consolidation, not merely a contract currency or the subsidiaries' local functional currencies.",
    },
    "PLTR": {
        "cik": "0001321655", "date": "2020-09-30", "sha": "582a59e26b295f7d4b227d128718553d09ea2a1b911c544dde33925a90aa3273",
        "start": "Generally the functional currency of the Company’s international subsidiaries is the local currency of the country in which they operate.",
        "end": "a remeasurement gain of $5.0 million, respectively.",
        "basis": "The accompanying consolidated financial statements include the accounts of Palantir Technologies Inc. and its consolidated subsidiaries and have been prepared in conformity with generally accepted accounting principles in the United States of America (“GAAP”).",
        "title": "Palantir Technologies Inc.",
        "reason": "Palantir's own consolidated accounting policies translate non-USD subsidiaries' assets and liabilities into USD and revenue and expenses at period rates; resulting translation is in consolidated OCI. This establishes the consolidation's USD destination currency without assuming that every subsidiary's functional currency is USD.",
    },
    "APP": {
        "cik": "0001751008", "date": "2021-04-15", "sha": "64aed7d520b787dea2f122a384bf3540d4cea86eb2cc6be88d4867ec640b70aa",
        "start": "Foreign Currency Transactions —Generally, the functional currency of our international subsidiaries is the U.S. dollar.",
        "end": "as a component of other income (expense), net.",
        "basis": "The accompanying consolidated financial statements have been prepared in conformity with U.S. generally accepted accounting principles (“GAAP”). Consolidated financial statements reflect our accounts and operations and those of our subsidiaries in which we have a controlling financial interest.",
        "title": "Applovin Corporation",
        "reason": "AppLovin's own consolidated financial-statement policy explicitly translates complete financial statements of non-USD subsidiaries to USD, using balance-sheet-date rates for assets and liabilities and period rates for revenue, costs and expenses. The destination of that consolidation is USD; this is separate from the general statement about subsidiary functional currency.",
    },
    "ZS": {
        "cik": "0001713683", "date": "2018-03-16", "sha": "e09b66a09d3ef86e879232e1705914d74a7977bda5ce32fdf5339a08e7535d0e",
        "start": "The functional currency of our foreign subsidiaries is the U.S. dollar.",
        "end": "The amount of re-measurement losses for the six months ended January 31, 2018 was not material.",
        "basis": "The accompanying consolidated financial statements include the accounts of Zscaler, Inc. and its wholly owned subsidiaries and have been prepared in conformity with accounting principles generally accepted in the United States (“U.S. GAAP”). All intercompany balances and transactions have been eliminated in consolidation.",
        "title": "Zscaler, Inc.",
        "reason": "Reviewed together with Note 2's parent-plus-wholly-owned-subsidiaries consolidation scope, the entire Foreign Currency policy remeasures monetary assets and liabilities into USD, nonmonetary items at historical rates, and revenue and expenses at period rates; resulting gains/losses go to the parent's consolidated operations. USD presentation is an inference from this complete consolidation/remeasurement policy, not from the subsidiary-functional-currency sentence alone.",
    },
    "GDDY": {
        "cik": "0001609711", "date": "2015-04-01", "sha": "dd3c93b52cedd3160b6b40c9c13b93d303350cfb69cc2e7140a730e719cb87d9",
        "start": "Our functional currency, and the functional currency of each of our subsidiaries, is the U.S. dollar.",
        "end": "during 2012, 2013 and 2014, respectively.",
        "basis": "Our consolidated financial statements have been prepared in accordance with U.S. generally accepted accounting principles (GAAP), and include our accounts and the accounts of our wholly-owned subsidiaries. All significant intercompany accounts and transactions have been eliminated in consolidation.",
        "relationship": "GoDaddy Inc. will consolidate Desert Newco in its consolidated financial statements and will report a non-controlling interest related to the LLC Units held by the Continuing LLC Owners on its consolidated financial statements.",
        "title": "Desert Newco, LLC",
        "reason": "The IPO prospectus explicitly connects GoDaddy's post-offering consolidation to operating predecessor Desert Newco. That operating group's own policy declares the parent and every subsidiary functional currency USD, remeasures foreign-currency assets into USD, measures foreign-currency revenue/expense transactions at event rates, and records FX in consolidated operations. Taken together, these support USD presentation for the post-IPO operating guidance; not inferred from listing currency, revenue-contract currency alone, or removal of noncontrolling interests.",
    },
}


def normalized_text(html):
    soup = BeautifulSoup(html, "html.parser")
    for node in soup(["script", "style"]):
        node.decompose()
    return re.sub(r"\s+", " ", soup.get_text(" ", strip=True))


def reviewed_paragraphs(ticker, document, html):
    review = REVIEWED[ticker]
    if document["cik"] != review["cik"] or document["filed"] != review["date"] or document["form"] != "424B4":
        raise ValueError("Not the exact reviewed pre-event prospectus")
    if hashlib.sha256(html.encode()).hexdigest() != review["sha"] or document["documentSha256"] != review["sha"]:
        raise ValueError("Reviewed original document hash mismatch")
    if not re.fullmatch(rf"https://www\.sec\.gov/Archives/edgar/data/{int(review['cik'])}/\d{{18}}/[^/]+\.htm", document["url"]):
        raise ValueError("Reviewed issuer source mismatch")
    text = normalized_text(html)
    start = text.find(review["start"])
    end = text.find(review["end"], start)
    if start < 0 or end < 0 or review["basis"] not in text or review["title"].lower() not in text.lower() or (review.get("relationship") and review["relationship"] not in text):
        raise ValueError("Reviewed consolidated policy or owner missing")
    paragraph = text[start:end + len(review["end"])]
    if len(paragraph) > 3500:
        raise ValueError("Unexpected accounting-note boundaries")
    return paragraph, review["basis"]


def build(source_path, targets_path, contexts_path, tickers=None):
    targets = json.loads(Path(targets_path).read_text())
    contexts = json.loads(Path(contexts_path).read_text())
    documents = [d for item in contexts for d in item["documents"]]
    selected = set(tickers or {"CRWD", "PLTR", "APP", "ZS"})
    if not selected or not selected <= set(REVIEWED):
        raise ValueError("Only explicitly reviewed issuer scope allowed")
    ready = []
    with closing(sqlite3.connect(Path(source_path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        for target in targets["targets"]:
            ticker, date = target["ticker"], target["targetAvailableAt"]
            if ticker not in selected:
                continue
            review = REVIEWED[ticker]
            if targets["issuers"][ticker]["cik"] != review["cik"] or review["date"] > date:
                raise ValueError("Target issuer/date cannot use this inference")
            choices = [d for d in documents if d["ticker"] == ticker and d["form"] == "424B4" and d["filed"] == review["date"]]
            if len(choices) != 1:
                raise ValueError("Missing or duplicate reviewed original document")
            doc = choices[0]
            paragraph, basis = reviewed_paragraphs(ticker, doc, Path(doc["htmlPath"]).read_text())
            proof = {"currency": "USD", "evidenceType": "issuer_reviewed_consolidation_presentation_inference",
                "quotes": [paragraph, basis] + ([review["relationship"]] if review.get("relationship") else []), "availableAt": doc["filed"], "sourceUrl": doc["url"],
                "documentPath": doc["htmlPath"], "documentSha256": doc["documentSha256"],
                "form": doc["form"], "accession": doc["accession"], "cik": review["cik"],
                "issuerConsolidatedStatementsTitle": review["title"], "reviewedAt": "2026-09-06",
                "inference": True, "reasoning": review["reason"],
                "limitations": "Dated currency-only analyst inference; no numerical statement, forecast scope, management guidance accuracy, economics or full model review approval."}
            if ticker == "GDDY":
                confirmations = [d for d in documents if d["ticker"] == ticker and d["filed"] == "2015-05-12" and d["name"] == "gddy20150512ex991q1earning.htm"]
                if len(confirmations) != 1 or date < "2015-05-12":
                    raise ValueError("GoDaddy requires already-published IPO closing/predecessor confirmation")
                confirmation = confirmations[0]
                original = Path(confirmation["htmlPath"]).read_text()
                if hashlib.sha256(original.encode()).hexdigest() != confirmation["documentSha256"]:
                    raise ValueError("GoDaddy same-event confirmation original hash mismatch")
                normalized = normalized_text(original)
                confirmation_quotes = [
                    "On April 7, 2015, GoDaddy Inc. successfully closed its initial public offering (IPO) of 26 million shares of Class A common stock at a public offering price of $20 per share, which included 3 million shares sold pursuant to the underwriters’ over-allotment option and 2.5 million shares sold to certain affiliates.",
                    "This press release presents historical results, for the periods presented, of Desert Newco, LLC, the predecessor of GoDaddy Inc. for financial reporting purposes.",
                ]
                if any(q not in normalized for q in confirmation_quotes):
                    raise ValueError("Exact original closing and predecessor scope statements missing")
                proof["supportingDocuments"] = [{"availableAt": confirmation["filed"], "sourceUrl": confirmation["url"],
                    "documentPath": confirmation["htmlPath"], "documentSha256": confirmation["documentSha256"],
                    "cik": confirmation["cik"], "accession": confirmation["accession"], "form": confirmation["form"],
                    "quotes": confirmation_quotes, "paragraphSha256": [hashlib.sha256(q.encode()).hexdigest() for q in confirmation_quotes]}]
            for event in target["events"]:
                row = db.execute("SELECT * FROM pit_guidance_events WHERE id=? AND ticker=? AND observed_at=?", (event["sourceId"], ticker, date)).fetchone()
                if not row or hashlib.sha256(row["evidence_excerpt"].encode()).hexdigest() != event["quoteSha256"]:
                    raise ValueError("Original target quotation changed")
                ready.append({"ticker": ticker, "sourceId": event["sourceId"], "observedAt": date,
                    "originalQuote": row["evidence_excerpt"], "originalQuoteSha256": event["quoteSha256"],
                    "originalPayloadSha256": hashlib.sha256(row["payload_json"].encode()).hexdigest(), "proof": proof})
    expected_count = sum(len(t["events"]) for t in targets["targets"] if t["ticker"] in selected)
    if not ready or len(ready) != expected_count:
        raise ValueError("Expected every explicitly selected reviewed pre-event currency case")
    return {"version": VERSION, "events": ready, "inferredEvents": len(ready), "releaseAuthorized": False,
        "sourceRowsChanged": 0, "scope": "Explicitly reviewed historical issuer consolidation currency inference, not a literal declaration"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ["source-db", "targets", "contexts", "output"]:
        parser.add_argument("--" + key, type=Path, required=True)
    parser.add_argument("--tickers", help="Comma-separated reviewed issuer scope; default initial CRWD,PLTR,APP,ZS batch")
    args = parser.parse_args()
    if args.output.exists():
        raise FileExistsError(args.output)
    result = build(args.source_db, args.targets, args.contexts, args.tickers.split(",") if args.tickers else None)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "events"}, indent=2))
