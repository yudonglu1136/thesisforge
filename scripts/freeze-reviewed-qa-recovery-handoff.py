#!/usr/bin/env python3
"""Freeze only explicitly scoped QA repairs, with per-target replay proof.

The 14k recovery tail remains pending. This does not turn a prior aggregate
attestation into target provenance and never writes a valuation database.
"""
import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import sys

SPEC = importlib.util.spec_from_file_location("qa_freeze_editor", Path(__file__).with_name("review-prior-qa-guard21-editorial.py"))
BASE = importlib.util.module_from_spec(SPEC); sys.modules[SPEC.name] = BASE; SPEC.loader.exec_module(BASE)
RSPEC = importlib.util.spec_from_file_location("qa_freeze_recovery", Path(__file__).with_name("recover-valuation-qa-snapshot-cache.py"))
RECOVERY = importlib.util.module_from_spec(RSPEC); sys.modules[RSPEC.name] = RECOVERY; RSPEC.loader.exec_module(RECOVERY)
CSPEC = importlib.util.spec_from_file_location("qa_freeze_money", Path(__file__).with_name("review-prior-qa-currency33-editorial.py"))
MONEY = importlib.util.module_from_spec(CSPEC); sys.modules[CSPEC.name] = MONEY; CSPEC.loader.exec_module(MONEY)
EXPECTED_RECOVERY_CACHE_SHA = "6332d7113204fedbaf162ff3a03ac2cb28527ce5da79c63c3d791889a4254489"
# Exact reviewed artifacts, not self-asserted pass statuses from arbitrary files.
EXPECTED_BUNDLES = {
    "55194403dae8d4458f5933efcfe71071525c40b675d26cd0062310875e483c02": "bb0b2b3d7c9a423d95d897a106af51e23357032960bf909d5c951b643775e020",
    "d299876a1c1e155f2b7aa13796587fde18163920fdb12a58f50621558b8c1f25": "8dd036af7a518d83eddf6d32cfcf184ebc333be0cefe67b5938f32d7b861f2d1",
    "01430849683ce7bb1fbfc93d29ab0b1df4252a4606d695116d3bf78780555ace": "90aedb09a102d5deb4863622993b8f7034ca4eb3de4043ba1bb8ecc1a30134f2",
    "725e7fcf2de590740159c41c9501cf826ef63c78e6f92468fab301754d009ca1": "fb202bf7fd8e7278478068673ababb302262ccdfab9dfec5b1df62b0a0e8b799",
}


