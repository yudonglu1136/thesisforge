#!/usr/bin/env python3
"""Find exact old-money-token bugs in a bound private Q&A recovery package.

Writes a review ledger plus a scoped local-translation input adapter. Does not
change cached translations, inference approvals, snapshots or financial inputs.
"""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sys


def load(name, filename):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(filename))
    module = importlib.util.module_from_spec(spec); sys.modules[name] = module; spec.loader.exec_module(module)
    return module


RECOVERY = load("qa_currency_recovery", "recover-valuation-qa-snapshot-cache.py")
QUEUE = load("qa_currency_queue", "prepare-qa-recovery-retranslation.py")
ENGINE = RECOVERY.ENGINE
NEW_FRAGMENT = r"[-+]?\d[\d,]*(?:\.\d+)?(?:\s*(?:trillions?|billions?|millions?|thousands?|[TBMK])(?![A-Za-z0-9]))?"
OLD_FRAGMENT = r"[-+]?\d[\d,]*(?:\.\d+)?\s*(?:trillion|billion|million|thousand|[TBMK])?"


def findings(cache, audit):
    if RECOVERY.sha(RECOVERY.json_bytes(cache)) != audit["recoveredCacheSha256"]:
        raise ValueError("Recovery cache binding mismatch")
    pattern = ENGINE.BASE_PROTECTED_VALUE_RE.pattern
    if pattern.count(NEW_FRAGMENT) != 1:
        raise ValueError("Expected exact reviewed currency-boundary implementation")
    legacy = re.compile(pattern.replace(NEW_FRAGMENT, OLD_FRAGMENT), ENGINE.PROTECTED_VALUE_RE.flags)
    selected = []
    for source, target in cache.items():
        old_values = [ENGINE.deterministic_protected_value(m) for m in legacy.finditer(source)]
        boundary_only_values = [ENGINE.deterministic_protected_value(m) for m in ENGINE.BASE_PROTECTED_VALUE_RE.finditer(source)]
        _, new_values = ENGINE.protect_numbers(source)
        if old_values == new_values:
            continue
        row = audit["sources"][source]
        if row["source_sha256"] != RECOVERY.sha(source) or row["translation_sha256"] != RECOVERY.sha(target):
            raise ValueError("Changed source/translation in recovery package")
        old_spans = [{"raw": m.group(), "value": ENGINE.deterministic_protected_value(m), "start": m.start(), "end": m.end()}
                     for m in legacy.finditer(source) if m.lastgroup == "money"]
        new_spans = [{"raw": m.group(), "value": ENGINE.deterministic_protected_value(m), "start": m.start(), "end": m.end()}
                     for m in ENGINE.PROTECTED_VALUE_RE.finditer(source) if m.lastgroup in ("money", "moneyrange")]
        active_ranges = [(start, end) for start, end, value in ENGINE.protected_value_spans(source) if "至" in value]
        shared_scale_changed = any(m.lastgroup == "moneyrange" and (m.start(), m.end()) in active_ranges
                                   and not m.group("range_left_scale") and m.group("range_right_scale")
                                   for m in ENGINE.PROTECTED_VALUE_RE.finditer(source))
        suffix_changed = old_values != boundary_only_values
        categories = []
        if suffix_changed: categories.append("currency_suffix_word_boundary_bug")
        if shared_scale_changed: categories.append("explicit_shared_scale_money_range")
        if not categories: categories.append("atomic_money_range_recipe_only")
        selected.append({"source": source, "sourceSha256": RECOVERY.sha(source),
                         "priorTranslationSha256": RECOVERY.sha(target), "priorTranslation": target,
                         "group": categories[0], "categories": categories,
                         "requiresMonetaryScopeRetranslation": suffix_changed or shared_scale_changed,
                         "references": row.get("references", []),
                         "oldMoneySpans": old_spans, "newMoneySpans": new_spans,
                         "oldProtectedValues": old_values, "boundaryOnlyProtectedValues": boundary_only_values, "newProtectedValues": new_values,
                         "numericStrict": row["numericStrict"], "warnings": ["legacy_currency_suffix_consumed_next_word"]})
    return sorted(selected, key=lambda row: row["sourceSha256"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recovery", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--exclude-reviewed-cache", type=Path, help="Queue difference only; full scope ledger is retained. This is not an approval assertion.")
    args = parser.parse_args()
    cache_bytes = (args.recovery / "cache.json").read_bytes()
    audit_bytes = (args.recovery / "recovery-audit.json").read_bytes()
    cache, audit = json.loads(cache_bytes), json.loads(audit_bytes)
    rows = findings(cache, audit)
    lineage = {"recoveryCacheSha256": RECOVERY.sha(cache_bytes), "recoveryAuditSha256": RECOVERY.sha(audit_bytes),
               "priorNumericGuardCodeSha256": audit["guardCodeSha256"], "revisedNumericGuardCodeSha256": RECOVERY.file_sha(RECOVERY.ENGINE_PATH),
               "reviewedChange": "Currency scale requires its complete word; preserve separating whitespace when no scale applies."}
    translation_rows = [row for row in rows if row["requiresMonetaryScopeRetranslation"]]
    queued_rows = translation_rows
    if args.exclude_reviewed_cache:
        excluded_bytes = args.exclude_reviewed_cache.read_bytes()
        excluded = json.loads(excluded_bytes)
        if not isinstance(excluded, dict) or any(not isinstance(k, str) or not isinstance(v, str) for k, v in excluded.items()):
            raise ValueError("Excluded cache must be an exact source-to-target map")
        lineage["queueOnlyExcludedCacheSha256"] = RECOVERY.sha(excluded_bytes)
        queued_rows = [row for row in translation_rows if row["source"] not in excluded]
    QUEUE.write_queue(args.output, queued_rows, lineage)
    report = {"schemaVersion": 1, "status": "source_scope_identified_not_translation_approval",
              "sourceCountAudited": len(cache), "affectedSourceCount": len(rows),
              "monetaryScopeRetranslationCount": len(translation_rows), "lineage": lineage, "sources": rows}
    report["queuedDifferenceCount"] = len(queued_rows)
    (args.output / "currency-suffix-source-audit.json").write_bytes(RECOVERY.json_bytes(report))
    print(json.dumps({"sourceCountAudited": len(cache), "affectedSourceCount": len(rows), "monetaryScopeRetranslationCount": len(translation_rows),
                      "tickers": sorted({ref["ticker"] for row in translation_rows for ref in row["references"]})}))


if __name__ == "__main__":
    main()
