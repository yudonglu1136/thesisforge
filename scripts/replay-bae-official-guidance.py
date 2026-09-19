#!/usr/bin/env python3
"""Replay BA.L guidance only; select current guidance cells, never results.

The original document, table, excluded columns and prior persisted evidence are
retained as provenance. Financials and all other issuers are immutable. New
documents must be explicitly bound to existing dated financial source events.
"""
import argparse
from contextlib import closing
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import sqlite3
import sys

VERSION = "bae-current-guidance-column-v1-2026-09-06"


def load(name, file):
    spec = importlib.util.spec_from_file_location(name, Path(__file__).with_name(file))
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    spec.loader.exec_module(module)
    return module


def clean(value):
    return re.sub(r"\s+", " ", re.sub(r"[*_`]", "", value)).strip()


def table_blocks(text):
    return list(re.finditer(r"(?m)^\|[^\n]+\|\s*$\n?(?:^\|[^\n]+\|\s*$\n?)*", text))


def selected_table_rows(text):
    """Project one metric/cell from an explicitly labelled current column."""
    # Older UK imports flattened a complete table into one quotation. Recover
    # only its explicit four-cell rows; keep that original quotation verbatim.
    if "\n" not in text and re.search(r"Updated guidance\s*\|\s*Previous guidance\s*\|\s*Results", text):
        year = re.search(r"Year ended 31 December (20\d{2})", text)
        if not year:
            raise ValueError("Missing annual header in retained source table")
        cells = re.findall(r"\|\s*(Sales|Underlying EBIT|Underlying EPS|Free cash flow target)\s*\|([^|]*)\|([^|]*)\|([^|]*)\|", text)
        if len(cells) != 4 or len({r[0] for r in cells}) != 4:
            raise ValueError("Incomplete retained four-column BAE guidance table")
        normalized = f"| Year ended 31 December {year[1]} | Updated guidance | Previous guidance | Results |\n| --- | --- | --- | --- |\n"
        normalized += "\n".join("| " + " | ".join(clean(v) for v in row) + " |" for row in cells)
        result = selected_table_rows(normalized)
        for item in result:
            item["provenance"].update(rawTable=text, tableSha256=hashlib.sha256(text.encode()).hexdigest(),
                kind="persisted_original_table_column_projection", normalizedTable=normalized,
                sourceContext="Original dated official quotation; deterministic column reconstruction, not a fresh filing review")
        return result
    projections = []
    for block in table_blocks(text):
        rows = [[clean(cell) for cell in line.strip().strip("|").split("|")]
                for line in block.group().splitlines() if line.strip()]
        headers = rows[:3]
        candidates = [(i, j, cell) for i, row in enumerate(headers) for j, cell in enumerate(row)
                      if re.fullmatch(r"(?:Updated )?guidance", cell, re.I)]
        if not candidates:
            continue
        updated = [p for p in candidates if p[2].lower().startswith("updated")]
        candidates = updated or candidates
        if len(candidates) != 1:
            raise ValueError("Ambiguous current guidance columns")
        header_row, column, column_name = candidates[0]
        year_cells = [cell for row in headers for cell in row[:1] if re.fullmatch(r"Year ended 31 December 20\d{2}", cell)]
        if len(set(year_cells)) != 1:
            raise ValueError("Missing/ambiguous exact annual guidance year")
        year_header = year_cells[0]
        year = int(year_header[-4:])
        preceding = text[max(0, block.start() - 1800):block.start()]
        headings = re.findall(r"(?m)^#{1,6}\s+([^\n]*guidance[^\n]*)", preceding, re.I)
        heading = clean(headings[-1]) if headings else ""
        annual_sentences = [clean(s) for s in re.split(r"(?<=[.!?])\s+", preceding)
                            if re.search(r"\bfull year\b", s, re.I) and re.search(r"guidance", s, re.I)]
        # Only actual source fragments, not a synthetic issuer quotation.
        context = (f"{heading}. " if heading else "") + (annual_sentences[-1] + " " if annual_sentences else "")
        context += f"{year_header} | {column_name}. "
        for row_index, row in enumerate(rows[header_row + 1:], header_row + 1):
            if len(row) <= column:
                raise ValueError("Truncated guidance row")
            label, value = row[0], row[column]
            metric = ("free_cash_flow_guidance" if re.search(r"free cash flow", label, re.I)
                      else "revenue_guidance" if re.fullmatch("Sales", label, re.I)
                      else "operating_income_guidance" if re.fullmatch("Underlying EBIT", label, re.I)
                      else "eps_guidance" if re.fullmatch("Underlying EPS", label, re.I) else None)
            if not metric or not value:
                continue
            cumulative = bool(re.search(r"cumulative|20\d{2}\s+to\s+20\d{2}", label, re.I))
            projections.append({"metric": metric, "label": label, "value": value, "year": year,
                "cumulative": cumulative, "excerpt": context + f"{label} | {value}",
                "provenance": {"kind": "original_document_table_column_projection", "rawTable": block.group(),
                    "tableSha256": hashlib.sha256(block.group().encode()).hexdigest(), "rows": rows,
                    "selectedColumn": column, "selectedHeader": column_name, "selectedRow": row_index,
                    "annualHeader": year_header, "sourceContext": preceding,
                    "excludedColumnsPolicy": "Previous guidance and historical results retained here but excluded from the metric quotation and scalar extraction"}})
    return projections


