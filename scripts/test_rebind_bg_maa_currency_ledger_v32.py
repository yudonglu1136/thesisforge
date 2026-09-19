import copy
import importlib.util
import json
from pathlib import Path
import unittest

SPEC = importlib.util.spec_from_file_location("rebind_currency", Path(__file__).with_name("rebind-bg-maa-currency-ledger-v32.py"))
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class RebindTests(unittest.TestCase):
    def setUp(self):
        payload = {"extraction_version": MODULE.OLD_VERSION, "amount": 300, "per_share_value": None,
                   "source_review": {"status": "pending"}, "new_optional": None}
        self.old = {"id": "id1", "ticker": "BG", "observed_at": "2019-05-08", "evidence_excerpt": "CapEx $550m, interest $290m-$310m",
                    "amount": 300.0, "currency": None, "extraction_version": MODULE.OLD_VERSION, "payload_json": json.dumps(payload)}
        self.new = {**self.old, "extraction_version": MODULE.NEW_VERSION,
                    "payload_json": json.dumps({**payload, "extraction_version": MODULE.NEW_VERSION}, sort_keys=True, separators=(",", ":"))}
        self.event = {"sourceId": "id1", "ticker": "BG", "observedAt": "2019-05-08", "originalQuote": self.old["evidence_excerpt"],
                      "originalQuoteSha256": MODULE.sha(self.old["evidence_excerpt"]), "originalPayloadSha256": MODULE.sha(self.old["payload_json"])}

    def test_version_only_and_json_formatting_change_allowed_not_numeric_approval(self):
        result = MODULE.compare(self.old, self.new, self.event)
        self.assertTrue(result["economicFieldsExact"])
        self.assertNotEqual(result["priorPayloadSha256"], result["reboundPayloadSha256"])

    def test_economic_review_quote_or_identity_change_rejected(self):
        for field, value in [("amount", 550.0), ("currency", "USD"), ("ticker", "OTHER"), ("evidence_excerpt", "revised quote")]:
            with self.subTest(field=field), self.assertRaises(ValueError):
                MODULE.compare(self.old, {**self.new, field: value}, self.event)
        for field, value in [("amount", 550), ("per_share_value", 2.31), ("source_review", {"status": "approved"})]:
            newer = copy.deepcopy(self.new)
            payload = json.loads(newer["payload_json"])
            payload[field] = value
            newer["payload_json"] = json.dumps(payload)
            with self.subTest(field=field), self.assertRaisesRegex(ValueError, "Payload source/economic"):
                MODULE.compare(self.old, newer, self.event)

    def test_missing_null_and_additional_unknown_schema_fields_rejected(self):
        for mode in ["missing", "added", "boolean"]:
            newer = copy.deepcopy(self.new)
            payload = json.loads(newer["payload_json"])
            if mode == "missing":
                del payload["new_optional"]
            elif mode == "added":
                payload["new_key"] = None
            else:
                payload["amount"] = True
            newer["payload_json"] = json.dumps(payload)
            with self.subTest(mode=mode), self.assertRaises(ValueError):
                MODULE.compare(self.old, newer, self.event)
        with self.assertRaises(ValueError):
            MODULE.compare(self.old, {**self.new, "unknown_sql_field": None}, self.event)

    def test_unreviewed_versions_or_prior_payload_hash_rejected(self):
        with self.assertRaisesRegex(ValueError, "version transition"):
            MODULE.compare(self.old, {**self.new, "extraction_version": "v33"}, self.event)
        with self.assertRaisesRegex(ValueError, "payload hash"):
            MODULE.compare(self.old, self.new, {**self.event, "originalPayloadSha256": "0" * 64})

    def test_duplicate_keys_and_nonfinite_json_rejected(self):
        for raw in ['{"amount":300,"amount":550}', '{"amount":NaN}']:
            with self.assertRaises(ValueError):
                MODULE.parse(raw)


if __name__ == "__main__":
    unittest.main()
