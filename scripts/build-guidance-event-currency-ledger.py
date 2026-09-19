#!/usr/bin/env python3
"""Inspect unresolved guidance currency at the event date, not a later filing.

Read-only source DB and dated public SEC CompanyFacts; creates a new evidence
ledger. USD inference is labeled as inference. Non-USD statements do not resolve
a bare-dollar guide, and absent predecessor evidence stays unresolved. This
command does not alter guidance, financials, issuer review or release status.
"""
import argparse
from collections import Counter, defaultdict
from contextlib import closing
import hashlib
import json
from pathlib import Path
import requests

from build_dated_reporting_currency_ledger import (
    VERSION, SEC_USER_AGENT, readonly, load_ciks, fetch_facts, resolve_currency,
)
from audit_dated_reporting_currency_ledger import audit


def build(args):
    if args.out.exists():
        raise FileExistsError("Choose a new, immutable evidence output")
    failures = json.loads(args.audit.read_text())["failures"]
    selected = {(r["ticker"], r["sourceId"]) for r in failures
                if r.get("code") == "guidance_currency_review_incomplete"}
    targets = defaultdict(list)
    with closing(readonly(args.source)) as db:
        for ticker, source_id in sorted(selected):
            rows = db.execute("SELECT observed_at,evidence_excerpt,payload_json,source_url,fiscal_period "
                              "FROM pit_guidance_events WHERE ticker=? AND id=?", (ticker, source_id)).fetchall()
            if len(rows) != 1:
                raise ValueError(f"Missing/ambiguous exact audited event: {ticker}/{source_id}")
            observed, quote, payload, url, period = rows[0]
            targets[(ticker, observed)].append({"sourceId": source_id, "quoteSha256": hashlib.sha256(quote.encode()).hexdigest(),
                "payloadSha256": hashlib.sha256(payload.encode()).hexdigest(), "sourceUrl": url, "fiscalPeriod": period})
    ciks, conflicts = load_ciks(args.metadata, [])
    session = requests.Session()
    session.headers.update({"User-Agent": SEC_USER_AGENT, "Accept": "application/json"})
    issuers, filings_by_ticker = {}, {}
    for ticker in sorted({key[0] for key in targets}):
        try:
            if ticker in conflicts or not ciks.get(ticker):
                raise ValueError("unverified_exact_issuer_cik")
            filings_by_ticker[ticker], issuers[ticker] = fetch_facts(session, ciks[ticker], args.cache, args.offline)
        except Exception as error:
            issuers[ticker] = {"cik": ciks.get(ticker), "status": "blocked", "reason": str(error)}
    rows = []
    for (ticker, observed), events in sorted(targets.items()):
        result = resolve_currency(filings_by_ticker[ticker], ciks[ticker], observed) if ticker in filings_by_ticker else {
            "status": "blocked", "reason": "missing_dated_original_issuer_statement"}
        if observed > "2026-09-05":
            result = {"status": "blocked", "reason": "event_after_frozen_cutoff"}
        row = {"ticker": ticker, "targetAvailableAt": observed, "financialRows": 0, "events": events, **result}
        row["guidanceCurrencyDisposition"] = (
            "dated_USD_statement_inference_candidate" if result.get("status") == "resolved" and result.get("currency") == "USD"
            else "requires_explicit_guidance_currency_or_predecessor_evidence")
        rows.append(row)
    ledger = {"version": VERSION, "asOf": "2026-09-05", "issuers": issuers, "targets": rows,
              "status": "source_evidence_only_not_an_adjudication_or_release", "source": str(args.source.resolve())}
    verification = audit(ledger)
    if verification["status"] != "passed":
        raise ValueError(f"Independent original-fact audit failed: {verification}")
    ledger["independentAudit"] = verification
    ledger["summary"] = dict(Counter(row["guidanceCurrencyDisposition"] for row in rows))
    ledger["eventCount"] = len(selected)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    args.out.write_text(json.dumps(ledger, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"output": str(args.out), "events": len(selected), "dateTargets": len(rows),
                      "summary": ledger["summary"], "independentAudit": verification}, indent=2))


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source", "metadata", "audit", "cache", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--offline", action="store_true")
    build(parser.parse_args())