def project_events(official, period, date, url, text):
    events = []
    for item in selected_table_rows(text):
        event = official.extract_metric_event(official.guidance_module(), "BA.L", period, date,
            url, f"official-bae-table:{hashlib.sha256(text.encode()).hexdigest()}", item["metric"], item["excerpt"])
        event.update(source_type="official_issuer_results_release", extraction_version=f"{official.guidance_module().EXTRACTION_VERSION}+{VERSION}",
                     guidance_target_year=item["year"], guidance_year=item["year"],
                     guidance_scope="multi_year_target" if item["cumulative"] else "full_year",
                     guidance_scope_evidence=item["provenance"]["annualHeader"], table_column_evidence=item["provenance"])
        if item["cumulative"]:
            event["guidance_subject"] = "non_company_or_non_periodic"
        growth = re.fullmatch(r"Increase in the range of ([\d.]+)% to ([\d.]+)%", item["value"], re.I)
        if growth:
            event.update(amount=None, unit=None, currency=None, growth_yoy=(float(growth[1]) + float(growth[2])) / 2,
                         quality_status="clear", extraction_confidence=0.98)
        if item["value"].startswith(">"):
            event["guidance_comparator"] = "greater_than"
            event["amount_interpretation"] = "Issuer lower-bound target, not an expected midpoint or exact forecast"
        event["payload_json"] = json.dumps({k: v for k, v in event.items() if k != "payload_json"}, separators=(",", ":"))
        events.append(event)
    return events


