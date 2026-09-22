import hashlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("storage_audit", Path(__file__).with_name("audit-fact-os-storage.py"))
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class StorageAuditTests(unittest.TestCase):
    def test_snapshot_hardlink_does_not_double_count_allocated_capacity(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder);(root/'original').write_bytes(b'1234')
            os.link(root/'original',root/'snapshot')
            entries,_=audit.files_under(root)
            total=audit.totals(entries)
            self.assertEqual(total['logical_bytes'],8)
            self.assertEqual(total['unique_file_inodes'],1)
            self.assertEqual(total['allocated_bytes'],(root/'original').stat().st_blocks*512)

    def test_retained_generations_are_not_current_rows_and_no_deletion(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for child in ("sync", "manifests", "raw", "parquet/stocks"):
                (root / child).mkdir(parents=True)
            data = b"source data"
            sha = hashlib.sha256(data).hexdigest()
            (root / f"raw/stocks-{sha}.zip").write_bytes(data)
            current = "parquet/stocks/2026-" + "a" * 32 + ".parquet"
            retained = "parquet/stocks/2026-" + "b" * 32 + ".parquet"
            (root / current).write_bytes(b"parquet")
            (root / retained).write_bytes(b"parquet")
            (root / "manifests/catalog.json").write_text(json.dumps({"datasets": {"stocks": {"partitions": [{"path": current}]}}}))
            result = audit.audit(root)
            self.assertTrue(result["passed"])
            self.assertEqual(result["parquet"]["current_manifest_references"]["files"], 1)
            self.assertEqual(result["parquet"]["retained_unreferenced"]["files"], 1)
            self.assertEqual(result["parquet"]["byte_identical_duplicates"]["logical_excess_bytes"], 7)
            self.assertEqual(result["deleted_files"], 0)
            self.assertTrue((root / retained).is_file())

    def test_duplicate_content_and_symlink_skipping(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ("one", "two"):
                (root / name).write_bytes(b"same")
            (root / "link").symlink_to(root / "one")
            entries, links = audit.files_under(root)
            self.assertEqual(links, 1)
            self.assertEqual(audit.duplicate_contents(entries)["logical_excess_bytes"], 4)


if __name__ == "__main__":
    unittest.main()
