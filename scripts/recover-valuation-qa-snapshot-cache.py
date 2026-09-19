#!/usr/bin/env python3
"""Recover stored bilingual Q&A as a NON-CONSUMABLE, source-bound review package.

No inference, network access, DB writes or approval inheritance. A prior metadata
attestation is not proof that the actual attached Chinese text was in its cache.
Only exact source matches may be reused; conflicting translations fail closed.
"""
from __future__ import annotations

import argparse
from collections import Counter
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import sys

ENGINE_PATH = Path(__file__).with_name("translate-valuation-qa-mlx.py")
SPEC = importlib.util.spec_from_file_location("qa_recovery_numeric_engine", ENGINE_PATH)
ENGINE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = ENGINE
SPEC.loader.exec_module(ENGINE)  # Pure functions only: MLX is lazily imported by inference.
VERSION = "qa-snapshot-source-recovery-v1"


def sha(value):
    return hashlib.sha256(value if isinstance(value, bytes) else value.encode("utf-8")).hexdigest()


def file_sha(path):
    with path.open("rb") as handle:
        return hashlib.file_digest(handle, "sha256").hexdigest()


def json_bytes(value):
    return (json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True) + "\n").encode("utf-8")


def frozen_connection(path):
    # immutable avoids SQLite creating lock sidecars. It is safe only for a
    # completed, checkpointed artifact, never an active DB or ignored WAL.
    path = path.resolve(strict=True)
    wal = Path(str(path) + "-wal")
    if wal.exists() and wal.stat().st_size:
        raise ValueError("Snapshot must be checkpointed and have no WAL frames")
    connection = sqlite3.connect(path.as_uri() + "?mode=ro&immutable=1", uri=True)
    connection.execute("PRAGMA query_only=ON")
    return connection


def inventory(path, *, require_chinese):
    digest = file_sha(path)
    cache, refs, source_set, conflicts = {}, {}, set(), []
    counts = Counter()
    with frozen_connection(path) as connection:
        for ticker, payload in connection.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots ORDER BY ticker"):
            counts["tickers"] += 1
            snapshot = json.loads(payload)
            payload_digest = sha(payload)
            for row_index, row in enumerate(snapshot.get("history", [])):
                counts["historyRows"] += 1
                qa_rows = (row.get("dataSnapshot") or {}).get("youtubeEarnings", {}).get("qa") or []
                if qa_rows:
                    counts["qaHistoryRows"] += 1
                for qa_index, qa in enumerate(qa_rows):
                    counts["qaPairs"] += 1
                    for field in ("question", "answer"):
                        source = str(qa.get(field) or "").strip()
                        if not source:
                            continue
                        source_set.add(source)
                        reference = {"ticker": ticker, "historyIndex": row_index,
                                     "periodId": row.get("periodId"), "label": row.get("label"),
                                     "field": f"history[{row_index}].dataSnapshot.youtubeEarnings.qa[{qa_index}].{field}",
                                     "snapshotPayloadSha256": payload_digest}
                        refs.setdefault(source, []).append(reference)
                        target = qa.get(field + "Zh")
                        if not require_chinese:
                            continue
                        if not isinstance(target, str) or not target.strip():
                            raise ValueError(f"Missing stored Chinese: {ticker} {reference['field']}")
                        if source in cache and cache[source] != target:
                            conflicts.append({"sourceSha256": sha(source), "reference": reference})
                        cache[source] = target
        metadata_rows = dict(connection.execute("SELECT key,value FROM valuation_pit_source_metadata"))
    if conflicts:
        raise ValueError(f"Conflicting stored translations: {json.dumps(conflicts[:5])}")
    wal = Path(str(path.resolve()) + "-wal")
    if file_sha(path) != digest or (wal.exists() and wal.stat().st_size):
        raise ValueError("Snapshot changed during read-only recovery")
    counts["uniqueSourceFields"] = len(source_set)
    return {"sha256": digest, "cache": cache, "references": refs, "sources": source_set,
            "counts": dict(counts), "metadata": metadata_rows}


