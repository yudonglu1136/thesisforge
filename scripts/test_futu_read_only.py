import unittest
from types import SimpleNamespace
from futu_read_only import read_account, FutuReadError


class Frame:
    def __init__(self, rows):
        self.rows = rows

    def to_dict(self, orient):
        assert orient == "records"
        return self.rows


SDK = SimpleNamespace(RET_OK=0, TrdEnv=SimpleNamespace(REAL="REAL"),
                      Currency=SimpleNamespace(USD="USD"))


class Context:
    def __init__(self):
        self.calls = []
        self.accounts = [{"acc_id": 42, "trd_env": "REAL"}]

    def get_acc_list(self):
        self.calls.append("accounts")
        return 0, Frame(self.accounts)

    def accinfo_query(self, **kwargs):
        self.calls.append(("funds", kwargs))
        return 0, Frame([{"total_assets": 100, "currency": "USD"}])

    def position_list_query(self, **kwargs):
        self.calls.append(("positions", kwargs))
        return 0, Frame([])


class ReadOnlyTests(unittest.TestCase):
    def test_explicit_real_identity_and_no_trade_methods(self):
        ctx = Context()
        result = read_account(ctx, SDK, "42")
        self.assertEqual(result["access"], "read_only")
        self.assertEqual(result["positions"], [])
        self.assertEqual(len(ctx.calls), 3)
        for _, kwargs in ctx.calls[1:]:
            self.assertEqual(kwargs["acc_id"], 42)
            self.assertEqual(kwargs["trd_env"], "REAL")
            self.assertNotIn("acc_index", kwargs)

    def test_no_fallback_to_another_or_simulated_account(self):
        for accounts in [[{"acc_id": 43, "trd_env": "REAL"}],
                         [{"acc_id": 42, "trd_env": "SIMULATE"}]]:
            ctx = Context()
            ctx.accounts = accounts
            with self.assertRaisesRegex(FutuReadError, "real_account_not_found"):
                read_account(ctx, SDK, 42)
            self.assertEqual(ctx.calls, ["accounts"])

    def test_partial_read_failure_does_not_publish(self):
        ctx = Context()
        ctx.position_list_query = lambda **kwargs: (-1, "private account details")
        with self.assertRaisesRegex(FutuReadError, "^futu_read_failed$"):
            read_account(ctx, SDK, 42)


if __name__ == "__main__":
    unittest.main()
