import importlib.util
from pathlib import Path
import sys
import unittest

SPEC = importlib.util.spec_from_file_location("currency_editorial_test", Path(__file__).with_name("review-prior-qa-currency33-editorial.py"))
MOD = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = MOD; SPEC.loader.exec_module(MOD)


class ExactCurrencyEditorialTests(unittest.TestCase):
    def test_range_representation_is_count_bound(self):
        source = "The range is $210-$230."
        self.assertEqual(MOD.normalize_range_representation(source, "区间为210美元 到 230美元。"), "区间为210美元至230美元。")

    def test_ambiguous_scalar_pair_is_not_silently_grouped(self):
        source = "$210 going to $230 is the change. The range is $210-$230."
        with self.assertRaisesRegex(ValueError, "Ambiguous range"):
            MOD.normalize_range_representation(source, "从210美元 到 230美元，区间为210美元 到 230美元。")

    def test_exact_selection_keeps_other_scalar_pair_separate(self):
        source = "$210 going to $230 is the change. The range is $210-$230."
        target = "从210美元 到 230美元，区间为210美元至230美元。"
        normalized = MOD.normalize_range_representation(source, target)
        self.assertEqual(normalized, target)
        protected = MOD.BASE.protect_edited(source, normalized)
        self.assertEqual(protected, "从⟦N0⟧ 到 ⟦N1⟧，区间为⟦N2⟧。")

    def test_costco_amount_owner_fix_is_explicit_not_numeric_guard_claim(self):
        _, edits, reason = next(row for row in MOD.EDITS if row[0].startswith("Gary Millerchip"))
        self.assertIn(("每笔订单支出达到 10美元 时可享受每月 150美元 优惠", "每月可享受 10美元 优惠、条件是购物篮金额达到 150美元"), edits)
        self.assertIn("ownership inversion", reason)

    def test_unqualified_quantity_is_not_promoted_to_millions(self):
        _, edits, reason = next(row for row in MOD.EDITS if row[0].startswith("Bob Halliday"))
        target = next(after for before, after in edits if "1.3 万片" in before)
        self.assertIn("1.3 百万片", target)
        self.assertNotIn("150 万", target)
        self.assertIn("do not invent a scale", reason)


if __name__ == "__main__":
    unittest.main()
