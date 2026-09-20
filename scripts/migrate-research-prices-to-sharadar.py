#!/usr/bin/env python3
"""Build an immutable Sharadar-only research database candidate.

The source SQLite database and Fact OS are read-only.  The output must not
already exist.  Historical prices are rebuilt from the exact SEP/SFP rows,
Yahoo-derived valuation comparison prices are recomputed (never relabelled),
and Yahoo dividend/cache rows are removed.  User portfolio databases are not
opened by this program.
"""

from __future__ import annotations

import argparse
import bisect
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sqlite3
from typing import Any

import duckdb


SHARADAR_SEP = "sharadar_fact_os_sep"
SHARADAR_SFP = "sharadar_fact_os_sfp"
SHARADAR_ACTIONS = "sharadar_fact_os_actions"
YAHOO_RE = re.compile(r"yahoo", re.I)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--fact-os-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--cutoff", default="2026-09-18")
    parser.add_argument("--generated-at", required=True)
    return parser.parse_args()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def sha256_bytes(value: bytes) -> str:
    return hashlib.sha256(value).hexdigest()


def json_bytes(value: Any) -> bytes:
    return json.dumps(value, ensure_ascii=False, sort_keys=True,
                      separators=(",", ":")).encode("utf-8")


def finite(value: Any) -> float | None:
    try:
        parsed = float(value)
        return parsed if parsed == parsed and abs(parsed) != float("inf") else None
    except (TypeError, ValueError):
        return None


