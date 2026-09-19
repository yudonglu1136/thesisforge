import importlib.util
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

SPEC = importlib.util.spec_from_file_location("currency_scope_test", Path(__file__).with_name("audit-qa-currency-suffix-repair.py"))
MODULE = importlib.util.module_from_spec(SPEC); SPEC.loader.exec_module(MODULE)


class CurrencySuffixScopeTest(unittest.TestCase):
    def fixture(self):
        cache = {"$50 to $100; $500,000 TAM.": "错误旧译文", "$5 million of revenue.": "营收500万美元。"}
        audit = {"recoveredCacheSha256": MODULE.RECOVERY.sha(MODULE.RECOVERY.json_bytes(cache)), "sources": {}}
        for source, target in cache.items():
            audit["sources"][source] = {"source_sha256": MODULE.RECOVERY.sha(source), "translation_sha256": MODULE.RECOVERY.sha(target),
                                       "references": [{"ticker": "TEST"}], "numericStrict": {}}
        return cache, audit

    def test_scope_is_exact_money_value_change_not_all_strings_with_to(self):
        cache, audit = self.fixture(); rows = MODULE.findings(cache, audit)
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["newProtectedValues"], ["50美元至100美元", "50 万美元"])
        self.assertEqual(rows[0]["oldProtectedValues"], ["500000 亿美元", "100美元", "5000000000 亿美元"])
        self.assertEqual(rows[0]["priorTranslation"], "错误旧译文")

    def test_mutated_translation_or_source_is_not_accepted(self):
        cache, audit = self.fixture(); cache[next(iter(cache))] = "另一份译文"
        with self.assertRaises(ValueError): MODULE.findings(cache, audit)
        cache, audit = self.fixture(); audit["sources"][next(iter(cache))]["source_sha256"] = "wrong"
        with self.assertRaises(ValueError): MODULE.findings(cache, audit)

    def test_queue_is_isolated_no_financial_or_model_tables(self):
        cache, audit = self.fixture(); rows = MODULE.findings(cache, audit)
        with tempfile.TemporaryDirectory() as temporary:
            target = Path(temporary) / "queue"
            manifest = MODULE.QUEUE.write_queue(target, rows, {})
            self.assertEqual(manifest["sourceCount"], 1)
            with sqlite3.connect(target / "translation-input-only.sqlite") as connection:
                tables = {r[0] for r in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
                self.assertEqual(tables, {"valuation_ticker_snapshots", "translation_input_queue_metadata"})
                self.assertEqual(connection.execute("SELECT value FROM translation_input_queue_metadata WHERE key='never_publish'").fetchone()[0], "true")
            with self.assertRaises(FileExistsError): MODULE.QUEUE.write_queue(target, rows, {})


if __name__ == "__main__":
    unittest.main()
