import gzip
import importlib.util
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(__file__).with_name("snapshot-valuation-runtime.py")
spec = importlib.util.spec_from_file_location("snapshot_runtime", SCRIPT)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class SnapshotTests(unittest.TestCase):
    def test_matching_compression_is_read_back(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw, gz = Path(tmp) / "db", Path(tmp) / "db.gz"
            raw.write_bytes(b"synthetic backup" * 100)
            gz.write_bytes(gzip.compress(raw.read_bytes(), mtime=0))
            result = module.verify_compressed_copy(raw, gz)
            self.assertEqual(result["uncompressedBytes"], raw.stat().st_size)
            self.assertEqual(len(result["uncompressedSha256"]), 64)

    def test_wrong_or_interrupted_gzip_fails(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw, gz = Path(tmp) / "db", Path(tmp) / "db.gz"
            raw.write_bytes(b"right")
            for value in [gzip.compress(b"wrong"), gzip.compress(b"right")[:-4]]:
                gz.write_bytes(value)
                with self.assertRaises((ValueError, EOFError)):
                    module.verify_compressed_copy(raw, gz)

    def test_backup_refuses_replacement_and_preserves_source(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            with sqlite3.connect(source) as db:
                db.execute("CREATE TABLE preserved(value TEXT)")
                db.execute("INSERT INTO preserved VALUES('untouched')")
            before = source.read_bytes()
            output = root / "private-backup"
            first = subprocess.run([sys.executable, str(SCRIPT), "--source", str(source), "--output-dir", str(output)], capture_output=True)
            self.assertEqual(first.returncode, 0, first.stderr)
            second = subprocess.run([sys.executable, str(SCRIPT), "--source", str(source), "--output-dir", str(output)], capture_output=True)
            self.assertNotEqual(second.returncode, 0)
            self.assertEqual(source.read_bytes(), before)

    def test_finalize_never_attests_a_wrong_compressed_copy(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.sqlite"
            with sqlite3.connect(source) as db:
                db.execute("CREATE TABLE preserved(value TEXT)")
            output = root / "private-backup"
            output.mkdir()
            (output / "runtime.sqlite").write_bytes(source.read_bytes())
            (output / "runtime.sqlite.gz").write_bytes(gzip.compress(b"different backup"))
            result = subprocess.run([sys.executable, str(SCRIPT), "--source", str(source), "--output-dir", str(output), "--finalize-existing"], capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertFalse((output / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
