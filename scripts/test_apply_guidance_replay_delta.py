import importlib.util
from contextlib import closing
import json
from pathlib import Path
import sqlite3
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('replay_delta', Path(__file__).with_name('apply-guidance-replay-delta.py'))
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class ReplayDeltaTests(unittest.TestCase):
    def test_concurrent_merge_preserves_json_type_and_field_presence(self):
        for old, new, concurrent in [
            (False, True, 0), (1, 2, True), (1, 2, 1.0),
            (None, False, mod.ABSENT),
            ({'amount': 1}, {'amount': 2}, {'amount': True}),
            ({'values': [1]}, {'values': [2]}, {'values': [True]}),
        ]:
            with self.assertRaises(ValueError):
                mod.merge_value(old, new, concurrent)
        self.assertEqual(mod.merge_value({'a': 1}, {'a': 1, 'proof': None}, {'a': 2}),
                         {'a': 2, 'proof': None})
        self.assertEqual(mod.merge_value({'a': 1}, {'a': True}, {'a': 1}), {'a': True})

    def test_source_equivalence_ignores_only_json_serialization_not_values_or_quote(self):
        before = {'id': 'a', 'evidence_excerpt': 'Original quote', 'amount': 2,
                  'payload_json': '{"version":"v31","proof":{"amount":2,"quote":"原文"}}'}
        target = {**before, 'payload_json': json.dumps(json.loads(before['payload_json']), sort_keys=True)}
        self.assertTrue(mod.same_source_row(before, target))
        for changed in [
            {**target, 'amount': 3}, {**target, 'evidence_excerpt': 'Edited quote'},
            {**target, 'payload_json': '{"version":"v31","proof":{"amount":3,"quote":"原文"}}'},
            {**target, 'payload_json': '{"version":"v31","proof":{"amount":2.0,"quote":"原文"}}'},
            {**target, 'payload_json': '{"version":"v31","proof":{"amount":2}}'},
            {**target, 'new_field': None}
        ]:
            self.assertFalse(mod.same_source_row(before, changed))
        with self.assertRaisesRegex(ValueError, 'duplicate'):
            mod.same_source_row(before, {**target, 'payload_json': '{"version":"v30","version":"v31"}'})
        self.assertFalse(mod.same_source_row({'payload_json': '{"count":1}'}, {'payload_json': '{"count":true}'}))

    def test_three_way_preserves_new_currency_evidence_and_blocks_same_scalar(self):
        old = {'amount': 12, 'currency': None, 'version': 'v30'}
        after = {**old, 'version': 'v31'}
        target = {**old, 'currency': 'USD', 'proof': {'source': 'original'}}
        self.assertEqual(mod.merge_value(old, after, target), {**target, 'version': 'v31'})
        with self.assertRaises(ValueError):
            mod.merge_value(old, {**after, 'amount': 13}, {**target, 'amount': 14})

    def fixture(self, root, name):
        p = Path(root) / name
        with closing(sqlite3.connect(p)) as db, db:
            db.execute('CREATE TABLE pit_guidance_events(id TEXT PRIMARY KEY,ticker TEXT,fiscal_period TEXT,observed_at TEXT,source_type TEXT,source_url TEXT,evidence_excerpt TEXT,speaker TEXT,speaker_role TEXT,metric_name TEXT,value_text TEXT,amount REAL,payload_json TEXT)')
            db.execute('INSERT INTO pit_guidance_events VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)',
                       ('a', 'CRDO', 'Q22026', '2026-08-01', mod.OWNER, 'https://example.test', 'Net income $12.', 'Manager', 'CFO', 'profit', '12', 12, '{"version":"v30"}'))
            db.execute('CREATE TABLE pit_source_metadata(key TEXT PRIMARY KEY,value TEXT)')
            db.execute("INSERT INTO pit_source_metadata VALUES('guidance_extraction_version','v30')")
            db.execute('CREATE TABLE pit_financial_periods(ticker TEXT,amount REAL)')
            db.execute("INSERT INTO pit_financial_periods VALUES('CRDO',99)")
        return p

    def test_copy_only_preserves_extra_issuer_and_requires_exact_hash_and_financials(self):
        with tempfile.TemporaryDirectory() as root:
            before, after, base = [self.fixture(root, name + '.sqlite') for name in ('before', 'after', 'base')]
            with closing(sqlite3.connect(after)) as db, db:
                db.execute('UPDATE pit_guidance_events SET payload_json=?', ('{"version":"v31"}',))
                db.execute("UPDATE pit_source_metadata SET value='v31'")
            with closing(sqlite3.connect(base)) as db, db:
                db.execute('UPDATE pit_guidance_events SET payload_json=?', ('{"version":"v30","currencyProof":"reviewed"}',))
                db.execute("INSERT INTO pit_financial_periods VALUES('NEW',101)")
            recipe = {'sourceCutoff': '2026-09-05'}
            for key, p in [('before', before), ('after', after), ('base', base)]:
                recipe[key] = str(p)
                recipe[key + 'Sha256'] = mod.file_hash(p)
            original_base = mod.file_hash(base)
            out, report = Path(root) / 'output.sqlite', Path(root) / 'report.json'
            result = mod.apply(recipe, out, report)
            self.assertFalse(result['releaseAuthorized'])
            self.assertEqual(result['concurrentEvidencePreserved'], 1)
            self.assertEqual(mod.file_hash(base), original_base)
            with closing(sqlite3.connect(out)) as db:
                self.assertEqual(json.loads(db.execute('SELECT payload_json FROM pit_guidance_events').fetchone()[0]),
                                 {'version': 'v31', 'currencyProof': 'reviewed'})
                self.assertEqual(db.execute('SELECT count(*) FROM pit_financial_periods').fetchone()[0], 2)
            with self.assertRaises(ValueError):
                mod.apply(recipe, out, report)
            wrong = {**recipe, 'baseSha256': '0' * 64}
            with self.assertRaisesRegex(ValueError, 'hash'):
                mod.apply(wrong, Path(root) / 'bad.sqlite', Path(root) / 'bad.json')
            with closing(sqlite3.connect(after)) as db, db:
                db.execute('UPDATE pit_financial_periods SET amount=1')
            recipe['afterSha256'] = mod.file_hash(after)
            with self.assertRaisesRegex(ValueError, 'protected'):
                mod.apply(recipe, Path(root) / 'bad2.sqlite', Path(root) / 'bad2.json')


if __name__ == '__main__':
    unittest.main()