@contextlib.contextmanager
def reader_lease(root: Path):
    lock_path = root / "sync/readers.lock"
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a") as lease:
        fcntl.flock(lease, fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(lease, fcntl.LOCK_UN)


def ensure_paths(args: argparse.Namespace) -> tuple[Path, Path, Path, Path]:
    source = args.source.expanduser().resolve()
    root = args.fact_os_root.expanduser().resolve()
    output = args.output.expanduser().resolve()
    receipt = args.receipt.expanduser().resolve()
    if not source.is_file():
        raise RuntimeError(f"source database missing: {source}")
    if not (root / "fact_os.duckdb").is_file():
        raise RuntimeError(f"Fact OS database missing: {root / 'fact_os.duckdb'}")
    if output.exists() or receipt.exists():
        raise RuntimeError("output and receipt must be new paths")
    if output == source:
        raise RuntimeError("source and output must differ")
    output.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    receipt.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    return source, root, output, receipt


def copy_sqlite(source: Path, output: Path) -> None:
    source_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    target_db = sqlite3.connect(output)
    try:
        source_db.backup(target_db, pages=8192)
    finally:
        target_db.close()
        source_db.close()
    os.chmod(output, 0o600)


def table_exists(db: sqlite3.Connection, table: str) -> bool:
    return db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?", (table,)).fetchone() is not None


def source_summary(db: sqlite3.Connection) -> dict[str, Any]:
    summary: dict[str, Any] = {}
    if table_exists(db, "price_points"):
        summary["price_points"] = dict(zip(
            ["rows", "symbols", "first", "last", "yahoo_rows"],
            db.execute("""
              SELECT COUNT(*), COUNT(DISTINCT symbol), MIN(date), MAX(date),
                     SUM(CASE WHEN lower(COALESCE(source,'')) LIKE '%yahoo%' THEN 1 ELSE 0 END)
              FROM price_points
            """).fetchone()))
    if table_exists(db, "dividend_events"):
        summary["dividend_events"] = dict(zip(
            ["rows", "yahoo_rows"],
            db.execute("""
              SELECT COUNT(*), SUM(CASE WHEN lower(COALESCE(source,'')) LIKE '%yahoo%' THEN 1 ELSE 0 END)
              FROM dividend_events
            """).fetchone()))
    for table in ("guru_backtests", "guru_backtest_proxies"):
        if table_exists(db, table):
            payloads = [json.loads(row[0]) for row in db.execute(f"SELECT payload_json FROM {table}")]
            summary[table] = {"rows": len(payloads),
                              "yahoo_provenance_payloads": sum(contains_yahoo_provenance(p) for p in payloads)}
    return summary


def requested_price_symbols(db: sqlite3.Connection) -> tuple[list[str], set[str]]:
    required = {str(row[0]).upper() for row in db.execute(
        "SELECT DISTINCT symbol FROM price_points WHERE symbol<>''"
    )}
    expanded = set(required)
    if table_exists(db, "valuation_ticker_snapshots"):
        for ticker, raw in db.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots"):
            candidates = [ticker]
            try:
                payload = json.loads(raw)
                candidates.extend([payload.get("ticker"), payload.get("key")])
            except json.JSONDecodeError:
                pass
            for candidate in candidates:
                normalized = str(candidate or "").strip().upper()
                if re.fullmatch(r"[A-Z0-9][A-Z0-9.-]{0,20}", normalized):
                    expanded.add(normalized)
    if table_exists(db, "investment_current_quotes"):
        columns = {row[1] for row in db.execute("PRAGMA table_info(investment_current_quotes)")}
        key = "ticker" if "ticker" in columns else "symbol" if "symbol" in columns else None
        if key:
            expanded.update(str(row[0]).upper() for row in db.execute(
                f"SELECT DISTINCT {key} FROM investment_current_quotes WHERE {key}<>''"
            ))
    return sorted(expanded), required


def rebuild_price_points(db: sqlite3.Connection, fact: duckdb.DuckDBPyConnection,
                         cutoff: str, generated_at: str) -> dict[str, Any]:
    symbols, required = requested_price_symbols(db)
    fact.execute("CREATE TEMP TABLE requested_symbols(symbol VARCHAR PRIMARY KEY)")
    fact.executemany("INSERT INTO requested_symbols VALUES (?)", [(symbol,) for symbol in symbols])
    coverage = fact.execute("""
      SELECT r.symbol,
             CASE WHEN s.ticker IS NOT NULL THEN 'stocks'
                  WHEN f.ticker IS NOT NULL THEN 'funds' END AS dataset
      FROM requested_symbols r
      LEFT JOIN (SELECT DISTINCT ticker FROM stocks WHERE date <= ?) s ON s.ticker=r.symbol
      LEFT JOIN (SELECT DISTINCT ticker FROM funds WHERE date <= ?) f ON f.ticker=r.symbol
      ORDER BY r.symbol
    """, [cutoff, cutoff]).fetchall()
    missing = [symbol for symbol, dataset in coverage if dataset is None]
    missing_required = sorted(set(missing) & required)
    overlap = fact.execute("""
      SELECT COUNT(*) FROM requested_symbols r
      JOIN (SELECT DISTINCT ticker FROM stocks WHERE date <= ?) s ON s.ticker=r.symbol
      JOIN (SELECT DISTINCT ticker FROM funds WHERE date <= ?) f ON f.ticker=r.symbol
    """, [cutoff, cutoff]).fetchone()[0]
    if missing_required or overlap:
        raise RuntimeError(f"ambiguous Fact OS coverage: missing_required={missing_required[:20]} overlap={overlap}")

    db.execute("DROP TABLE IF EXISTS price_points_sharadar_next")
    db.execute("""
      CREATE TABLE price_points_sharadar_next (
        symbol TEXT NOT NULL, date TEXT NOT NULL, open REAL, high REAL, low REAL,
        close REAL NOT NULL, volume REAL, source TEXT NOT NULL,
        updated_at TEXT NOT NULL, adjusted_close REAL,
        PRIMARY KEY(symbol,date)
      ) WITHOUT ROWID
    """)
    insert = db.cursor()
    expected_rows = 0
    for dataset, source in (("stocks", SHARADAR_SEP), ("funds", SHARADAR_SFP)):
        cursor = fact.execute(f"""
          SELECT p.ticker, CAST(p.date AS VARCHAR), p.open, p.high, p.low,
                 p.close, p.volume, p._observed_at, p.closeadj
          FROM {dataset} p JOIN requested_symbols r ON r.symbol=p.ticker
          WHERE p.date <= ?
          ORDER BY p.ticker,p.date
        """, [cutoff])
        while True:
            rows = cursor.fetchmany(25_000)
            if not rows:
                break
            normalized = []
            for symbol, date, open_, high, low, close, volume, observed_at, adjusted in rows:
                if finite(close) is None or close <= 0:
                    raise RuntimeError(f"invalid Sharadar close for {symbol} {date}")
                normalized.append((symbol, date, open_, high, low, close, volume,
                                   source, str(observed_at or generated_at), adjusted))
            insert.executemany("""
              INSERT INTO price_points_sharadar_next
              (symbol,date,open,high,low,close,volume,source,updated_at,adjusted_close)
              VALUES (?,?,?,?,?,?,?,?,?,?)
            """, normalized)
            expected_rows += len(normalized)
    actual = db.execute("""
      SELECT COUNT(*),COUNT(DISTINCT symbol),MIN(date),MAX(date),
             COUNT(*)-COUNT(DISTINCT symbol||char(0)||date),
             SUM(CASE WHEN close<=0 OR adjusted_close<=0 THEN 1 ELSE 0 END),
             SUM(CASE WHEN lower(source) LIKE '%yahoo%' THEN 1 ELSE 0 END)
      FROM price_points_sharadar_next
    """).fetchone()
    covered_count = len(symbols) - len(missing)
    if actual[0] != expected_rows or actual[1] != covered_count or actual[4] or actual[5] or actual[6]:
        raise RuntimeError(f"Sharadar price validation failed: {actual}")
    db.execute("DROP TABLE price_points")
    db.execute("ALTER TABLE price_points_sharadar_next RENAME TO price_points")
    db.execute("CREATE INDEX IF NOT EXISTS idx_price_points_symbol_date ON price_points(symbol,date)")
    return {"rows": actual[0], "symbols": actual[1], "requestedSymbols": len(symbols),
            "unavailableSymbols": missing, "first": actual[2], "last": actual[3],
            "sources": dict(db.execute("SELECT source,COUNT(*) FROM price_points GROUP BY source"))}


def price_index(db: sqlite3.Connection, ticker: str) -> tuple[list[str], list[tuple]]:
    rows = db.execute("""
      SELECT date,close,source FROM price_points
      WHERE symbol=? AND close>0 ORDER BY date
    """, (ticker,)).fetchall()
    return [row[0] for row in rows], rows


def prior_price(index: tuple[list[str], list[tuple]], date: Any) -> tuple | None:
    dates, rows = index
    if not date or not dates:
        return None
    position = bisect.bisect_right(dates, str(date)[:10]) - 1
    return rows[position] if position >= 0 else None


def comparison(price: Any, fair: Any, target: Any) -> tuple[float | None, float | None]:
    p, f, t = finite(price), finite(fair), finite(target)
    upside = f / p - 1 if p and p > 0 and f is not None else None
    expected = (t / p) ** (1 / 3) - 1 if p and p > 0 and t and t > 0 else None
    return upside, expected


def migrate_valuation_payload(payload: dict[str, Any], index: tuple[list[str], list[tuple]],
                              include_history: bool) -> dict[str, Any]:
    dates, points = index
    ticker = str(payload.get("ticker") or payload.get("key") or "").upper()
    latest = dict(payload.get("latest") or {})
    last = points[-1] if points else None
    latest_price = last[1] if last else None
    latest["latestPrice"] = latest_price
    latest["latestPriceDate"] = last[0] if last else None
    latest["latestPriceSource"] = last[2] if last else "sharadar_unavailable"
    latest["priceType"] = "RAW_CLOSE"
    anchor = prior_price(index, latest.get("valuationAnchorDate"))
    latest["valuationAnchorPrice"] = anchor[1] if anchor else None
    latest["valuationAnchorDate"] = anchor[0] if anchor else None
    latest["upsideToBase"], latest["expectedReturn3Y"] = comparison(
        latest_price, latest.get("baseFairValue"), latest.get("targetPrice3Y"))
    payload["latest"] = latest
    payload["priceSource"] = {
        "source": last[2] if last else "sharadar_unavailable",
        "priceType": "RAW_CLOSE", "localOnly": True,
        "status": "available" if last else "missing"
    }
    if include_history:
        payload["priceHistory"] = [
            {"date": date, "close": close, "source": source, "priceType": "RAW_CLOSE"}
            for date, close, source in points
        ]
    else:
        payload.pop("priceHistory", None)
    for row in payload.get("history") or []:
        quoted = prior_price(index, row.get("asOfDate") or row.get("priceDate"))
        price = quoted[1] if quoted else None
        row["currentPrice"] = price
        row["priceAtDate"] = price
        row["priceDate"] = quoted[0] if quoted else None
        row["upsideDownside"], row["expectedReturn3Y"] = comparison(
            price, row.get("fairValue"), row.get("targetPrice3Y"))
        snapshot = row.get("dataSnapshot")
        if isinstance(snapshot, dict):
            snapshot["asOfPriceSource"] = {
                "priceDate": quoted[0] if quoted else None,
                "source": quoted[2] if quoted else "sharadar_unavailable",
                "priceType": "RAW_CLOSE"
            }
    quality = dict(payload.get("dataQuality") or {})
    quality.update({"canonicalPriceSource": "Sharadar Local Fact OS",
                    "pricePoints": len(points), "hasLivePriceSeries": bool(points)})
    payload["dataQuality"] = quality
    warnings = [str(item) for item in payload.get("warnings") or []
                if "yahoo" not in str(item).lower()]
    if not points:
        warnings.append(f"No exact Sharadar listing is available for {ticker}; no legacy price was substituted.")
    payload["warnings"] = list(dict.fromkeys(warnings))
    return payload


def migrate_valuations(db: sqlite3.Connection, generated_at: str) -> dict[str, Any]:
    if not table_exists(db, "valuation_ticker_snapshots"):
        return {"tickers": 0, "unsupported": []}
    indexes: dict[str, tuple[list[str], list[tuple]]] = {}
    migrated: dict[str, dict[str, Any]] = {}
    unsupported: list[str] = []
    rows = db.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker").fetchall()
    for ticker, raw in rows:
        payload = json.loads(raw)
        key = str(payload.get("ticker") or payload.get("key") or ticker).upper()
        indexes.setdefault(key, price_index(db, key))
        payload = migrate_valuation_payload(payload, indexes[key], True)
        if not indexes[key][1]:
            unsupported.append(key)
        migrated[ticker] = payload
        db.execute("""
          UPDATE valuation_ticker_snapshots SET generated_at=?,payload_json=? WHERE ticker=?
        """, (generated_at, json.dumps(payload, separators=(",", ":"), ensure_ascii=False), ticker))
    if table_exists(db, "valuation_snapshots"):
        for snapshot_id, raw in db.execute("SELECT id,payload_json FROM valuation_snapshots").fetchall():
            dashboard = json.loads(raw)
            next_tickers = []
            for item in dashboard.get("tickers") or []:
                key = str(item.get("ticker") or item.get("key") or "").upper()
                indexes.setdefault(key, price_index(db, key))
                next_tickers.append(migrate_valuation_payload(item, indexes[key], False))
            dashboard["tickers"] = next_tickers
            dashboard["generatedAt"] = generated_at
            source = dict(dashboard.get("source") or {})
            source["priceSource"] = "Sharadar Local Fact OS"
            source["priceGenerationPolicy"] = "exact SEP/SFP rows; no provider fallback"
            dashboard["source"] = source
            summary = dict(dashboard.get("summary") or {})
            latest_dates = [item.get("latest", {}).get("latestPriceDate") for item in next_tickers
                            if item.get("latest", {}).get("latestPriceDate")]
            summary["livePriceTickerCount"] = len(latest_dates)
            summary["latestPriceDate"] = max(latest_dates) if latest_dates else None
            dashboard["summary"] = summary
            db.execute("UPDATE valuation_snapshots SET generated_at=?,payload_json=? WHERE id=?",
                       (generated_at, json.dumps(dashboard, separators=(",", ":"), ensure_ascii=False), snapshot_id))
    return {"tickers": len(rows), "unsupported": sorted(set(unsupported))}


def migrate_dividends(db: sqlite3.Connection, fact: duckdb.DuckDBPyConnection,
                      cutoff: str, generated_at: str) -> dict[str, Any]:
    if not table_exists(db, "dividend_events"):
        return {"removedYahoo": 0, "insertedSharadar": 0}
    yahoo_tickers = [row[0] for row in db.execute("""
      SELECT DISTINCT ticker FROM dividend_events
      WHERE lower(COALESCE(source,'')) LIKE '%yahoo%' ORDER BY ticker
    """)]
    removed = db.execute("DELETE FROM dividend_events WHERE lower(COALESCE(source,'')) LIKE '%yahoo%'").rowcount
    if not yahoo_tickers:
        return {"removedYahoo": removed, "insertedSharadar": 0}
    fact.execute("CREATE TEMP TABLE dividend_symbols(symbol VARCHAR PRIMARY KEY)")
    fact.executemany("INSERT INTO dividend_symbols VALUES (?)", [(ticker,) for ticker in yahoo_tickers])
    rows = fact.execute("""
      SELECT a.ticker,a.name,CAST(a.date AS VARCHAR),a.value,a._observed_at
      FROM actions a JOIN dividend_symbols s ON s.symbol=a.ticker
      WHERE a.action='dividend' AND a.date BETWEEN CAST(? AS DATE)-INTERVAL 2 YEAR AND CAST(? AS DATE)
        AND a.value>0
      ORDER BY a.ticker,a.date
    """, [cutoff, cutoff]).fetchall()
    insert = db.cursor()
    for ticker, name, ex_date, amount, observed_at in rows:
        payload = {"provenance": {"dataset": "Sharadar ACTIONS", "observedAt": str(observed_at)},
                   "payDateStatus": "not_provided_by_source"}
        insert.execute("""
          INSERT OR REPLACE INTO dividend_events
          (ticker,company_name,ex_date,pay_date,record_date,declaration_date,amount,currency,
           status,source,source_label,logo_url,payload_json,updated_at)
          VALUES (?,?,?,NULL,NULL,NULL,?,'USD','historical',?,'Sharadar ACTIONS',NULL,?,?)
        """, (ticker, name, ex_date, amount, SHARADAR_ACTIONS,
              json.dumps(payload, separators=(",", ":")), str(observed_at or generated_at)))
    return {"removedYahoo": removed, "insertedSharadar": len(rows), "tickers": yahoo_tickers}


def delete_price_derived_caches(db: sqlite3.Connection) -> dict[str, int]:
    """Remove every curve built from the replaced all-Yahoo price table.

    Some older proxy rows used provider-neutral labels even though their actual
    observations came from price_points.  Provenance-string filtering is not
    sufficient, so the entire derived cache is invalidated and rebuilt.
    """
    deleted: dict[str, int] = {}
    for table in ("guru_backtests", "guru_backtest_proxies"):
        if not table_exists(db, table):
            continue
        deleted[table] = db.execute(f"DELETE FROM {table}").rowcount
    return deleted


PROVENANCE_KEYS = {
    "source", "sources", "provider", "providers", "sourcecontext", "sourcelabel",
    "pricesource", "latestpricesource", "upstreamsource", "priceprovider", "method",
    "methodology", "basis", "closebasis", "returnbasis", "documentationurl", "url"
}


def contains_yahoo_provenance(value: Any, parent_key: str = "") -> bool:
    if isinstance(value, dict):
        return any(contains_yahoo_provenance(child, str(key).lower()) for key, child in value.items())
    if isinstance(value, list):
        return any(contains_yahoo_provenance(child, parent_key) for child in value)
    normalized_key = re.sub(r"[^a-z]", "", parent_key.lower())
    return normalized_key in PROVENANCE_KEYS and bool(YAHOO_RE.search(str(value or "")))


def active_yahoo_counts(db: sqlite3.Connection) -> dict[str, int]:
    counts = {
        "price_points": db.execute("SELECT COUNT(*) FROM price_points WHERE lower(COALESCE(source,'')) LIKE '%yahoo%'").fetchone()[0],
        "dividend_events": db.execute("SELECT COUNT(*) FROM dividend_events WHERE lower(COALESCE(source,'')) LIKE '%yahoo%'").fetchone()[0],
    }
    for table in ("valuation_ticker_snapshots", "valuation_snapshots", "guru_backtests", "guru_backtest_proxies"):
        if table_exists(db, table):
            counts[table] = sum(
                contains_yahoo_provenance(json.loads(raw))
                for (raw,) in db.execute(f"SELECT payload_json FROM {table}").fetchall()
            )
    return counts


def main() -> None:
    args = parse_args()
    source, root, output, receipt = ensure_paths(args)
    dt.date.fromisoformat(args.cutoff)
    dt.datetime.fromisoformat(args.generated_at.replace("Z", "+00:00"))
    catalog = root / "manifests/catalog.json"
    initial_catalog = catalog.read_bytes()
    source_hash = sha256_file(source)
    copy_sqlite(source, output)
    before_db = sqlite3.connect(f"file:{source}?mode=ro", uri=True)
    before = source_summary(before_db)
    before_db.close()
    db = sqlite3.connect(output)
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA journal_mode=DELETE")
    try:
        with reader_lease(root):
            fact = duckdb.connect(str(root / "fact_os.duckdb"), read_only=True)
            try:
                db.execute("BEGIN IMMEDIATE")
                prices = rebuild_price_points(db, fact, args.cutoff, args.generated_at)
                valuations = migrate_valuations(db, args.generated_at)
                dividends = migrate_dividends(db, fact, args.cutoff, args.generated_at)
                removed_caches = delete_price_derived_caches(db)
                db.execute("COMMIT")
            except BaseException:
                db.execute("ROLLBACK")
                raise
            finally:
                fact.close()
            final_catalog = catalog.read_bytes()
            if final_catalog != initial_catalog:
                raise RuntimeError("Fact OS generation changed during migration")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.execute("VACUUM")
        db.execute("PRAGMA optimize")
        yahoo = active_yahoo_counts(db)
        if any(yahoo.values()):
            raise RuntimeError(f"active Yahoo rows remain: {yahoo}")
        integrity = db.execute("PRAGMA integrity_check").fetchone()[0]
        if integrity != "ok":
            raise RuntimeError(f"candidate integrity failed: {integrity}")
        after = source_summary(db)
    finally:
        db.close()
    payload = {
        "kind": "thesisforge_sharadar_research_migration_receipt",
        "generatedAt": args.generated_at,
        "cutoff": args.cutoff,
        "source": {"path": str(source), "bytes": source.stat().st_size, "sha256": source_hash},
        "factOs": {"root": str(root), "catalogSha256": sha256_bytes(initial_catalog)},
        "output": {"path": str(output), "bytes": output.stat().st_size, "sha256": sha256_file(output)},
        "before": before, "after": after, "prices": prices, "valuations": valuations,
        "dividends": dividends, "invalidatedPriceDerivedCaches": removed_caches,
        "activeYahooCounts": yahoo, "integrity": "ok",
        "policies": ["exact Sharadar SEP/SFP rows", "no interpolation or forward fill",
                     "unsupported listings fail closed", "user portfolio databases not opened"]
    }
    receipt.write_bytes(json_bytes(payload) + b"\n")
    os.chmod(receipt, 0o600)
    print(json.dumps(payload, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
