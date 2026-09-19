#!/usr/bin/env python3
"""Repair only frozen FY24+ Diageo native-USD inputs in a NEW private source.

Every monetary amount is reconciled to the exact dated paid-provider row before
conversion. Shares, pre-FY24 history and every unrelated table remain unchanged.
This input audit never certifies a rebuilt valuation or authorizes a release.
"""
import argparse
from contextlib import closing
import hashlib
import importlib.util
import json
import math
from pathlib import Path
import sqlite3

FIELDS = {"revenue_m": "revenue", "gross_profit_m": "gp", "operating_income_m": "opinc",
          "net_income_m": "netinc", "cfo_m": "ncfo", "capex_m": "capex", "equity_m": "equity",
          "assets_m": "assets", "cash_m": "cashneq", "debt_m": "debt"}
VERSION = "dge-fy24-dated-usd-gbp-input-repair-v1-2026-09-06"


def builder_module():
    spec = importlib.util.spec_from_file_location("dge_currency_builder", Path(__file__).with_name("build-pit-valuation-source.py"))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def equal(left, right):
    return left is right if left is None or right is None else math.isclose(left, right, rel_tol=1e-10, abs_tol=1e-8)


def repaired_payload(old, raw, rates, builder):
    if (old.get("ticker") != "DGE.L" or old.get("sourceTicker") != "DEO"
            or old.get("periodEndDate", "") < "2023-12-31"
            or old.get("asOfDate", "") < "2024-01-30"):
        raise ValueError("Outside exact dated DGE repair scope")
    if old.get("sourceRecord", {}).get("currencyScale") != 1 or old.get("financialStatementCurrency") != "GBP":
        raise ValueError("Not the original unconverted GBP-labelled input; refusing double FX")
    if (str(raw["datekey"]) != old["asOfDate"] or str(raw["reportperiod"]) != old["periodEndDate"]
            or raw["dimension"] != old["sourceDimension"]):
        raise ValueError("Provider row does not match the exact retained PIT observation")
    native = {}
    for key, provider_key in FIELDS.items():
        value = raw.get(provider_key)
        value = None if value is None else float(value) / 1_000_000
        if key == "capex_m" and value is not None:
            value = abs(value)
        if not equal(old.get(key), value):
            raise ValueError(f"Native provider reconciliation failed: {key}: {old.get(key)} != {value}")
        native[key] = value
    native["fcf_after_capex_m"] = (native["cfo_m"] - native["capex_m"]
        if native["cfo_m"] is not None and native["capex_m"] is not None else None)
    if not equal(native["fcf_after_capex_m"], old.get("fcf_after_capex_m")):
        raise ValueError("Native FCF bridge does not reconcile")
    built = builder.build_period("DGE.L", "DEO", raw, fx_rate_book=rates)
    if not equal(built["shares_m"], old.get("shares_m")):
        raise ValueError("Ordinary shares changed; outside currency-only repair")
    result = json.loads(json.dumps(old))
    for key in native:
        result[key] = built[key]
    result["sourceFinancialStatementCurrency"] = "USD"
    result["reportingCurrency"] = "USD"
    result["reportingCurrencyEvidence"] = builder.DGE_USD_REPORTING_EVIDENCE
    for key in ("sourceCurrency", "modelCurrency", "currencyScale", "currencyScaleNote", "fxConversion"):
        result["sourceRecord"][key] = built["sourceRecord"][key]
    result["sourceRecord"].update({"currencyRepairVersion": VERSION,
        "nativeReportedFinancialsM": native, "reportingCurrencyEvidence": builder.DGE_USD_REPORTING_EVIDENCE,
        "originalPayloadSha256": hashlib.sha256(json.dumps(old, sort_keys=True).encode()).hexdigest()})
    # Independently reconstruct GBP from the exact ledger rows rather than using
    # the conversion rate returned by build_period / FxRateBook.conversion.
    fx = built["sourceRecord"]["fxConversion"]
    gbp = next(r["units_per_eur"] for r in rates.rows if r["currency"] == "GBP" and r["rate_date"] == fx["targetRateDate"])
    usd = next(r["units_per_eur"] for r in rates.rows if r["currency"] == "USD" and r["rate_date"] == fx["sourceRateDate"])
    for key, value in native.items():
        expected = None if value is None else value * gbp / usd
        if not equal(result[key], expected):
            raise ValueError(f"Independent GBP reconstruction failed: {key}")
    return result, {"period": raw["fiscalperiod"], "dimension": raw["dimension"], "availableAt": old["asOfDate"],
                    "nativeCurrency": "USD", "modelCurrency": "GBP", "nativeAmountsM": native,
                    "gbpAmountsM": {k: result[k] for k in native}, "fx": fx, "sharesUnchangedM": old.get("shares_m"),
                    "nativeProviderReconciliation": "pass", "independentGbpReconstruction": "pass"}


