import unittest
from datetime import date
from .rpc import dispatch, json_value
from .repository import MissingData


class Reader:
    def get_coverage(self):
        return [{'dataset': table, 'backfill_complete': True, 'locally_available': True} for table in ('tickers', 'stocks')]
    def resolve_security(self, ticker):
        return {'price_dataset': 'stocks'}
    def get_price(self, ticker, as_of, price_type):
        return {'ticker': ticker, 'date': as_of, 'price_type': price_type}


class ReaderRPCTests(unittest.TestCase):
    def test_only_explicit_read_methods_are_allowed(self):
        for name in ('__getattribute__', 'execute', 'sync', 'backfill', 'close', 'db'):
            with self.assertRaises(ValueError): dispatch(Reader(), {'method': name})

    def test_typed_arguments_are_forwarded_without_sql(self):
        result = dispatch(Reader(), {'method': 'get_price', 'args': ['MSFT', '2026-09-10', 'RAW_CLOSE']})
        self.assertEqual(result['price_type'], 'RAW_CLOSE')

    def test_json_dates_null_nonfinite_numbers(self):
        self.assertEqual(json_value({'date': date(2026, 9, 10), 'value': float('nan')}), {'date': '2026-09-10', 'value': None})

    def test_app_queries_require_complete_backfill_but_explicit_diagnostic_can_read(self):
        reader = Reader()
        reader.get_coverage = lambda: []
        request = {'method': 'get_price', 'args': ['MSFT', '2026-09-10', 'RAW_CLOSE']}
        with self.assertRaises(MissingData): dispatch(reader, request)
        self.assertEqual(dispatch(reader, {**request, 'allow_partial': True})['ticker'], 'MSFT')
        self.assertEqual(dispatch(reader, {'method': 'get_coverage'}), [])


if __name__ == '__main__': unittest.main()
