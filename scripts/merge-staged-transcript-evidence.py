#!/usr/bin/env python3
"""Merge a bounded transcript extraction into a pending-review input stage only."""
import argparse
from contextlib import closing
import datetime as dt
import json
from pathlib import Path
import sqlite3

OWNER = "downloaded_online_earnings_transcript"


def merge(source, target, tickers, as_of, apply=False):
    dt.date.fromisoformat(as_of)
    tickers = sorted(set(tickers))
    if not tickers:
        raise ValueError("Explicit nonempty ticker scope required")
    bind = ",".join("?" for _ in tickers)
    with closing(sqlite3.connect(Path(source).resolve().as_uri() + "?mode=ro", uri=True)) as src:
        src.row_factory = sqlite3.Row
        rows = [dict(row) for row in src.execute(
            f"SELECT * FROM pit_guidance_events WHERE ticker IN ({bind}) AND source_type=? AND observed_at<=? ORDER BY ticker,id",
            [*tickers, OWNER, as_of])]
    if set(row["ticker"] for row in rows) != set(tickers):
        raise ValueError("A requested ticker has no dated transcript events; retain prior evidence")
    for row in rows:
        if dt.date.fromisoformat(row["observed_at"]).isoformat() > as_of:
            raise ValueError("Future transcript event")
    with closing(sqlite3.connect(Path(target).resolve().as_uri() + ("?mode=rw" if apply else "?mode=ro"), uri=True)) as dst:
        review = dict(dst.execute("SELECT ticker,status FROM pit_issuer_review"))
        if any(review.get(ticker) != "pending_economic_review" for ticker in tickers):
            raise ValueError("Only an explicit pending-review stage may be modified")
        coverage = set(row[0] for row in dst.execute("SELECT ticker FROM pit_guidance_coverage"))
        if not set(tickers).issubset(coverage):
            raise ValueError("Missing stage guidance coverage")
        other_count = dst.execute("SELECT count(*) FROM pit_guidance_events WHERE source_type<>?", (OWNER,)).fetchone()[0]
        for row in rows:
            prior = dst.execute("SELECT source_type,ticker FROM pit_guidance_events WHERE id=?", (row["id"],)).fetchone()
            if prior and prior != (OWNER, row["ticker"]):
                raise ValueError("Transcript ID collides with another owner or ticker")
        if apply:
            with dst:
                # Preserve older raw evidence. Only this deterministic owner ID
                # may be replaced, and every issuer is queued for official re-review.
                columns = list(rows[0])
                sql = f"INSERT OR REPLACE INTO pit_guidance_events ({','.join(columns)}) VALUES ({','.join('?' for _ in columns)})"
                for row in rows:
                    dst.execute(sql, [row[key] for key in columns])
                for ticker in tickers:
                    count, periods = dst.execute("SELECT count(*),count(DISTINCT fiscal_period) FROM pit_guidance_events WHERE ticker=?", (ticker,)).fetchone()
                    dst.execute("UPDATE pit_guidance_coverage SET guidance_events=?,guidance_periods=?,status=?,note=? WHERE ticker=?", (
                        count, periods, "official_guidance_review_incomplete",
                        "Scoped local transcript evidence merged; official issuer review and independent model-consumption audit required.", ticker))
                assert dict(dst.execute("SELECT ticker,status FROM pit_issuer_review")) == review
                assert set(row[0] for row in dst.execute("SELECT ticker FROM pit_guidance_coverage")) == coverage
                assert dst.execute("SELECT count(*) FROM pit_guidance_events WHERE source_type<>?", (OWNER,)).fetchone()[0] == other_count
    return {"applied": apply, "tickers": tickers, "rawTranscriptEvents": len(rows), "asOf": as_of,
            "modelInputsApproved": False, "officialReviewRequired": True}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-db", type=Path, required=True)
    parser.add_argument("--target-db", type=Path, required=True)
    parser.add_argument("--tickers", required=True)
    parser.add_argument("--as-of", required=True)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    print(json.dumps(merge(args.source_db, args.target_db,
        [ticker.strip().upper() for ticker in args.tickers.split(",") if ticker.strip()], args.as_of, args.apply), indent=2))


if __name__ == "__main__":
    main()
