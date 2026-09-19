#!/usr/bin/env python3
"""Apply exact, original-document-verified guidance currencies to a NEW copy.

Never alters financial reporting currency, amounts, growth, original quotations,
source ownership, model approvals, coverage or any unrelated source-table rows.
The emitted review registry is independently consumed by the JS source auditor.
"""
import argparse
from contextlib import closing
import datetime as dt
import hashlib
import importlib.util
import json
import math
import os
from pathlib import Path
import re
import sqlite3
from bs4 import BeautifulSoup

VERSION = "event-specific-official-currency-v1-2026-09-06"
CIKS = {"TSM": "0001046179", "DDOG": "0001561550", "GTLB": "0001653482", "SHOP": "0001594805",
        "APP": "0001751008", "CRWD": "0001535527", "PLTR": "0001321655", "ZS": "0001713683",
        "ESTC": "0001707753", "GDDY": "0001609711", "BG": "0001996862", "MAA": "0000912595",
        "GEV": "0001996810", "NWSA": "0001564708", "DIS": "0001001039", "CI": "0000701221",
        "CSGP": "0001057352", "FERG": "0001832433", "APA": "0000006769", "AVAV": "0001368622",
        "TSLA": "0001318605", "ABBV": "0001551152"}
TYPES = {"explicit_same_event_guidance_currency", "explicit_company_reporting_currency_declaration",
         "issuer_reviewed_consolidation_presentation_inference", "explicit_consolidated_statement_currency_units",
         "dated_parent_statement_xbrl_currency"}


def digest(value):
    return hashlib.sha256(value.encode() if isinstance(value, str) else value).hexdigest()


def normalize_html(html):
    soup = BeautifulSoup(html, "html.parser")
    for tag in soup(["script", "style"]):
        tag.decompose()
    return re.sub(r"\s+", " ", soup.get_text(" ", strip=True))


def normalize_proof(event):
    if event.get("ticker") == "TSM" and "primaryGuidance" in event:
        return {"currency": event["currency"], "evidenceType": "explicit_same_event_guidance_currency",
            "quotes": [event["primaryGuidance"]["quote"]], "availableAt": event["filingDate"],
            "sourceUrl": event["sourceUrl"], "documentPath": event["documentPath"],
            "documentSha256": event["documentSha256"], "accession": event["accession"], "form": "6-K",
            "cik": CIKS["TSM"], "primaryGuidance": event["primaryGuidance"], "inference": False}
    return dict(event["proof"])


