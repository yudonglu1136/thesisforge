#!/usr/bin/env python3
"""Copy-only integration of exact official-guidance and financial repair scopes.

This does not approve issuers or models. Transcript events, untouched financial
periods and every other source table remain byte-exact; conflicting FX fails.
"""
import argparse
from contextlib import closing
import hashlib
import json
from pathlib import Path
import sqlite3

OFFICIAL = {"official_issuer_results_release", "official_issuer_sec_filing"}


def ro(path):
    return sqlite3.connect(Path(path).resolve(strict=True).as_uri() + "?mode=ro", uri=True)


def sha(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def table_rows(db, table):
    # Table names come exclusively from sqlite_master, never SQL fragments.
    quoted = '"' + table.replace('"', '""') + '"'
    return sorted(db.execute(f"SELECT * FROM {quoted}").fetchall(), key=repr)


def integrate(base_path, patch_path, manifest, output_path):
    output = Path(output_path).resolve()
    if output.exists():
        raise FileExistsError("Never overwrite a source or candidate")
    if sha(patch_path) != manifest["patchSha256"]:
        raise ValueError("Patch bytes changed since review")
    tickers = manifest["officialTickers"]
    financial = [tuple(row) for row in manifest["financialKeys"]]
    metadata_keys = manifest["metadataKeys"]
    if (not tickers or len(tickers) != len(set(tickers)) or
            len(financial) != len(set(financial)) or len(metadata_keys) != len(set(metadata_keys))):
        raise ValueError("Explicit unique scopes required")
    if any(len(row) != 3 or row[0] not in tickers or row[2] not in {"ARQ", "ART"} for row in financial):
        raise ValueError("Invalid exact financial repair key")
    with closing(ro(base_path)) as base, closing(ro(patch_path)) as patch:
        tables = [row[0] for row in base.execute("SELECT name FROM sqlite_master WHERE type='table'")]
        target_tables = {"pit_guidance_events", "pit_guidance_coverage", "pit_financial_periods", "pit_fx_reference_rates", "pit_source_metadata"}
        if not target_tables.issubset(tables):
            raise ValueError("Base is not a complete PIT source")
        for table in target_tables:
            if base.execute(f"PRAGMA table_info({table})").fetchall() != patch.execute(f"PRAGMA table_info({table})").fetchall():
                raise ValueError(f"Schema mismatch: {table}")
        guidance_columns = [row[1] for row in base.execute("PRAGMA table_info(pit_guidance_events)")]
        scope = set(tickers)
        def keep_guidance(row):
            record = dict(zip(guidance_columns, row))
            return not (record["ticker"] in scope and record["source_type"] in OFFICIAL)
        original_guidance = table_rows(base, "pit_guidance_events")
        retained_guidance = list(filter(keep_guidance, original_guidance))
        patch_guidance = [row for row in table_rows(patch, "pit_guidance_events") if not keep_guidance(row)]
        retained_ids = {dict(zip(guidance_columns, row))["id"] for row in retained_guidance}
        if any(dict(zip(guidance_columns, row))["id"] in retained_ids for row in patch_guidance):
            raise ValueError("Official patch collides with a retained owner")
        financial_columns = [row[1] for row in base.execute("PRAGMA table_info(pit_financial_periods)")]
        replacements = []
        for key in financial:
            where = "WHERE ticker=? AND fiscal_period=? AND dimension=?"
            old = base.execute(f"SELECT * FROM pit_financial_periods {where}", key).fetchone()
            new = patch.execute(f"SELECT * FROM pit_financial_periods {where}", key).fetchone()
            if not old or not new or old[:-1] != new[:-1]:
                raise ValueError("Financial repair cannot change identity/date/currency columns or add/remove history")
            old_payload, new_payload = json.loads(old[-1]), json.loads(new[-1])
            if old_payload.get("shares_m") != new_payload.get("shares_m"):
                raise ValueError("Currency repair cannot change shares")
            replacements.append((key, new[-1]))
        coverage = []
        for ticker in tickers:
            row = patch.execute("SELECT * FROM pit_guidance_coverage WHERE ticker=?", (ticker,)).fetchone()
            old = base.execute("SELECT * FROM pit_guidance_coverage WHERE ticker=?", (ticker,)).fetchone()
            if not row or not old:
                raise ValueError("Coverage scope is not retained in both sources")
            coverage.append(row)
        metadata = []
        for key in metadata_keys:
            row = patch.execute("SELECT key,value FROM pit_source_metadata WHERE key=?", (key,)).fetchone()
            if not row:
                raise ValueError(f"Missing scoped metadata: {key}")
            metadata.append(row)
        fx_added = []
        for row in patch.execute("SELECT * FROM pit_fx_reference_rates"):
            prior = base.execute("SELECT * FROM pit_fx_reference_rates WHERE currency=? AND rate_date=?", row[:2]).fetchone()
            if prior and prior[:3] != row[:3]:
                raise ValueError("Conflicting dated FX rate; no averaging or replacement")
            if not prior:
                fx_added.append(row)
        output.parent.mkdir(parents=True, exist_ok=True)
        with closing(sqlite3.connect(output)) as target:
            base.backup(target)
            with target:
                bind = ",".join("?" for _ in tickers)
                target.execute(f"DELETE FROM pit_guidance_events WHERE ticker IN ({bind}) AND source_type IN (?,?)", [*tickers, *sorted(OFFICIAL)])
                target.executemany(f"INSERT INTO pit_guidance_events VALUES({','.join('?' for _ in guidance_columns)})", patch_guidance)
                for key, payload in replacements:
                    target.execute("UPDATE pit_financial_periods SET payload_json=? WHERE ticker=? AND fiscal_period=? AND dimension=?", [payload, *key])
                for row in coverage:
                    target.execute("DELETE FROM pit_guidance_coverage WHERE ticker=?", (row[0],))
                    target.execute(f"INSERT INTO pit_guidance_coverage VALUES({','.join('?' for _ in row)})", row)
                for row in fx_added:
                    target.execute(f"INSERT INTO pit_fx_reference_rates VALUES({','.join('?' for _ in row)})", row)
                for row in metadata:
                    target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES(?,?)", row)
                report = {"status": "source_patches_integrated_not_model_approved", "releaseAuthorized": False,
                          "baseSourceSha256": sha(base_path), "patchSha256": sha(patch_path),
                          "officialTickers": tickers, "officialEvents": len(patch_guidance),
                          "financialKeys": manifest["financialKeys"], "addedFxRows": len(fx_added)}
                target.execute("INSERT OR REPLACE INTO pit_source_metadata VALUES('reviewed_source_patch_integration',?)", (json.dumps(report, sort_keys=True),))
                if list(filter(keep_guidance, table_rows(target, "pit_guidance_events"))) != retained_guidance:
                    raise ValueError("Unrelated guidance changed")
                def keep_financial(row):
                    record = dict(zip(financial_columns, row))
                    return (record["ticker"], record["fiscal_period"], record["dimension"]) not in financial
                if list(filter(keep_financial, table_rows(target, "pit_financial_periods"))) != list(filter(keep_financial, table_rows(base, "pit_financial_periods"))):
                    raise ValueError("Unrelated financial history changed")
                for table in set(tables) - target_tables:
                    if table_rows(target, table) != table_rows(base, table):
                        raise ValueError(f"Protected table changed: {table}")
                if target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                    raise ValueError("Source integrity failed")
            report["outputSha256"] = sha(output)
            report["unrelatedRowsExact"] = True
            return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for arg in ["base", "patch", "manifest", "output", "report"]:
        parser.add_argument("--" + arg, required=True, type=Path)
    args = parser.parse_args()
    if args.report.exists():
        raise FileExistsError("Never overwrite an integration report")
    result = integrate(args.base, args.patch, json.loads(args.manifest.read_text()), args.output)
    args.report.write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result, indent=2))


if __name__ == "__main__":
    main()
