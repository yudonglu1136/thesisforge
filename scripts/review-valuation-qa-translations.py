#!/usr/bin/env python3
"""Apply explicit source-bound editorial corrections to a NEW local Q&A cache.

Every numeric placeholder is validated by the existing numeric-protection
engine. Preserve the previous cache/audit and record the editor and rationale;
never attribute an edited translation solely to the original local model.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path

SPEC = importlib.util.spec_from_file_location("qa_translation", Path(__file__).with_name("translate-valuation-qa-mlx.py"))
ENGINE = importlib.util.module_from_spec(SPEC)
import sys
sys.modules[SPEC.name] = ENGINE
SPEC.loader.exec_module(ENGINE)


def sha(text):
    return hashlib.sha256(text.encode()).hexdigest()


def apply_review(cache, audit, manifest):
    if not manifest.get("reviewer") or not manifest.get("reviewedAt") or not manifest.get("corrections"):
        raise ValueError("Explicit editor, review date and corrections required")
    output = dict(cache)
    report = json.loads(json.dumps(audit))
    lookup = {sha(source): source for source in report["sources"]}
    if len(lookup) != len(report["sources"]):
        raise ValueError("Ambiguous source identities")
    applied = []
    seen = set()
    for correction in manifest["corrections"]:
        key = correction["sourceSha256"]
        if key in seen or key not in lookup or not correction.get("reason"):
            raise ValueError("Unknown/duplicate source or missing review rationale")
        seen.add(key)
        source = lookup[key]
        old = report["sources"][source]
        current = cache.get(source, "")
        expected_old_hash = sha(current) if current else ""
        if (old["source_sha256"] != key or old["translation_sha256"] != expected_old_hash or
                correction["originalTranslationSha256"] != expected_old_hash):
            raise ValueError("Reviewed source or prior translation changed")
        _, values = ENGINE.protect_numbers(source)
        unprotected = ENGINE.PLACEHOLDER_RE.sub("", correction["protectedTranslation"])
        if ENGINE.PROTECTED_VALUE_RE.search(unprotected):
            raise ValueError("All numeric expressions must use source-bound placeholders; no new raw numbers")
        translated = ENGINE.restore_numbers(correction["protectedTranslation"], values)
        warnings = ENGINE.chunk_warnings(source, translated)
        if warnings:
            raise ValueError(f"Edited translation fails independent quality guards: {warnings}")
        output[source] = translated
        report["sources"][source] = {**old, "translation_sha256": sha(translated),
                                      "translation_chars": len(translated), "status": "approved", "warnings": []}
        applied.append({"sourceSha256": key, "priorTranslationSha256": expected_old_hash,
                        "translationSha256": sha(translated), "priorStatus": old["status"],
                        "reason": correction["reason"]})
    report["statusCounts"] = dict(Counter(row["status"] for row in report["sources"].values()))
    report["translatedCount"] = len(output)
    report["editorialReview"] = {"reviewer": manifest["reviewer"], "reviewedAt": manifest["reviewedAt"],
                                  "scope": "exact_source_bound_edits_only_not_full_cache_human_approval", "corrections": applied}
    return output, report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for argument in ["cache", "audit", "manifest", "output-cache", "output-audit"]:
        parser.add_argument("--" + argument, required=True, type=Path)
    args = parser.parse_args()
    if args.output_cache.exists() or args.output_audit.exists() or args.output_cache.resolve() == args.output_audit.resolve():
        raise ValueError("Use two new output paths; never overwrite prior review lineage")
    cache, audit = apply_review(json.loads(args.cache.read_text()), json.loads(args.audit.read_text()), json.loads(args.manifest.read_text()))
    audit["editorialReview"]["priorCacheFileSha256"] = hashlib.sha256(args.cache.read_bytes()).hexdigest()
    audit["editorialReview"]["priorAuditFileSha256"] = hashlib.sha256(args.audit.read_bytes()).hexdigest()
    for target, data in [(args.output_cache, cache), (args.output_audit, audit)]:
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(data, ensure_ascii=False, sort_keys=True, indent=2) + "\n")
    print(json.dumps({"corrected": len(audit["editorialReview"]["corrections"]), "statusCounts": audit["statusCounts"]}))


if __name__ == "__main__":
    main()
