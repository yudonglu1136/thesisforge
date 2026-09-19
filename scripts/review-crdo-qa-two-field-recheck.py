#!/usr/bin/env python3
"""Correct initial two CRDO targets plus one final source-bound month/timing expression."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location("crdo_two_editor", Path(__file__).with_name("review-prior-qa-guard21-editorial.py"))
BASE = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = BASE; SPEC.loader.exec_module(BASE)
EDITS = [
 ("Bill Brennan — President, CEO & Chairman, Credo Technology Group: Yes, we definitely see it being broader", [
  ("PCIe Gen 6", "PCIe Gen six（第六代）")],
  "Represent the explicit English word six without introducing a new digit recipe. The protocol generation and 200 gig-per-lane meaning are unchanged."),
 ("what is the expectation for this IP in Q3?", [
  ("500 万美元-700 万美元", "500 万美元至700 万美元"),
  ("来自 Q2 的IP收入未能进入 Q3 那部分", "Q2缺失的那部分IP收入延后进入 Q3")],
  "Fix the prior translation's reversed relationship: missing Q2 revenue comes into Q3, not fails to enter Q3. Normalize only the explicit $5m-$7m range representation."),
 ("Bill Brennan — President and CEO, Credo Technology Group: I think we've alluded", [
  ("其中11月是个关键月份", "其中十一月是个关键月份"),
  ("时间可能在一个月左右", "前后可能相差一个月左右")],
  "November is an explicit source month, represented in Chinese words for exact digit-recipe replay. Give or take a month is timing uncertainty around the upcoming quarter, not a one-month duration.")
]


def review(cache, audit):
    if len(cache) != 216: raise ValueError("Exact prior 216-field CRDO cache required")
    corrections = []
    for prefix, edits, reason in EDITS:
        found = [s for s in cache if s.startswith(prefix)]
        if len(found) != 1: raise ValueError("Expected exact unique CRDO field")
        source = found[0]; target = cache[source]
        for before, after in edits:
            if before not in target: raise ValueError("Reviewed original CRDO wording changed")
            target = target.replace(before, after)
        corrections.append({"sourceSha256": BASE.sha(source), "originalTranslationSha256": BASE.sha(cache[source]),
                            "protectedTranslation": BASE.protect_edited(source, target), "reason": reason})
    manifest = {"reviewer": "Codex exact-source bilingual editorial review, not a human review claim",
                "reviewedAt": "2026-09-06", "corrections": corrections}
    output, report = BASE.EDITOR.apply_review(cache, audit, manifest)
    report["finalRecheckScope"] = {"exactEditorialCount": 3, "otherSourcesRetainPriorAuditNotNewSemanticApproval": 213,
                                  "numericGuardVersion": BASE.ENGINE.NUMERIC_PROTECTION_VERSION}
    return output, report, manifest


def main():
    p = argparse.ArgumentParser(description=__doc__)
    for k in ("cache", "audit", "output"): p.add_argument("--" + k, required=True, type=Path)
    a = p.parse_args(); cb, ab = a.cache.read_bytes(), a.audit.read_bytes()
    output, report, manifest = review(json.loads(cb), json.loads(ab))
    report["editorialReview"]["priorCacheFileSha256"] = hashlib.sha256(cb).hexdigest()
    report["editorialReview"]["priorAuditFileSha256"] = hashlib.sha256(ab).hexdigest()
    a.output.mkdir(parents=True, exist_ok=False)
    for name, value in (("cache.json", output), ("audit.json", report), ("editorial-manifest.json", manifest)):
        with (a.output / name).open("x") as h: h.write(json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    print(json.dumps({"sourceCount": 216, "editedSourceCount": 3, "statusCounts": report["statusCounts"]}))


if __name__ == "__main__": main()