def validate_proof(event, proof, row, html):
    ticker = event["ticker"]
    expected_cik = "0001144519" if ticker == "BG" and event["observedAt"] < "2023-11-01" else CIKS.get(ticker)
    if ticker not in CIKS or proof.get("cik") != expected_cik or proof.get("currency") != "USD":
        raise ValueError("Unreviewed issuer/CIK or currency")
    if proof.get("evidenceType") not in TYPES:
        raise ValueError("Unknown currency proof type")
    if ticker in {"DIS", "CI"} and (proof.get("evidenceType") != "dated_parent_statement_xbrl_currency" or
            (proof.get("xbrlStatementEvidence") or {}).get("schemaVersion") != "whole-entity-original-statement-xbrl-v1"):
        raise ValueError("DIS/CI additions require the exact reviewed whole-parent statement contract")
    accession = proof.get("accession", "")
    if not re.fullmatch(r"\d{10}-\d{2}-\d{6}", accession):
        raise ValueError("Invalid filing accession")
    expected = rf"https://www\.sec\.gov/Archives/edgar/data/{int(expected_cik)}/{accession.replace('-', '')}/[^/]+\.htm"
    if not re.fullmatch(expected, proof.get("sourceUrl", "")):
        raise ValueError("Official issuer/accession URL mismatch")
    for value in [proof.get("availableAt"), event.get("observedAt")]:
        if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", str(value)):
            raise ValueError("Invalid dated source evidence")
        dt.date.fromisoformat(value)
    if proof["availableAt"] > event["observedAt"]:
        raise ValueError("Future evidence cannot repair an earlier event")
    if digest(html) != proof.get("documentSha256"):
        raise ValueError("Frozen primary document hash mismatch")
    text = normalize_html(html)
    quotes = proof.get("quotes") or []
    if not quotes or any(not quote or quote not in text for quote in quotes):
        raise ValueError("Original official paragraph not present in frozen document")
    for support in proof.get("supportingDocuments", []):
        source_text = Path(support["documentPath"]).read_text()
        support_url = rf"https://www\.sec\.gov/Archives/edgar/data/{int(CIKS[ticker])}/{support['accession'].replace('-', '')}/[^/]+\.htm"
        if support["cik"] != CIKS[ticker] or support["availableAt"] > event["observedAt"] or not re.fullmatch(support_url, support["sourceUrl"]):
            raise ValueError("Supporting original issuer/date/accession mismatch")
        if digest(source_text) != support["documentSha256"] or any(q not in normalize_html(source_text) or digest(q) != support["paragraphSha256"][i] for i, q in enumerate(support["quotes"])):
            raise ValueError("Supporting original document or paragraph hash mismatch")
    if row["ticker"] != ticker or row["id"] != event["sourceId"] or row["observed_at"] != event["observedAt"]:
        raise ValueError("Exact event identity/date mismatch")
    if digest(row["evidence_excerpt"]) != event["originalQuoteSha256"] or row["evidence_excerpt"] != event["originalQuote"]:
        raise ValueError("Original guidance quote changed")
    if row["currency"] is not None:
        raise ValueError("Existing currency must not be overwritten")
    payload = json.loads(row["payload_json"])
    if payload.get("currency") is not None or payload.get("official_guidance_currency_evidence"):
        raise ValueError("Existing payload currency/evidence must not be overwritten")
    if (payload.get("currency_resolution") or {}).get("status") == "conflicting_currency":
        raise ValueError("Conflicting quote currency requires separate review")
    if row["unit"] == "currency_per_share":
        per_share = payload.get("per_share_value")
        if row["metric_name"] != "eps_guidance" or row["amount"] is not None or isinstance(per_share, bool) or not isinstance(per_share, (float, int)) or not math.isfinite(per_share):
            raise ValueError("Per-share currency proof requires exact EPS scalar and null monetary-million amount")
    elif row["amount"] is None or row["unit"] != "reported millions":
        raise ValueError("Only monetary-million or explicit EPS per-share events are reviewed")
    if proof["evidenceType"] == "explicit_same_event_guidance_currency":
        target = proof["primaryGuidance"]
        if ticker != "TSM" or row["metric_name"] != "revenue_guidance" or proof["availableAt"] != row["observed_at"]:
            raise ValueError("Same-event primary guide owner/date mismatch")
        period = re.fullmatch(r"Q([1-4])(20\d{2})", row["fiscal_period"])
        if not period:
            raise ValueError("Invalid original fiscal period")
        quarter, year = int(period[1]), int(period[2])
        expected_period = (quarter + 1, year) if quarter < 4 else (1, year + 1)
        if (target["quarter"], target["year"]) != expected_period or abs(row["amount"] - target["midpointM"]) > 1e-7:
            raise ValueError("Primary range/target quarter disagrees with original guidance")
        explicit_range = re.search(r"Revenue is expected to be between US\$([\d.]+) billion and US\$([\d.]+) billion", quotes[0])
        if not explicit_range or abs(float(explicit_range[1]) * 1000 - target["lowM"]) > 1e-7 or abs(float(explicit_range[2]) * 1000 - target["highM"]) > 1e-7:
            raise ValueError("Primary quoted USD endpoints do not support normalized range")
    if proof["evidenceType"] == "explicit_company_reporting_currency_declaration":
        patterns = [r"(?:functional and )?reporting currency of the Company(?: and its subsidiaries)? is (?:the )?(?:U\.?S\.?|United States) dollar",
                    r"Our reporting currency and the functional currency of our wholly owned foreign subsidiaries is the U\.S\. dollar",
                    r"Shopify reports in U\.S\. dollars and in accordance with U\.S\. GAAP",
                    r"(?:Bunge's|Our) reporting currency is the U\.S\. dollar"]
        if ticker in {"GEV", "NWSA", "CSGP", "FERG", "APA"}:
            validator = "validate_csgp_ferg_currency_primary.py" if ticker in {"CSGP", "FERG", "APA"} else "validate_gev_nwsa_currency_primary.py"
            spec = importlib.util.spec_from_file_location("exact_direct", Path(__file__).with_name(validator))
            library = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(library)
            library.validate_exact_direct(event, proof, row, html)
        elif not any(re.search(pattern, quote, re.I) for pattern in patterns for quote in quotes):
            raise ValueError("No direct company reporting-currency declaration")
        if ticker == "BG" and (proof["form"] != "10-K" or "BUNGE LIMITED" not in text or (dt.date.fromisoformat(event["observedAt"]) - dt.date.fromisoformat(proof["availableAt"])).days > 400):
            raise ValueError("Bunge requires original dated predecessor 10-K reporting declaration")
    if proof["evidenceType"] in {"explicit_consolidated_statement_currency_units", "dated_parent_statement_xbrl_currency"}:
        legacy = (proof.get("xbrlStatementEvidence") or {}).get("schemaVersion") == "whole-entity-original-statement-xbrl-v1"
        avav = (proof.get("xbrlStatementEvidence") or {}).get("schemaVersion") == "avav-original-parent-statement-currency-v1"
        validator = "validate_avav_statement_currency.py" if avav else "validate_legacy_parent_statement_currency.py" if legacy else "validate_bg_maa_currency_primary.py"
        spec = importlib.util.spec_from_file_location("statement_units", Path(__file__).with_name(validator))
        library = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(library)
        if avav:
            library.validate_proof(event, proof, row, html)
        elif legacy:
            library.validate_legacy_statement_proof(event, proof, row, html)
        else:
            library.validate_statement_proof(event, proof, html)
    if proof["evidenceType"] == "issuer_reviewed_consolidation_presentation_inference":
        if ticker in {"TSLA", "ABBV"}:
            spec = importlib.util.spec_from_file_location("early_group", Path(__file__).with_name("validate_early_group_currency_inference.py"))
            library = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(library)
            library.validate_proof(event, proof, row, html)
            return
        if ticker not in {"APP", "CRWD", "PLTR", "ZS", "GDDY"} or not proof.get("inference") or not proof.get("reasoning") or len(quotes) != (3 if ticker == "GDDY" else 2):
            raise ValueError("Inference needs reviewed whole-note reasoning and consolidation scope")
        patterns = [r"assets and liabilities", r"(?:translated|translates|re-measured).{0,160}(?:into|to) U\.S\. dollars", r"revenue and (?:costs and )?expenses", r"(?:comprehensive income|consolidated statements of operations|stockholders’ equity)"]
        if ticker == "GDDY":
            patterns = [r"Our functional currency, and the functional currency of each of our subsidiaries, is the U\.S\. dollar", r"Assets denominated in foreign currencies are remeasured into U\.S\. dollars", r"revenue and expense transactions", r"consolidated statements of operations"]
            if "GoDaddy Inc. will consolidate Desert Newco" not in quotes[2] or "non-controlling interest" not in quotes[2]:
                raise ValueError("Missing exact GoDaddy predecessor consolidation relationship")
            support = proof.get("supportingDocuments") or []
            if len(support) != 1 or not any("successfully closed its initial public offering" in q for q in support[0]["quotes"]) or not any("predecessor of GoDaddy Inc. for financial reporting purposes" in q for q in support[0]["quotes"]):
                raise ValueError("Missing GoDaddy already-published closing/predecessor confirmation")
        if not all(re.search(pattern, quotes[0], re.I) for pattern in patterns) or not re.search(r"consolidated financial statements", quotes[1], re.I):
            raise ValueError("Subsidiary functional-only evidence is insufficient")


