#!/usr/bin/env python3
"""Read-only readiness ledger for a staged Guru coverage expansion.

Input availability and completed automated extraction are never counted as a
released fair value. This report contains no licensed financial or price values.
"""
import argparse
from collections import Counter
from contextlib import closing
import csv
import importlib.util
import json
from pathlib import Path
import sqlite3


def build_report(inventory, source_path):
    with closing(sqlite3.connect(Path(source_path).resolve().as_uri() + "?mode=ro", uri=True)) as db:
        db.row_factory = sqlite3.Row
        metadata = dict(db.execute("SELECT key, value FROM pit_source_metadata"))
        financial = {row["ticker"]: dict(row) for row in db.execute("SELECT * FROM pit_financial_coverage")}
        guidance = {row["ticker"]: dict(row) for row in db.execute("SELECT * FROM pit_guidance_coverage")}
        issuer = {row["ticker"]: dict(row) for row in db.execute("SELECT * FROM pit_issuer_review")}
        raw_counts = dict(db.execute("SELECT ticker, count(*) FROM pit_raw_financial_review GROUP BY ticker"))
        event_counts = dict(db.execute("SELECT ticker, count(*) FROM pit_guidance_events GROUP BY ticker"))
        financial_rows = db.execute("SELECT count(*) FROM pit_financial_periods").fetchone()[0]
        scope = json.loads(metadata.get("official_sec_guidance_last_scope", "{}"))
    current_visible = inventory.get("scope") == "exact_cusip_current_visible_targets_not_latest_selected_book"
    if current_visible:
        spec = importlib.util.spec_from_file_location("source_bound_staging", Path(__file__).with_name("stage-guru-valuation-expansion.py"))
        staging = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(staging)
        securities = staging.select_staging_targets(inventory)
    else:
        securities = {row["ticker"]: row for row in inventory["securities"] if row["inLatestSelectedBook"]
                      and row["status"] == "needs_economic_profile_and_official_guidance_review"}
    if set(securities) != set(issuer):
        raise ValueError("Candidate issuer population differs from source-bound missing coverage; do not report partial staging as complete")
    rows = []
    for ticker, security in sorted(securities.items()):
        fin = financial.get(ticker, {})
        guide = guidance.get(ticker, {})
        review = issuer[ticker]
        rows.append({
            "ticker": ticker, "issuer": security["name"],
            "sourceCurrencyCandidate": security.get("reportingCurrency"),
            "rawFinancialRows": raw_counts.get(ticker, 0),
            "financialInputStatus": fin.get("status", "missing"),
            "guidanceExtractionStatus": guide.get("status", "missing"),
            "guidanceRawEvents": event_counts.get(ticker, 0),
            "guidanceNote": guide.get("note"),
            "issuerReviewStatus": review["status"],
            "issuerReviewReason": review["reason"],
            "inLatestScopedReview": ticker in scope.get("issuers", {}),
            "latestScopedReviewFailed": ticker in scope.get("failedTickers", []),
            "releaseStatus": "not_released",
        })
    return {
        "schemaVersion": 1, "asOf": inventory["asOf"],
        "status": "incomplete_not_a_valuation_release",
        "scope": inventory["scope"], "latestReportDate": inventory.get("latestReportDate"),
        "sourceVisibilityBinding": inventory.get("sourceVisibilityBinding"),
        "securityMasterSha256": inventory.get("securityMasterSha256"),
        "baselineValuationTickers": inventory.get("releasedValuationTickers"),
        "candidateIssuers": len(rows), "rawFinancialRows": sum(raw_counts.values()),
        "normalizedFinancialRows": financial_rows,
        "financialInputStatuses": dict(Counter(row["financialInputStatus"] for row in rows)),
        "guidanceExtractionStatuses": dict(Counter(row["guidanceExtractionStatus"] for row in rows)),
        "issuerReviewStatuses": dict(Counter(row["issuerReviewStatus"] for row in rows)),
        "latestScopedReviewFailedTickers": scope.get("failedTickers", []),
        "incompleteGuidanceReviewTickers": [row["ticker"] for row in rows if row["guidanceExtractionStatus"] == "official_guidance_review_incomplete"],
        "officialScanVersion": metadata.get("official_sec_guidance_version"),
        "officialScanRecordedAt": metadata.get("official_sec_guidance_imported_at"),
        "newReleasedValuations": 0,
        "limitations": [*inventory.get("limitations", []),
            "Automated no_quantified_official_guidance means no accepted extraction in the recorded review window, not a claim that management never provides guidance.",
            "A populated raw source row is not an audited valuation model. Issuer economics, currency history, quoted share claims and applicable forecasts still require review.",
            "This input-stage ledger does not attest that a candidate passed the two-run valuation release verifier or was deployed."],
        "securities": rows,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inventory", type=Path, required=True)
    parser.add_argument("--source-db", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    report = build_report(json.loads(args.inventory.read_text()), args.source_db)
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    with args.output.with_suffix(".csv").open("w", newline="") as handle:
        writer = csv.DictWriter(handle, fieldnames=list(report["securities"][0]))
        writer.writeheader()
        writer.writerows(report["securities"])
    print(json.dumps({key: value for key, value in report.items() if key != "securities"}, indent=2))


if __name__ == "__main__":
    main()