def repair(source_path, output_path, raw_rows):
    source_path, output_path = Path(source_path).resolve(strict=True), Path(output_path).resolve()
    if output_path.exists():
        raise FileExistsError(output_path)
    builder = builder_module()
    raw_by_key = {}
    for raw in raw_rows:
        raw = dict(raw)
        raw["datekey"] = raw.get("datekey") or raw.get("date")
        key = (raw["fiscalperiod"], raw["dimension"], str(raw["datekey"]))
        if key in raw_by_key and raw != raw_by_key[key]:
            raise ValueError("Conflicting exact-date paid-provider rows")
        raw_by_key[key] = raw
    prepared, audit = [], []
    with closing(sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True)) as source:
        rates = builder.FxRateBook.from_connection(source)
        rows = source.execute("SELECT fiscal_period,dimension,available_at,payload_json FROM pit_financial_periods WHERE ticker='DGE.L' AND report_period >= '2023-12-31' ORDER BY available_at,dimension").fetchall()
        for period, dimension, date, payload in rows:
            raw = raw_by_key.get((period, dimension, date))
            if raw is None:
                raise ValueError(f"Missing exact provider row: {period}/{dimension}/{date}")
            fixed, record = repaired_payload(json.loads(payload), raw, rates, builder)
            prepared.append((json.dumps(fixed, separators=(",", ":")), period, dimension))
            audit.append(record)
        if not prepared:
            raise ValueError("No scoped financial rows")
        with closing(sqlite3.connect(output_path)) as target:
            source.backup(target)
            target.executemany("UPDATE pit_financial_periods SET payload_json=? WHERE ticker='DGE.L' AND fiscal_period=? AND dimension=?", prepared)
            target.commit()
    return {"schemaVersion": 1, "version": VERSION, "sourceDb": str(source_path), "outputDb": str(output_path),
            "releaseAuthorized": False, "modelRebuildRequired": True, "changedRows": len(prepared), "rows": audit}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-db", type=Path, required=True)
    parser.add_argument("--output-db", type=Path, required=True)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--jansen-root", type=Path)
    options = parser.parse_args()
    builder = builder_module()
    dataset = builder.ds.dataset((options.jansen_root or builder.DEFAULT_JANSEN_ROOT) / "fundamentals", format="parquet", partitioning="hive")
    date_field = next(k for k in builder.PIT_CUTOFF_FIELD_CANDIDATES if k in dataset.schema.names)
    rows = dataset.to_table(columns=[*builder.SOURCE_COLUMNS, date_field],
        filter=(builder.ds.field("ticker") == "DEO") & builder.ds.field("dimension").isin(["ARQ", "ART"])).to_pylist()
    for row in rows:
        row["datekey"] = row[date_field]
    result = repair(options.source_db, options.output_db, rows)
    options.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps({k: v for k, v in result.items() if k != "rows"}, indent=2))


if __name__ == "__main__":
    main()
