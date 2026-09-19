#!/usr/bin/env python3
"""Stage a full, additive PIT rebuild without approving or publishing valuations.

Copies the entire runtime baseline, preserves every existing source row, and
adds only exact reviewed securities from an isolated research batch. The normal
importer, two-run strict verifier, and all-ticker ledger remain mandatory.
Missing legacy review provenance stays pending; an old release is not silently
promoted to a new source/model approval.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3


SCOPED_TABLES = (
    "pit_financial_periods", "pit_financial_coverage",
    "pit_guidance_events", "pit_guidance_coverage",
    "pit_issuer_review", "pit_raw_financial_review",
)
OPTIONAL_TABLES = {"pit_issuer_review", "pit_raw_financial_review"}
FINANCIAL_STATES = {"covered", "annual_only", "derived"}
GUIDANCE_STATES = {"covered", "covered_official_filing", "no_quantified_official_guidance"}


def ro(path):
    return sqlite3.connect(Path(path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)


def quote(value):
    return '"' + value.replace('"', '""') + '"'


def schema(db, table):
    row = db.execute("SELECT sql FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone()
    return row[0] if row else None


def columns(db, table):
    return [r[1] for r in db.execute(f"PRAGMA table_info({quote(table)})")]


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def table_digest(db, table):
    """Exact row-byte preservation, including JSON strings and source dates."""
    digest = hashlib.sha256()
    info = db.execute(f"PRAGMA table_info({quote(table)})").fetchall()
    order = [r[1] for r in sorted(info, key=lambda r: r[5]) if r[5]] or [r[1] for r in info]
    count = 0
    for row in db.execute(f"SELECT * FROM {quote(table)} ORDER BY {','.join(map(quote, order))}"):
        digest.update((json.dumps(row, separators=(",", ":"), ensure_ascii=True) + "\n").encode())
        count += 1
    return {"rows": count, "sha256": digest.hexdigest()}


def metadata_seed(snapshot):
    """A model run must recompute outputs; isolated fair values cannot leak in."""
    keep = ("ticker", "key", "name", "sector", "industry", "currency", "description",
            "cik", "cusip", "aliases", "valuationProfile", "sp500MembershipAsOf",
            "priceHistory", "priceSource")
    result = {key: snapshot[key] for key in keep if key in snapshot}
    result["latest"] = {key: snapshot.get("latest", {}).get(key) for key in
                        ("latestPrice", "latestPriceDate", "latestPriceSource")}
    result["dataQuality"] = {"valuationStatus": "pending_full_rebuild",
                             "pricePoints": len(result.get("priceHistory", []))}
    return result


def copy_scoped(source, target, table, tickers):
    sql = schema(source, table)
    if sql is None:
        if table in OPTIONAL_TABLES:
            return 0
        raise ValueError(f"Missing required addition source table: {table}")
    if schema(target, table) is None:
        target.execute(sql)
    if columns(source, table) != columns(target, table):
        raise ValueError(f"Column mismatch: {table}")
    bind = ",".join("?" for _ in tickers)
    rows = source.execute(f"SELECT * FROM {quote(table)} WHERE ticker IN ({bind})", tickers)
    insert = f"INSERT INTO {quote(table)} VALUES({','.join('?' for _ in columns(source, table))})"
    count = 0
    for row in rows:
        # Conflict is fatal. Never replace a retained row or coalesce identities.
        target.execute(insert, row)
        count += 1
    return count


def assemble(baseline_path, base_source_path, addition_source_path,
             addition_metadata_path, manifest_path, output_dir, tickers):
    requested = sorted(set(tickers))
    if not requested or len(requested) != len(tickers):
        raise ValueError("An explicit, nonempty, duplicate-free ticker scope is required")
    output = Path(output_dir).resolve()
    if output.exists():
        raise FileExistsError("Never overwrite an existing candidate directory")
    manifest = json.loads(Path(manifest_path).read_text())
    companies = {row["ticker"]: row for row in manifest["companies"]}
    for ticker in requested:
        row = companies.get(ticker, {})
        if (row.get("reviewStatus") != "reviewed" or row.get("releaseNeeds") or
                not all(row.get(k) for k in ("cik", "valuationProfile", "identityEvidence", "reviewedAt"))):
            raise ValueError(f"{ticker}: missing explicit identity/economic review")

    with closing(ro(baseline_path)) as baseline, closing(ro(base_source_path)) as base, \
            closing(ro(addition_source_path)) as addition, closing(ro(addition_metadata_path)) as metadata:
        baseline_tickers = sorted(r[0] for r in baseline.execute("SELECT ticker FROM valuation_ticker_snapshots"))
        source_tickers = sorted(r[0] for r in base.execute("SELECT ticker FROM pit_financial_coverage"))
        if source_tickers != baseline_tickers:
            raise ValueError("Base source must cover the exact full retained runtime universe")
        if set(requested) & set(baseline_tickers):
            raise ValueError("Additive-only assembly refuses to overwrite any retained ticker")
        for ticker in requested:
            review = addition.execute("SELECT status FROM pit_issuer_review WHERE ticker=?", (ticker,)).fetchone()
            financial = addition.execute("SELECT status FROM pit_financial_coverage WHERE ticker=?", (ticker,)).fetchone()
            guidance = addition.execute("SELECT status FROM pit_guidance_coverage WHERE ticker=?", (ticker,)).fetchone()
            snapshot = metadata.execute("SELECT payload_json FROM valuation_ticker_snapshots WHERE ticker=?", (ticker,)).fetchone()
            if not review or review[0] != "reviewed":
                raise ValueError(f"{ticker}: addition source review is incomplete")
            if not financial or financial[0] not in {"covered", "annual_only"}:
                raise ValueError(f"{ticker}: addition financial coverage is incomplete")
            if not guidance or guidance[0] not in GUIDANCE_STATES:
                raise ValueError(f"{ticker}: addition official guidance review is incomplete")
            if not snapshot or json.loads(snapshot[0]).get("ticker") != ticker:
                raise ValueError(f"{ticker}: exact ticker metadata is absent or mismatched")
        output.mkdir(parents=True, mode=0o700)
        for source, filename in ((base, "source.sqlite"), (baseline, "candidate.sqlite")):
            with closing(sqlite3.connect(output / filename)) as target:
                source.backup(target)

        with closing(sqlite3.connect(output / "source.sqlite")) as target:
            target.execute("BEGIN IMMEDIATE")
            added = {table: copy_scoped(addition, target, table, requested) for table in SCOPED_TABLES}
            # Carry every reviewed addition's reference rate; conflicting dated
            # rates are not silently replaced, even when the scopes differ.
            fx_columns = columns(addition, "pit_fx_reference_rates")
            if fx_columns != columns(target, "pit_fx_reference_rates"):
                raise ValueError("FX schema mismatch")
            added_fx = 0
            for row in addition.execute("SELECT * FROM pit_fx_reference_rates"):
                prior = target.execute("SELECT * FROM pit_fx_reference_rates WHERE currency=? AND rate_date=?", row[:2]).fetchone()
                if prior and prior[:3] != row[:3]:
                    raise ValueError(f"Conflicting dated official FX evidence: {row[0]} {row[1]}")
                if not prior:
                    target.execute(f"INSERT INTO pit_fx_reference_rates VALUES({','.join('?' for _ in row)})", row)
                    added_fx += 1
            pending_inheritance = []
            for ticker, state in target.execute("SELECT ticker,status FROM pit_financial_coverage").fetchall():
                if state == "derived" or target.execute("SELECT 1 FROM pit_issuer_review WHERE ticker=?", (ticker,)).fetchone():
                    continue
                pending_inheritance.append(ticker)
                target.execute("INSERT INTO pit_issuer_review VALUES(?,?,?)", (ticker,
                    "inherited_release_review_pending",
                    "Retained released issuer. Bind prior audited release and unchanged economic/profile provenance; audit changed source inputs. This is not a new manual review requirement or an inferred approval."))
            provenance = {
                "schemaVersion": 1, "status": "staged_full_union_not_release_approved",
                "retainedTickers": baseline_tickers, "addedTickers": requested,
                "baseSourceSha256": sha256(base_source_path),
                "additionSourceSha256": sha256(addition_source_path),
                "reviewManifestSha256": sha256(manifest_path),
            }
            target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('additive_rebuild_provenance',?)", (json.dumps(provenance, sort_keys=True),))
            target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('target_ticker_count',?)", (str(len(baseline_tickers) + len(requested)),))
            # The source fingerprint records this actual union, not the inherited
            # original baseline fingerprint incorrectly claimed for a new batch.
            fingerprint = hashlib.sha256(json.dumps(provenance, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('source_fingerprint',?)", (fingerprint,))
            blockers = [{"ticker": t, "kind": "financial", "status": s} for t, s in target.execute("SELECT ticker,status FROM pit_financial_coverage") if s not in FINANCIAL_STATES]
            blockers += [{"ticker": t, "kind": "guidance", "status": s} for t, s in target.execute("SELECT ticker,status FROM pit_guidance_coverage") if s not in GUIDANCE_STATES]
            blockers += [{"ticker": t, "kind": "review", "status": s} for t, s in target.execute("SELECT ticker,status FROM pit_issuer_review") if s != "reviewed"]
            target.commit()
            if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("Combined source integrity check failed")
        with closing(sqlite3.connect(output / "candidate.sqlite")) as target:
            for ticker in requested:
                row = metadata.execute("SELECT generated_at,payload_json FROM valuation_ticker_snapshots WHERE ticker=?", (ticker,)).fetchone()
                target.execute("INSERT INTO valuation_ticker_snapshots(ticker,generated_at,payload_json) VALUES(?,?,?)",
                               (ticker, row[0], json.dumps(metadata_seed(json.loads(row[1])), separators=(",", ":"))))
            target.commit()
            if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("Full runtime candidate integrity check failed")

    report = {**provenance, "source": str(output / "source.sqlite"), "candidate": str(output / "candidate.sqlite"),
              "addedSourceRows": added, "addedFxRows": added_fx,
              "pendingLegacyReviewProvenance": sorted(pending_inheritance), "inputBlockers": blockers,
              "releaseAuthorized": False,
              "nextSteps": ["Resolve exact source and inherited-review provenance blockers without blanket approval.",
                            "Run the normal full importer with fixed timestamp on two independent runtime copies.",
                            "Enrich/audit all historical Q&A, run the unchanged full strict verifier and all-ticker ledger."]}
    (output / "assembly.json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("baseline", "base-source", "addition-source", "addition-metadata", "manifest", "output-dir"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--tickers", required=True)
    args = parser.parse_args()
    print(json.dumps(assemble(args.baseline, args.base_source, args.addition_source,
                              args.addition_metadata, args.manifest, args.output_dir,
                              [v.strip().upper() for v in args.tickers.split(",") if v.strip()]), indent=2))


if __name__ == "__main__":
    main()
