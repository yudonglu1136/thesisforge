#!/usr/bin/env python3
"""Offline same-input replay evidence; NOT a replacement for two real API syncs.

Only a completed, successful two-pass live receipt is eligible. Static equality
of two *different upstream extracts* is deliberately not required: the provider
may have added records. Every recorded second-pass input must already equal the
current canonical facts before any Store.ingest call is allowed. Existing raw
inputs and Parquet files are never intentionally changed; Store still creates
new ingestion audit receipts and updates observation timestamps as usual.

An explicit --root is required. No API client, credential loader, or network
library is imported. Run under an OS network-denial sandbox for extra assurance.
"""
from contextlib import contextmanager, ExitStack
from datetime import datetime, timezone
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import zipfile

import duckdb

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fact_os.contracts import Contract, TABLES, ident
from fact_os.store import Store, checksum, literal


class ReplayRefused(RuntimeError):
    """Credential-free error code; never include a vendor response or raw row."""


def require(condition, code):
    if not condition:
        raise ReplayRefused(code)


def normalized(value):
    return json.loads(json.dumps(value, default=str))


def validate_receipt(receipt, tables):
    require(tables and len(set(tables)) == len(tables) and set(tables) <= set(TABLES), "invalid_table_set")
    require(receipt.get("scope") == "local_only" and receipt.get("finished_at"), "completed_local_receipt_required")
    try:
        start, finish = (datetime.fromisoformat(receipt[key]) for key in ("started_at", "finished_at"))
        require(start.tzinfo is not None and finish.tzinfo is not None and start <= finish, "invalid_receipt_times")
    except (KeyError, TypeError, ValueError):
        raise ReplayRefused("invalid_receipt_times") from None
    require(receipt.get("errors") == [], "live_sync_errors")
    assertions = receipt.get("assertions", {})
    require(assertions.get("all_syncs_succeeded") is True and assertions.get("no_history_shrink") is True,
            "live_success_and_history_assertions_required")
    for name in ("second_pass_same_row_counts", "second_pass_same_date_coverage"):
        require(type(assertions.get(name)) is bool, "completed_live_assertions_required")
    passes = receipt.get("passes", [])
    require(len(passes) == 2 and [row.get("pass") for row in passes] == [1, 2], "two_complete_passes_required")
    prior = receipt.get("before", {})
    for record in passes:
        results = record.get("results", [])
        require(len(results) == len(tables) and {row.get("dataset") for row in results} == set(tables), "missing_or_duplicate_table")
        for row in results:
            table = row["dataset"]
            require(not row.get("error") and row.get("status") in ("ingested", "unchanged"), "unsuccessful_live_result:" + table)
            require(re.fullmatch(r"[a-f0-9]{32}", str(row.get("run_id", ""))), "live_run_id_required:" + table)
            state = record.get("after", {}).get(table, {})
            old = prior.get(table, {})
            require(state.get("backfill_complete") is True and not state.get("last_error"), "incomplete_or_failed_state:" + table)
            require(type(state.get("row_count")) is int and type(old.get("row_count")) is int
                    and state["row_count"] >= old["row_count"] > 0, "history_shrunk:" + table)
            require(not old.get("min_date") or (state.get("min_date") and state["min_date"] <= old["min_date"]), "history_shrunk:" + table)
            require(not old.get("max_date") or (state.get("max_date") and state["max_date"] >= old["max_date"]), "history_shrunk:" + table)
        prior = record["after"]
    return {row["dataset"]: row for row in passes[1]["results"]}


def local_file(path, parent, code):
    path, parent = Path(path), Path(parent).resolve()
    # Reject symlinks even when their destination happens to be inside the tree.
    require(path.is_absolute() and path.is_file(), code)
    resolved = path.resolve()
    require(resolved.is_relative_to(parent) and resolved != parent, code)
    require(not any(part.is_symlink() for part in [path, *path.parents] if part != parent.parent), code)
    return resolved


