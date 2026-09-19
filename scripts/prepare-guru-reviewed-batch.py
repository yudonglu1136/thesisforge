#!/usr/bin/env python3
"""Build isolated model inputs for explicitly reviewed Guru securities.

This never replaces a released database. A resulting modeled batch still needs
the complete additive release and independent audit before production use.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3
from guru_reviewed_input_corrections import apply_reviewed_input_corrections


def readonly(path):
    return sqlite3.connect(Path(path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)


def prepare(source_path, metadata_path, manifest_path, output_dir, tickers):
    output_dir = Path(output_dir).resolve()
    if output_dir.exists():
        raise FileExistsError("Refusing to overwrite an existing candidate directory")
    requested = sorted(set(tickers))
    if not requested:
        raise ValueError("An explicit nonempty ticker scope is required")
    manifest = json.loads(Path(manifest_path).read_text())
    companies = {r["ticker"]: r for r in manifest["companies"]}
    for ticker in requested:
        company = companies.get(ticker, {})
        if company.get("reviewStatus") != "reviewed" or company.get("releaseNeeds"):
            raise ValueError(f"{ticker}: issuer identity/economic review is not complete")
        if not all(company.get(k) for k in ("valuationProfile", "identityEvidence", "cik", "reviewedAt")):
            raise ValueError(f"{ticker}: incomplete reviewed manifest")
    with closing(readonly(source_path)) as source, closing(readonly(metadata_path)) as meta:
        for ticker in requested:
            financial = source.execute("SELECT status FROM pit_financial_coverage WHERE ticker=?", (ticker,)).fetchone()
            guidance = source.execute("SELECT status FROM pit_guidance_coverage WHERE ticker=?", (ticker,)).fetchone()
            if not financial or financial[0] not in {"covered", "annual_only"}:
                raise ValueError(f"{ticker}: financial inputs unavailable")
            if not guidance or guidance[0] not in {"covered", "covered_official_filing", "no_quantified_official_guidance"}:
                raise ValueError(f"{ticker}: official guidance review incomplete")
            if not meta.execute("SELECT 1 FROM valuation_ticker_snapshots WHERE ticker=?", (ticker,)).fetchone():
                raise ValueError(f"{ticker}: missing exact-security metadata")
        output_dir.mkdir(mode=0o700, parents=True)
        for src, name in ((source, "source.sqlite"), (meta, "model.sqlite")):
            with closing(sqlite3.connect(output_dir / name)) as dst:
                src.backup(dst)
    with closing(sqlite3.connect(output_dir / "source.sqlite")) as dst:
        bind = ",".join("?" for _ in requested)
        for table in ("pit_financial_periods", "pit_financial_coverage", "pit_guidance_events", "pit_guidance_coverage", "pit_issuer_review", "pit_raw_financial_review"):
            dst.execute(f"DELETE FROM {table} WHERE ticker NOT IN ({bind})", requested)
        for ticker in requested:
            dst.row_factory = sqlite3.Row
            records = [dict(row) for row in dst.execute("SELECT * FROM pit_financial_periods WHERE ticker=?", (ticker,))]
            corrected = apply_reviewed_input_corrections(companies[ticker], records)
            for record in corrected:
                if "payload_json" in record:
                    dst.execute("UPDATE pit_financial_periods SET payload_json=? WHERE ticker=? AND fiscal_period=? AND dimension=?", (
                        record["payload_json"], ticker, record["fiscal_period"], record["dimension"]))
            dst.row_factory = None
            dst.execute("UPDATE pit_issuer_review SET status='reviewed',reason=? WHERE ticker=?", (
                json.dumps({"basis": "explicit_reviewed_manifest", "identity": companies[ticker]}, separators=(",", ":")), ticker))
        dst.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('batch_scope',?)", (json.dumps(requested),))
        dst.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('batch_status','isolated_model_candidate_not_release')")
        dst.commit()
        if dst.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise RuntimeError("Source candidate failed integrity check")
    with closing(sqlite3.connect(output_dir / "model.sqlite")) as dst:
        bind = ",".join("?" for _ in requested)
        dst.execute(f"DELETE FROM valuation_ticker_snapshots WHERE ticker NOT IN ({bind})", requested)
        for ticker in requested:
            raw = dst.execute("SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?", (ticker,)).fetchone()[0]
            snapshot = {**json.loads(raw), **companies[ticker]}
            dst.execute("UPDATE valuation_ticker_snapshots SET payload_json=? WHERE ticker=?", (json.dumps(snapshot, separators=(",", ":")), ticker))
        dst.commit()
    result = {"status": "isolated_model_candidate_not_release", "tickers": requested,
              "manifestSha256": hashlib.sha256(Path(manifest_path).read_bytes()).hexdigest(),
              "source": str(output_dir / "source.sqlite"), "model": str(output_dir / "model.sqlite")}
    (output_dir / "preparation.json").write_text(json.dumps(result, indent=2) + "\n")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("source-db", "metadata-db", "manifest", "output-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--tickers", required=True)
    args = parser.parse_args()
    print(json.dumps(prepare(args.source_db, args.metadata_db, args.manifest, args.output_dir,
                             [t.strip().upper() for t in args.tickers.split(",") if t.strip()]), indent=2))


if __name__ == "__main__":
    main()