def contract_for(event, proof, row, ledger_sha):
    result = {"version": VERSION, "ticker": row["ticker"], "sourceId": row["id"], "observedAt": row["observed_at"],
        "originalQuoteSha256": digest(row["evidence_excerpt"]), "originalQuotedCurrency": None,
        "resolvedCurrency": "USD", "evidenceType": proof["evidenceType"], "reportingCurrencyOverride": False,
        "metricName": row["metric_name"], "fiscalPeriod": row["fiscal_period"], "amountM": row["amount"],
        "unit": row["unit"], "sourceLedgerSha256": ledger_sha,
        "preEnrichmentPayloadSha256": digest(row["payload_json"]),
        "originalEvidencePayloadSha256": event["originalPayloadSha256"],
        "proof": {**proof, "paragraphSha256": [digest(q) for q in proof["quotes"]],
                  "documentVerification": "frozen_original_html_sha256_and_exact_normalized_paragraphs_verified"},
        "policy": "Currency-only event evidence; original quote, financial reporting currency, source ownership, scope, amounts, growth and model review state unchanged. Full independent source/model audits still required."}
    if row["unit"] == "currency_per_share":
        result["perShareValue"] = json.loads(row["payload_json"])["per_share_value"]
    return result


def row_digest(db, table, excluded=()):
    clause = " WHERE id NOT IN (" + ",".join("?" for _ in excluded) + ")" if excluded else ""
    rows = db.execute(f'SELECT * FROM "{table}"{clause} ORDER BY 1', excluded)
    h = hashlib.sha256()
    for row in rows:
        h.update(json.dumps(list(row), separators=(",", ":"), ensure_ascii=False).encode())
        h.update(b"\n")
    return h.hexdigest()