@contextmanager
def locks(root):
    # Same order/protocol as normal ingestion. The job lease spans metadata,
    # every preflight, and both replay rounds; GC cannot remove pinned files.
    with ExitStack() as stack:
        for name, mode in (("ingestion-job.lock", fcntl.LOCK_EX), ("readers.lock", fcntl.LOCK_SH)):
            path = root / "sync" / name
            require(not path.is_symlink(), "unsafe_lock_path")
            lock = stack.enter_context(path.open("a"))
            try:
                fcntl.flock(lock, mode | fcntl.LOCK_NB)
            except BlockingIOError:
                raise ReplayRefused("ingestion_or_gc_lock_busy") from None
            stack.callback(fcntl.flock, lock, fcntl.LOCK_UN)
        yield


def read_catalog(root):
    path = local_file(root / "manifests/catalog.json", root / "manifests", "missing_or_unsafe_catalog")
    catalog = json.loads(path.read_text())
    require(catalog.get("version") == 1 and isinstance(catalog.get("datasets"), dict), "unsupported_catalog")
    return catalog


def parquet_paths(root, table, entry):
    paths = []
    for part in entry.get("partitions", []):
        relative = Path(part["path"])
        require(not relative.is_absolute() and ".." not in relative.parts, "unsafe_partition_path:" + table)
        paths.append(local_file(root / relative, root / "parquet" / table, "unsafe_partition_path:" + table))
    require(paths and len(set(paths)) == len(paths), "missing_or_duplicate_partition:" + table)
    return paths


def raw_metadata(root, catalog, results, receipt):
    path = local_file(root / "fact_os.duckdb", root, "missing_or_unsafe_catalog_database")
    plans = []
    # Close this read-only connection before Store obtains its writer connection.
    with duckdb.connect(str(path), read_only=True, config={"autoload_known_extensions": False,
                                                        "autoinstall_known_extensions": False}) as db:
        for table, result in results.items():
            entry = catalog["datasets"].get(table)
            require(entry and entry.get("state", {}).get("backfill_complete") is True
                    and not entry["state"].get("last_error"), "missing_or_unready_table:" + table)
            contract_row = db.execute("SELECT ddl,schema_hash FROM contracts WHERE dataset=?", [table]).fetchone()
            require(contract_row and contract_row[0] == entry.get("ddl"), "official_contract_mismatch:" + table)
            contract = Contract.from_ddl(table, contract_row[0])
            require(contract.digest == contract_row[1], "official_contract_mismatch:" + table)
            parts = db.execute("SELECT bucket,path FROM partitions WHERE dataset=? ORDER BY bucket", [table]).fetchall()
            require(normalized(parts) == [[p["bucket"], p["path"]] for p in entry.get("partitions", [])], "catalog_database_mismatch:" + table)
            require("date" in contract.keys or all(bucket == 0 for bucket, _ in parts), "repartition_required:" + table)
            state_cursor = db.execute("SELECT * FROM sync_state WHERE dataset=?", [table])
            state_row = state_cursor.fetchone()
            state = dict(zip([column[0] for column in state_cursor.description], state_row)) if state_row else None
            require(normalized(state) == entry["state"], "catalog_database_mismatch:" + table)
            row = db.execute("SELECT dataset,checksum,source_path,row_count,schema_hash,scope,observed_at FROM ingest_runs WHERE run_id=?",
                             [result["run_id"]]).fetchone()
            require(row and row[0] == table and row[4] == contract.digest, "recorded_run_contract_mismatch:" + table)
            require(row[5] in ("incremental", "verified_full_bulk"), "unverified_source_scope:" + table)
            require(type(row[3]) is int and row[3] > 0 and row[3] == result.get("input_rows"), "recorded_input_count_mismatch:" + table)
            require(re.fullmatch(r"[a-f0-9]{64}", str(row[1])), "invalid_raw_checksum:" + table)
            observed = datetime.fromisoformat(row[6])
            require(datetime.fromisoformat(receipt["started_at"]) <= observed <= datetime.fromisoformat(receipt["finished_at"]),
                    "recorded_run_outside_receipt:" + table)
            raw = local_file(Path(row[2]), root / "raw", "unsafe_raw_path:" + table)
            require(checksum(raw) == row[1], "raw_checksum_mismatch:" + table)
            plans.append({"table": table, "path": raw, "checksum": row[1], "scope": row[5],
                          "input_rows": row[3], "contract": contract, "run_id": result["run_id"],
                          "partitions": parquet_paths(root, table, entry)})
    return plans


