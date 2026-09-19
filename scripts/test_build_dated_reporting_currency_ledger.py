import copy
import unittest
from build_dated_reporting_currency_ledger import companyfacts_filings, resolve_currency, explicit_currency
from audit_dated_reporting_currency_ledger import verify_target


def source(currency="USD", filed="2026-05-01", end="2026-03-31", accession="0000000001-26-000001"):
    row = {"filed": filed, "end": end, "accn": accession, "form": "10-Q", "val": 10}
    return {"cik": 1, "entityName": "Fixture Inc.", "facts": {"us-gaap": {
        "RevenueFromContractWithCustomerExcludingAssessedTax": {"units": {currency: [{**row, "start": "2026-01-01"}]}},
        "NetCashProvidedByUsedInOperatingActivities": {"units": {currency: [{**row, "start": "2026-01-01", "val": -5}]}},
        "CashAndCashEquivalentsAtCarryingValue": {"units": {currency: [row]}}
    }}}


class DatedReportingCurrencyTests(unittest.TestCase):
    def resolve(self, payload, target="2026-05-01"):
        return resolve_currency(companyfacts_filings(payload, "0000000001"), "0000000001", target)

    def test_multiple_entity_statement_concepts_agree(self):
        result = self.resolve(source())
        self.assertEqual(result["status"], "resolved")
        self.assertEqual(result["currency"], "USD")
        self.assertEqual(len(result["filings"][0]["categories"]), 3)
        self.assertEqual(result["filings"][0]["reference"]["accession"], "0000000001-26-000001")
        self.assertEqual(result["filings"][0]["facts"][1]["fact"]["val"], -5)

    def test_normalized_quote_and_fx_do_not_establish_reporting_currency(self):
        self.assertIsNone(explicit_currency({"financialStatementCurrency": "USD", "sourceRecord": {
            "currency": "USD", "modelCurrency": "USD", "currencyScale": 1, "rawProviderFxusd": 1}}))
        self.assertEqual(explicit_currency({"sourceRecord": {"sourceCurrency": "MXN"}}), "MXN")
        self.assertIsNone(explicit_currency({"reportingCurrency": "USD", "sourceRecord": {"sourceCurrency": "MXN"}}))

    def test_no_future_filing_leakage(self):
        self.assertEqual(self.resolve(source(), "2026-04-30")["reason"], "no_dated_aggregate_statement_facts")

    def test_conflict_does_not_fall_back_to_old_usd(self):
        p = source()
        newer = source("EUR", "2026-05-15", "2026-03-31", "0000000001-26-000002")
        for concept, node in newer["facts"]["us-gaap"].items():
            p["facts"]["us-gaap"][concept]["units"].update(node["units"])
        # New filing has EUR revenue/cash but USD operating cash: reject.
        cf = p["facts"]["us-gaap"]["NetCashProvidedByUsedInOperatingActivities"]["units"]
        cf["USD"].extend(cf.pop("EUR"))
        self.assertEqual(self.resolve(p, "2026-05-20")["reason"], "conflicting_statement_currencies")

    def test_currency_change_is_dated(self):
        p = source()
        newer = source("EUR", "2026-05-15", "2026-03-31", "0000000001-26-000002")
        for concept, node in newer["facts"]["us-gaap"].items():
            p["facts"]["us-gaap"][concept]["units"].update(node["units"])
        self.assertEqual(self.resolve(p, "2026-05-10")["currency"], "USD")
        self.assertEqual(self.resolve(p, "2026-05-20")["currency"], "EUR")

    def test_revenue_aliases_are_not_two_independent_categories(self):
        p = source()
        facts = p["facts"]["us-gaap"]
        del facts["NetCashProvidedByUsedInOperatingActivities"]
        del facts["CashAndCashEquivalentsAtCarryingValue"]
        facts["Revenues"] = copy.deepcopy(facts["RevenueFromContractWithCustomerExcludingAssessedTax"])
        self.assertEqual(self.resolve(p)["reason"], "insufficient_independent_statement_concepts")

    def test_concepts_from_different_filings_cannot_be_combined(self):
        p = source()
        p["facts"]["us-gaap"]["RevenueFromContractWithCustomerExcludingAssessedTax"]["units"]["USD"][0]["accn"] = "0000000001-26-000009"
        self.assertEqual(self.resolve(p)["status"], "blocked")

    def test_unknown_or_per_share_unit_not_currency(self):
        for unit in ["USD/shares", "shares", "pure", "UNKNOWN", "AAA"]:
            with self.subTest(unit=unit):
                self.assertEqual(self.resolve(source(unit))["reason"], "unsupported_or_nonmonetary_statement_unit")

    def test_entity_identity_mismatch(self):
        with self.assertRaisesRegex(ValueError, "CIK"):
            companyfacts_filings(source(), "0000000002")

    def test_missing_schema_not_guess(self):
        with self.assertRaisesRegex(ValueError, "schema"):
            companyfacts_filings({"cik": 1, "currency": "USD"}, "1")

    def test_custom_or_segment_tags_not_counted(self):
        p = source()
        p["facts"]["custom"] = p["facts"].pop("us-gaap")
        self.assertEqual(self.resolve(p)["status"], "blocked")

    def test_balance_sheet_totals_supply_independent_currency_evidence(self):
        p = source()
        row = copy.deepcopy(p["facts"]["us-gaap"]["CashAndCashEquivalentsAtCarryingValue"])
        p["facts"]["us-gaap"] = {"Assets": row, "StockholdersEquity": copy.deepcopy(row)}
        result = self.resolve(p)
        self.assertEqual(result["currency"], "USD")
        self.assertEqual(result["filings"][0]["categories"], ["total_assets", "total_equity"])
        proof = {"ticker": "A", "targetAvailableAt": "2026-05-01", **result}
        self.assertEqual(verify_target(proof, {"cik": "0000000001"}, p), [])

    def test_whole_entity_balance_sheet_currency_conflict_still_blocks(self):
        p = source()
        usd = p["facts"]["us-gaap"]["CashAndCashEquivalentsAtCarryingValue"]["units"]["USD"]
        p["facts"]["us-gaap"]["Assets"] = {"units": {"EUR": copy.deepcopy(usd)}}
        self.assertEqual(self.resolve(p)["reason"], "conflicting_statement_currencies")

    def test_invalid_or_future_measurement_end_not_accepted(self):
        p = source(end="2026-06-30")
        self.assertEqual(self.resolve(p)["status"], "blocked")

    def test_old_unit_evidence_expires(self):
        self.assertEqual(self.resolve(source(), "2027-06-06")["reason"], "statement_currency_evidence_older_than_400_days")

    def test_raw_fact_and_input_preserved(self):
        p = source("MXN")
        original = copy.deepcopy(p)
        result = self.resolve(p)
        self.assertEqual(p, original)
        self.assertEqual(result["currency"], "MXN")
        self.assertTrue(all(x["unit"] == "MXN" for x in result["filings"][0]["facts"]))

    def test_nonfinite_or_bool_facts_do_not_prove_currency(self):
        for bad in [True, float("nan"), float("inf")]:
            p = source()
            for node in p["facts"]["us-gaap"].values():
                node["units"]["USD"][0]["val"] = bad
            self.assertEqual(self.resolve(p)["status"], "blocked")

    def test_independent_original_fact_audit_accepts_exact_proof(self):
        p = source()
        row = {"ticker": "A", "targetAvailableAt": "2026-05-01", **self.resolve(p)}
        self.assertEqual(verify_target(row, {"cik": "0000000001"}, p), [])

    def test_independent_original_fact_audit_rejects_forgery(self):
        p = source()
        original = {"ticker": "A", "targetAvailableAt": "2026-05-01", **self.resolve(p)}
        for mutate in [
            lambda r: r.update(currency="EUR"),
            lambda r: r["filings"][0]["facts"][0]["fact"].update(val=999),
            lambda r: r["filings"][0]["reference"].update(filingDate="2026-04-30"),
            lambda r: r["filings"][0].update(facts=r["filings"][0]["facts"][:1]),
            lambda r: r.update(availableAt="2026-04-30"),
            lambda r: r["filings"][0]["reference"].update(filingUrl="https://example.com"),
        ]:
            row = copy.deepcopy(original)
            mutate(row)
            self.assertTrue(verify_target(row, {"cik": "0000000001"}, p))

    def test_independent_audit_checks_unquoted_conflicting_facts(self):
        p = source()
        row = {"ticker": "A", "targetAvailableAt": "2026-05-01", **self.resolve(p)}
        # Even if the ledger silently omits contradictory raw units, audit finds it.
        units = p["facts"]["us-gaap"]["NetCashProvidedByUsedInOperatingActivities"]["units"]
        units["EUR"] = copy.deepcopy(units["USD"])
        self.assertIn("currency_or_hidden_conflicting_unit", verify_target(row, {"cik": "0000000001"}, p))

    def test_independent_audit_does_not_accept_two_nonmonetary_units(self):
        p = source("USD/shares")
        row = {"ticker": "A", "targetAvailableAt": "2026-05-01", "status": "resolved", "currency": "USD/shares"}
        self.assertEqual(verify_target(row, {"cik": "0000000001"}, p), ["unsupported_or_nonmonetary_claimed_currency"])


if __name__ == "__main__":
    unittest.main()
