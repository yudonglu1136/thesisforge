#!/usr/bin/env python3
"""Read-only, reproducible migration evidence. Never queries an upstream API.

Prints schema/count/coverage metadata, never private portfolio rows or credentials.
Use --full for natural-key scans and --offline-probes for semantic service checks.
The canonical catalog is pinned at process start; concurrent sync cannot mix versions.
"""
from __future__ import annotations

import argparse
from collections import Counter
from contextlib import contextmanager
from datetime import datetime, timezone
import fcntl
import hashlib
import json
import math
from pathlib import Path
import socket
import sqlite3
import sys
import tempfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))


def sqlite_inventory(path):
    """SQLite URI mode=ro includes committed WAL without modifying source rows."""
    if not path.is_file():
        return {"path": str(path), "exists": False}
    with sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True) as db:
        tables = db.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name").fetchall()
        output = {}
        for (name,) in tables:
            safe = '"' + name.replace('"', '""') + '"'
            output[name] = {
                "row_count": db.execute(f"SELECT COUNT(*) FROM {safe}").fetchone()[0],
                "columns": [{"name": r[1], "type": r[2], "not_null": bool(r[3]), "key_order": r[5]}
                            for r in db.execute(f"PRAGMA table_info({safe})")],
            }
        return {"path": str(path), "exists": True, "bytes": path.stat().st_size,
                "quick_check": db.execute("PRAGMA quick_check").fetchone()[0], "tables": output}


@contextmanager
def deny_network():
    def denied(*_args, **_kwargs):
        raise AssertionError("Network connection attempted during local FactRepository query")
    with patch.object(socket, "create_connection", denied), patch.object(socket.socket, "connect", denied), patch.object(socket.socket, "connect_ex", denied):
        yield


@contextmanager
def reader_lease(root):
    """Use the repository's GC lock while a pinned audit reads old partitions."""
    path = root / "sync/readers.lock"
    if not path.parent.exists():
        yield
        return
    with path.open("a") as lease:
        fcntl.flock(lease, fcntl.LOCK_SH)
        try:
            yield
        finally:
            fcntl.flock(lease, fcntl.LOCK_UN)