def read_relation(paths):
    return "read_parquet([" + ",".join(literal(path) for path in paths) + "],union_by_name=true)"


def canonical_relation(plan, db):
    """Match Store's per-partition schema extension, not union-created NULLs.

    Older partitions may lack the derived quality column entirely. Store adds
    an empty string to that partition before comparing; union_by_name alone
    would instead manufacture NULL when a newer partition has the column.
    A NULL actually stored in a present quality column must remain NULL.
    """
    if plan["table"] not in ("stocks", "funds", "fundamentals"):
        return read_relation(plan["partitions"])
    groups = {True: [], False: []}
    required = {col for col, _ in plan["contract"].columns} | {"_ingestion_run", "_observed_at"}
    for path in plan["partitions"]:
        columns = {row[0] for row in db.execute("DESCRIBE SELECT * FROM " + read_relation([path])).fetchall()}
        require(required <= columns, "canonical_schema_mismatch:" + plan["table"])
        groups["_quality_issues" in columns].append(path)
    relations = []
    for has_quality, paths in groups.items():
        if paths:
            extension = "" if has_quality else ", ''::VARCHAR AS _quality_issues"
            relations.append("SELECT *" + extension + " FROM " + read_relation(paths))
    return "(" + " UNION ALL BY NAME ".join(relations) + ")"


def check_same_input(plan, db, scratch):
    table, contract, source = plan["table"], plan["contract"], plan["path"]
    if zipfile.is_zipfile(source):
        with zipfile.ZipFile(source) as archive:
            members = [entry for entry in archive.infolist() if entry.filename.lower().endswith(".csv") and not entry.is_dir()]
            require(len(members) == 1, "invalid_raw_archive:" + table)
            require(members[0].file_size + 5 * 1024**3 < shutil.disk_usage(scratch).free, "insufficient_preflight_disk")
            source = scratch / (table + ".csv")
            with archive.open(members[0]) as src, source.open("xb") as dest:
                shutil.copyfileobj(src, dest, 1024 * 1024)
    db.execute("CREATE OR REPLACE TEMP VIEW landing AS SELECT * FROM read_csv(" + literal(source) + ",header=true,all_varchar=true,nullstr='\\N')")
    require({row[0] for row in db.execute("DESCRIBE landing").fetchall()} == {col for col, _ in contract.columns}, "raw_schema_mismatch:" + table)
    expressions = []
    for col, kind in contract.columns:
        expression = ident(col) if kind == "VARCHAR" else "NULLIF(" + ident(col) + ",'')"
        expressions.append(f"CAST({expression} AS {kind}) AS {ident(col)}")
    db.execute("CREATE OR REPLACE TEMP TABLE incoming AS SELECT " + ",".join(expressions) + " FROM landing")
    require(db.execute("SELECT count(*) FROM incoming").fetchone()[0] == plan["input_rows"], "raw_row_count_mismatch:" + table)
    keys = ",".join(map(ident, contract.keys))
    require(not db.execute("SELECT 1 FROM incoming WHERE " + " OR ".join(ident(key) + " IS NULL" for key in contract.keys) + " LIMIT 1").fetchone(), "raw_null_key:" + table)
    require(not db.execute(f"SELECT 1 FROM incoming GROUP BY {keys} HAVING count(*)>1 LIMIT 1").fetchone(), "raw_duplicate_key:" + table)
    db.execute("CREATE OR REPLACE TEMP VIEW current AS SELECT * FROM " + canonical_relation(plan, db))
    current_columns = {row[0] for row in db.execute("DESCRIBE current").fetchall()}
    require({col for col, _ in contract.columns} | {"_ingestion_run", "_observed_at"} <= current_columns, "canonical_schema_mismatch:" + table)
    different = [f"n.{ident(col)} IS DISTINCT FROM p.{ident(col)}" for col, _ in contract.columns]
    # Store also compares derived quality flags. Check these before allowing a
    # replay, so an old flag/schema migration cannot cause an unexpected write.
    flags = []
    if table in ("stocks", "funds"):
        flags = [f"CASE WHEN n.{field} IS NULL OR n.{field}<=0 OR NOT isfinite(n.{field}) THEN 'invalid_price:{field}' ELSE NULL END"
                 for field in ("close", "closeadj", "closeunadj")]
    elif table == "fundamentals":
        flags = ["CASE WHEN n.dimension LIKE 'AR%' AND n.reportperiod>n.date THEN 'invalid_pit_period' ELSE NULL END"]
    if flags:
        prior_flags = "p._quality_issues" if "_quality_issues" in current_columns else "''"
        different.append("concat_ws(';'," + ",".join(flags) + ") IS DISTINCT FROM " + prior_flags)
    equal_keys = " AND ".join(f"n.{ident(key)}=p.{ident(key)}" for key in contract.keys)
    count, mismatches = db.execute("SELECT count(*),count(*) FILTER (WHERE " + " OR ".join(different) +
                                  ") FROM incoming n LEFT JOIN current p ON " + equal_keys).fetchone()
    require(count == plan["input_rows"] and mismatches == 0, "stale_or_missing_canonical_input:" + table)
    db.execute("DROP VIEW current; DROP TABLE incoming; DROP VIEW landing")


