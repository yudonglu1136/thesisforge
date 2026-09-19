import copy
import hashlib
import json
from pathlib import Path
import unittest

from guru_reviewed_input_corrections import apply_reviewed_input_corrections


MANIFEST = json.loads((Path(__file__).resolve().parents[1] / "server/config/guru-valuation-reviewed-batch.json").read_text())


def issuer(ticker):
    return copy.deepcopy(next(row for row in MANIFEST["companies"] if row["ticker"] == ticker))


def rows(company):
    correction = company["inputCorrections"][0]
    return [{
        "ticker": company["ticker"], "fiscal_period": correction["fiscalPeriod"],
        "dimension": dimension, "available_at": correction["expectedRecordAvailableDate"],
        "report_period": correction["periodEndDate"], "currency": correction["currency"],
        "payload_json": json.dumps({
            "ticker": company["ticker"], "periodEndDate": correction["periodEndDate"],
            "asOfDate": correction["expectedRecordAvailableDate"], "sourceDimension": dimension,
            "financialStatementCurrency": correction["currency"], "shares_m": correction["expectedOriginalValue"],
            "sourceRecord": {"rawShareCounts": {"sharesbas": correction["expectedOriginalValue"] * 1e6}, "appliedShareFactor": 1},
            "sources": {"shares_m": {"dataset": "raw_provider", "tag": "sharesbas"}},
        })
    } for dimension in correction["dimensions"]]


