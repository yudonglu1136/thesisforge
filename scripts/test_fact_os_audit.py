import csv
import fcntl
import importlib.util
from pathlib import Path
import tempfile
import unittest

from fact_os.store import Store

spec = importlib.util.spec_from_file_location("fact_audit", Path(__file__).with_name("audit-fact-os.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class AuditTest(unittest.TestCase):
    def test_raw_anomaly_is_counted_and_explicitly_flagged(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            store = Store(root / "warehouse")
            store.install_contract("stocks", '''CREATE TABLE IF NOT EXISTS "stocks" (
                "ticker" TEXT, "date" TEXT, "close" REAL, "closeadj" REAL,
                "closeunadj" REAL, PRIMARY KEY ("ticker","date"));''')
            with (root / "source.csv").open("w", newline="") as source:
                writer = csv.writer(source)
                writer.writerow(["ticker", "date", "close", "closeadj", "closeunadj"])
                writer.writerow(["TEST", "2020-01-01", 2, 1, 0])
            store.ingest("stocks", root / "source.csv", scope="verified_full_bulk")
            result = audit.fact_inventory(store.root, full=True)["tables"]["stocks"]
            self.assertEqual(result["row_count"], 1)
            self.assertEqual(result["invalid_prices"], 1)
            self.assertEqual(result["flagged_source_rows"], 1)
            self.assertEqual(result["unflagged_invalid_price_rows"], 0)
            self.assertEqual(result["duplicate_key_excess"], 0)
            self.assertEqual(result["null_key_rows"], 0)

    def test_network_guard_rejects_socket_connect(self):
        import socket
        with audit.deny_network(), self.assertRaises(AssertionError):
            socket.create_connection(("127.0.0.1", 1))

    def test_audit_lease_prevents_retired_partition_gc(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "sync").mkdir()
            lock = root / "sync/readers.lock"
            with audit.reader_lease(root), lock.open("a") as collector:
                with self.assertRaises(BlockingIOError):
                    fcntl.flock(collector, fcntl.LOCK_EX | fcntl.LOCK_NB)
            with lock.open("a") as collector:
                fcntl.flock(collector, fcntl.LOCK_EX | fcntl.LOCK_NB)
                fcntl.flock(collector, fcntl.LOCK_UN)


if __name__ == "__main__":
    unittest.main()