def inventory(root):
    result = {}
    for base, dirs, names in os.walk(root / "parquet", followlinks=False):
        require(not any((Path(base) / name).is_symlink() for name in dirs + names), "unsafe_parquet_symlink")
        for name in names:
            path = Path(base) / name
            stat = path.stat()
            result[str(path.relative_to(root))] = {"bytes": stat.st_size, "mtime_ns": stat.st_mtime_ns, "sha256": checksum(path)}
    return result


def coverage(root, catalog, plans, db):
    result = {}
    for plan in plans:
        table, contract = plan["table"], plan["contract"]
        entry = catalog["datasets"][table]
        columns = dict(contract.columns)
        date_col = "date" if "date" in columns else "lastupdated" if "lastupdated" in columns else None
        dates = f"min({ident(date_col)}),max({ident(date_col)})" if date_col else "NULL,NULL"
        count, lo, hi = db.execute("SELECT count(*)," + dates + " FROM " + read_relation(parquet_paths(root, table, entry))).fetchone()
        observed = {"row_count": count, "min_date": str(lo) if lo is not None else None, "max_date": str(hi) if hi is not None else None}
        require(observed == {key: entry["state"].get(key) for key in observed}, "canonical_coverage_mismatch:" + table)
        result[table] = observed
    return result