def apply(source_path, ledger_paths, output_path, registry_path, report_path, existing_registry=None):
    source_path = Path(source_path).resolve(strict=True)
    output_path, registry_path, report_path = map(lambda p: Path(p).absolute(), [output_path, registry_path, report_path])
    if len({source_path, output_path.resolve(), registry_path.resolve(), report_path.resolve()}) != 4:
        raise ValueError("All input/output paths must be distinct")
    for path in [output_path, registry_path, report_path]:
        if path.exists() or path.is_symlink():
            raise FileExistsError("Only NEW output paths allowed: " + str(path))
    events = []
    for path in ledger_paths:
        raw = Path(path).read_bytes()
        ledger = json.loads(raw)
        events.extend((event, digest(raw)) for event in ledger["events"])
    ids = [e["sourceId"] for e, _ in events]
    if not ids or len(ids) != len(set(ids)):
        raise ValueError("Explicit nonempty unique event IDs required")
    changes, registry = [], {}
    if existing_registry:
        inherited = json.loads(Path(existing_registry).read_text())
        if inherited.get("version") != VERSION or not isinstance(inherited.get("documents"), dict):
            raise ValueError("Invalid inherited reviewed-document registry")
        registry = inherited["documents"]
    with closing(sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True)) as source:
        source.row_factory = sqlite3.Row
        if source.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("Source integrity failed")
        for retained in source.execute("SELECT id,ticker,payload_json FROM pit_guidance_events WHERE payload_json LIKE '%official_guidance_currency_evidence%'"):
            contract = json.loads(retained["payload_json"]).get("official_guidance_currency_evidence")
            if not contract:
                continue
            proof = contract.get("proof") or {}
            known = registry.get(proof.get("documentSha256")) or {}
            if known.get("ticker") != retained["ticker"] or retained["id"] not in known.get("sourceIds", []) or known.get("paragraphSha256") != proof.get("paragraphSha256"):
                raise ValueError("Inherited reviewed currency contract missing from the existing registry")
        for event, ledger_sha in events:
            found = source.execute("SELECT * FROM pit_guidance_events WHERE id=?", (event["sourceId"],)).fetchone()
            if not found:
                raise ValueError("Missing exact source event: " + event["sourceId"])
            row = dict(found)
            proof = normalize_proof(event)
            validate_proof(event, proof, row, Path(proof["documentPath"]).read_text())
            contract = contract_for(event, proof, row, ledger_sha)
            payload = json.loads(row["payload_json"])
            resolution = {"status": "independently_reviewed_official_event_currency", "currency": "USD",
                "originalQuotedCurrency": None, "evidenceType": proof["evidenceType"],
                "priorResolution": payload.get("currency_resolution"), "sourceLedgerSha256": ledger_sha}
            updated = {**payload, "currency": "USD", "currency_resolution": resolution,
                       "official_guidance_currency_evidence": contract}
            changes.append((row, json.dumps(updated, separators=(",", ":"), ensure_ascii=False)))
            key = proof["documentSha256"]
            entry = {"ticker": event["ticker"], "cik": proof["cik"], "sourceUrl": proof["sourceUrl"],
                     "accession": proof["accession"], "availableAt": proof["availableAt"],
                     "evidenceType": proof["evidenceType"], "paragraphSha256": contract["proof"]["paragraphSha256"],
                     "sourceIds": [], "reviewClassification": "analyst_inference" if proof.get("inference") else "direct_primary_statement"}
            if proof.get("supportingDocuments"):
                entry["supportingDocuments"] = [{key: d[key] for key in ["availableAt", "sourceUrl", "documentSha256", "cik", "accession", "form", "paragraphSha256"]} for d in proof["supportingDocuments"]]
            if proof.get("xbrlStatementEvidence"):
                xbrl = proof["xbrlStatementEvidence"]
                entry["xbrlStatementEvidence"] = {key: xbrl[key] for key in ["sourceUrl", "documentSha256", "fragmentsSha256"]}
                if xbrl.get("schemaVersion") in {"whole-entity-original-statement-xbrl-v1", "avav-original-parent-statement-currency-v1"}:
                    entry["xbrlStatementEvidence"].update({key:xbrl[key] for key in ["schemaVersion", "periodEnd", "rootOpenTagSha256", "contextScope"]})
            if proof.get("filingDateEvidence"):
                entry["filingDateEvidence"] = {key: proof["filingDateEvidence"][key] for key in ["sourceUrl", "documentSha256", "headerTextSha256"]}
            if key in registry and {k:v for k,v in registry[key].items() if k != "sourceIds"} != {k:v for k,v in entry.items() if k != "sourceIds"}:
                raise ValueError("Conflicting reviewed primary-document contract")
            registry.setdefault(key, entry)["sourceIds"].append(event["sourceId"])
        tables = [r[0] for r in source.execute("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%' ORDER BY name")]
        before = {table: row_digest(source, table, ids if table == "pit_guidance_events" else ()) for table in tables}
        output_path.parent.mkdir(parents=True, exist_ok=True)
        fd = os.open(output_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        with closing(sqlite3.connect(output_path)) as target:
            source.backup(target)
            target.executemany("UPDATE pit_guidance_events SET currency='USD',payload_json=? WHERE id=?", [(raw, row["id"]) for row, raw in changes])
            target.commit()
            after = {table: row_digest(target, table, ids if table == "pit_guidance_events" else ()) for table in tables}
            if before != after or target.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
                raise ValueError("Unrelated source rows changed or output integrity failed")
    registry_payload = {"version": VERSION, "policy": "Bounded original documents reviewed for exact guidance-event currencies, not a general USD issuer override", "documents": registry}
    registry_path.parent.mkdir(parents=True, exist_ok=True)
    registry_path.write_text(json.dumps(registry_payload, indent=2) + "\n")
    report = {"version": VERSION, "sourceDb": str(source_path), "outputDb": str(output_path), "changedEvents": len(changes),
        "releaseAuthorized": False, "allUnrelatedRowsExact": True, "allFinancialRowsExact": True,
        "originalGuidanceIdentityQuoteAndOwnerPreserved": True, "changedFieldsOnly": ["currency", "payload.currency", "payload.currency_resolution", "payload.official_guidance_currency_evidence"],
        "originalSourceSha256": digest(source_path.read_bytes()), "outputSha256": digest(output_path.read_bytes()),
        "registryPath": str(registry_path), "registrySha256": digest(registry_path.read_bytes()),
        "events": [{"sourceId": row["id"], "ticker": row["ticker"], "observedAt": row["observed_at"],
                    "originalQuoteSha256": digest(row["evidence_excerpt"]), "beforeCurrency": row["currency"], "afterCurrency": "USD",
                    "beforePayloadSha256": digest(row["payload_json"]), "afterPayloadSha256": digest(raw)} for row, raw in changes]}
    report_path.write_text(json.dumps(report, indent=2) + "\n")
    return report


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    for key in ["source-db", "output-db", "registry", "report"]:
        parser.add_argument("--" + key, type=Path, required=True)
    parser.add_argument("--ledger", type=Path, action="append", required=True)
    parser.add_argument("--existing-registry", type=Path, help="Preserve an existing exact-document registry when adding reviewed events")
    args = parser.parse_args()
    result = apply(args.source_db, args.ledger, args.output_db, args.registry, args.report, args.existing_registry)
    print(json.dumps({k: v for k, v in result.items() if k != "events"}, indent=2))