class ReviewedInputCorrectionsTest(unittest.TestCase):
    def test_both_actual_company_share_corrections_preserve_raw_and_lineage(self):
        for ticker, expected in [("CROX", 48.136), ("SOFI", 1290.312404)]:
            company = issuer(ticker)
            original = rows(company)
            before = copy.deepcopy(original)
            result = apply_reviewed_input_corrections(company, original)
            self.assertEqual(original, before)
            for source, corrected in zip(original, result):
                payload = json.loads(corrected["payload_json"])
                raw = json.loads(source["payload_json"])
                self.assertEqual(payload["shares_m"], expected)
                self.assertEqual(payload["sourceRecord"]["rawShareCounts"], raw["sourceRecord"]["rawShareCounts"])
                self.assertEqual(payload["sourceRecord"]["reviewedInputCorrections"][0]["originalSource"], raw["sources"]["shares_m"])
                self.assertEqual(payload["asOfDate"], raw["asOfDate"])
                self.assertEqual(len(payload["sources"]["shares_m"]["correctionSha256"]), 64)

    def test_idempotent_and_nonmatching_history_is_byte_for_byte_preserved(self):
        company = issuer("CROX")
        original = rows(company)
        history = {**original[0], "fiscal_period": "2025-Q2", "payload_json": '{"untouched":"historical source"}'}
        original.append(history)
        result = apply_reviewed_input_corrections(company, original)
        self.assertEqual(result[-1], history)
        self.assertEqual(apply_reviewed_input_corrections(company, result), result)

    def test_reviewed_share_policy_replaces_unreviewed_annotation_preserving_original(self):
        company = issuer("CROX")
        original = rows(company)
        policy = "Unreviewed provider denominator; reconcile period-end versus cover-date shares before model consumption."
        for row in original:
            payload = json.loads(row["payload_json"])
            payload["sourceRecord"]["shareCountPolicy"] = policy
            row["payload_json"] = json.dumps(payload)
        result = apply_reviewed_input_corrections(company, original)
        for row in result:
            source = json.loads(row["payload_json"])["sourceRecord"]
            self.assertEqual(source["shareCountBasis"], "official_period_end_common_shares")
            self.assertIn("Period-end basic ordinary shares", source["shareCountPolicy"])
            self.assertEqual(source["reviewedInputCorrections"][0]["originalShareCountPolicy"], policy)
        self.assertEqual(apply_reviewed_input_corrections(company, result), result)

    def test_missing_or_duplicate_dimension_blocks(self):
        company = issuer("CROX")
        original = rows(company)
        for bad in [original[:1], original + original[:1], []]:
            with self.assertRaisesRegex(ValueError, "dimensions"):
                apply_reviewed_input_corrections(company, bad)

    def test_mismatched_sql_currency_period_or_availability_blocks(self):
        company = issuer("SOFI")
        for key, value in [("currency", "EUR"), ("available_at", "2026-07-28"), ("report_period", "2026-03-31")]:
            original = rows(company)
            original[0][key] = value
            with self.assertRaisesRegex(ValueError, "mismatch"):
                apply_reviewed_input_corrections(company, original)

    def test_payload_identity_currency_date_or_factor_cannot_be_spoofed(self):
        company = issuer("CROX")
        for key, value in [("ticker", "SOFI"), ("financialStatementCurrency", "EUR"),
                           ("asOfDate", "2026-07-29"), ("sourceDimension", "ART"),
                           ("periodEndDate", "2026-03-31"), ("shares_m", 48.1)]:
            original = rows(company)
            payload = json.loads(original[0]["payload_json"])
            payload[key] = value
            original[0]["payload_json"] = json.dumps(payload)
            with self.assertRaises(ValueError):
                apply_reviewed_input_corrections(company, original)
        original = rows(company)
        payload = json.loads(original[0]["payload_json"])
        payload["sourceRecord"]["appliedShareFactor"] = 0.5
        original[0]["payload_json"] = json.dumps(payload)
        with self.assertRaisesRegex(ValueError, "factor"):
            apply_reviewed_input_corrections(company, original)

    def test_future_foreign_or_wrong_field_corrections_block(self):
        for key, value in [("sourceAvailableDate", "2026-08-31"), ("currency", "EUR"),
                           ("sourceAvailableDate", "2026-02-30"), ("periodEndDate", "2026-6-30"),
                           ("field", "fcf_after_capex_m"), ("value", -2),
                           ("sourceUrl", "https://www.sec.gov/Archives/edgar/data/1/wrong.htm"),
                           ("sourceUrl", "https://example.com/filing.htm"), ("sourceLocator", "")]:
            company = issuer("CROX")
            original = rows(company)
            company["inputCorrections"][0][key] = value
            with self.assertRaises(ValueError):
                apply_reviewed_input_corrections(company, original)

    def test_unreviewed_or_blocked_company_cannot_apply(self):
        for update in [{"reviewStatus": "unreviewed"}, {"economicReview": {"releaseBlockers": ["unresolved"]}}]:
            company = issuer("CROX")
            original = rows(company)
            company.update(update)
            with self.assertRaisesRegex(ValueError, "approved economic"):
                apply_reviewed_input_corrections(company, original)

    def test_conflicting_idempotence_lineage_blocks(self):
        company = issuer("SOFI")
        result = apply_reviewed_input_corrections(company, rows(company))
        payload = json.loads(result[0]["payload_json"])
        payload["sourceRecord"]["reviewedInputCorrections"][0]["correctionSha256"] = "wrong"
        result[0]["payload_json"] = json.dumps(payload)
        with self.assertRaisesRegex(ValueError, "lineage"):
            apply_reviewed_input_corrections(company, result)

    def test_no_correction_does_not_rewrite_inputs(self):
        original = [{"payload_json": "raw immutable row"}]
        self.assertEqual(apply_reviewed_input_corrections(issuer("POWL"), original), original)

    def cash_fixture(self):
        company = issuer("CROX")
        original = rows(company)
        template = company["inputCorrections"][0]
        for row in original:
            payload = json.loads(row["payload_json"])
            payload.update({"cfo_m": None, "capex_m": None, "fcf_after_capex_m": None, "revenue_m": None})
            row["payload_json"] = json.dumps(payload)
        raw_hash = hashlib.sha256(original[1]["payload_json"].encode()).hexdigest()
        company["inputCorrections"] = []
        for field, value in [("cfo_m", -10), ("capex_m", 2), ("fcf_after_capex_m", -12), ("revenue_m", 20)]:
            company["inputCorrections"].append({**template, "id": f"reconstruct-{field}", "field": field,
                "unit": "million_reporting_currency", "dimensions": ["ART"], "expectedOriginalValue": None, "value": value,
                "sourcePrecisionM": .001, "precisionPolicy": "Exact reported USD thousands, never wider tolerance",
                "expectedOriginalPayloadSha256ByDimension": {"ART": raw_hash},
                "sourceComponents": [{"valueM": value, "multiplier": 1, "url": template["sourceUrl"],
                    "sha256": "a" * 64, "locator": "synthetic exact cash-flow line", "currency": template["currency"],
                    "availableDate": template["sourceAvailableDate"], "periodEndDate": template["periodEndDate"]}]})
        return company, original

    def test_exact_null_art_cash_reconstruction_preserves_arq_and_original_payload(self):
        company, original = self.cash_fixture()
        result = apply_reviewed_input_corrections(company, original)
        self.assertEqual(result[0], original[0])
        payload = json.loads(result[1]["payload_json"])
        self.assertEqual([payload[f] for f in ["cfo_m", "capex_m", "fcf_after_capex_m", "revenue_m"]], [-10, 2, -12, 20])
        self.assertEqual(payload["sourceRecord"]["reviewedOriginalFinancialPayload"]["json"], original[1]["payload_json"])
        self.assertEqual(apply_reviewed_input_corrections(company, result), result)

    def test_source_precision_cannot_excuse_one_thousand_dollar_derivation_error(self):
        company, original = self.cash_fixture()
        company["inputCorrections"][0]["value"] += .001
        with self.assertRaisesRegex(ValueError, "exact source derivation"):
            apply_reviewed_input_corrections(company, original)

    def test_monetary_evidence_requires_primary_identity_date_currency_and_hash(self):
        for field, value in [("sha256", "bad"), ("currency", "EUR"), ("availableDate", "2099-01-01"),
                             ("url", "https://www.sec.gov/Archives/edgar/data/1/wrong.htm"), ("locator", "")]:
            company, original = self.cash_fixture()
            company["inputCorrections"][0]["sourceComponents"][0][field] = value
            with self.assertRaisesRegex(ValueError, "component"):
                apply_reviewed_input_corrections(company, original)

    def test_partial_cash_reconstruction_cannot_leave_broken_identity(self):
        company, original = self.cash_fixture()
        company["inputCorrections"] = company["inputCorrections"][:1]
        with self.assertRaisesRegex(ValueError, "CFO minus cash capex"):
            apply_reviewed_input_corrections(company, original)

    def test_monetary_reconstruction_cannot_override_nonnull_provider_field(self):
        company, original = self.cash_fixture()
        payload = json.loads(original[1]["payload_json"])
        payload["cfo_m"] = 7
        original[1]["payload_json"] = json.dumps(payload)
        with self.assertRaisesRegex(ValueError, "original input changed"):
            apply_reviewed_input_corrections(company, original)

    def test_trusted_original_payload_hash_catches_other_raw_field_tampering(self):
        company, original = self.cash_fixture()
        payload = json.loads(original[1]["payload_json"])
        payload["shares_m"] += 1
        original[1]["payload_json"] = json.dumps(payload)
        with self.assertRaisesRegex(ValueError, "trusted source hash"):
            apply_reviewed_input_corrections(company, original)


if __name__ == "__main__":
    unittest.main()