def offline_probes(root):
    from fact_os.repository import FactRepository, PriceType, PITUnavailable
    cases = {}
    with deny_network():
        repo = FactRepository(root)
        try:
            tests = {
                "nvda_prices": lambda: repo.get_price_history("NVDA", "1900-01-01", "2100-01-01", PriceType.TOTAL_RETURN_ADJUSTED_CLOSE),
                "msft_fundamentals": lambda: repo.get_fundamentals("MSFT", "ART", as_of="2020-01-01"),
                "msft_dividends": lambda: repo.get_dividends("MSFT", "1900-01-01", "2100-01-01"),
                "googl_ownership": lambda: repo.get_institutional_ownership_history("GOOGL"),
            }
            for name, operation in tests.items():
                try:
                    rows = operation()
                    passed = bool(rows)
                    if name == "msft_fundamentals":
                        passed = passed and all(str(r.get("available_at", r.get("datekey", ""))) <= "2020-01-01" for r in rows)
                    cases[name] = {"passed": passed, "row_count": len(rows)}
                except Exception as exc:
                    cases[name] = {"passed": False, "error_type": type(exc).__name__}
            try:
                field_map = {PriceType.RAW_CLOSE: "closeunadj", PriceType.SPLIT_ADJUSTED_CLOSE: "close",
                             PriceType.TOTAL_RETURN_ADJUSTED_CLOSE: "closeadj"}
                source = repo.db.execute("SELECT date,closeunadj,close,closeadj FROM stocks WHERE ticker='NVDA' ORDER BY date").fetchall()
                mismatch = 0
                counts = {}
                for column_index, price_type in enumerate(field_map, start=1):
                    series = repo.get_price_history("NVDA", "1900-01-01", "2100-01-01", price_type)
                    counts[price_type.name] = len(series)
                    actual = {str(point["date"]): point["value"] for point in series}
                    expected = {str(row[0]): row[column_index] for row in source}
                    mismatch += len(set(actual) ^ set(expected))
                    mismatch += sum(actual[day] != expected[day] for day in set(actual) & set(expected))
                cases["nvda_full_history_price_semantics"] = {
                    "passed": bool(source) and mismatch == 0, "row_count": len(source),
                    "first_date": str(source[0][0]) if source else None,
                    "last_date": str(source[-1][0]) if source else None,
                    "fields": {kind.name: field for kind, field in field_map.items()},
                    "series_counts": counts, "mismatch_count": mismatch,
                    "raw_vs_split_differing_dates": sum(row[1] != row[2] for row in source),
                    "split_vs_total_return_differing_dates": sum(row[2] != row[3] for row in source),
                }
            except Exception as exc:
                cases["nvda_full_history_price_semantics"] = {"passed": False, "error_type": type(exc).__name__}
            try:
                history = repo.get_metric_history("MSFT", "MarketCap")
                source = {str(row[0]): row[1] for row in repo.db.execute(
                    "SELECT date,marketcap FROM daily WHERE ticker='MSFT' ORDER BY date").fetchall()}
                actual = {str(row["date"]): row for row in history}
                mismatches = len(set(actual) ^ set(source))
                for day in set(actual) & set(source):
                    expected = source[day] * 1000000 if source[day] is not None else None
                    fact = actual[day]
                    mismatches += not (fact["value"] == expected and fact["unit"] == "USD"
                        and fact["currency"] == "USD" and str(fact["available_at"]) == day
                        and fact["provenance"]["table"] == "daily")
                cutoff = "2020-01-01"
                historical = repo.get_metric("MSFT", "MarketCap", as_of=cutoff)
                expected_latest = max((day for day in source if day <= cutoff), default=None)
                passed = bool(source) and mismatches == 0 and historical is not None
                passed = passed and str(historical["date"]) == expected_latest
                cases["msft_daily_marketcap_units_and_history"] = {
                    "passed": passed, "row_count": len(source), "mismatch_count": mismatches,
                    "first_date": min(source) if source else None,
                    "last_date": max(source) if source else None,
                    "source_field": "daily.marketcap", "source_unit": "USD millions",
                    "canonical_unit": "USD", "scale": 1000000,
                    "historical_as_of": cutoff,
                    "historical_observation_date": historical["date"] if historical else None,
                    "null_source_values": sum(value is None for value in source.values()),
                    "availability_basis": "daily market observation date; not a historical vendor vintage",
                }
            except Exception as exc:
                cases["msft_daily_marketcap_units_and_history"] = {"passed": False, "error_type": type(exc).__name__}
            if "descriptions" in repo._datasets:
                try:
                    expected_units = {
                        ("DAILY", "marketcap"): "USD millions",
                        ("SF3A", "shrunits"): "unit thousands",
                        ("SF3A", "shrvalue"): "USD millions",
                        ("SF3B", "shrunits"): "unit thousands",
                        ("SF3B", "shrvalue"): "USD millions",
                        ("SF1", "revenue"): "currency",
                        **{(table, field): "USD/share" for table in ("SEP", "SFP")
                           for field in ("close", "closeadj", "closeunadj")},
                    }
                    dictionary = {(row[0], row[1]): (row[2], row[3]) for row in repo.db.execute(
                        'SELECT "table",indicator,unittype,title FROM descriptions').fetchall()}
                    mismatches = [f"{table}.{field}" for (table, field), unit in expected_units.items()
                                  if dictionary.get((table, field), (None, None))[0] != unit]
                    adjustment_titles_match = all(
                        "Split Adjusted" in dictionary.get((table, "close"), (None, ""))[1]
                        and "Splits Dividends and Spinoffs" in dictionary.get((table, "closeadj"), (None, ""))[1]
                        and "Unadjusted" in dictionary.get((table, "closeunadj"), (None, ""))[1]
                        for table in ("SEP", "SFP"))
                    cases["official_dictionary_price_and_metric_units"] = {
                        "passed": not mismatches and adjustment_titles_match,
                        "checked_definitions": len(expected_units), "mismatched_units": mismatches,
                        "adjustment_titles_match": adjustment_titles_match,
                    }
                except Exception as exc:
                    cases["official_dictionary_price_and_metric_units"] = {"passed": False, "error_type": type(exc).__name__}
            try:
                latest_quarter = repo.db.execute("SELECT max(date) FROM holdings WHERE ticker='GOOGL'").fetchone()[0]
                changes = repo.get_holder_changes("GOOGL", str(latest_quarter))
                classes = Counter(row["change"] for row in changes)
                source_quarter = lambda quarter: {(row[0], row[1]): (row[2], row[3]) for row in repo.db.execute(
                    "SELECT investorid,securitytype,units*1000,value*1000000 FROM holdings WHERE ticker='GOOGL' AND securitytype='SHR' AND date=?",
                    [quarter]).fetchall()}
                old = source_quarter(changes[0]["previous_quarter"]) if changes else {}
                new = source_quarter(latest_quarter)
                valid = bool(changes)
                for row in changes:
                    before, after = row["previous_units"], row["current_units"]
                    key = (row["investor_id"], row["security_type"])
                    expected = ("NEW" if key not in old else "EXITED" if key not in new else
                                "INCREASED" if after > before else "DECREASED" if after < before else "UNCHANGED")
                    valid = valid and before == old.get(key, (0, 0))[0] and after == new.get(key, (0, 0))[0]
                    valid = valid and row["previous_value_usd"] == old.get(key, (0, 0))[1] and row["current_value_usd"] == new.get(key, (0, 0))[1]
                    valid = valid and row["unit_change"] == after - before and row["change"] == expected
                    valid = valid and row["available_at"] is None and row["pit_supported"] is False
                conserved = math.isclose(sum(row["unit_change"] for row in changes),
                    sum(row[0] for row in new.values()) - sum(row[0] for row in old.values()), rel_tol=1e-10, abs_tol=1e-5)
                cases["googl_holder_changes"] = {"passed": valid, "quarter": str(latest_quarter),
                    "row_count": len(changes), "classifications": dict(sorted(classes.items())),
                    "unique_holder_keys": len({(row["investor_id"], row["security_type"]) for row in changes}),
                    "source_holder_key_union": len(old.keys() | new.keys()),
                    "unit_change_conservation": conserved}
                cases["googl_holder_changes"]["passed"] = valid and conserved and len(changes) == len(old.keys() | new.keys())
                try:
                    repo.get_holder_changes("GOOGL", str(latest_quarter), as_of="2026-09-18")
                    cases["holdings_does_not_fabricate_filing_pit"] = {"passed": False}
                except PITUnavailable:
                    cases["holdings_does_not_fabricate_filing_pit"] = {"passed": True}
            except Exception as exc:
                cases["googl_holder_changes"] = {"passed": False, "error_type": type(exc).__name__}
            try:
                repo.get_fundamentals("MSFT", "MRT", as_of="2020-01-01")
                cases["pit_rejects_restated"] = {"passed": False}
            except PITUnavailable:
                cases["pit_rejects_restated"] = {"passed": True}
            except Exception as exc:
                cases["pit_rejects_restated"] = {"passed": False, "error_type": type(exc).__name__}
        finally:
            repo.close()
    return cases