def verify_replay(root, receipt, tables=TABLES):
    results = validate_receipt(receipt, tuple(tables))
    root = Path(root).resolve()
    require(root.is_dir() and all((root / name).is_dir() and not (root / name).is_symlink()
                                 for name in ("raw", "parquet", "manifests", "sync", "staging")), "existing_local_root_required")
    with locks(root), tempfile.TemporaryDirectory(prefix="fact-os-replay-preflight-") as temporary:
        catalog = read_catalog(root)
        plans = raw_metadata(root, catalog, results, receipt)
        before_files = inventory(root)
        with duckdb.connect(":memory:", config={"autoload_known_extensions": False, "autoinstall_known_extensions": False}) as db:
            db.execute("SET memory_limit='512MB'; SET threads=2; SET enable_progress_bar=false")
            db.execute("SET temp_directory=" + literal(Path(temporary) / "spill"))
            before = coverage(root, catalog, plans, db)
            for plan in plans:
                check_same_input(plan, db, Path(temporary))
            for table, value in before.items():
                prior = receipt["passes"][1]["after"][table]
                require(value["row_count"] >= prior["row_count"]
                        and (not prior.get("min_date") or value["min_date"] <= prior["min_date"])
                        and (not prior.get("max_date") or value["max_date"] >= prior["max_date"]), "history_shrunk_since_live_receipt:" + table)
            require(read_catalog(root) == catalog and inventory(root) == before_files, "canonical_changed_during_preflight")
            # All tables have passed; only now permit Store's audit writes.
            store = Store(root)
            rounds = []
            for number in (1, 2):
                round_results = []
                for plan in plans:
                    require(checksum(plan["path"]) == plan["checksum"], "raw_changed_after_preflight:" + plan["table"])
                    result = store.ingest(plan["table"], plan["path"], scope=plan["scope"])
                    require(result.get("status") == "unchanged", "unexpected_non_noop_ingestion:" + plan["table"])
                    round_results.append(result)
                after_catalog = read_catalog(root)
                require({table: entry["partitions"] for table, entry in after_catalog["datasets"].items()} ==
                        {table: entry["partitions"] for table, entry in catalog["datasets"].items()}, "partition_paths_changed")
                require(inventory(root) == before_files, "parquet_files_changed")
                after = coverage(root, after_catalog, plans, db)
                require(after == before, "replay_coverage_changed")
                rounds.append({"pass": number, "results": round_results, "after": after})
        return {"finished_at": datetime.now(timezone.utc).isoformat(), "scope": "offline_same_input_replay_only",
                "not_a_substitute_for_live_sync": True, "passed": True,
                "inputs": [{"dataset": plan["table"], "live_run_id": plan["run_id"], "checksum": plan["checksum"],
                            "schema_hash": plan["contract"].digest, "scope": plan["scope"], "input_rows": plan["input_rows"]} for plan in plans],
                "before": before, "passes": rounds,
                "parquet": {"files": len(before_files), "bytes": sum(row["bytes"] for row in before_files.values()),
                            "inventory_sha256": hashlib.sha256(json.dumps(before_files, sort_keys=True).encode()).hexdigest()},
                "assertions": {name: True for name in ("all_inputs_equal_before_any_ingestion", "both_replays_unchanged",
                    "same_row_counts_and_dates", "all_parquet_paths_and_files_unchanged", "no_history_shrink")},
                "writes": "Ingestion audit receipts and observation metadata only; raw inputs and Parquet facts unchanged"}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--receipt", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--tables", nargs="+", choices=TABLES, default=list(TABLES))
    args = parser.parse_args(argv)
    require(args.output.suffix == ".json" and args.output.resolve().is_relative_to(args.root.resolve() / "audit"), "output_must_be_new_audit_json")
    args.output.parent.mkdir(parents=True, exist_ok=True)
    # Reserve exclusively BEFORE performing any ingestion; never overwrite an
    # earlier report, including a failed run's evidence.
    with args.output.open("x") as stream:
        try:
            receipt_bytes = args.receipt.read_bytes()
            report = verify_replay(args.root, json.loads(receipt_bytes), args.tables)
            report["live_receipt_sha256"] = hashlib.sha256(receipt_bytes).hexdigest()
        except Exception as exc:
            report = {"passed": False, "scope": "offline_same_input_replay_only",
                      "error": str(exc) if isinstance(exc, ReplayRefused) else type(exc).__name__}
        json.dump(report, stream, indent=2, default=str)
        stream.write("\n")
    print(json.dumps({"output": str(args.output), "passed": report["passed"], "error": report.get("error")}))
    return 0 if report["passed"] else 1


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (ReplayRefused, FileExistsError) as exc:
        print(json.dumps({"passed": False, "error": str(exc) if isinstance(exc, ReplayRefused) else "output_already_exists"}))
        raise SystemExit(1)
