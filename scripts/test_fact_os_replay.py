"""Synthetic, local-only replay regressions. Never open the real Fact OS root."""
from contextlib import redirect_stdout
from datetime import datetime, timezone
import copy
import csv
import fcntl
import importlib.util
import io
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import duckdb

spec = importlib.util.spec_from_file_location("fact_os_replay", Path(__file__).with_name("verify-fact-os-replay.py"))
replay = importlib.util.module_from_spec(spec)
spec.loader.exec_module(replay)
from fact_os.store import Store, checksum


FIELDS = ["ticker", "date", "close", "closeadj", "closeunadj", "lastupdated"]


class ReplayTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="fact-replay-test-")
        self.root = Path(self.temporary.name).resolve() / "facts"
        self.started = datetime.now(timezone.utc).isoformat()
        self.store = Store(self.root)
        self.network = patch("socket.socket.connect", side_effect=AssertionError("offline fixture unexpectedly requested network"))
        self.network.start()
        self.tables = ("stocks", "funds")
        self.rows = {}
        for table in self.tables:
            ddl = f'CREATE TABLE IF NOT EXISTS "{table}" ("ticker" TEXT,"date" TEXT,"close" REAL,"closeadj" REAL,"closeunadj" REAL,"lastupdated" TEXT,PRIMARY KEY ("ticker","date"));'
            self.store.install_contract(table, ddl)
            self.rows[table] = {"ticker": "ABC", "date": "2000-01-03", "close": 4,
                                "closeadj": 3, "closeunadj": 8, "lastupdated": "2024-01-01"}
            self.put(table, self.rows[table], scope="verified_full_bulk")
        before = self.state()
        first = [self.put(table, self.rows[table]) for table in self.tables]
        first_state = self.state()
        self.latest = {table: {**row, "date": "2024-01-03", "close": 5} for table, row in self.rows.items()}
        second = [self.put(table, self.latest[table]) for table in self.tables]
        self.receipt = {"started_at": self.started, "finished_at": datetime.now(timezone.utc).isoformat(),
                        "scope": "local_only", "errors": [], "before": before,
                        "passes": [{"pass": 1, "results": first, "after": first_state},
                                   {"pass": 2, "results": second, "after": self.state()}],
                        "assertions": {"all_syncs_succeeded": True, "no_history_shrink": True,
                                       "second_pass_same_row_counts": False, "second_pass_same_date_coverage": False}}

    def tearDown(self):
        self.network.stop()
        self.temporary.cleanup()

    def put(self, table, row, scope="incremental"):
        contents = io.StringIO()
        writer = csv.DictWriter(contents, fieldnames=FIELDS)
        writer.writeheader()
        writer.writerow(row)
        source = self.root / "raw" / (table + "-fixture.csv")
        source.write_text(contents.getvalue())
        raw = self.root / "raw" / (table + "-sync-" + checksum(source) + ".csv")
        if raw.exists():
            source.unlink()
        else:
            source.rename(raw)
        return self.store.ingest(table, raw, scope=scope)

    def state(self):
        return {row["dataset"]: row for row in self.store.status()}

    def runs(self):
        with duckdb.connect(str(self.store.path), read_only=True) as db:
            return db.execute("SELECT count(*) FROM ingest_runs").fetchone()[0]

    def raw(self, table="stocks"):
        result = next(row for row in self.receipt["passes"][1]["results"] if row["dataset"] == table)
        with duckdb.connect(str(self.store.path), read_only=True) as db:
            return Path(db.execute("SELECT source_path FROM ingest_runs WHERE run_id=?", [result["run_id"]]).fetchone()[0])

    def fixture_quality_column(self, bucket, expression):
        """Change only a disposable fixture partition to an older schema/state."""
        catalog = replay.read_catalog(self.root)
        part = next(row for row in catalog["datasets"]["stocks"]["partitions"] if row["bucket"] == bucket)
        source = self.root / part["path"]
        temporary = source.with_name("fixture-schema-replacement.parquet")
        extension = "" if expression is None else ", " + expression + " AS _quality_issues"
        with duckdb.connect(":memory:") as db:
            db.execute("COPY (SELECT * EXCLUDE(_quality_issues)" + extension + " FROM read_parquet(" +
                       replay.literal(source) + ")) TO " + replay.literal(temporary) + " (FORMAT PARQUET)")
        temporary.replace(source)

    def assert_refused_before_ingestion(self, code, receipt=None):
        before = self.runs()
        files = replay.inventory(self.root)
        with patch.object(Store, "ingest", side_effect=AssertionError("must preflight all tables before ingestion")):
            with self.assertRaisesRegex(replay.ReplayRefused, code):
                replay.verify_replay(self.root, receipt or self.receipt, self.tables)
        self.assertEqual(self.runs(), before)
        self.assertEqual(replay.inventory(self.root), files)

    def test_same_input_replay_preserves_history_files_and_all_official_values(self):
        before, files = self.runs(), replay.inventory(self.root)
        report = replay.verify_replay(self.root, self.receipt, self.tables)
        self.assertTrue(report["passed"])
        self.assertTrue(report["not_a_substitute_for_live_sync"])
        self.assertEqual(self.runs(), before + 2 * len(self.tables))
        self.assertEqual(replay.inventory(self.root), files)
        self.assertEqual(report["before"]["stocks"], {"row_count": 2, "min_date": "2000-01-03", "max_date": "2024-01-03"})
        self.assertTrue(all(row["status"] == "unchanged" for record in report["passes"] for row in record["results"]))

    def test_old_input_cannot_overwrite_a_newer_revision(self):
        self.put("stocks", {**self.latest["stocks"], "lastupdated": "2024-02-01", "close": 9})
        self.assert_refused_before_ingestion("stale_or_missing_canonical_input:stocks")

    def test_mixed_partition_quality_schemas_match_store_without_rewriting_files(self):
        # Keep the other partition's quality column so global union_by_name
        # would fill the missing column with NULL and falsely reject equality.
        self.fixture_quality_column(2024, None)
        before = replay.inventory(self.root)
        report = replay.verify_replay(self.root, self.receipt, self.tables)
        self.assertTrue(report["passed"])
        self.assertEqual(replay.inventory(self.root), before)
        self.assertTrue(all(row["status"] == "unchanged" for record in report["passes"] for row in record["results"]))

    def test_actual_stored_null_quality_is_not_coalesced_to_empty(self):
        self.fixture_quality_column(2000, None)
        self.fixture_quality_column(2024, "NULL::VARCHAR")
        self.assert_refused_before_ingestion("stale_or_missing_canonical_input:stocks")

    def test_stored_quality_difference_still_blocks_replay(self):
        self.fixture_quality_column(2024, "'invalid_price:close'")
        self.assert_refused_before_ingestion("stale_or_missing_canonical_input:stocks")

    def test_last_table_preflight_failure_prevents_even_first_table_audit_writes(self):
        self.put("funds", {**self.latest["funds"], "closeadj": 3.5})
        self.assert_refused_before_ingestion("stale_or_missing_canonical_input:funds")

    def test_raw_path_outside_root_rejected_even_with_correct_bytes(self):
        outside = self.root.parent / "outside.csv"
        outside.write_bytes(self.raw().read_bytes())
        run = self.receipt["passes"][1]["results"][0]["run_id"]
        with self.store.writer() as db:
            db.execute("UPDATE ingest_runs SET source_path=? WHERE run_id=?", [str(outside), run])
        self.assert_refused_before_ingestion("unsafe_raw_path:stocks")

    def test_raw_symlink_and_checksum_tampering_rejected(self):
        raw = self.raw()
        original = raw.read_bytes()
        raw.write_bytes(original + b"\n")
        self.assert_refused_before_ingestion("raw_checksum_mismatch:stocks")
        raw.write_bytes(original)
        sibling = self.root / "raw" / "same-bytes.csv"
        sibling.write_bytes(original)
        raw.unlink()
        raw.symlink_to(sibling)
        self.assert_refused_before_ingestion("unsafe_raw_path:stocks")

    def test_job_lock_precedes_database_reads_and_spans_preflight(self):
        with (self.root / "sync/ingestion-job.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with patch.object(replay, "read_catalog", side_effect=AssertionError("must lock before reading catalog")):
                with self.assertRaisesRegex(replay.ReplayRefused, "ingestion_or_gc_lock_busy"):
                    replay.verify_replay(self.root, self.receipt, self.tables)
            fcntl.flock(lock, fcntl.LOCK_UN)

    def test_gc_exclusive_lease_is_not_bypassed(self):
        with (self.root / "sync/readers.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            self.assert_refused_before_ingestion("ingestion_or_gc_lock_busy")
            fcntl.flock(lock, fcntl.LOCK_UN)

    def test_incomplete_failed_missing_or_empty_live_results_rejected(self):
        variants = []
        data = copy.deepcopy(self.receipt); data.pop("finished_at"); variants.append((data, "completed_local_receipt_required"))
        data = copy.deepcopy(self.receipt); data["errors"] = [{"error": "fixture"}]; variants.append((data, "live_sync_errors"))
        data = copy.deepcopy(self.receipt); data["passes"][1]["results"].pop(); variants.append((data, "missing_or_duplicate_table"))
        data = copy.deepcopy(self.receipt); data["passes"][1]["results"][0]["status"] = "no_rows"; variants.append((data, "unsuccessful_live_result"))
        data = copy.deepcopy(self.receipt); data["passes"][1]["results"][0].pop("run_id"); variants.append((data, "live_run_id_required"))
        for data, code in variants:
            with self.subTest(code=code):
                self.assert_refused_before_ingestion(code, data)

    def test_current_failure_and_unverified_contract_fail_closed(self):
        self.store.record_error("stocks", "fixture_failure")
        self.assert_refused_before_ingestion("missing_or_unready_table:stocks")
        with self.store.writer() as db:
            db.execute("UPDATE sync_state SET last_error=NULL WHERE dataset='stocks'")
            db.execute("UPDATE contracts SET schema_hash=? WHERE dataset='stocks'", ["0" * 64])
        self.assert_refused_before_ingestion("official_contract_mismatch:stocks")

    def test_unverified_ingestion_scope_is_not_treated_as_live_source(self):
        run = self.receipt["passes"][1]["results"][0]["run_id"]
        with self.store.writer() as db:
            db.execute("UPDATE ingest_runs SET scope='archive_unverified' WHERE run_id=?", [run])
        self.assert_refused_before_ingestion("unverified_source_scope:stocks")

    def test_cli_saves_new_evidence_and_refuses_existing_output_before_ingest(self):
        source = self.root / "audit" / "live.json"
        source.parent.mkdir()
        source.write_text(json.dumps(self.receipt))
        output = source.with_name("replay.json")
        args = ["--root", str(self.root), "--receipt", str(source), "--output", str(output), "--tables", *self.tables]
        with redirect_stdout(io.StringIO()):
            self.assertEqual(replay.main(args), 0)
        contents = output.read_bytes()
        self.assertTrue(json.loads(contents)["passed"])
        with patch.object(Store, "ingest", side_effect=AssertionError("existing output must abort before ingestion")):
            with self.assertRaises(FileExistsError):
                replay.main(args)
        self.assertEqual(output.read_bytes(), contents)


if __name__ == "__main__":
    unittest.main()