def quarter_variants(value):
    # Narrow, testable equivalence only. No dropping numeric expressions or
    # arbitrary number-word/engineering-unit substitutions to hide mismatches.
    match = re.fullmatch(r"(?:Q([1-4])|([1-4])Q)", value, re.I)
    if match:
        number = int(match.group(1) or match.group(2))
        chinese = "一二三四"[number - 1]
        return [f"Q{number}", f"{number}Q", f"第{number}季度", f"第{chinese}季度", f"{number}季度"]
    match = re.fullmatch(r"FY\s*(20\d{2})", value, re.I)
    if match:
        year = match.group(1)
        return [value, f"{year}财年", f"{year}财政年度", f"{year} 财年"]
    return [value]


def numeric_check(source, target, *, normalize=False):
    _, values = ENGINE.protect_numbers(source)
    remaining = target
    failures, normalizations = [], []
    for value, expected in sorted(Counter(values).items(), key=lambda item: (-len(item[0]), item[0])):
        variants = quarter_variants(value) if normalize else [value]
        escaped = [re.escape(v) for v in sorted(set(variants), key=lambda s: -len(s))]
        if normalize:
            escaped = [re.sub(r"(?:\\ )+", r"\\s*", v) for v in escaped]
        pattern = r"(?<![A-Za-z0-9])(?:" + "|".join(escaped) + r")(?![A-Za-z0-9])"
        matches = list(re.finditer(pattern, remaining))
        if len(matches) != expected:
            failures.append({"expectedValue": value, "expectedCount": expected, "actualCount": len(matches)})
        if normalize:
            for match in matches:
                if match.group() != value:
                    normalizations.append({"sourceValue": value, "storedEquivalent": match.group(),
                                           "rule": "explicit_quarter_or_fiscal_year_or_whitespace_equivalence"})
        remaining = re.sub(pattern, "〰", remaining)
    unmatched = re.findall(r"\d[\d,.]*", remaining)
    if unmatched:
        failures.append({"unaccountedNumericTokens": unmatched})
    return {"status": "pass" if not failures else "pending_review", "protectedValueCount": len(values),
            "failures": failures, "normalizations": normalizations}


def check_pair(source, target):
    strict = numeric_check(source, target)
    normalized = numeric_check(source, target, normalize=True)
    warnings = ENGINE.chunk_warnings(source, target)
    if warnings:
        group = "language_or_terminology_guard_review"
    elif strict["status"] == "pass":
        group = "exact_numeric_guard_pass"
    elif normalized["status"] == "pass":
        group = "explicit_representation_equivalence"
    else:
        group = "numeric_mismatch_review"
    checked = not warnings and (strict["status"] == "pass" or normalized["status"] == "pass")
    return {"status": "recovery_checked" if checked else "recovered_pending_review",
            "checkScope": "source_hash_exact_numeric_and_language_guards_not_manual_semantic_approval",
            "group": group, "numericStrict": strict, "numericNormalized": normalized, "warnings": warnings}


def validate_attestation(inventory_row, expected):
    if inventory_row["sha256"] != expected["baselineSha256"]:
        raise ValueError("Baseline file SHA-256 mismatch")
    attestation = json.loads(inventory_row["metadata"].get("transcript_qa_translation_audit", "null"))
    if not isinstance(attestation, dict) or attestation.get("status") != "pass":
        raise ValueError("Missing prior translation attestation")
    for key in ("cacheSha256", "auditSha256", "usedSourceCount"):
        if attestation.get(key) != expected[key]:
            raise ValueError(f"Prior attestation {key} mismatch")
    if len(inventory_row["cache"]) != expected["usedSourceCount"]:
        raise ValueError("Recovered source coverage differs from prior attestation")
    return attestation


def verified_extra(cache_path, audit_path):
    cache_bytes, audit_bytes = cache_path.read_bytes(), audit_path.read_bytes()
    cache, audit = json.loads(cache_bytes), json.loads(audit_bytes)
    for source, translated in cache.items():
        row = audit.get("sources", {}).get(source, {})
        if (row.get("source_sha256") != sha(source) or row.get("translation_sha256") != sha(translated)
                or row.get("status") not in ("pass", "approved")):
            raise ValueError("Additional cache missing exact source/translation approval")
    return cache, audit, {"cacheSha256": sha(cache_bytes), "auditSha256": sha(audit_bytes)}


