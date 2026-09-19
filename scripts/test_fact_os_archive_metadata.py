import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
import zipfile

from fact_os.store import checksum

spec = importlib.util.spec_from_file_location("archive_metadata", Path(__file__).with_name("recover-fact-os-archive-metadata.py"))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class MetadataTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        (self.root / "raw").mkdir()
        temporary = self.root / "raw/source.zip"
        with zipfile.ZipFile(temporary, "w") as archive:
            archive.writestr("stocks.csv", "ticker,date,close\nTEST,2020-01-01,1\n")
        digest = checksum(temporary)
        self.archive = self.root / "raw" / f"stocks-{digest}.zip"
        temporary.rename(self.archive)
        (self.root / "raw/stocks-full.resume.json").write_text(json.dumps({"etag": '"recorded-etag"', "length": str(self.archive.stat().st_size)}))
        self.runs = [{"dataset": "stocks", "run_id": "test", "checksum": digest, "observed_at": "2020-01-02T00:00:00+00:00",
                      "source_path": str(self.archive), "row_count": 1, "schema_hash": "test-schema", "scope": "verified_full_bulk"}]
        self.access = {"stocks": {"dataset": "stocks", "checked_at": "2020-01-01T00:00:00+00:00", "query_status": 200, "bulk_status": 302}}

    def tearDown(self):
        self.temp.cleanup()

    def test_recovers_only_metadata_and_reruns_are_idempotent(self):
        before = self.archive.read_bytes()
        result = module.recover_one(self.root, "stocks", self.runs, self.access, write=True)
        self.assertEqual(result["status"], "recovered")
        sidecar = self.root / result["metadata"]
        saved = sidecar.read_bytes()
        self.assertIsNone(json.loads(saved)["download_completed_at"])
        self.assertEqual(module.recover_one(self.root, "stocks", self.runs, self.access, write=True)["status"], "existing_verified")
        self.assertEqual(sidecar.read_bytes(), saved)
        self.assertEqual(self.archive.read_bytes(), before)

    def test_ambiguous_full_ingestions_are_not_guessed(self):
        with self.assertRaisesRegex(ValueError, "one exact"):
            module.recover_one(self.root, "stocks", self.runs * 2, self.access, write=True)

    def test_archive_outside_recorded_content_address_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "exact recorded archive"):
            module.recover_one(self.root, "stocks", [{**self.runs[0], "source_path": str(self.root / "other.zip")}], self.access, write=True)

    def test_missing_bulk_evidence_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "bulk redirect"):
            module.recover_one(self.root, "stocks", self.runs, {}, write=True)


if __name__ == "__main__":
    unittest.main()
