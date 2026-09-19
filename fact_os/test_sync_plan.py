"""Offline date-window regressions; no fixtures, credentials, or IO required."""
from datetime import date, timedelta
import unittest

from .sync_plan import bounded_date_windows, price_date_windows


class SyncPlanTest(unittest.TestCase):
    def test_default_four_year_windows_cover_start_and_end(self):
        self.assertEqual(bounded_date_windows('1900-01-01', '1908-02-02'), [
            ('1900-01-01', '1903-12-31'),
            ('1904-01-01', '1907-12-31'),
            ('1908-01-01', '1908-02-02'),
        ])

    def test_exact_boundary_keeps_the_final_day(self):
        self.assertEqual(bounded_date_windows('2000-01-01', '2004-01-01'), [
            ('2000-01-01', '2003-12-31'), ('2004-01-01', '2004-01-01'),
        ])

    def test_leap_day_start_and_anniversaries(self):
        self.assertEqual(bounded_date_windows('1996-02-29', '2004-03-01'), [
            ('1996-02-29', '2000-02-28'),
            ('2000-02-29', '2004-02-28'),
            ('2004-02-29', '2004-03-01'),
        ])
        self.assertEqual(bounded_date_windows('2020-02-29', '2021-03-01', years=1), [
            ('2020-02-29', '2021-02-27'), ('2021-02-28', '2021-03-01'),
        ])
        self.assertEqual(bounded_date_windows('2096-02-29', '2100-03-01'), [
            ('2096-02-29', '2100-02-27'), ('2100-02-28', '2100-03-01'),
        ])

    def test_disjoint_ranges_have_no_gaps_for_every_supported_size(self):
        first, last = date(1999, 12, 19), date(2026, 9, 19)
        for years in range(1, 5):
            windows = bounded_date_windows(first, last, years=years)
            self.assertEqual(windows[0][0], first.isoformat())
            self.assertEqual(windows[-1][1], last.isoformat())
            next_start = first
            days = 0
            for start, end in windows:
                start, end = date.fromisoformat(start), date.fromisoformat(end)
                self.assertEqual(start, next_start)
                self.assertGreaterEqual(end, start)
                self.assertLessEqual((end - start).days + 1, 366 * years)
                days += (end - start).days + 1
                next_start = end + timedelta(days=1)
            self.assertEqual(days, (last - first).days + 1)

    def test_single_day_and_date_type_are_supported(self):
        self.assertEqual(bounded_date_windows(date(2024, 2, 29), '2024-02-29'), [
            ('2024-02-29', '2024-02-29'),
        ])

    def test_maximum_date_does_not_overflow(self):
        self.assertEqual(bounded_date_windows('9997-01-01', '9999-12-31'), [
            ('9997-01-01', '9999-12-31'),
        ])
        self.assertEqual(bounded_date_windows('9999-12-31', '9999-12-31'), [
            ('9999-12-31', '9999-12-31'),
        ])

    def test_invalid_dates_and_reversed_ranges_are_rejected(self):
        for invalid in ('2023-02-29', '2024-13-01', '2024-01-32', '20240101',
                        '2024-W01-1', '2024-01-01T00:00:00', '', None, 20240101):
            with self.subTest(value=invalid):
                with self.assertRaises(ValueError):
                    bounded_date_windows(invalid, '2026-01-01')
                with self.assertRaises(ValueError):
                    bounded_date_windows('2020-01-01', invalid)
        with self.assertRaisesRegex(ValueError, 'start must not be after end'):
            bounded_date_windows('2026-01-02', '2026-01-01')

    def test_invalid_window_sizes_cannot_issue_wide_queries(self):
        for invalid in (0, -1, 5, 100, 1.5, '4', None, True):
            with self.subTest(value=invalid), self.assertRaises(ValueError):
                bounded_date_windows('1900-01-01', '2026-09-19', years=invalid)


