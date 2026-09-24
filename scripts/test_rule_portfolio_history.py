import importlib.util
from pathlib import Path
import unittest
import pandas as pd

spec = importlib.util.spec_from_file_location('rules', Path(__file__).with_name('build-rule-portfolio-inputs.py'))
rules = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rules)


class HistoryWindowTests(unittest.TestCase):
    def test_default_retains_2013_signal_and_supports_explicit_recent_window(self):
        frame = pd.DataFrame({'entry': ['2012-10-01', '2013-01-02', '2023-01-03'],
                              'q': ['2012-09-30', '2012-12-31', '2022-12-31']})
        self.assertEqual(rules.history_window(frame).entry.tolist(), ['2013-01-02', '2023-01-03'])
        self.assertEqual(rules.history_window(frame, '2023-01-01').entry.tolist(), ['2023-01-03'])

    def test_early_window_cannot_silently_use_only_recent_candidate_quarters(self):
        with self.assertRaisesRegex(ValueError, 'candidate_history_incomplete'):
            rules.require_quarter_coverage(['2012-12-31', '2022-12-31'], ['2022-12-31'])
        rules.require_quarter_coverage(['2012-12-31'], ['2012-12-31'])

    def test_invalid_or_empty_window_fails(self):
        frame = pd.DataFrame({'entry': ['2023-01-03']})
        for start in ['2024-01-01', '2023-02-30', 'bad']:
            with self.assertRaises(ValueError):
                rules.history_window(frame, start)


if __name__ == '__main__':
    unittest.main()
