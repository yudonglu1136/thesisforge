#!/usr/bin/env python3
"""Replace Guru security-master Yahoo validation with exact Sharadar coverage."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import duckdb


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def sha(value):
    return hashlib.sha256(canonical(value).encode()).hexdigest()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--fact-os-root", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--generated-at", required=True)
    parser.add_argument("--cutoff", required=True)
    args = parser.parse_args()
    source, root, output = args.input.resolve(), args.fact_os_root.resolve(), args.output.resolve()
    if output.exists():
        raise RuntimeError("output must be new")
    master = json.loads(source.read_text())
    fact = duckdb.connect(str(root / "fact_os.duckdb"), read_only=True)
    securities, newly_unresolved, validations = [], [], {}
    try:
        for row in master["securities"]:
            symbol = row["ticker"]
            stock = fact.execute("SELECT CAST(MIN(date) AS VARCHAR),CAST(MAX(date) AS VARCHAR) FROM stocks WHERE ticker=? AND date<=?", [symbol, args.cutoff]).fetchone()
            fund = fact.execute("SELECT CAST(MIN(date) AS VARCHAR),CAST(MAX(date) AS VARCHAR) FROM funds WHERE ticker=? AND date<=?", [symbol, args.cutoff]).fetchone()
            dataset, bounds = ("SEP", stock) if stock and stock[0] else (("SFP", fund) if fund and fund[0] else (None, (None, None)))
            validation = {
                "provider": "Sharadar Local Fact OS",
                "dataset": dataset,
                "status": "available" if dataset else "unavailable",
                "symbol": symbol,
                "instrumentType": "ETF" if dataset == "SFP" else "EQUITY" if dataset == "SEP" else None,
                "firstObservedDate": bounds[0],
                "lastObservedDate": bounds[1],
                "symbolExactMatch": bool(dataset),
            }
            validations[symbol] = validation
            if not dataset:
                newly_unresolved.append({
                    "cusip": row["cusip"],
                    "status": "unresolved",
                    "reason": "sharadar_exact_symbol_history_unavailable",
                    "candidate": {key: row.get(key) for key in ("ticker", "name", "securityId", "compositeFigi", "shareClassFigi") if row.get(key)},
                    "firstReportDate": row.get("firstReportDate"),
                    "lastReportDate": row.get("lastReportDate"),
                })
                continue
            next_row = dict(row)
            next_row["providerValidation"] = validation
            securities.append(next_row)
        next_unresolved = []
        for row in master["unresolved"]:
            next_row = dict(row)
            prior = next_row.get("providerValidation")
            if isinstance(prior, dict):
                symbol = str(prior.get("symbol") or next_row.get("openFigiTicker") or "").upper()
                stock = fact.execute("SELECT CAST(MIN(date) AS VARCHAR),CAST(MAX(date) AS VARCHAR) FROM stocks WHERE ticker=? AND date<=?", [symbol, args.cutoff]).fetchone()
                fund = fact.execute("SELECT CAST(MIN(date) AS VARCHAR),CAST(MAX(date) AS VARCHAR) FROM funds WHERE ticker=? AND date<=?", [symbol, args.cutoff]).fetchone()
                dataset, bounds = ("SEP", stock) if stock and stock[0] else (("SFP", fund) if fund and fund[0] else (None, (None, None)))
                next_row["providerValidation"] = {
                    "provider": "Sharadar Local Fact OS", "dataset": dataset,
                    "status": "available" if dataset else "not_found", "symbol": symbol,
                    "instrumentType": "ETF" if dataset == "SFP" else "EQUITY" if dataset == "SEP" else "",
                    "firstObservedDate": bounds[0], "lastObservedDate": bounds[1],
                    "symbolExactMatch": bool(dataset),
                }
                validations[f"unresolved:{next_row['cusip']}:{symbol}"] = next_row["providerValidation"]
            next_unresolved.append(next_row)
    finally:
        fact.close()
    master["securities"] = sorted(securities, key=lambda row: row["cusip"])
    master["unresolved"] = sorted(next_unresolved + newly_unresolved, key=lambda row: row["cusip"])
    master["generatedAt"] = args.generated_at
    master["matchingPolicy"] = "exact_numeric_cusip_or_letter_prefixed_cins_to_single_openfigi_us_equity_then_sharadar_exact_symbol_history_validation"
    master["source"]["providerValidation"] = "Sharadar Local Fact OS exact SEP/SFP symbol and observed daily history"
    master["source"]["providerValidationResponseSha256"] = sha(validations)
    master["source"]["providerValidationCatalogSha256"] = hashlib.sha256((root / "manifests/catalog.json").read_bytes()).hexdigest()
    master["source"]["providerValidationCutoff"] = args.cutoff
    master["selection"]["resolvedCusips"] = len(master["securities"])
    master["selection"]["unresolvedCusips"] = len(master["unresolved"])
    records = {key: master[key] for key in ("securities", "unresolved", "ambiguous")}
    master["recordsSha256"] = sha(records)
    if (master["selection"]["resolvedCusips"] + master["selection"]["unresolvedCusips"] +
            master["selection"]["ambiguousCusips"] != master["selection"]["observedCusips"]):
        raise RuntimeError("security-master partitions do not reconcile")
    if "yahoo" in canonical({"matchingPolicy": master["matchingPolicy"], "source": master["source"],
                              "securities": master["securities"], "unresolved": master["unresolved"],
                              "ambiguous": master["ambiguous"]}).lower():
        raise RuntimeError("active Yahoo validation remains")
    output.write_text(json.dumps(master, indent=2, ensure_ascii=False) + "\n")
    print(json.dumps({"resolved": len(master["securities"]), "unresolved": len(master["unresolved"]),
                      "newlyUnresolved": [row["candidate"]["ticker"] for row in newly_unresolved],
                      "recordsSha256": master["recordsSha256"]}, indent=2))


if __name__ == "__main__":
    main()
