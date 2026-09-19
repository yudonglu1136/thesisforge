#!/usr/bin/env python3
"""Recover original PIT inputs from a released valuation database, read-only.

Creates NEW input files for reproducible diagnostic rebuilds. Historical
approval is not renewed: the strict release auditor must recheck every output.
"""
import argparse
from contextlib import closing
import importlib.util
import json
from pathlib import Path
import sqlite3


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def reconstruct(baseline_path, fx_path, output_path):
    output = Path(output_path).resolve()
    if output.exists():
        raise FileExistsError("Never overwrite an existing source or runtime database")
    builder = load("pit_recovery_builder", "build-pit-valuation-source.py")
    extractor = load("pit_recovery_extractor", "extract-pit-management-guidance.py")
    with closing(sqlite3.connect(Path(baseline_path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as src:
        src.row_factory = sqlite3.Row
        with closing(builder.create_database(output)) as dst:
            extractor.ensure_schema(dst)
            meta = dict(src.execute("SELECT key,value FROM valuation_pit_source_metadata"))
            dst.executemany("INSERT INTO pit_source_metadata VALUES(?,?)", meta.items())
            dst.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('reconstructed_source_status','diagnostic_rebuild_requires_fresh_release_audit')")
            columns = [r[1] for r in dst.execute("PRAGMA table_info(pit_financial_periods)")]
            dst.executemany(f"INSERT INTO pit_financial_periods VALUES({','.join('?' for _ in columns)})", (
                tuple(row[k] for k in columns) for row in src.execute("SELECT * FROM valuation_pit_financials ORDER BY ticker,fiscal_period,dimension")))
            with closing(sqlite3.connect(Path(fx_path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)) as fx:
                dst.executemany("INSERT INTO pit_fx_reference_rates VALUES(?,?,?,?,?,?)", fx.execute("SELECT * FROM pit_fx_reference_rates"))
            # Preserve exact reference-rate observations embedded in the released
            # source, supplementing (not replacing) the complete dated FX book.
            for row in dst.execute("SELECT payload_json FROM pit_financial_periods").fetchall():
                fx = json.loads(row[0]).get("sourceRecord", {}).get("fxConversion") or {}
                for side in ("source", "target"):
                    currency, date, value = (fx.get(side + k) for k in ("Currency", "RateDate", "UnitsPerEur"))
                    if currency and date and value:
                        prior = dst.execute("SELECT units_per_eur FROM pit_fx_reference_rates WHERE currency=? AND rate_date=?", (currency, date)).fetchone()
                        if prior and abs(prior[0] - value) > 1e-9:
                            raise ValueError(f"Conflicting official FX observation {currency} {date}")
                        dst.execute("INSERT OR IGNORE INTO pit_fx_reference_rates VALUES(?,?,?,?,?,?)", (
                            currency, date, value, fx["sourceUrl"], fx["extractionVersion"], "released_source_recovery"))
            guide_cols = [r[1] for r in dst.execute("PRAGMA table_info(pit_guidance_events)")]
            for row in src.execute("SELECT * FROM valuation_pit_guidance ORDER BY source_database,source_id"):
                outer = json.loads(row["payload_json"])
                nested = outer.get("payload_json")
                if isinstance(nested, str):
                    nested = json.loads(nested)
                event = {**(nested or {}), **{k: v for k, v in outer.items() if k != "payload_json"}}
                event.update({"id": row["source_id"], "ticker": row["ticker"], "fiscal_period": row["fiscal_period"],
                              "source_type": outer.get("source_type") or row["source_database"]})
                if not event.get("source_file") or not event.get("actual_or_guidance"):
                    raise ValueError(f"Incomplete retained guidance source {row['source_id']}")
                event["payload_json"] = json.dumps(event, separators=(",", ":"))
                dst.execute(f"INSERT INTO pit_guidance_events VALUES({','.join('?' for _ in guide_cols)})", [event.get(k) for k in guide_cols])
            no_quantified = set(json.loads(meta["guidance_no_quantified_tickers"]))
            for ticker_row in src.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker"):
                ticker = ticker_row["ticker"]
                rows = dst.execute("SELECT source_ticker,dimension,available_at FROM pit_financial_periods WHERE ticker=?", (ticker,)).fetchall()
                if not rows:
                    snapshot = json.loads(ticker_row["payload_json"])
                    if ticker != "RKLX" or snapshot.get("dataQuality", {}).get("valuationStatus") != "not_applicable":
                        raise ValueError(f"Retained issuer has no financials: {ticker}")
                    dst.execute("INSERT INTO pit_financial_coverage VALUES(?,?,'derived',0,0,NULL,NULL,?)", (ticker, "RKLB", "Derived ETF; no issuer financial statement model."))
                    continue
                arq = sum(r[1] == "ARQ" for r in rows)
                art = sum(r[1] == "ART" for r in rows)
                dst.execute("INSERT INTO pit_financial_coverage VALUES(?,?,?,?,?,?,?,?)", (
                    ticker, rows[0][0], "covered" if arq else "annual_only", arq, art,
                    min(r[2] for r in rows), max(r[2] for r in rows), "Recovered unchanged released as-reported inputs; re-audit required"))
                events = dst.execute("SELECT fiscal_period,source_file,source_type FROM pit_guidance_events WHERE ticker=?", (ticker,)).fetchall()
                transcripts = [r for r in events if r[2] == "downloaded_online_earnings_transcript"]
                status = "no_quantified_official_guidance" if ticker in no_quantified else "covered" if transcripts else "covered_official_filing"
                dst.execute("INSERT INTO pit_guidance_coverage VALUES(?,?,?,?,?,?,?)", (
                    ticker, len(set(r[1] for r in transcripts)), len(set(r[0] for r in transcripts)),
                    len(set(r[0] for r in events)), len(events), status,
                    "Recovered prior release declaration, not a new independent approval"))
            dst.commit()
            if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("Recovered input integrity failed")
            return {"source": str(output), "status": "diagnostic_rebuild_requires_fresh_release_audit",
                    "financialRows": dst.execute("SELECT count(*) FROM pit_financial_periods").fetchone()[0],
                    "guidanceEvents": dst.execute("SELECT count(*) FROM pit_guidance_events").fetchone()[0]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "fx-source", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(reconstruct(args.baseline, args.fx_source, args.output), indent=2))


if __name__ == "__main__":
    main()
