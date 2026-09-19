#!/usr/bin/env python3
"""Triage numeric mismatches without treating plausible aliases as approvals."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re


def sha(data):
    return hashlib.sha256(data).hexdigest()


def labels(row):
    result = set()
    for failure in row["numericNormalized"]["failures"]:
        value = failure.get("expectedValue", "")
        if "unaccountedNumericTokens" in failure:
            result.add("unaccounted_digits_need_source_context")
        elif "美元" in value or "英镑" in value or "欧元" in value or "日元" in value:
            result.add("currency_magnitude_or_format")
        elif "%" in value or "基点" in value:
            result.add("percentage_basis_points_sign_range_or_count")
        elif re.fullmatch(r"(?:FY\s*\d{2,4}|\dQ|Q\d|H[12])", value, re.I):
            result.add("quarter_fiscal_year_or_half_year")
        elif re.search(r"(?:\d+x|\d+(?:st|nd|rd|th)|\d+s|mid-\d|high-\d|low-\d)", value, re.I):
            result.add("multiple_ordinal_decade_or_financial_range_suffix")
        elif re.search(r"[A-Za-z]", value):
            result.add("engineering_product_identifier_or_named_number")
        else:
            result.add("plain_numeric_value_or_occurrence_count")
    return sorted(result)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recovery", type=Path, required=True)
    parser.add_argument("--currency-scope", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if args.output.exists():
        raise ValueError("Output must be new")
    audit_bytes = (args.recovery / "recovery-audit.json").read_bytes()
    cache_bytes = (args.recovery / "cache.json").read_bytes()
    scope_bytes = args.currency_scope.read_bytes()
    audit, cache, scope = json.loads(audit_bytes), json.loads(cache_bytes), json.loads(scope_bytes)
    if sha(cache_bytes) != audit["recoveredCacheSha256"]:
        raise ValueError("Cache hash mismatch")
    currency_affected = {row["sourceSha256"] for row in scope["sources"]}
    rows, samples, counts, expression_counts = [], {}, Counter(), Counter()
    for source, row in audit["sources"].items():
        if row["group"] != "numeric_mismatch_review":
            continue
        if sha(source.encode()) != row["source_sha256"] or sha(cache[source].encode()) != row["translation_sha256"]:
            raise ValueError("Changed source or translation")
        categories = labels(row)
        if row["source_sha256"] in currency_affected:
            categories.append("confirmed_legacy_currency_suffix_bug")
        item = {"sourceSha256": row["source_sha256"], "translationSha256": row["translation_sha256"],
                "categories": categories, "status": "triage_only_not_approved", "references": row.get("references", []),
                "numericFailures": row["numericNormalized"]["failures"]}
        rows.append(item)
        for category in categories:
            counts[category] += 1
            samples.setdefault(category, [])
            if len(samples[category]) < 5:
                samples[category].append({**item, "source": source, "translation": cache[source]})
        for failure in row["numericNormalized"]["failures"]:
            if failure.get("expectedValue"):
                expression_counts[failure["expectedValue"]] += 1
    report = {"schemaVersion": 1, "status": "triage_only_not_translation_approval", "fieldCount": len(rows),
              "categoryCountPolicy": "multi_label_fields_may_appear_in_several_categories",
              "categoryCounts": dict(counts), "commonExpressions": expression_counts.most_common(40),
              "lineage": {"recoveryAuditSha256": sha(audit_bytes), "cacheSha256": sha(cache_bytes), "currencyScopeSha256": sha(scope_bytes)},
              "normalizationRequirements": {
                  "quarter_fiscal_year_or_half_year": "Bind the complete fiscal label and its year/context; H2 can mean hydrogen, not always the second half. Never discard the digit.",
                  "multiple_ordinal_decade_or_financial_range_suffix": "Distinguish 2x multiples from doubled growth, 70s percentage levels from calendar decades, and ordinal words; exact source context is required.",
                  "engineering_product_identifier_or_named_number": "Do not treat gig/gigabit/gigabyte as interchangeable, or remove versions from product names. Any engineering-unit equivalence needs the actual unit and dimensional conversion.",
                  "percentage_basis_points_sign_range_or_count": "Bind ranges and signs: a dash range endpoint may be positive while a stand-alone signed value is negative. A percent is not a basis point; count repeated expressions separately.",
                  "currency_magnitude_or_format": "Compare amount times explicit source scale to target amount times 亿/万. Bare amounts cannot inherit a scale from the next English word.",
                  "unaccounted_digits_need_source_context": "An English spelled-out month or number may legitimately become a digit, but prove its paired context; additional digits are never silently ignored."},
              "fields": rows, "samples": samples}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    with args.output.open("x") as handle:
        handle.write(json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"fieldCount": len(rows), "categoryCounts": dict(counts), "reportSha256": sha(args.output.read_bytes())}))


if __name__ == "__main__":
    main()
