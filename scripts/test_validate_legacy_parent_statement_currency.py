import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest

SPEC=importlib.util.spec_from_file_location("legacy_parent",Path(__file__).with_name("validate_legacy_parent_statement_currency.py"))
MODULE=importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)
DATA=json.loads((Path(__file__).parent.parent/"server/fixtures/event-guidance-currency-evidence-dis-ci.json").read_text())


def refreshed(xml):
    xml["fragmentsSha256"]=[MODULE.sha(f["raw"]) for f in xml["fragments"]]
    return xml


class LegacyParentStatementTests(unittest.TestCase):
    def test_nine_actual_original_statements_for_eighteen_events(self):
        self.assertEqual(len(DATA["documents"]),9)
        self.assertEqual(len(DATA["events"]),18)
        for row in DATA["events"]:
            proof=DATA["documents"][row["contract"]["proofDocumentSha256"]]
            MODULE.validate_fragment_semantics(row["ticker"],proof["cik"],proof["xbrlStatementEvidence"])

    def test_segment_and_subsidiary_context_cannot_replace_aggregate_even_with_rehashed_fragments(self):
        for proof in DATA["documents"].values():
            xml=copy.deepcopy(proof["xbrlStatementEvidence"])
            for f in xml["fragments"]:
                if f["key"].startswith("context:"):
                    f["raw"]=re.sub(r"</(xbrli:)?entity>",lambda m:"<"+(m[1] or "")+"segment/></"+(m[1] or "")+"entity>",f["raw"])
            with self.assertRaises(ValueError):
                MODULE.validate_fragment_semantics("DIS" if proof["cik"]=="0001001039" else "CI",proof["cik"],refreshed(xml))

    def test_non_usd_wrong_issuer_or_statement_year_rejected(self):
        for proof in DATA["documents"].values():
            ticker="DIS" if proof["cik"]=="0001001039" else "CI"
            for before,after in [("iso4217:USD","iso4217:CAD"),(proof["cik"],"0000000001"),(proof["xbrlStatementEvidence"]["periodEnd"],"2099-12-31")]:
                xml=copy.deepcopy(proof["xbrlStatementEvidence"])
                for f in xml["fragments"]:f["raw"]=f["raw"].replace(before,after)
                with self.assertRaises(ValueError):MODULE.validate_fragment_semantics(ticker,proof["cik"],refreshed(xml))

    def test_complete_four_categories_and_original_namespaces_required(self):
        proof=next(iter(DATA["documents"].values()))
        for kind in ["missing","duplicate","namespace"]:
            xml=copy.deepcopy(proof["xbrlStatementEvidence"])
            if kind=="missing":xml["fragments"].pop()
            elif kind=="duplicate":xml["fragments"].append(copy.deepcopy(xml["fragments"][-1]))
            else:
                xml["rootOpenTag"]=xml["rootOpenTag"].replace('xmlns:iso4217="http://www.xbrl.org/2003/iso4217"','xmlns:iso4217="https://example.com/currencies"')
                xml["rootOpenTagSha256"]=MODULE.sha(xml["rootOpenTag"])
            with self.assertRaises(ValueError):MODULE.validate_fragment_semantics("CI" if proof["cik"]=="0000701221" else "DIS",proof["cik"],refreshed(xml))

    def test_old_cigna_and_disney_cannot_cross_reorganization_boundary(self):
        for ticker,date in [("CI","2018-12-20"),("DIS","2019-03-20")]:
            row=next(r for r in DATA["events"] if r["ticker"]==ticker)
            proof=DATA["documents"][row["contract"]["proofDocumentSha256"]]
            with self.assertRaisesRegex(ValueError,"reorganization boundary"):
                MODULE.validate_legacy_statement_proof({**row,"observedAt":date},proof,{},"")


if __name__=="__main__":unittest.main()
