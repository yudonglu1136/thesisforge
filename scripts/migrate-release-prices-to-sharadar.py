#!/usr/bin/env python3
"""Create immutable Sharadar-only strategy and composition databases.

Both input SQLite databases and the local Fact OS are read-only.  The outputs
must be new files.  Price observations, price-linked valuation evidence and
security-provider validation are rebuilt from exact SEP/SFP rows; no Yahoo row
is relabelled, interpolated, forward-filled, or retained.
"""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import sqlite3
from typing import Any

import duckdb


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--strategy-source", type=Path, required=True)
    parser.add_argument("--composition-source", type=Path, required=True)
    parser.add_argument("--fact-os-root", type=Path, required=True)
    parser.add_argument("--strategy-output", type=Path, required=True)
    parser.add_argument("--composition-output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--cutoff", required=True)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--security-version", required=True)
    parser.add_argument("--action-version", required=True)
    return parser.parse_args()


def digest_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def digest(value: Any) -> str:
    encoded = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()
    return hashlib.sha256(encoded).hexdigest()


def finite(value: Any) -> float | None:
    try:
        parsed = float(value)
        return parsed if parsed == parsed and abs(parsed) != float("inf") else None
    except (TypeError, ValueError):
        return None


@contextlib.contextmanager
def reader_lease(root: Path):
    lock = root / "sync/readers.lock"
    lock.parent.mkdir(parents=True, exist_ok=True)
    with lock.open("a") as handle:
        fcntl.flock(handle, fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def copy_database(source: Path, output: Path) -> None:
    if output.exists():
        raise RuntimeError(f"refusing to replace output: {output}")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    output_db = sqlite3.connect(output)
    try:
        source_db.backup(output_db, pages=8192)
    finally:
        output_db.close()
        source_db.close()
    os.chmod(output, 0o600)


def table_exists(db: sqlite3.Connection, table: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def coverage(fact: duckdb.DuckDBPyConnection, symbols: list[str], cutoff: str) -> dict[str, str]:
    fact.execute("DROP TABLE IF EXISTS requested_runtime_symbols")
    fact.execute("CREATE TEMP TABLE requested_runtime_symbols(symbol VARCHAR PRIMARY KEY)")
    fact.executemany("INSERT INTO requested_runtime_symbols VALUES (?)", [(symbol,) for symbol in symbols])
    rows = fact.execute("""
      SELECT r.symbol,
             CASE WHEN s.ticker IS NOT NULL THEN 'stocks'
                  WHEN f.ticker IS NOT NULL THEN 'funds' END dataset,
             CASE WHEN s.ticker IS NOT NULL THEN 'sharadar_fact_os_sep'
                  WHEN f.ticker IS NOT NULL THEN 'sharadar_fact_os_sfp' END AS source_label
      FROM requested_runtime_symbols r
      LEFT JOIN (SELECT DISTINCT ticker FROM stocks WHERE date<=?) s ON s.ticker=r.symbol
      LEFT JOIN (SELECT DISTINCT ticker FROM funds WHERE date<=?) f ON f.ticker=r.symbol
      ORDER BY r.symbol
    """, [cutoff, cutoff]).fetchall()
    ambiguous = fact.execute("""
      SELECT r.symbol FROM requested_runtime_symbols r
      JOIN (SELECT DISTINCT ticker FROM stocks WHERE date<=?) s ON s.ticker=r.symbol
      JOIN (SELECT DISTINCT ticker FROM funds WHERE date<=?) f ON f.ticker=r.symbol
    """, [cutoff, cutoff]).fetchall()
    if ambiguous:
        raise RuntimeError(f"ambiguous SEP/SFP symbols: {ambiguous[:20]}")
    return {symbol: dataset for symbol, dataset, _ in rows if dataset}


def source_label(dataset: str) -> str:
    return "sharadar_fact_os_sep" if dataset == "stocks" else "sharadar_fact_os_sfp"


def fact_rows(fact: duckdb.DuckDBPyConnection, dataset: str, symbol: str,
              start: str, cutoff: str) -> list[tuple]:
    return fact.execute(f"""
      SELECT CAST(date AS VARCHAR),open,high,low,close,closeadj,volume,_observed_at
      FROM {dataset}
      WHERE ticker=? AND date BETWEEN CAST(? AS DATE) AND CAST(? AS DATE)
        AND close>0 AND closeadj>0
      ORDER BY date
    """, [symbol, start, cutoff]).fetchall()


def price_lookup(fact: duckdb.DuckDBPyConnection, dataset: str, symbol: str,
                 dates: list[str]) -> dict[str, float]:
    if not dates:
        return {}
    fact.execute("DROP TABLE IF EXISTS requested_price_dates")
    fact.execute("CREATE TEMP TABLE requested_price_dates(date DATE PRIMARY KEY)")
    fact.executemany("INSERT INTO requested_price_dates VALUES (?)", [(date,) for date in sorted(set(dates))])
    return dict(fact.execute(f"""
      SELECT CAST(p.date AS VARCHAR),p.close FROM {dataset} p
      JOIN requested_price_dates d ON d.date=p.date
      WHERE p.ticker=? AND p.close>0 ORDER BY p.date
    """, [symbol]).fetchall())


def replace_provider_validation(payload: dict[str, Any], symbol: str,
                                dataset: str | None, first: str | None,
                                last: str | None) -> dict[str, Any]:
    payload = dict(payload)
    old = payload.get("providerValidation")
    instrument = "ETF" if dataset == "funds" else "EQUITY" if dataset == "stocks" else None
    payload["providerValidation"] = {
        "provider": "Sharadar Local Fact OS",
        "dataset": "SFP" if dataset == "funds" else "SEP" if dataset == "stocks" else None,
        "status": "available" if dataset else "unavailable",
        "symbol": symbol,
        "instrumentType": instrument,
        "firstObservedDate": first,
        "lastObservedDate": last,
        "symbolExactMatch": True if dataset else False,
        "replacesLegacyValidation": bool(old),
    }
    return payload


def update_output_price(payload: dict[str, Any], price: float | None, date: str,
                        source: str) -> dict[str, Any]:
    payload = dict(payload)
    payload["currentPrice"] = price
    payload["priceAtDate"] = price
    payload["priceDate"] = date if price is not None else None
    fair = finite(payload.get("fairValue"))
    target = finite(payload.get("targetPrice3Y"))
    payload["upsideDownside"] = fair / price - 1 if price and fair is not None else None
    payload["expectedReturn3Y"] = (target / price) ** (1 / 3) - 1 if price and target and target > 0 else None
    snapshot = payload.get("dataSnapshot")
    if isinstance(snapshot, dict):
        snapshot = dict(snapshot)
        snapshot["asOfPriceSource"] = {
            "priceDate": date if price is not None else None,
            "source": source if price is not None else "sharadar_unavailable",
            "priceType": "RAW_CLOSE",
        }
        payload["dataSnapshot"] = snapshot
    return payload


def migrate_strategy(source: Path, output: Path, fact: duckdb.DuckDBPyConnection,
                     cutoff: str, generated_at: str, catalog_hash: str,
                     security_version: str, action_version: str) -> dict[str, Any]:
    copy_database(source, output)
    db = sqlite3.connect(output)
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA journal_mode=DELETE")
    before = {
        "series": db.execute("SELECT COUNT(*) FROM price_series").fetchone()[0],
        "observations": db.execute("SELECT COUNT(*) FROM price_observations").fetchone()[0],
        "yahooSeries": db.execute("SELECT COUNT(*) FROM price_series WHERE lower(COALESCE(provider,'')||' '||source_label) LIKE '%yahoo%'").fetchone()[0],
    }
    ranges = db.execute("""
      SELECT s.symbol,s.storage_kind,MIN(p.date),MAX(p.date)
      FROM price_series s JOIN price_observations p ON p.series_id=s.id
      GROUP BY s.symbol,s.storage_kind ORDER BY s.symbol,s.storage_kind
    """).fetchall()
    symbols = sorted({row[0] for row in ranges})
    datasets = coverage(fact, symbols, cutoff)
    provenance_ids: dict[str, str] = {}
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("DELETE FROM etf_catalog")
        db.execute("DELETE FROM price_observations")
        db.execute("DELETE FROM price_series")
        for dataset in sorted(set(datasets.values())):
            label = source_label(dataset)
            content = json.dumps({"provider": "Sharadar Local Fact OS", "dataset": dataset,
                                  "catalogSha256": catalog_hash, "cutoff": cutoff}, separators=(",", ":"))
            source_id = digest(["runtime-price-source", label, catalog_hash, cutoff])
            db.execute("INSERT OR IGNORE INTO source_documents(id,kind,locator,sha256,content,stored_at) VALUES(?,?,?,?,?,?)",
                       (source_id, "sharadar_fact_os_price_release", f"local-fact-os://{dataset}",
                        hashlib.sha256(content.encode()).hexdigest(), content, generated_at))
            provenance_ids[dataset] = source_id
        inserted = 0
        series_count = 0
        source_read = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
        try:
            etf_inception = {row[0]: row[1] for row in source_read.execute("SELECT symbol,inception FROM etf_catalog")}
        finally:
            source_read.close()
        for symbol, storage, first, _last in ranges:
            dataset = datasets.get(symbol)
            if not dataset:
                continue
            rows = fact_rows(fact, dataset, symbol, first, cutoff)
            if not rows:
                continue
            label = source_label(dataset)
            series_id = digest(["sharadar-runtime-series", symbol, storage, catalog_hash, cutoff])
            db.execute("""
              INSERT INTO price_series(id,symbol,provider,source_label,storage_kind,close_basis,
                return_basis,quote_currency,status,source_id) VALUES(?,?,?,?,?,?,?,?,?,?)
            """, (series_id, symbol, "sharadar", label, storage, "split_adjusted_close",
                  None if storage == "valuation_snapshot" else "total_return_adjusted_close",
                  "USD", "full_daily_source_verified", provenance_ids[dataset]))
            db.executemany("""
              INSERT INTO price_observations(series_id,date,open,high,low,close,adjusted_close,
                volume,observed_at,quality_status) VALUES(?,?,?,?,?,?,?,?,?,?)
            """, [(series_id, date, open_, high, low, close, adjusted, volume,
                   observed or generated_at, "verified_daily_bar")
                  for date, open_, high, low, close, adjusted, volume, observed in rows])
            series_count += 1
            inserted += len(rows)
            if storage == "cta_etf" and symbol in etf_inception:
                points_hash = digest([(row[0], row[4], row[5]) for row in rows])
                db.execute("INSERT OR REPLACE INTO etf_catalog VALUES(?,?,?,?,?,?,?,?)",
                           (symbol, etf_inception[symbol], rows[0][0], rows[-1][0], series_id,
                            f"local-fact-os://{dataset}/{symbol}", points_hash, generated_at))

        evidence_rows = db.execute("""
          SELECT ticker,fiscal_period,model_version,price_symbol,price_date,payload_json
          FROM model_price_evidence ORDER BY price_symbol,price_date
        """).fetchall()
        evidence_by_symbol: dict[str, list[tuple]] = {}
        for row in evidence_rows:
            evidence_by_symbol.setdefault(row[3], []).append(row)
        evidence_updated = 0
        for symbol, items in evidence_by_symbol.items():
            dataset = datasets.get(symbol)
            prices = price_lookup(fact, dataset, symbol, [row[4] for row in items]) if dataset else {}
            label = source_label(dataset) if dataset else "sharadar_unavailable"
            for ticker, period, version, price_symbol, price_date, raw in items:
                price = prices.get(price_date)
                payload = json.loads(raw)
                payload["source"] = {"priceDate": price_date if price is not None else None,
                                     "source": label, "priceType": "RAW_CLOSE"}
                payload["policy"] = "Exact Sharadar SEP/SFP raw close used only for comparison with the PIT fair-value output."
                db.execute("""
                  UPDATE model_price_evidence SET close=?,source_label=?,payload_json=?
                  WHERE ticker=? AND fiscal_period=? AND model_version=?
                """, (price, label, json.dumps(payload, separators=(",", ":")), ticker, period, version))
                node = db.execute("SELECT id,output_json FROM valuation_nodes WHERE ticker=? AND fiscal_period=? AND model_version=?",
                                  (ticker, period, version)).fetchone()
                if node:
                    output_payload = update_output_price(json.loads(node[1]), price, price_date, label)
                    db.execute("UPDATE valuation_nodes SET output_json=? WHERE id=?",
                               (json.dumps(output_payload, separators=(",", ":")), node[0]))
                evidence_updated += 1

        security_rows = db.execute("SELECT cusip,ticker,evidence_json FROM security_identifiers").fetchall()
        validation_updated = 0
        bounds: dict[str, tuple[str | None, str | None]] = {}
        for cusip, symbol, raw in security_rows:
            dataset = datasets.get(symbol)
            if dataset and symbol not in bounds:
                bounds[symbol] = fact.execute(f"SELECT CAST(MIN(date) AS VARCHAR),CAST(MAX(date) AS VARCHAR) FROM {dataset} WHERE ticker=? AND date<=?", [symbol, cutoff]).fetchone()
            first, last = bounds.get(symbol, (None, None))
            payload = replace_provider_validation(json.loads(raw), symbol, dataset, first, last)
            db.execute("UPDATE security_identifiers SET evidence_json=? WHERE cusip=?",
                       (json.dumps(payload, separators=(",", ":")), cusip))
            validation_updated += 1

        security_content = json.dumps({"provider": "Sharadar Local Fact OS", "catalogSha256": catalog_hash,
                                       "cutoff": cutoff, "validatedIdentifiers": validation_updated},
                                      separators=(",", ":"))
        security_source_id = digest(["sharadar-security-validation", catalog_hash, cutoff])
        db.execute("INSERT OR IGNORE INTO source_documents(id,kind,locator,sha256,content,stored_at) VALUES(?,?,?,?,?,?)",
                   (security_source_id, "security_master", "local-fact-os://tickers-and-prices",
                    hashlib.sha256(security_content.encode()).hexdigest(), security_content, generated_at))
        db.execute("UPDATE security_identifiers SET source_id=?", (security_source_id,))

        if table_exists(db, "warehouse_meta"):
            prior_counts_raw = db.execute("SELECT source_counts_json FROM warehouse_meta WHERE id=1").fetchone()[0]
            source_counts = json.loads(prior_counts_raw)
            raw_price_points = db.execute("""SELECT COUNT(*) FROM price_observations p
              JOIN price_series s ON s.id=p.series_id WHERE s.storage_kind='raw_price_points'""").fetchone()[0]
            source_counts.update({
                "price_points": raw_price_points,
                "priceProvider": "Sharadar Local Fact OS",
                "priceSeries": series_count,
                "priceObservations": inserted,
                "missingSymbols": sorted(set(symbols) - set(datasets)),
            })
            release_manifest_hash = digest([catalog_hash, cutoff, raw_price_points, inserted, series_count])
            db.execute("""UPDATE warehouse_meta SET cutoff=?,generated_at=?,manifest_hash=?,
              source_counts_json=?,security_version=?,action_version=? WHERE id=1""",
                       (cutoff, generated_at, release_manifest_hash,
                        json.dumps(source_counts, separators=(",", ":")), security_version, action_version))

        referenced = """
          SELECT source_id FROM managers UNION SELECT source_id FROM filing_manifest
          UNION SELECT source_id FROM filings UNION SELECT source_id FROM security_identifiers
          UNION SELECT source_id FROM corporate_actions UNION SELECT document_id FROM document_holdings
          UNION SELECT source_id FROM price_series
        """
        db.execute(f"""DELETE FROM source_documents WHERE id NOT IN ({referenced})
          AND lower(kind||' '||locator||' '||content) LIKE '%yahoo%'""")
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise
    finally:
        # The read-only helper above owns an independent connection.
        pass
    db.execute("VACUUM")
    db.execute("PRAGMA optimize")
    yahoo = {
        "series": db.execute("SELECT COUNT(*) FROM price_series WHERE lower(COALESCE(provider,'')||' '||source_label) LIKE '%yahoo%'").fetchone()[0],
        "evidence": db.execute("SELECT COUNT(*) FROM model_price_evidence WHERE lower(COALESCE(source_label,'')||' '||payload_json) LIKE '%yahoo%'").fetchone()[0],
        "valuationOutputs": db.execute("SELECT COUNT(*) FROM valuation_nodes WHERE lower(output_json) LIKE '%yahoo%'").fetchone()[0],
        "securityValidation": db.execute("SELECT COUNT(*) FROM security_identifiers WHERE lower(evidence_json) LIKE '%yahoo%'").fetchone()[0],
        "etfCatalog": db.execute("SELECT COUNT(*) FROM etf_catalog WHERE lower(COALESCE(source_url,'')) LIKE '%yahoo%'").fetchone()[0],
        "priceSourceDocuments": db.execute("""SELECT COUNT(*) FROM source_documents
          WHERE kind IN ('full_population_price_refresh','market_refresh','price_snapshot_metadata',
            'current_comparison_quote','all_price_confirmation','verified_yahoo_gap_repair',
            'full_daily_recovery','full_daily_recovery_audit','etf_artifact')
          AND lower(kind||' '||locator||' '||content) LIKE '%yahoo%'""").fetchone()[0],
    }
    integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
    after = {"series": db.execute("SELECT COUNT(*) FROM price_series").fetchone()[0],
             "observations": db.execute("SELECT COUNT(*) FROM price_observations").fetchone()[0],
             "first": db.execute("SELECT MIN(date) FROM price_observations").fetchone()[0],
             "last": db.execute("SELECT MAX(date) FROM price_observations").fetchone()[0]}
    db.close()
    if integrity != "ok" or any(yahoo.values()):
        raise RuntimeError(f"strategy migration validation failed integrity={integrity} yahoo={yahoo}")
    return {"before": before, "after": after, "requestedSymbols": len(symbols),
            "coveredSymbols": len(datasets), "missingSymbols": sorted(set(symbols) - set(datasets)),
            "valuationEvidenceUpdated": evidence_updated,
            "securityValidationsUpdated": validation_updated, "activeYahoo": yahoo}


def migrate_composition(source: Path, output: Path, fact: duckdb.DuckDBPyConnection,
                        cutoff: str, generated_at: str, catalog_hash: str) -> dict[str, Any]:
    copy_database(source, output)
    db = sqlite3.connect(output)
    db.execute("PRAGMA journal_mode=DELETE")
    columns = {row[1] for row in db.execute("PRAGMA table_info(series)")}
    if "provider" not in columns:
        db.execute("ALTER TABLE series ADD COLUMN provider TEXT")
    symbols = [row[0] for row in db.execute("SELECT symbol FROM series ORDER BY symbol")]
    datasets = coverage(fact, symbols, cutoff)
    before = {"series": len(symbols), "prices": db.execute("SELECT COUNT(*) FROM prices").fetchone()[0],
              "sourceResponses": db.execute("SELECT COUNT(*) FROM source_responses").fetchone()[0]}
    db.execute("BEGIN IMMEDIATE")
    try:
        db.execute("DELETE FROM prices")
        db.execute("DELETE FROM series")
        db.execute("DELETE FROM source_responses")
        db.execute("DELETE FROM audit")
        price_count = 0
        for symbol in symbols:
            dataset = datasets.get(symbol)
            if not dataset:
                continue
            rows = fact_rows(fact, dataset, symbol, "1900-01-01", cutoff)
            if not rows:
                continue
            label = source_label(dataset)
            metadata = {"symbol": symbol, "currency": "USD",
                        "instrumentType": "ETF" if dataset == "funds" else "EQUITY",
                        "provider": "Sharadar Local Fact OS", "dataset": "SFP" if dataset == "funds" else "SEP",
                        "catalogSha256": catalog_hash}
            points_hash = digest([(row[0], row[4], row[5]) for row in rows])
            db.execute("""INSERT INTO series(symbol,provider_symbol,currency,first_date,last_date,row_count,
              source_sha256,metadata_json,events_json,status,provider) VALUES(?,?,?,?,?,?,?,?,?,?,?)""",
                       (symbol, symbol, "USD", rows[0][0], rows[-1][0], len(rows), points_hash,
                        json.dumps(metadata, separators=(",", ":")), "{}", "current", "sharadar"))
            db.executemany("INSERT INTO prices VALUES(?,?,?,?,?,?,?,?,?)",
                           [(symbol, date, open_, high, low, close, adjusted, volume, "verified_daily_bar")
                            for date, open_, high, low, close, adjusted, volume, _observed in rows])
            audit = {"symbol": symbol, "source": f"local-fact-os://{dataset}/{symbol}",
                     "provider": "sharadar", "sourceLabel": label, "first": rows[0][0],
                     "last": rows[-1][0], "rows": len(rows), "sourceHash": points_hash,
                     "catalogSha256": catalog_hash, "generatedAt": generated_at}
            db.execute("INSERT INTO audit VALUES(?,?)", (symbol, json.dumps(audit, separators=(",", ":"))))
            price_count += len(rows)
        db.execute("COMMIT")
    except BaseException:
        db.execute("ROLLBACK")
        raise
    db.execute("VACUUM")
    db.execute("PRAGMA optimize")
    yahoo = sum(db.execute(f"SELECT COUNT(*) FROM {table} WHERE lower({column}) LIKE '%yahoo%'").fetchone()[0]
                for table, column in (("series", "COALESCE(provider,'')||' '||metadata_json||' '||events_json"),
                                      ("audit", "payload_json")))
    integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
    after = {"series": db.execute("SELECT COUNT(*) FROM series").fetchone()[0],
             "prices": price_count, "first": db.execute("SELECT MIN(date) FROM prices").fetchone()[0],
             "last": db.execute("SELECT MAX(date) FROM prices").fetchone()[0]}
    db.close()
    if integrity != "ok" or yahoo:
        raise RuntimeError(f"composition migration validation failed integrity={integrity} yahoo={yahoo}")
    return {"before": before, "after": after, "requestedSymbols": len(symbols),
            "coveredSymbols": len(datasets), "missingSymbols": sorted(set(symbols) - set(datasets)),
            "activeYahoo": yahoo}


def main() -> None:
    args = arguments()
    dt.date.fromisoformat(args.cutoff)
    dt.datetime.fromisoformat(args.generated_at.replace("Z", "+00:00"))
    paths = [args.strategy_source, args.composition_source, args.fact_os_root,
             args.strategy_output, args.composition_output, args.receipt]
    strategy_source, composition_source, root, strategy_output, composition_output, receipt = [p.expanduser().resolve() for p in paths]
    if not strategy_source.is_file() or not composition_source.is_file() or not (root / "fact_os.duckdb").is_file():
        raise RuntimeError("source database or Fact OS missing")
    if strategy_output.exists() or composition_output.exists() or receipt.exists():
        raise RuntimeError("outputs and receipt must be new")
    catalog_bytes = (root / "manifests/catalog.json").read_bytes()
    catalog_hash = hashlib.sha256(catalog_bytes).hexdigest()
    with reader_lease(root):
        fact = duckdb.connect(str(root / "fact_os.duckdb"), read_only=True)
        try:
            strategy = migrate_strategy(strategy_source, strategy_output, fact, args.cutoff,
                                        args.generated_at, catalog_hash,
                                        args.security_version, args.action_version)
            composition = migrate_composition(composition_source, composition_output, fact,
                                              args.cutoff, args.generated_at, catalog_hash)
        finally:
            fact.close()
        if (root / "manifests/catalog.json").read_bytes() != catalog_bytes:
            raise RuntimeError("Fact OS generation changed during migration")
    report = {
        "kind": "thesisforge_sharadar_release_price_migration",
        "generatedAt": args.generated_at, "cutoff": args.cutoff,
        "factOs": {"root": str(root), "catalogSha256": catalog_hash},
        "sources": {"strategy": {"path": str(strategy_source), "sha256": digest_file(strategy_source)},
                    "composition": {"path": str(composition_source), "sha256": digest_file(composition_source)}},
        "strategy": strategy, "composition": composition,
        "outputs": {"strategy": {"path": str(strategy_output), "bytes": strategy_output.stat().st_size,
                                     "sha256": digest_file(strategy_output)},
                    "composition": {"path": str(composition_output), "bytes": composition_output.stat().st_size,
                                        "sha256": digest_file(composition_output)}},
        "policies": ["exact Sharadar SEP/SFP rows", "no interpolation or forward fill",
                     "unsupported listings fail closed", "no user database opened"],
    }
    receipt.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipt.write_text(json.dumps(report, indent=2, ensure_ascii=False) + "\n")
    os.chmod(receipt, 0o600)
    print(json.dumps(report, indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
