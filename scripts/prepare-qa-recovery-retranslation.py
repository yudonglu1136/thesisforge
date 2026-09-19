#!/usr/bin/env python3
"""Build an isolated input queue for the existing local Qwen translator.

The tiny SQLite is a translator-interface fixture, NOT a valuation candidate.
Only original English fields are copied; no financial/model rows are produced.
"""
import argparse
import hashlib
import json
from pathlib import Path
import sqlite3


def digest(data):
    return hashlib.sha256(data).hexdigest()


def prepare(audit, cache, groups):
    expected = audit["recoveredCacheSha256"]
    serialized = (json.dumps(cache, ensure_ascii=False, sort_keys=True, indent=2) + "\n").encode()
    if digest(serialized) != expected or audit.get("consumableByEnricher") is not False:
        raise ValueError("Expected an exact-bound non-consumable recovery package")
    selected = []
    for source, row in audit["sources"].items():
        if row["group"] not in groups:
            continue
        target = cache[source]
        if row["source_sha256"] != digest(source.encode()) or row["translation_sha256"] != digest(target.encode()):
            raise ValueError("Recovery source/translation changed")
        selected.append({"source": source, "sourceSha256": row["source_sha256"],
                         "priorTranslationSha256": row["translation_sha256"], "group": row["group"],
                         "references": row.get("references", []), "numericStrict": row["numericStrict"],
                         "warnings": row["warnings"]})
    if not selected:
        raise ValueError("No source fields match the explicit scope")
    return sorted(selected, key=lambda row: row["sourceSha256"])


def write_queue(directory, selected, lineage):
    directory.mkdir(parents=True, exist_ok=False)
    path = directory / "translation-input-only.sqlite"
    with sqlite3.connect(path) as connection:
        connection.execute("CREATE TABLE valuation_ticker_snapshots(ticker TEXT PRIMARY KEY,payload_json TEXT NOT NULL)")
        connection.execute("CREATE TABLE translation_input_queue_metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        payload = {"purpose": "local_translation_input_adapter_only_not_financial_research", "history": [
            {"dataSnapshot": {"youtubeEarnings": {"qa": [{"question": row["source"], "answer": ""} for row in selected]}}}
        ]}
        connection.execute("INSERT INTO valuation_ticker_snapshots VALUES(?,?)", ("__TRANSLATION_QUEUE_ONLY__", json.dumps(payload, ensure_ascii=False)))
        connection.execute("INSERT INTO translation_input_queue_metadata VALUES(?,?)", ("never_publish", "true"))
    manifest = {"schemaVersion": 1, "purpose": "isolated_local_qwen_retranslation_not_valuation_model",
                "sourceCount": len(selected), "priorLineage": lineage,
                "inputDatabaseSha256": digest(path.read_bytes()), "sources": selected}
    (directory / "queue-manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return manifest


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--recovery-audit", type=Path, required=True)
    parser.add_argument("--recovery-cache", type=Path, required=True)
    parser.add_argument("--group", action="append", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    audit_bytes, cache_bytes = args.recovery_audit.read_bytes(), args.recovery_cache.read_bytes()
    selected = prepare(json.loads(audit_bytes), json.loads(cache_bytes), set(args.group))
    result = write_queue(args.output, selected, {"recoveryAuditSha256": digest(audit_bytes), "recoveryCacheSha256": digest(cache_bytes)})
    print(json.dumps({"sourceCount": result["sourceCount"], "inputDatabaseSha256": result["inputDatabaseSha256"]}))


if __name__ == "__main__":
    main()