def replay(source_path, output_path, documents, report_path):
    source_path, output_path = Path(source_path).resolve(strict=True), Path(output_path).resolve()
    if output_path.exists() or Path(report_path).exists():
        raise FileExistsError("New private output and report paths required")
    official = load("bae_replay_sec", "import-sec-official-guidance.py")
    uk = load("bae_replay_uk", "import-official-uk-pit.py")
    prepared, document_audit = [], []
    with closing(sqlite3.connect(source_path.as_uri() + "?mode=ro", uri=True)) as source:
        source.row_factory = sqlite3.Row
        originals = [dict(r) for r in source.execute("SELECT * FROM pit_guidance_events WHERE ticker='BA.L' AND source_type='official_issuer_results_release'")]
        frozen_ids, seen_frozen = [], set()
        for original in originals:
            quote = original["evidence_excerpt"]
            if "\n" in quote or not re.search(r"Updated guidance\s*\|\s*Previous guidance\s*\|\s*Results", quote):
                continue
            frozen_ids.append(original["id"])
            key = (original["observed_at"], quote)
            if key in seen_frozen:
                continue
            seen_frozen.add(key)
            prepared.extend(project_events(official, original["fiscal_period"], original["observed_at"], original["source_url"], quote))
            document_audit.append({"observedAt": original["observed_at"], "sourceUrl": original["source_url"],
                "reviewType": "existing_dated_source_quote_column_replay_not_a_new_filing_fetch",
                "originalQuotationSha256": hashlib.sha256(quote.encode()).hexdigest()})
        dates = set()
        for document in documents:
            date, url, period = document["observedAt"], document["sourceUrl"], document["fiscalPeriod"]
            if date in dates:
                raise ValueError("Duplicate document event date")
            dates.add(date)
            row = source.execute("SELECT payload_json FROM pit_financial_periods WHERE ticker='BA.L' AND available_at=? AND fiscal_period=?", (date, period)).fetchone()
            if not row:
                raise ValueError("Document has no matching dated financial source event")
            if not re.fullmatch(r"https://(?:(?:www|investors)\.)?baesystems\.com/.+", url):
                raise ValueError("Not a BAE primary source URL")
            text = Path(document["textPath"]).read_text()
            if len(text) < 1000:
                raise ValueError("Source document incomplete")
            if not re.search(rf"(?:Published Time:\s*{date}|{int(date[-2:])}\s+[A-Za-z]+\s+{date[:4]})", text):
                raise ValueError("Document does not independently show the declared date")
            projected = project_events(official, period, date, url, text)
            if not projected:
                raise ValueError("No explicitly labelled current guidance table")
            # Reparse narrative without flattening tables into its sentences.
            narrative = text
            for block in reversed(table_blocks(text)):
                narrative = narrative[:block.start()] + "\n" + narrative[block.end():]
            fy, quarter = period.split("-")
            event = uk.Event("BA.L", int(fy), quarter, date, document.get("title", "Official results"), url, None, "half_year")
            parsed = uk.guidance_events(official.guidance_module(), event, narrative)
            for item in parsed:
                item["fiscal_period"] = period
                item["payload_json"] = json.dumps({k: v for k, v in item.items() if k != "payload_json"}, separators=(",", ":"))
            prepared.extend(projected + parsed)
            document_audit.append({**document, "documentSha256": hashlib.sha256(text.encode()).hexdigest(),
                                   "selectedTableEvents": len(projected), "narrativeEvents": len(parsed)})
        if not prepared:
            raise ValueError("No source-owned replay scope")
        with closing(sqlite3.connect(output_path)) as target:
            source.backup(target)
            columns = [r[1] for r in target.execute("PRAGMA table_info(pit_guidance_events)")]
            for date in dates:
                target.execute("DELETE FROM pit_guidance_events WHERE ticker='BA.L' AND observed_at=? AND source_type='official_issuer_results_release'", (date,))
            for source_id in frozen_ids:
                target.execute("DELETE FROM pit_guidance_events WHERE id=? AND ticker='BA.L' AND source_type='official_issuer_results_release'", (source_id,))
            for event in prepared:
                target.execute(f"INSERT OR REPLACE INTO pit_guidance_events({','.join(columns)}) VALUES({','.join('?' for _ in columns)})", tuple(event.get(k) for k in columns))
            all_events = [json.loads(r[0]) for r in target.execute("SELECT payload_json FROM pit_guidance_events WHERE ticker='BA.L'")]
            counts = official.guidance_coverage_counts(all_events)
            status = "official_guidance_review_incomplete" if counts["reviewRequiredEvents"] else "covered_official_filing" if counts["usableOfficialEvents"] else "no_quantified_official_guidance"
            target.execute("UPDATE pit_guidance_coverage SET guidance_periods=?,guidance_events=?,status=?,note=? WHERE ticker='BA.L'",
                (counts["periods"], counts["events"], status, f"Exact current guidance columns reviewed on {', '.join(sorted(dates))}; prior official evidence retained outside these dated events. {json.dumps(counts, sort_keys=True)}"))
            archive = [r for r in originals if r["observed_at"] in dates or r["id"] in frozen_ids]
            target.execute("INSERT OR REPLACE INTO pit_source_metadata(key,value) VALUES(?,?)",
                ("bae_official_guidance_column_replay", json.dumps({"version": VERSION, "documents": document_audit,
                    "supersededOriginalRows": archive, "financialRowsChanged": 0}, separators=(",", ":"))))
            target.commit()
    result = {"version": VERSION, "sourceDb": str(source_path), "outputDb": str(output_path), "documents": document_audit,
              "coverage": counts, "financialRowsChanged": 0, "releaseAuthorized": False, "supersededOriginalRows": archive}
    Path(report_path).write_text(json.dumps(result, indent=2) + "\n")
    return {k: v for k, v in result.items() if k != "supersededOriginalRows"}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-db", required=True)
    parser.add_argument("--output-db", required=True)
    parser.add_argument("--documents", required=True)
    parser.add_argument("--report", required=True)
    options = parser.parse_args()
    print(json.dumps(replay(options.source_db, options.output_db, json.loads(Path(options.documents).read_text()), options.report), indent=2))