class PriceSyncPlanTest(unittest.TestCase):
    def assert_complete_coverage(self, windows, first, last):
        self.assertEqual(windows[0][0], first.isoformat())
        self.assertEqual(windows[-1][1], last.isoformat())
        covered = 0
        previous = None
        for low, high in windows:
            low, high = date.fromisoformat(low), date.fromisoformat(high)
            self.assertLessEqual(low, high)
            if previous is not None:
                self.assertEqual(low, previous + timedelta(days=1))
            covered += (high - low).days + 1
            previous = high
        self.assertEqual(covered, (last - first).days + 1)

    def test_prefix_is_retained_before_local_history(self):
        self.assertEqual(price_date_windows('1990-01-01', '1998-03-04', '1997-12-31'), [
            ('1990-01-01', '1993-12-31'),
            ('1994-01-01', '1997-12-30'),
            ('1997-12-31', '1998-01-30'),
            ('1998-01-31', '1998-03-02'),
            ('1998-03-03', '1998-03-04'),
        ])

    def test_31_day_seeds_have_no_gaps_or_overlaps_across_leap_years(self):
        first, last, anchor = date(1900, 1, 1), date(2026, 9, 19), date(1997, 12, 31)
        windows = price_date_windows(first, last, anchor)
        self.assert_complete_coverage(windows, first, last)
        after = [(date.fromisoformat(a), date.fromisoformat(b)) for a, b in windows
                 if date.fromisoformat(a) >= anchor]
        self.assertEqual(after[0][0], anchor)
        self.assertTrue(all((b - a).days + 1 == 31 for a, b in after[:-1]))
        self.assertLessEqual((after[-1][1] - after[-1][0]).days + 1, 31)
        self.assertEqual(len(windows), 364)

    def test_leap_day_anchor_and_date_arguments(self):
        self.assertEqual(price_date_windows(date(2024, 2, 28), date(2024, 4, 1), date(2024, 2, 29)), [
            ('2024-02-28', '2024-02-28'),
            ('2024-02-29', '2024-03-30'),
            ('2024-03-31', '2024-04-01'),
        ])

    def test_anchor_at_start_does_not_create_empty_prefix(self):
        self.assertEqual(price_date_windows('2024-01-01', '2024-02-01', '2024-01-01'), [
            ('2024-01-01', '2024-01-31'), ('2024-02-01', '2024-02-01'),
        ])

    def test_anchor_at_end_preserves_all_earlier_dates(self):
        windows = price_date_windows('2020-01-01', '2024-01-01', '2024-01-01')
        self.assertEqual(windows, [
            ('2020-01-01', '2023-12-31'), ('2024-01-01', '2024-01-01'),
        ])

    def test_one_day_and_maximum_date_do_not_overflow(self):
        for day in ('0001-01-01', '2024-02-29', '9999-12-31'):
            self.assertEqual(price_date_windows(day, day, day), [(day, day)])
        self.assertEqual(price_date_windows('9999-12-01', '9999-12-31', '9999-12-15'), [
            ('9999-12-01', '9999-12-14'), ('9999-12-15', '9999-12-31'),
        ])

    def test_missing_invalid_or_out_of_bounds_metadata_falls_back_without_truncation(self):
        first, last = '2000-01-01', '2026-09-19'
        expected = bounded_date_windows(first, last)
        self.assertEqual(price_date_windows(first, last), expected)
        for hint in (None, '', '2023-02-29', '20260901', '2026-09-01T00:00:00',
                     20260901, True, [], {}, '1999-12-31', '2026-09-20'):
            with self.subTest(hint=hint):
                self.assertEqual(price_date_windows(first, last, hint), expected)

    def test_invalid_query_range_is_not_hidden_by_metadata_fallback(self):
        for first, last in (('invalid', '2026-09-19'), ('1900-01-01', 'invalid'),
                            ('2026-09-20', '2026-09-19')):
            with self.subTest(first=first, last=last), self.assertRaises(ValueError):
                price_date_windows(first, last, None)


if __name__ == '__main__':
    unittest.main()
