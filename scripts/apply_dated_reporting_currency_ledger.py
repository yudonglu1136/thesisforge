#!/usr/bin/env python3
"""Attach independently audited reporting-currency evidence in a NEW DB copy.

Never updates the original DB, amounts, sourceRecord, FX, filing dates,
financial SQL currency, guidance, coverage or issuer review status.
"""
from collections import Counter
from contextlib import closing
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import argparse

from audit_dated_reporting_currency_ledger import audit


def readonly(path):
    return sqlite3.connect(Path(path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)


def digest(value):
    return hashlib.sha256(value).hexdigest()


def apply_ledger(source_path, metadata_path, ledger_path, output_path):
    source_path = Path(source_path).resolve(strict=True)
    metadata_path = Path(metadata_path).resolve(strict=True)
    ledger_path = Path(ledger_path).resolve(strict=True)
    output_path = Path(output_path).absolute()
    if output_path.exists() or output_path.is_symlink():
        raise FileExistsError("Refusing to overwrite any existing target or symlink")
    if output_path.resolve() in {source_path, metadata_path}:
        raise ValueError("Output cannot be an input database")
    raw_ledger = ledger_path.read_bytes()
    ledger_hash = digest(raw_ledger)
    ledger = json.loads(raw_ledger)
    verified = audit(ledger)
    if verified.get("status") != "passed":
        raise ValueError(f"Independent original-fact audit failed: {verified}")
    rows = ledger["targets"]
    keys = [(row["ticker"], row["targetAvailableAt"]) for row in rows]
    if len(keys) != len(set(keys)):
        raise ValueError("Duplicate ledger target keys")
    resolved = {key: row for key, row in zip(keys, rows) if row["status"] == "resolved"}
    with closing(readonly(metadata_path)) as metadata:
        metadata_ciks = {}
        for ticker, raw in metadata.execute("SELECT ticker,payload_json FROM valuation_ticker_snapshots"):
            cik = str(json.loads(raw).get("cik", ""))
            if cik.isdigit() and int(cik) > 0:
                metadata_ciks[ticker] = cik.zfill(10)
    for ticker in {key[0] for key in resolved}:
        if not metadata_ciks.get(ticker) or metadata_ciks[ticker] != ledger["issuers"][ticker]["cik"]:
            raise ValueError(f"{ticker}: authoritative runtime snapshot CIK does not match ledger")
    with closing(readonly(source_path)) as source:
        source.execute("BEGIN")
        if source.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Source database integrity failed")
        counts = {(t, d): n for t, d, n in source.execute(
            "SELECT ticker,available_at,count(*) FROM pit_financial_periods GROUP BY ticker,available_at")}
        for key, row in resolved.items():
            if isinstance(row.get("financialRows"), bool) or counts.get(key) != row.get("financialRows"):
                raise ValueError(f"{key}: exact target date / financial row count does not match")
        changes = []
        original_financial_rows = 0
        unchanged_financial_rows = 0
        for ticker, period, dimension, available, currency, raw in source.execute(
                "SELECT ticker,fiscal_period,dimension,available_at,currency,payload_json FROM pit_financial_periods ORDER BY ticker,fiscal_period,dimension"):
            original_financial_rows += 1
            row = resolved.get((ticker, available))
            if row is None:
                unchanged_financial_rows += 1
                continue
            payload = json.loads(raw)
            # Existing evidence belongs to its original review. Never replace it.
            if "reportingCurrency" in payload or "reportingCurrencyEvidence" in payload:
                raise ValueError(f"{ticker}/{period}/{dimension}: existing reporting-currency evidence cannot be overwritten")
            record = payload.get("sourceRecord") or {}
            explicit = [payload.get("sourceFinancialStatementCurrency"), record.get("sourceCurrency"), record.get("reportingCurrency")]
            if any(v is not None and v != row["currency"] for v in explicit):
                raise ValueError(f"{ticker}/{period}/{dimension}: existing explicit source currency conflicts")
            if payload.get("asOfDate") != available or payload.get("ticker") != ticker or payload.get("sourceDimension") != dimension:
                raise ValueError(f"{ticker}/{period}/{dimension}: payload and SQL identity/date mismatch")
            issuer = ledger["issuers"][ticker]
            evidence = {
                "version": ledger["version"], "status": "independently_verified_dated_reporting_currency",
                "currency": row["currency"], "targetAvailableAt": available,
                "sourceAvailableAt": row["availableAt"], "basis": row["basis"],
                "cik": issuer["cik"], "companyFactsUrl": issuer["url"], "companyFactsSha256": issuer["sha256"],
                "ledgerSha256": ledger_hash, "originalPayloadSha256": digest(raw.encode("utf8")),
                "filings": row["filings"],
                "policy": "Only reporting-currency evidence appended. Original normalized numbers, sourceRecord, FX and dates unchanged; no original statement amount or conversion asserted."
            }
            updated = {**payload, "reportingCurrency": row["currency"], "reportingCurrencyEvidence": evidence}
            if {k: v for k, v in updated.items() if k not in {"reportingCurrency", "reportingCurrencyEvidence"}} != payload:
                raise ValueError("Currency enrichment unexpectedly changed original payload")
            changes.append((json.dumps(updated, separators=(",", ":"), allow_nan=False), ticker, period, dimension))
        if len(changes) != sum(row["financialRows"] for row in resolved.values()):
            raise ValueError("Not every resolved target row was accounted for")
        output_path.parent.mkdir(parents=True, exist_ok=True)
        # O_EXCL closes the check/create race; sqlite never opens a preexisting DB.
        fd = os.open(output_path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.close(fd)
        with closing(sqlite3.connect(output_path)) as target:
            source.backup(target)
            target.execute("PRAGMA journal_mode=DELETE")
            target.executemany("UPDATE pit_financial_periods SET payload_json=? WHERE ticker=? AND fiscal_period=? AND dimension=?", changes)
            target.commit()
            if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise RuntimeError("New evidence-copy database failed integrity check; do not publish")
            after_rows = target.execute("SELECT count(*) FROM pit_financial_periods").fetchone()[0]
            if after_rows != original_financial_rows:
                raise RuntimeError("New copy changed financial row count; do not publish")
    return {"status": "new_currency_evidence_copy_not_release_authorization", "source": str(source_path),
            "output": str(output_path.resolve()), "sourceRows": original_financial_rows,
            "enrichedRows": len(changes), "unchangedRows": unchanged_financial_rows,
            "resolvedTargets": len(resolved), "blockedTargetsUnchanged": sum(row["status"] == "blocked" for row in rows),
            "ledgerSha256": ledger_hash, "independentAudit": verified,
            "changedFieldsOnly": ["payload.reportingCurrency", "payload.reportingCurrencyEvidence"]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ["source-db", "metadata-db", "ledger", "output-db"]:
        parser.add_argument("--" + key, type=Path, required=True)
    args = parser.parse_args()
    result = apply_ledger(args.source_db, args.metadata_db, args.ledger, args.output_db)
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