def fact_inventory(root, full=False, datasets=None):
    import duckdb
    from fact_os.contracts import Contract, REQUIRED, ident
    catalog = root / "manifests/catalog.json"
    if not catalog.is_file():
        return {"path": str(root), "exists": False, "missing_required": list(REQUIRED)}
    manifest = json.loads(catalog.read_text())
    output = {"path": str(root), "exists": True, "catalog_version": manifest.get("version"), "tables": {}}
    with tempfile.TemporaryDirectory(prefix="tf-fact-audit-") as tmp, duckdb.connect(":memory:") as db:
        db.execute("SET memory_limit='2GB'; SET threads=2")
        db.execute("SET temp_directory='" + tmp.replace("'", "''") + "'")
        for table, entry in manifest["datasets"].items():
            if datasets and table not in datasets:
                continue
            contract = Contract.from_ddl(table, entry["ddl"])
            files = [(root / p["path"]).resolve() for p in entry.get("partitions", [])]
            if any(not p.is_relative_to(root.resolve()) for p in files):
                raise ValueError("Manifest partition escaped Fact OS root")
            item = {"natural_key": list(contract.keys), "schema_hash": contract.digest,
                    "column_count": len(contract.columns), "partitions": len(files), "sync_state": entry.get("state")}
            output["tables"][table] = item
            if not files:
                item["present"] = False
                continue
            item["present"] = True
            item["parquet_bytes"] = sum(p.stat().st_size for p in files)
            paths = "[" + ",".join("'" + str(p).replace("'", "''") + "'" for p in files) + "]"
            db.execute(f"CREATE VIEW {ident(table)} AS SELECT * FROM read_parquet({paths}, union_by_name=true)")
            columns = {c[0] for c in contract.columns}
            actual_columns = {c[0] for c in db.execute(f"DESCRIBE {ident(table)}").fetchall()}
            quality_flag = "COALESCE(_quality_issues,'')" if "_quality_issues" in actual_columns else "''"
            item["row_count"] = db.execute(f"SELECT COUNT(*) FROM {ident(table)}").fetchone()[0]
            item["state_row_count_matches"] = item["row_count"] == (entry.get("state") or {}).get("row_count")
            if "_quality_issues" in actual_columns:
                item["flagged_source_rows"] = db.execute(f"SELECT COUNT(*) FROM {ident(table)} WHERE {quality_flag}<>''").fetchone()[0]
            item["dates"] = {}
            for column in ("date", "reportperiod", "calendardate", "lastupdated"):
                if column in columns:
                    values = db.execute(f"SELECT MIN({ident(column)}),MAX({ident(column)}) FROM {ident(table)}").fetchone()
                    item["dates"][column] = {"min": values[0], "max": values[1]}
            if table == "fundamentals":
                item["dimensions"] = dict(db.execute("SELECT dimension,COUNT(*) FROM fundamentals GROUP BY dimension ORDER BY dimension").fetchall())
                item["ar_period_after_available"] = db.execute("SELECT COUNT(*) FROM fundamentals WHERE dimension LIKE 'AR%' AND reportperiod>date").fetchone()[0]
                item["unflagged_invalid_pit_rows"] = db.execute(f"SELECT COUNT(*) FROM fundamentals WHERE dimension LIKE 'AR%' AND reportperiod>date AND NOT contains({quality_flag},'invalid_pit_period')").fetchone()[0]
            if table in ("stocks", "funds"):
                invalids = [f"({field} IS NULL OR {field}<=0 OR NOT isfinite({field}))" for field in ("close", "closeadj", "closeunadj")]
                item["invalid_prices"] = db.execute(f"SELECT COUNT(*) FROM {ident(table)} WHERE {' OR '.join(invalids)}").fetchone()[0]
                unflagged = [f"({invalid} AND NOT contains({quality_flag},'invalid_price:{field}'))"
                             for invalid, field in zip(invalids, ("close", "closeadj", "closeunadj"))]
                item["unflagged_invalid_price_rows"] = db.execute(f"SELECT COUNT(*) FROM {ident(table)} WHERE {' OR '.join(unflagged)}").fetchone()[0]
            if table == "holdings":
                item["security_types"] = dict(db.execute("SELECT securitytype,COUNT(*) FROM holdings GROUP BY securitytype ORDER BY securitytype").fetchall())
            if full:
                keys = ','.join(ident(k) for k in contract.keys)
                item["duplicate_key_excess"] = db.execute(f"SELECT COALESCE(SUM(n-1),0) FROM (SELECT COUNT(*) n FROM {ident(table)} GROUP BY {keys} HAVING COUNT(*)>1)").fetchone()[0]
                nulls = ' OR '.join(f'{ident(k)} IS NULL' for k in contract.keys)
                item["null_key_rows"] = db.execute(f"SELECT COUNT(*) FROM {ident(table)} WHERE {nulls}").fetchone()[0]
    present = {t for t, entry in manifest["datasets"].items() if entry.get("partitions")}
    output["missing_required"] = sorted(set(REQUIRED) - present)
    output["incomplete_backfills"] = sorted(t for t in REQUIRED if not (manifest["datasets"].get(t, {}).get("state") or {}).get("backfill_complete"))
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=ROOT / "data/fact_os")
    parser.add_argument("--sqlite-inventory", action="store_true")
    parser.add_argument("--full", action="store_true")
    parser.add_argument("--tables", nargs="+")
    parser.add_argument("--offline-probes", action="store_true")
    parser.add_argument("--require-complete", action="store_true", help="Exit nonzero for missing required tables, unfinished full backfills or failed checks")
    parser.add_argument("--output", type=Path, help="Also save a new local JSON evidence file (refuses overwrite)")
    args = parser.parse_args()
    catalog_path = args.root.resolve() / "manifests/catalog.json"
    initial_catalog = catalog_path.read_bytes() if catalog_path.exists() else b""
    output = {"generated_at": datetime.now(timezone.utc).isoformat(), "project": str(ROOT),
              "scope": "local read-only audit; no portfolio payloads, credentials, or network queries"}
    if args.sqlite_inventory:
        output["legacy_databases"] = [sqlite_inventory(ROOT / "server/data" / name) for name in
                                      ("guru-analysis.sqlite", "valuation-pit-source.sqlite", "ontology-snapshot.sqlite")]
        private_root = ROOT / "server/data/user-portfolios"
        output["private_boundary"] = {"path": str(private_root), "present": private_root.exists(),
                                       "user_portfolio_database_count": len(list(private_root.glob("*/portfolio.sqlite"))),
                                       "action": "not opened, not migrated"}
    with reader_lease(args.root.resolve()):
        output["fact_os"] = fact_inventory(args.root.resolve(), args.full, args.tables)
        if args.offline_probes:
            output["offline_probes"] = offline_probes(args.root.resolve())
    failures = []
    final_catalog = catalog_path.read_bytes() if catalog_path.exists() else b""
    output["source_generation"] = {"catalog_sha256": hashlib.sha256(initial_catalog).hexdigest(),
                                   "stable_during_audit": initial_catalog == final_catalog}
    if initial_catalog != final_catalog:
        failures.append("catalog_changed_during_audit:rerun_after_ingestion_completes")
    for label in ("missing_required", "incomplete_backfills"):
        failures.extend(f"{label}:{table}" for table in output["fact_os"].get(label, []))
    for table, item in output["fact_os"].get("tables", {}).items():
        if item.get("present") and not (item.get("sync_state") or {}).get("backfill_complete"):
            failures.append(f"{table}:incomplete_present_backfill")
        if (item.get("sync_state") or {}).get("last_error"):
            failures.append(f"{table}:unresolved_sync_error")
        if item.get("state_row_count_matches") is False:
            failures.append(f"{table}:catalog_count_mismatch")
        for check in ("duplicate_key_excess", "null_key_rows", "unflagged_invalid_price_rows", "unflagged_invalid_pit_rows"):
            if item.get(check, 0):
                failures.append(f"{table}:{check}:{item[check]}")
    failures.extend(f"offline:{name}" for name, result in output.get("offline_probes", {}).items() if not result["passed"])
    output["validation"] = {"passed": not failures, "failures": failures, "full_key_scan": args.full}
    serialized = json.dumps(output, default=str, indent=2)
    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("x") as result:
            result.write(serialized + "\n")
    print(serialized)
    if args.require_complete and failures:
        raise SystemExit(2)


if __name__ == "__main__":
    main()