def sha(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode()


def verify_bundle_bytes(cache_bytes, audit_bytes):
    if EXPECTED_BUNDLES.get(sha(cache_bytes)) != sha(audit_bytes):
        raise ValueError("Bundle bytes differ from the exact independently reviewed cache/audit pair")


def verify_final_pair(source, target, record):
    if record.get("status") not in ("approved", "pass"):
        raise ValueError("An unreviewed recovery status cannot enter the scoped cache")
    if record.get("source_sha256") != sha(source) or record.get("translation_sha256") != sha(target):
        raise ValueError("Actual source/target hash mismatch")
    exact_numeric = RECOVERY.numeric_check(source, target)
    if exact_numeric["status"] != "pass":
        raise ValueError(f"Actual target has an unbound numeric expression or a missing exact value: {exact_numeric['failures']}")
    protected = BASE.protect_edited(source, target)
    _, values = BASE.ENGINE.protect_numbers(source)
    if BASE.ENGINE.restore_numbers(protected, values) != target:
        raise ValueError("Final target cannot be replayed exactly")
    warnings = BASE.ENGINE.chunk_warnings(source, target)
    if warnings: raise ValueError(f"Final target language/terminology failure: {warnings}")
    return {"status": "checked", "scope": "exact_final_target_count_language_and_hash_not_automatic_semantic_approval",
            "protectedTranslation": protected, "protectedValues": values,
            "protectedTranslationSha256": sha(protected), "replayedTranslationSha256": sha(target),
            "independentExactNumericCheck": exact_numeric,
            "numericProtection": BASE.ENGINE.NUMERIC_PROTECTION_VERSION}


def current_mechanical_check(source, target):
    """Inspect the actual target without overwriting or approving it.

    The optional normalization only proves exact source-bound monetary range
    punctuation/whitespace and explicit quarter/FY equivalence. No quantity
    scale, financial metric ownership or semantic judgment is inferred.
    """
    pair = RECOVERY.check_pair(source, target)
    if pair["status"] == "recovery_checked":
        return pair
    try:
        canonical = MONEY.normalize_range_representation(source, target)
    except ValueError:
        return pair
    if canonical != target:
        equivalent = RECOVERY.numeric_check(source, canonical, normalize=True)
        if equivalent["status"] == "pass" and not pair["warnings"]:
            return {**pair, "status": "recovery_checked", "group": "exact_source_money_range_representation_equivalence",
                    "moneyRangeRepresentationProof": {"rule": "exact_source_range_values_only_punctuation_whitespace_no_scale_inference",
                                                      "actualTargetSha256": sha(target), "canonicalCheckTargetSha256": sha(canonical),
                                                      "numericCheck": equivalent}}
    return pair


def freeze(recovery_directory, package_directories):
    recovery_bytes = (recovery_directory / "cache.json").read_bytes()
    ra_bytes = (recovery_directory / "recovery-audit.json").read_bytes()
    if sha(recovery_bytes) != EXPECTED_RECOVERY_CACHE_SHA:
        raise ValueError("The exact frozen recovery source index is required")
    recovered, recovery_audit = json.loads(recovery_bytes), json.loads(ra_bytes)
    if len(recovered) != 14678 or recovery_audit["recoveredCacheSha256"] != sha(recovery_bytes):
        raise ValueError("Recovery scope changed")
    cache, source_audits, registry, warnings = {}, {}, [], []
    fresh_semantic, carried_prior = 0, 0
    counts = []
    for directory in package_directories:
        cb, ab = (directory / "cache.json").read_bytes(), (directory / "audit.json").read_bytes()
        verify_bundle_bytes(cb, ab)
        entries, audit = json.loads(cb), json.loads(ab)
        counts.append(len(entries))
        if set(entries) != set(audit["sources"]): raise ValueError("Package cache/audit scope mismatch")
        note_index = {row["sourceSha256"]: row for row in audit.get("exactSourceReview", {}).get("sources", [])}
        corrections = {row["sourceSha256"]: row for row in audit.get("editorialReview", {}).get("corrections", [])}
        is_crdo = bool(audit.get("finalRecheckScope"))
        if is_crdo:
            if len(entries) != 216 or len(corrections) != 3: raise ValueError("Exact CRDO three-field recheck expected")
        elif len(entries) == 21:
            if len(corrections) != 16: raise ValueError("Exact 21-field editorial expected")
        elif len(note_index) != len(entries):
            raise ValueError("Exact per-source bilingual review notes required")
        registry.append({"directory": str(directory.resolve()), "sourceCount": len(entries), "cacheSha256": sha(cb), "auditSha256": sha(ab),
                         "originalQwenProvenance": {key: audit.get(key) for key in ("model", "numericProtection", "systemPromptSha256", "retrySystemPromptSha256", "numericSpanSystemPromptSha256", "finalRetrySystemPromptSha256", "startedAt", "updatedAt")},
                         "editorialReview": audit.get("editorialReview"), "finalRecheckScope": audit.get("finalRecheckScope")})
        for source, target in entries.items():
            if source not in recovered or source in cache: raise ValueError("Unknown or conflicting source across packages")
            original = recovery_audit["sources"][source]
            if original["source_sha256"] != sha(source) or original["translation_sha256"] != sha(recovered[source]):
                raise ValueError("Recovery source/old-target index corrupted")
            proof = verify_final_pair(source, target, audit["sources"][source])
            exact_review = not is_crdo or sha(source) in corrections
            fresh_semantic += int(exact_review); carried_prior += int(not exact_review)
            source_warnings = note_index.get(sha(source), {}).get("sourceWarnings", [])
            for warning in source_warnings:
                if isinstance(warning, str):
                    category = "source_internal_inconsistency" if "both $1.85-$1.95 and $185-$195" in warning else "source_ambiguity"
                    warning = {"category": category, "detail": warning}
                warnings.append({"sourceSha256": sha(source), "source": source, "references": original.get("references", []), **warning})
            cache[source] = target
            source_audits[source] = {**audit["sources"][source], "finalTargetProof": proof,
                                    "originalRecoveryTranslationSha256": original["translation_sha256"],
                                    "sourceBundleCacheSha256": sha(cb), "sourceBundleAuditSha256": sha(ab),
                                    "semanticReviewScope": ("current_targeted_CRDO_expression_review" if is_crdo and exact_review else "current_full_field_bilingual_review" if exact_review else "retain_exact_prior_CRDO_audit_not_new_semantic_approval"),
                                    "sourceWarnings": source_warnings, "references": original.get("references", [])}
    if sorted(counts) != [19, 21, 33, 216] or len(cache) != 289 or fresh_semantic != 76 or carried_prior != 213:
        raise ValueError("The frozen bounded 289-field handoff scope changed")
    pending, full_checks, merged = [], [], {**recovered, **cache}
    for source, target in merged.items():
        original = recovery_audit["sources"][source]
        if original["source_sha256"] != sha(source) or original["translation_sha256"] != sha(recovered[source]):
            raise ValueError("Full source/old-target index binding changed")
        check = current_mechanical_check(source, target)
        record = {"sourceSha256": sha(source), "source": source, "actualTargetSha256": sha(target),
                  "priorTargetSha256": original["translation_sha256"], "scopeReviewed": source in cache,
                  "currentV8MechanicalCheck": check, "previousRecoveryGroup": original["group"], "references": original.get("references", [])}
        full_checks.append(record)
        if source not in cache:
            pending.append({**record, "status": "pending_not_consumable_no_semantic_approval"})
    code_names = ["translate-valuation-qa-mlx.py", "review-prior-qa-guard21-editorial.py", "review-prior-qa-currency33-editorial.py",
                  "review-prior-qa-money19-editorial.py", "review-crdo-qa-two-field-recheck.py", "recover-valuation-qa-snapshot-cache.py", Path(__file__).name]
    audit = {"schemaVersion": 1, "status": "scoped_exact_target_cache_ready_not_full_platform_release", "model": "mlx-community/Qwen3-4B-Instruct-2507-4bit",
             "modelAttribution": "Original local Qwen generation plus separately documented exact editorial; not all targets are solely model output",
             "numericProtection": "per_source_original_generation_plus_independent_" + BASE.ENGINE.NUMERIC_PROTECTION_VERSION,
             "systemPromptSha256": None, "retrySystemPromptSha256": None,
             "promptProvenance": "Multiple exact original prompts; use sourceBundleAuditSha256 and packageRegistry, not a fabricated single prompt hash",
             "sourceCount": len(cache), "translatedCount": len(cache),
             "statusCounts": dict(Counter(row["status"] for row in source_audits.values())),
             "sources": source_audits, "packageRegistry": registry,
             "independentGuardCodeSha256": sha(Path(BASE.ENGINE.__file__).read_bytes()),
             "codeHashes": {name: sha(Path(__file__).with_name(name).read_bytes()) for name in code_names},
             "recoveryCacheSha256": sha(recovery_bytes), "recoveryAuditSha256": sha(ra_bytes),
             "originalAggregateAuditNotInheritedAsTargetApproval": True, "cacheSha256": sha(json_bytes(cache)),
             "fullPlatformReady": False, "sourceFinancialFactAttestation": False}
    report = {"sourceUniverse": len(recovered), "scopedConsumableExactTargetCount": len(cache), "currentFullFieldSemanticReviewCount": 73,
              "currentTargetedCRDOExpressionReviewCount": 3,
              "retainedPriorExactCRDOAuditCountNotNewSemanticApproval": carried_prior, "pendingNotConsumableCount": len(pending),
              "sourceWarningsCount": len(warnings), "sourceInternalInconsistencyCount": sum(w["category"] == "source_internal_inconsistency" for w in warnings),
              "pendingGroups": dict(Counter(row["previousRecoveryGroup"] for row in pending)),
              "fullCurrentV8MechanicalGroups": dict(Counter(row["currentV8MechanicalCheck"]["group"] for row in full_checks)),
              "fullCurrentV8MechanicalPassCountNotSemanticApproval": sum(row["currentV8MechanicalCheck"]["status"] == "recovery_checked" for row in full_checks),
              "fullCurrentV8MechanicalPendingCount": sum(row["currentV8MechanicalCheck"]["status"] != "recovery_checked" for row in full_checks),
              "originalCacheBytesRecovered": False, "originalAggregatePassReused": False,
              "newUncachedEnglishSourceCount": 0, "newEnglishScopeVersusBaseline": 216,
              "scopeMeaning": "289 are valid only as a source/target-bound subset; the full 14,678-field enrichment must still fail until pending fields are independently resolved.",
              "cacheSha256": sha(json_bytes(cache)), "auditSha256": sha(json_bytes(audit)),
              "pendingIndexSha256": sha(json_bytes(pending)), "sourceWarningsSha256": sha(json_bytes(warnings)),
              "fullCurrentV8LedgerSha256": sha(json_bytes(full_checks)), "mergedRecoveredCacheSha256NonConsumable": sha(json_bytes(merged))}
    return {"cache.json": cache, "audit.json": audit, "pending-source-index.json": pending,
            "source-warnings.json": warnings, "handoff-summary.json": report,
            "full-v8-guard-ledger.json": full_checks, "reconstructed-cache-NOT-FULLY-APPROVED.json": merged}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument("--recovery", type=Path, required=True); p.add_argument("--package", type=Path, action="append", required=True)
    p.add_argument("--output", type=Path, required=True); a = p.parse_args()
    files = freeze(a.recovery, a.package)
    a.output.mkdir(parents=True, exist_ok=False)
    for name, value in files.items():
        with (a.output / name).open("xb") as h: h.write(json_bytes(value))
    print(json.dumps(files["handoff-summary.json"], ensure_ascii=False))


if __name__ == "__main__": main()