def recover(baseline, expected, candidate=None, extra=None):
    attestation = validate_attestation(baseline, expected)
    cache = dict(baseline["cache"])
    sources = {}
    for source, target in cache.items():
        sources[source] = {"source_sha256": sha(source), "translation_sha256": sha(target),
                           "source_chars": len(source), "translation_chars": len(target),
                           "origin": "stored_baseline_snapshot_not_proven_original_cache_entry",
                           "references": baseline["references"][source], **check_pair(source, target)}
    if extra:
        extra_cache, extra_audit, extra_hashes = extra
        for source, target in extra_cache.items():
            if source in cache and cache[source] != target:
                raise ValueError("Conflicting translation across baseline and additional audited cache")
            cache[source] = target
            # Keep original approval separately; the recovery report itself is
            # intentionally not a translator-compatible approval artifact.
            sources[source] = {"source_sha256": sha(source), "translation_sha256": sha(target),
                               "origin": "additional_source_hash_verified_audited_cache",
                               "originalSourceAudit": extra_audit["sources"][source],
                               "originalAuditLineage": {k: v for k, v in extra_audit.items() if k != "sources"},
                               "originalFileHashes": extra_hashes, **check_pair(source, target)}
    current = candidate["sources"] if candidate else set(cache)
    missing = sorted(current - cache.keys())
    new = sorted(current - baseline["sources"])
    groups = Counter(row["group"] for row in sources.values())
    audit = {"schemaVersion": 1, "recoveryVersion": VERSION,
             "operation": "recovered_stored_bilingual_snapshot_not_new_inference",
             "consumableByEnricher": False, "manualSemanticApproval": False,
             "baselineSha256": baseline["sha256"], "baselineCounts": baseline["counts"],
             "priorModelAttestation": attestation, "originalCacheBytesRecovered": sha(json_bytes(baseline["cache"])) == attestation["cacheSha256"],
             "originalAuditBytesRecovered": False, "guardCodeSha256": file_sha(ENGINE_PATH),
             "recoveryCodeSha256": file_sha(Path(__file__)),
             "candidateSha256": candidate["sha256"] if candidate else None,
             "candidateCounts": candidate["counts"] if candidate else None,
             "recoveredCacheSha256": sha(json_bytes(cache)), "sourceCount": len(sources),
             "statusCounts": dict(Counter(row["status"] for row in sources.values())),
             "groupCounts": dict(groups), "currentSourceCount": len(current),
             "currentNewSourceCount": len(new), "untranslatedCurrentSourceCount": len(missing),
             "untranslatedCurrentSources": [{"source": s, "sourceSha256": sha(s), "references": candidate["references"][s]} for s in missing],
             "sources": sources}
    samples = {"version": VERSION, "groups": {}}
    for group in groups:
        entries = [(s, r) for s, r in sources.items() if r["group"] == group]
        limit = len(entries) if group == "language_or_terminology_guard_review" else 15
        samples["groups"][group] = [{"source": s, "translation": cache[s], "audit": r} for s, r in entries[:limit]]
    return cache, audit, samples


def write_new(directory, cache, audit, samples):
    directory.mkdir(parents=True, exist_ok=False)
    for name, value in (("cache.json", cache), ("recovery-audit.json", audit), ("review-samples.json", samples)):
        with (directory / name).open("xb") as handle:
            handle.write(json_bytes(value))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--baseline-sha256", required=True)
    parser.add_argument("--original-cache-sha256", required=True)
    parser.add_argument("--original-audit-sha256", required=True)
    parser.add_argument("--original-source-count", type=int, required=True)
    parser.add_argument("--candidate", type=Path)
    parser.add_argument("--extra-cache", type=Path)
    parser.add_argument("--extra-audit", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    if bool(args.extra_cache) != bool(args.extra_audit):
        raise ValueError("Additional cache and audit must be supplied together")
    if args.output.exists():
        raise ValueError("Use a new private output directory")
    baseline = inventory(args.baseline, require_chinese=True)
    candidate = inventory(args.candidate, require_chinese=False) if args.candidate else None
    extra = verified_extra(args.extra_cache, args.extra_audit) if args.extra_cache else None
    expected = {"baselineSha256": args.baseline_sha256, "cacheSha256": args.original_cache_sha256,
                "auditSha256": args.original_audit_sha256, "usedSourceCount": args.original_source_count}
    cache, audit, samples = recover(baseline, expected, candidate, extra)
    write_new(args.output, cache, audit, samples)
    print(json.dumps({k: v for k, v in audit.items() if k not in ("sources", "untranslatedCurrentSources")}, indent=2))


if __name__ == "__main__":
    main()
