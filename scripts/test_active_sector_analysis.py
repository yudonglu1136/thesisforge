import unittest

from active_sector_analysis import aggregate_sectors


def position(manager, ticker, current, previous, value, old_value, **extra):
    return dict(investorid=manager, ticker=ticker, sector="Technology", industry="Chips",
                name=ticker, investor_name=manager, current_units=current,
                adjusted_previous_units=previous, current_value=value, previous_value=old_value,
                current_book_value=1000, previous_book_value=800,
                reported_action="increased", **extra)


class SectorAnalysisTest(unittest.TestCase):
    def test_same_price_separates_shares_from_price_and_reconciles(self):
        data = aggregate_sectors([
            position("A", "X", 120, 100, 24, 10),
            position("B", "X", 80, 100, 16, 10),
        ])["Technology"]
        self.assertEqual(data["summary"]["addProxyM"], 4)
        self.assertEqual(data["summary"]["trimProxyM"], 4)
        self.assertEqual(data["summary"]["netProxyM"], 0)
        self.assertEqual(data["summary"]["reportedValueChangeM"], 20)
        self.assertEqual(data["summary"]["valuationResidualM"], 20)
        self.assertEqual(sum(x["netProxyM"] for x in data["managers"]), 0)
        self.assertEqual(sum(x["currentWeight"] for x in data["stocks"]), 1)

    def test_split_normalized_shares_do_not_create_flow(self):
        item = position("A", "X", 1000, 1000, 20, 20)
        item["reported_action"] = "unchanged"
        result = aggregate_sectors([item])["Technology"]
        self.assertEqual(result["summary"]["netProxyM"], 0)

    def test_missing_entire_filing_excluded_new_exit_are_comparable(self):
        new = position("A", "NEW", 100, None, 20, None)
        new["reported_action"] = "new"
        exit_row = position("B", "EXIT", None, 100, None, 10)
        exit_row["reported_action"] = "exited"
        missing = position("C", "MISSING", None, 100, None, 500)
        missing["reported_action"] = "not_comparable"
        result = aggregate_sectors([new, exit_row, missing])["Technology"]
        self.assertEqual(result["summary"]["positions"], 2)
        self.assertEqual(result["summary"]["netProxyM"], 10)
        self.assertEqual(result["summary"]["priorPricePositions"], 1)
        self.assertNotIn("MISSING", str(result["stocks"]))

    def test_unknown_value_is_not_zero_or_priced(self):
        result = aggregate_sectors([position("A", "X", 100, 90, None, None)])["Technology"]
        self.assertIsNone(result["summary"]["netProxyM"])
        self.assertIsNone(result["summary"]["currentValueM"])
        self.assertEqual(result["summary"]["unpricedPositions"], 1)

    def test_complete_population_not_top_fifty_and_deterministic(self):
        rows = [position(str(i), "X", 100 + i, 100, (100 + i) / 10, 10) for i in range(70)]
        first = aggregate_sectors(rows)["Technology"]
        second = aggregate_sectors(list(reversed(rows)))["Technology"]
        self.assertEqual(len(first["managers"]), 70)
        self.assertEqual(first, second)

    def test_inconsistent_source_shares_are_quarantined_not_corrected(self):
        # One SF3 record has 1,000x prior shares, but an ordinary reported value.
        rows = [position(str(i), "X", 120, 100, 24, 10) for i in range(5)]
        rows.append(position("BAD", "X", 120, 100000, 24, 10))
        result = aggregate_sectors(rows)["Technology"]
        self.assertAlmostEqual(result["summary"]["netProxyM"], 20)
        self.assertEqual(result["summary"]["inconsistentPositions"], 1)
        bad = next(r for r in result["managers"] if r["investorId"] == "BAD")
        self.assertIsNone(bad["netProxyM"])
        self.assertEqual(bad["previousValueM"], 10)
        self.assertIsNone(result["summary"]["valuationResidualM"])

    def test_rounding_allowance_does_not_reject_small_positions(self):
        rows = [position(str(i), "X", 120, 100, 24, 10) for i in range(5)]
        rows.append(position("SMALL", "X", .6, .8, .1, .1))
        result = aggregate_sectors(rows)["Technology"]
        self.assertEqual(result["summary"]["inconsistentPositions"], 0)
        self.assertAlmostEqual(result["summary"]["netProxyM"], 19.96)

    def test_value_without_shares_does_not_establish_zero_position(self):
        row = position("BAD", "X", 0, 100, 24, 10)
        rows = [position(str(i), "X", 120, 100, 24, 10) for i in range(5)] + [row]
        result = aggregate_sectors(rows)["Technology"]
        self.assertEqual(result["summary"]["inconsistentPositions"], 1)
        self.assertAlmostEqual(result["summary"]["netProxyM"], 20)


if __name__ == "__main__":
    unittest.main()
