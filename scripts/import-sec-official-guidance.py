#!/usr/bin/env python3
"""Import issuer-approved PIT guidance from official SEC result filings.

This is the fallback for foreign issuers whose earnings-call transcript pages
are unavailable. Filing dates, rather than report periods or later revisions,
are the point-in-time availability boundary.
"""

from __future__ import annotations

import argparse
import collections
import concurrent.futures
import datetime as dt
import hashlib
import importlib.util
import json
import math
import re
import sqlite3
import sys
import time
from pathlib import Path

import requests
from bs4 import BeautifulSoup
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry


DEFAULT_SOURCE_DB = Path("server/data/valuation-pit-source.sqlite")
DEFAULT_TARGET_DB = Path("server/data/guru-analysis.sqlite")
DEFAULT_MANIFEST = Path("server/config/sp500-valuation-universe.json")
DEFAULT_GURU_MANIFEST = Path("server/config/guru-valuation-universe.json")
SEC_USER_AGENT = "Guru Intelligence data engineering luyudong1136@gmail.com"
IMPORT_VERSION = "official-sec-guidance-v11-listed-html-fallback-2026-09-06"
GUIDANCE_EXTRACTOR = Path(__file__).with_name("extract-pit-management-guidance.py")
SEC_REQUEST_DELAY_SECONDS = 0.36
ISSUERS = {
    "CCEP": {"cik": "0001650107", "start": "2016-01-01"},
    "DGE.L": {"cik": "0000835403", "start": "2010-01-01"},
    "FER": {"cik": "0001468522", "start": "2024-01-01"},
}
RESULT_DOCUMENT = re.compile(
    r"result|earnings|trading|update|half|interim|financial|annual|quarter|q[1-4]|[1-4]q(?:20)?\d{2}|prelim|ex[-_]?99",
    re.I,
)
EXCLUDED_DOCUMENT = re.compile(
    r"weekly|monthly|share|repurchase|dividend|pdmr|earningsreleasedate|announcement",
    re.I,
)
GUIDANCE_ANCHOR = re.compile(r"\b(guidance|outlook|forecast)\b", re.I)
DISCLAIMER = re.compile(
    r"forward-looking statements|actual results (?:could|may) differ|risks and uncertainties",
    re.I,
)
FORWARD = re.compile(
    r"\b(reaffirm(?:s|ed|ing)?|expect(?:s|ed)?|forecast(?:s)?|project(?:s)?(?!\s+(?:execution|cost|construction|completion|timeline))|target(?:s)?|anticipat(?:e|es)|guidance|outlook|"
    r"will be|is expected|are expected|budgeted)\b",
    re.I,
)
NUMBER = re.compile(
    r"(?:(?:US\$|MXN|MX\$|Ps\.|[$£€])\s*\d[\d,.]*(?:\s*(?:billion|million|thousand|bn|mm|mn|m))?|"
    r"\d[\d,.]*\)?\s*%|\d[\d,.]*\s*(?:billion|million|thousand|bn|mm|mn|m)\b)",
    re.I,
)
HISTORICAL_ACTUAL = re.compile(
    r"\b(reached|recorded|reported|generated|increased|decreased|declined|rose|"
    r"came in|performance|results|year to date|ytd|versus|vs\.)\b",
    re.I,
)
HISTORICAL_GUIDANCE = re.compile(
    r"ahead of (?:prior |previous )?guidance|above (?:prior |previous )?guidance|"
    r"compared (?:with|to) (?:prior |previous )?guidance",
    re.I,
)
GUIDANCE_TABLE_VALUE = re.compile(
    r"growth of|at least|approximately|~|between|\brange\b|\d(?:\.\d+)?\s*%\s*(?:to|[-–])|"
    r"unchanged|including leases|payout ratio|on track for .* target",
    re.I,
)
METRICS = (
    ("free_cash_flow_guidance", re.compile(r"free cash flow|\bfcf\b", re.I)),
    ("capex_guidance", re.compile(r"capital expenditure|\bcapex\b", re.I)),
    ("gross_margin", re.compile(r"gross margin", re.I)),
    ("operating_margin", re.compile(r"operating margin", re.I)),
    ("operating_income_guidance", re.compile(r"operating profit|operating income", re.I)),
    ("eps_guidance", re.compile(r"earnings per share|\beps\b", re.I)),
    ("revenue_guidance", re.compile(r"revenue|net sales", re.I)),
    ("ebitda_guidance", re.compile(r"\bebitda\b", re.I)),
)
AMOUNT = re.compile(
    r"(?P<currency>US\$|[$£€])?\s*(?P<value>\d[\d,]*(?:\.\d+)?)\s*"
    r"(?P<scale>billion|million|bn|mm|mn|m)\b",
    re.I,
)
PERCENT = re.compile(
    r"(?<![\w.])(?P<value>\d+(?:\.\d+)?)\s*(?:%|percent\b)", re.I
)
PERCENT_RANGE = re.compile(
    r"(?<![\w.])(?P<low>\d+(?:\.\d+)?)\s*(?:%|percent\b)?\s*"
    r"(?:to|[-–]|and)\s*(?P<high>\d+(?:\.\d+)?)\s*(?:%|percent\b)",
    re.I,
)


def iso_date(value):
    try:
        parsed = dt.date.fromisoformat(str(value))
    except ValueError as error:
        raise argparse.ArgumentTypeError("Date must be YYYY-MM-DD") from error
    if parsed.isoformat() != value:
        raise argparse.ArgumentTypeError("Date must be YYYY-MM-DD")
    return value


def normalize_tickers(values):
    if values is None:
        return None
    if isinstance(values, str):
        values = [values]
    tickers = set()
    for value in values:
        for token in str(value).split(","):
            ticker = token.strip().upper()
            if not re.fullmatch(r"[A-Z0-9][A-Z0-9.-]{0,15}", ticker):
                raise ValueError(f"Invalid requested ticker: {token!r}")
            tickers.add(ticker)
    if not tickers:
        raise ValueError("Explicit --tickers cannot be empty")
    return sorted(tickers)


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-db", type=Path, default=DEFAULT_SOURCE_DB)
    parser.add_argument("--target-db", type=Path, default=DEFAULT_TARGET_DB)
    parser.add_argument("--manifest", type=Path, default=DEFAULT_MANIFEST)
    parser.add_argument("--guru-manifest", type=Path, default=DEFAULT_GURU_MANIFEST)
    parser.add_argument("--tickers", nargs="+", help="Exact canonical tickers, separated by spaces or commas; always review official filings even when transcripts exist.")
    parser.add_argument("--as-of", type=iso_date, default=dt.datetime.now(dt.timezone.utc).date().isoformat())
    parser.add_argument("--start-date", type=iso_date, help="Inclusive filing-date start; previously stored guidance outside this window is preserved.")
    parser.add_argument("--cache-dir", type=Path, default=Path("/tmp/pit-official-sec-guidance"))
    parser.add_argument("--workers", type=int, default=3)
    args = parser.parse_args(argv)
    try:
        args.tickers = normalize_tickers(args.tickers)
    except ValueError as error:
        parser.error(str(error))
    if args.start_date and args.start_date > args.as_of:
        parser.error("--start-date cannot follow --as-of")
    return args


def normalize_cik(value):
    digits = str(value or "").strip()
    return digits.zfill(10) if re.fullmatch(r"\d{1,10}", digits) and int(digits) > 0 else None


def select_issuer_targets(coverage_rows, cik_candidates, *, tickers=None, start_date=None, as_of=None):
    """Resolve one complete, explicit review scope before any network or write."""
    as_of = iso_date(as_of or dt.datetime.now(dt.timezone.utc).date().isoformat())
    if start_date is not None:
        iso_date(start_date)
        if start_date > as_of:
            raise ValueError("start_date cannot follow as_of")
    coverage = {str(row[0]).upper(): row for row in coverage_rows}
    selected = normalize_tickers(tickers)
    if selected is None:
        selected = sorted(
            ticker for ticker, row in coverage.items()
            if row[1] in {"missing_transcripts", "no_explicit_guidance", "official_guidance_review_incomplete"}
            or bool(row[2])
        )
    targets = {}
    problems = []
    for ticker in selected:
        if ticker not in coverage:
            problems.append(f"{ticker}: missing_guidance_coverage")
            continue
        ciks = {normalize_cik(value) for value in cik_candidates.get(ticker, [])}
        ciks.discard(None)
        if not ciks:
            problems.append(f"{ticker}: missing_issuer_cik")
            continue
        if len(ciks) != 1:
            problems.append(f"{ticker}: conflicting_issuer_ciks ({', '.join(sorted(ciks))})")
            continue
        start = start_date or ISSUERS.get(ticker, {}).get("start", "2010-01-01")
        if start > as_of:
            problems.append(f"{ticker}: review_start_after_as_of")
            continue
        targets[ticker] = {"cik": next(iter(ciks)), "start": start, "as_of": as_of}
    if problems:
        raise ValueError("Official guidance scope rejected: " + "; ".join(problems))
    return targets


def issuer_targets(source_db: Path, target_db: Path, manifest_path: Path, *,
                   guru_manifest_path: Path | None = None, tickers=None,
                   start_date=None, as_of=None):
    cik_candidates = collections.defaultdict(set)
    for ticker, config in ISSUERS.items():
        cik_candidates[ticker].add(config["cik"])
    for candidate_path in (manifest_path, guru_manifest_path):
        if candidate_path is None:
            continue
        manifest = json.loads(candidate_path.read_text(encoding="utf-8"))
        for company in manifest.get("companies") or []:
            cik = normalize_cik(company.get("cik"))
            if cik:
                # An unfinished valuation review does not prevent official
                # evidence collection for a separately identified issuer.
                cik_candidates[str(company["ticker"]).upper()].add(cik)
    if target_db.exists():
        with sqlite3.connect(f"{target_db.resolve().as_uri()}?mode=ro", uri=True) as connection:
            for ticker, payload_json in connection.execute(
                "SELECT ticker, payload_json FROM valuation_ticker_snapshots"
            ):
                payload = json.loads(payload_json)
                cik = normalize_cik(
                    payload.get("cik")
                    or ((payload.get("dataQuality") or {}).get("secCompanyFacts") or {}).get("cik")
                )
                if cik:
                    cik_candidates[str(ticker).upper()].add(cik)
    with sqlite3.connect(f"{source_db.resolve().as_uri()}?mode=ro", uri=True) as connection:
        rows = connection.execute(
            """
            SELECT coverage.ticker, coverage.status, EXISTS (
              SELECT 1 FROM pit_guidance_events AS events
              WHERE events.ticker = coverage.ticker
                AND events.source_type = 'official_issuer_sec_filing'
            ) AS has_official_events
            FROM pit_guidance_coverage AS coverage
            ORDER BY coverage.ticker
            """
        ).fetchall()
    return select_issuer_targets(rows, cik_candidates, tickers=tickers,
                                 start_date=start_date, as_of=as_of)


def get_json(session: requests.Session, url: str, cache: Path):
    if cache.exists():
        return json.loads(cache.read_text())
    response = session.get(url, timeout=20)
    response.raise_for_status()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(response.text)
    time.sleep(SEC_REQUEST_DELAY_SECONDS)
    return response.json()


def get_text(session: requests.Session, url: str, cache: Path):
    if cache.exists():
        return cache.read_text(errors="replace")
    response = session.get(url, timeout=20)
    response.raise_for_status()
    cache.parent.mkdir(parents=True, exist_ok=True)
    cache.write_text(response.text)
    time.sleep(SEC_REQUEST_DELAY_SECONDS)
    return response.text


def filing_rows(records: dict, start_date: str, as_of: str | None = None):
    for index, form in enumerate(records["form"]):
        filing_date = records["filingDate"][index]
        primary = records["primaryDocument"][index]
        items = (records.get("items") or [""] * len(records["form"]))[index]
        if form not in {"6-K", "8-K"} or filing_date < start_date or (as_of and filing_date > as_of):
            continue
        if form == "8-K" and not re.search(r"(?:^|,|\s)(?:2\.02|7\.01)(?:$|,|\s)", items or ""):
            continue
        # A generic 6-K wrapper can carry results in an EX99 attachment. Inspect
        # its accession directory; only clear non-results filings may be skipped.
        if form == "6-K" and EXCLUDED_DOCUMENT.search(primary) and not RESULT_DOCUMENT.search(primary):
            continue
        yield {
            "accession": records["accessionNumber"][index],
            "filing_date": filing_date,
            "report_date": records["reportDate"][index],
            "primary": primary,
            "form": form,
            "items": items,
        }


def submission_record_sets(session, submission: dict, cache_dir: Path):
    yield submission["filings"]["recent"]
    for row in submission["filings"].get("files") or []:
        name = row.get("name")
        if not name:
            continue
        yield get_json(
            session,
            f"https://data.sec.gov/submissions/{name}",
            cache_dir / "submission-archives" / name,
        )


def accession_documents(
    session,
    cik: str,
    filing: dict,
    cache_dir: Path,
    document_errors: list[dict] | None = None,
):
    accession = filing["accession"].replace("-", "")
    base = f"https://www.sec.gov/Archives/edgar/data/{int(cik)}/{accession}"
    index = get_json(session, f"{base}/index.json", cache_dir / accession / "index.json")
    names = [item["name"] for item in index["directory"]["item"]]
    candidates = []
    for name in names:
        if not name.lower().endswith((".htm", ".html", ".txt")):
            continue
        if name == filing["primary"] or RESULT_DOCUMENT.search(name):
            candidates.append(name)
    if not candidates:
        # Some valid accessions list only an otherwise generically named
        # exhibit (for example an IPO underwriting agreement). Read the actual
        # directory-listed HTML instead of calling a missing primary a reviewed
        # no-guidance filing. Never invent a replacement document or discard a
        # failed source; fiscal-period/guidance checks below still apply.
        fallback = [name for name in names
                    if name.lower().endswith((".htm", ".html"))
                    and not re.search(r"(?:^|-)index(?:-headers)?\.html?$", name, re.I)
                    and "/" not in name and "\\" not in name]
        if len(fallback) > 6:
            raise ValueError("Too many unclassified listed HTML documents for bounded fallback review")
        candidates.extend(fallback)
    for name in dict.fromkeys(candidates):
        try:
            yield name, f"{base}/{name}", get_text(
                session, f"{base}/{name}", cache_dir / accession / name
            )
        except Exception as error:
            if document_errors is not None:
                document_errors.append({
                    "accession": filing["accession"],
                    "document": name,
                    "error": str(error),
                })


def clean_lines(html: str):
    soup = BeautifulSoup(html, "html.parser")
    for node in soup(["script", "style"]):
        node.decompose()
    # A source-code newline or inline <span>/<sup> is not a financial row
    # boundary. Keep each actual paragraph intact before separating blocks.
    for node in soup.find_all(["p", "li", "h1", "h2", "h3", "h4"]):
        value = re.sub(r"\s+", " ", node.get_text(" ", strip=True)).strip()
        node.clear()
        node.append(value)
    lines = []
    for raw_line in soup.get_text("\n").splitlines():
        for fragment in re.split(r"[•●▪]", raw_line):
            line = re.sub(r"\s+", " ", fragment).strip(" \t")
            if line:
                lines.append(line)
    return lines


def fiscal_period(lines: list[str], filing: dict):
    heading = " ".join(lines[:180])
    report_date = filing["report_date"] or filing["filing_date"]
    year = int(report_date[:4])
    primary = filing["primary"]
    primary_quarter = re.search(r"q([1-4])(?:[-_ ]?)(20\d{2})", primary, re.I)
    if primary_quarter:
        return f"Q{primary_quarter.group(1)}{primary_quarter.group(2)}"
    year_first_quarter = re.search(r"(20\d{2}).*?q([1-4])", primary, re.I)
    if year_first_quarter:
        return f"Q{year_first_quarter.group(2)}{year_first_quarter.group(1)}"
    short_year_quarter = re.search(r"(?<!\d)([1-4])q[-_ ]?(20\d{2}|\d{2})(?!\d)", primary, re.I)
    if short_year_quarter:
        fiscal_year = short_year_quarter.group(2)
        if len(fiscal_year) == 2:
            fiscal_year = f"20{fiscal_year}"
        return f"Q{short_year_quarter.group(1)}{fiscal_year}"
    if re.search(r"half[-_ ]?year|interim|\bh1\b", primary, re.I):
        return f"Q2{year}"
    patterns = (
        ("Q1", r"\b(?:q1|first quarter|1st quarter)\b"),
        ("Q2", r"\b(?:q2|second quarter|2nd quarter|half[- ]year|first half|h1)\b"),
        ("Q3", r"\b(?:q3|third quarter|3rd quarter)\b"),
        ("Q4", r"\b(?:q4|fourth quarter|4th quarter|full[- ]year|fy\s*\d{2,4})\b"),
    )
    for quarter, pattern in patterns:
        match = re.search(pattern, heading, re.I)
        if match:
            return f"{quarter}{year}"
    # The filing/report calendar date does not identify an issuer fiscal period.
    return None


def metric_values(text: str, metric: str):
    metric_pattern = dict(METRICS)[metric]
    metric_match = metric_pattern.search(text)
    if not metric_match:
        return None, None, None, None
    metric_position = metric_match.start()
    metric_end = metric_match.end()
    next_metric_positions = []
    for other_metric, other_pattern in METRICS:
        if other_metric == metric:
            continue
        other_match = other_pattern.search(text, metric_end)
        if other_match:
            next_metric_positions.append(other_match.start())
    segment_end = min(next_metric_positions, default=len(text))
    sentence_separator = re.search(r"[.;](?:\s|$)", text[metric_end:segment_end])
    if sentence_separator:
        segment_end = min(segment_end, metric_end + sentence_separator.start())
    segment = text[metric_position:segment_end]
    local_metric_position = 0
    amounts = []
    for match in AMOUNT.finditer(segment):
        value = float(match.group("value").replace(",", ""))
        scale = match.group("scale").lower()
        if scale in {"billion", "bn"}:
            value *= 1000
        symbol = match.group("currency") or ""
        currency = {"£": "GBP", "€": "EUR"}.get(symbol, "USD" if "$" in symbol else None)
        amounts.append((value, currency, match.start(), match.end()))
    percentages = [
        (float(match.group("value")), match.start()) for match in PERCENT.finditer(segment)
    ]
    amounts.sort(key=lambda item: abs(item[2] - local_metric_position))
    percentages.sort(key=lambda item: abs(item[1] - local_metric_position))
    selected_amounts = amounts[:1]
    selected_percentages = percentages[:1]
    if len(amounts) >= 2:
        first, second = sorted(amounts[:2], key=lambda item: item[2])
        connector = segment[first[3]:second[2]]
        if re.fullmatch(r"\s*(?:to|[-–]|and)\s*", connector, re.I):
            selected_amounts = [first, second]
    percent_range = PERCENT_RANGE.search(segment)
    if percent_range:
        selected_percentages = [
            (float(percent_range.group("low")), percent_range.start("low")),
            (float(percent_range.group("high")), percent_range.start("high")),
        ]
    elif len(percentages) >= 2:
        first, second = sorted(percentages[:2], key=lambda item: item[1])
        first_match = next(
            (match for match in PERCENT.finditer(segment) if match.start() == first[1]),
            None,
        )
        if first_match:
            connector = segment[first_match.end():second[1]]
            if re.fullmatch(r"\s*(?:to|[-–]|and)\s*", connector, re.I):
                selected_percentages = [first, second]
    amount = (
        sum(value for value, _, _, _ in selected_amounts) / len(selected_amounts)
        if selected_amounts else None
    )
    currency = next((currency for _, currency, _, _ in selected_amounts if currency), None)
    margin = sum(value for value, _ in selected_percentages) / len(selected_percentages) if selected_percentages and metric in {
        "gross_margin", "operating_margin"
    } else None
    growth = sum(value for value, _ in selected_percentages) / len(selected_percentages) if selected_percentages and metric in {
        "revenue_guidance", "operating_income_guidance", "ebitda_guidance"
    } else None
    return amount, currency, margin, growth


def annual_guidance_heading(line):
    match = re.fullmatch(
        r"(?:(?:full[- ]year|fiscal year|fy)\s*)?(20\d{2})\s+(?:guidance|outlook)|"
        r"(?:(?:full[- ]year|annual)\s+)?(?:guidance|outlook)\s+(?:for\s+)?(?:(?:fiscal year|fy)\s*)?(20\d{2})",
        str(line).strip().rstrip(":"), re.I,
    )
    return int(next(value for value in match.groups() if value)) if match else None


CAPITAL_BUDGET = re.compile(r"\b(?:have\s+)?budgeted\s+capital expenditures?\b|\bcapital expenditures?\s+budget\b", re.I)
CAPITAL_NONCASH_BASIS = re.compile(r"\bincluding\s+(?:as\s+)?right[- ]of[- ]use\s+assets\b|\binclud(?:es?|ing)\s+non[- ]cash\b", re.I)


def noncash_capital_budget_evidence(event):
    text = str(event.get("evidence_excerpt") or event.get("value_text") or "")
    return event.get("metric_name") == "capex_guidance" and bool(CAPITAL_BUDGET.search(text) and CAPITAL_NONCASH_BASIS.search(text))


def capital_budget_research_candidates(lines):
    """Keep long MD&A capital programs with their noncash definition attached.

    These are research observations, not a cash-capex/FCFE forecast. Retain the
    total, component and actual-cash wording without clipping the qualification.
    """
    result = {}
    for index, line in enumerate(lines):
        if not CAPITAL_BUDGET.search(line) or not NUMBER.search(line):
            continue
        definitions = [text for text in lines[max(0, index - 3):index]
                       if re.search(r"\bcapital expenditures?\b", text, re.I) and CAPITAL_NONCASH_BASIS.search(text)]
        excerpt = "\n".join([line, *definitions])
        if noncash_capital_budget_evidence({"metric_name": "capex_guidance", "evidence_excerpt": excerpt}):
            result[index] = excerpt
    return result


def guidance_lines(lines: list[str], ticker: str):
    budget_candidates = capital_budget_research_candidates(lines)
    accepted = {("capex_guidance", text): ("capex_guidance", text) for text in budget_candidates.values()}
    guidance_until = -1
    annual_heading = None
    disclosure_heading = None
    preliminary_heading = next((line for line in lines[:80] if len(line) < 240 and re.search(
        r"\bpreliminary\b.*\b(?:financial results|expected results)\b", line, re.I
    )), None)
    for index, line in enumerate(lines):
        if index in budget_candidates:
            continue  # Do not emit an unqualified duplicate without its basis.
        if DISCLAIMER.search(line) or re.match(r"^(?:disclaimer|non-ifrs measures|medium[- ]term|long[- ]term)\b", line, re.I):
            guidance_until = -1
            annual_heading = None
            disclosure_heading = None
            continue
        if index > guidance_until:
            annual_heading = None
        heading_year = annual_guidance_heading(line)
        if heading_year is not None:
            annual_heading = line
            guidance_until = index + 30
        elif GUIDANCE_ANCHOR.search(line) and len(line) <= 100 and re.search(
            r"\bq[1-4]\b|\b(?:first|second|third|fourth|next) quarter\b", line, re.I
        ):
            annual_heading = None
        if GUIDANCE_ANCHOR.search(line) and len(line) <= 120 and not re.search(r"\b(?:results|performance|grew|reported)\b", line, re.I):
            guidance_until = index + 30
            disclosure_heading = line
        if index <= guidance_until and len(line) <= 120 and re.fullmatch(
            r"(?:For\s+(?:the\s+)?)?(?:Full[- ]Year\s+(?:Fiscal\s+)?20\d{2}|Fiscal Year\s+20\d{2}|20\d{2}|"
            r"Q[1-4]\s+(?:(?:FY|Fiscal(?:\s+Year)?)\s*)?20\d{2}|"
            r"(?:First|Second|Third|Fourth)\s+Quarter(?:\s+of)?\s+(?:(?:Fiscal(?:\s+Year)?)\s+)?20\d{2})"
            r"(?:\s+Financial\s+(?:Outlook|Guidance))?(?:,?\s+we expect)?\s*:?", line, re.I,
        ):
            annual_heading = line
        candidate = line
        if index and len(lines[index - 1]) <= 100:
            previous_metrics = [pattern for _, pattern in METRICS if pattern.search(lines[index - 1])]
            if previous_metrics and not NUMBER.search(lines[index - 1]):
                candidate = f"{lines[index - 1]} {line}"
        initial_metrics = [(name, pattern) for name, pattern in METRICS if pattern.search(candidate)]
        if initial_metrics and not NUMBER.search(candidate):
            if index + 1 in budget_candidates:
                continue  # The next budget already has its complete noncash basis.
            candidate = " ".join(lines[index:min(len(lines), index + 2)])
        if len(candidate) > 2500:
            continue
        metrics = [(name, pattern) for name, pattern in METRICS if pattern.search(candidate)]
        if any(name == "capex_guidance" for name, _ in metrics) and re.search(
            r"cap(?:ex|ital expenditure).*?% of revenue", candidate, re.I
        ):
            metrics = [(name, pattern) for name, pattern in metrics if name != "revenue_guidance"]
        if not metrics or not NUMBER.search(candidate):
            continue
        forward_positions = [match.start() for match in FORWARD.finditer(candidate)]
        metric_positions = [pattern.search(candidate).start() for _, pattern in metrics]
        explicit = bool(
            GUIDANCE_ANCHOR.search(candidate)
            or any(abs(forward - metric) <= 180 for forward in forward_positions for metric in metric_positions)
        )
        compact_table_value = (
            index <= guidance_until
            and len(candidate) <= 260
            and bool(GUIDANCE_TABLE_VALUE.search(candidate) or annual_heading and NUMBER.search(candidate))
        )
        if ticker == "FER" and not re.search(r"\b(guidance|outlook|forecast|target)\b", candidate, re.I):
            continue
        if HISTORICAL_GUIDANCE.search(candidate):
            continue
        # Compensation vesting thresholds are not management's operating
        # forecast. Keep the original filing in the evidence cache, but do not
        # demand a financial reporting period for a PSU award-plan paragraph.
        # An explicitly mixed operating-outlook paragraph still needs review.
        if (not GUIDANCE_ANCHOR.search(candidate)
                and re.search(r"\b(?:PSUs?|performance (?:share|stock) units?|stock price goal)\b", candidate, re.I)
                and re.search(r"\brevenue (?:goal|hurdle)\b", candidate, re.I)
                and re.search(r"\b(?:tranche|vest(?:ing|ed)?|performance period)\b", candidate, re.I)):
            continue
        if "share buyback" in candidate.lower() and not GUIDANCE_ANCHOR.search(candidate):
            continue
        if not explicit and not compact_table_value:
            continue
        if HISTORICAL_ACTUAL.search(candidate) and not explicit:
            continue
        # Carry only the actual heading, never invent annual scope for an
        # unscoped table. This also keeps the guidance year distinct from the
        # fiscal period reported by a year-end earnings release.
        excerpt = f"{annual_heading}. {candidate}" if annual_heading else (
            f"Guidance: {candidate}" if compact_table_value and not explicit else candidate
        )
        if annual_heading and disclosure_heading and not FORWARD.search(annual_heading) and not FORWARD.search(candidate):
            excerpt = f"{disclosure_heading}. {excerpt}"
        if preliminary_heading and not annual_heading and preliminary_heading not in excerpt:
            excerpt = f"{preliminary_heading}. {excerpt}"
        for metric, _ in metrics:
            accepted[(metric, excerpt)] = (metric, excerpt)
    return list(accepted.values())


def ensure_schema(connection):
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS pit_guidance_events (
          id TEXT PRIMARY KEY, ticker TEXT NOT NULL, fiscal_period TEXT NOT NULL,
          observed_at TEXT NOT NULL, metric_name TEXT NOT NULL,
          actual_or_guidance TEXT NOT NULL, amount REAL, unit TEXT, currency TEXT,
          growth_yoy REAL, growth_qoq REAL, margin_pct REAL, value_text TEXT,
          quality_status TEXT NOT NULL, extraction_confidence REAL NOT NULL,
          speaker TEXT, source_url TEXT NOT NULL, evidence_excerpt TEXT NOT NULL,
          source_file TEXT NOT NULL, source_type TEXT NOT NULL,
          extraction_version TEXT NOT NULL, payload_json TEXT NOT NULL
        );
        """
    )


def build_session():
    session = requests.Session()
    session.headers.update({"User-Agent": SEC_USER_AGENT, "Accept-Encoding": "gzip, deflate"})
    session.mount(
        "https://",
        HTTPAdapter(
            max_retries=Retry(
                total=1,
                connect=1,
                read=1,
                backoff_factor=1.0,
                status_forcelist=(429, 500, 502, 503, 504),
                allowed_methods=("GET",),
            )
        ),
    )
    return session


def guidance_module():
    spec = importlib.util.spec_from_file_location("pit_guidance_extractor", GUIDANCE_EXTRACTOR)
    module = importlib.util.module_from_spec(spec)
    assert spec.loader
    spec.loader.exec_module(module)
    return module


def extract_metric_event(
    guidance_lib,
    ticker: str,
    period: str,
    filing_date: str,
    source_url: str,
    source_file: str,
    metric: str,
    excerpt: str,
    metric_position_override: int | None = None,
):
    metric_positions = guidance_lib.metric_names(excerpt)
    fallback_match = dict(METRICS)[metric].search(excerpt)
    fallback_position = fallback_match.start() if fallback_match else 0
    position = min(
        (metric_position for metric_name, metric_position in metric_positions if metric_name == metric),
        key=lambda metric_position: abs(metric_position - fallback_position),
        default=fallback_position,
    )
    if metric_position_override is not None:
        position = metric_position_override
    elif sum(name == metric for name, _ in metric_positions) > 1:
        candidates = extract_metric_events(guidance_lib, ticker, period, filing_date, source_url, source_file, metric, excerpt)
        return max(candidates, key=lambda event: (
            any(event.get(key) is not None for key in ("amount", "per_share_value", "growth_yoy", "margin_pct")),
            event.get("guidance_subject") == "company_total",
            event.get("actual_or_guidance") == "guidance",
        ))
    extracted = guidance_lib.extract_event(
        ticker,
        period,
        filing_date,
        source_url,
        Path(source_file),
        "Issuer management / investor relations filing",
        excerpt,
        metric,
        position,
        metric_positions or [(metric, position)],
    )
    heading = excerpt.split(". ", 1)[0]
    target_year = annual_guidance_heading(heading)
    if target_year is not None and extracted.get("guidance_scope") not in {"quarter", "multi_year_target"}:
        extracted.update({
            "guidance_scope": "full_year",
            "guidance_scope_evidence": heading,
            "guidance_target_year": target_year,
            "guidance_year": target_year,
        })
    digest = hashlib.sha256(
        f"{ticker}|{period}|{filing_date}|{metric}|{excerpt}".encode()
    ).hexdigest()[:24]
    payload = {
        **extracted,
        "id": digest,
        "ticker": ticker,
        "fiscal_period": period,
        "observed_at": filing_date,
        "metric_name": metric,
        "actual_or_guidance": extracted.get("actual_or_guidance", "guidance"),
        "value_text": extracted.get("value_text") or excerpt,
        "quality_status": extracted.get("quality_status", "ambiguous"),
        "extraction_confidence": extracted.get("extraction_confidence", 0),
        "speaker": "Issuer management / investor relations filing",
        "source_url": source_url,
        "evidence_excerpt": excerpt,
        "source_file": source_file,
        "source_type": "official_issuer_sec_filing",
        "extraction_version": f"{guidance_lib.EXTRACTION_VERSION}+{IMPORT_VERSION}",
    }
    if noncash_capital_budget_evidence(payload):
        payload.update({
            "quality_status": "research_only_cash_noncash_mapping",
            "model_exclusion_reason": "cash-noncash-mapping-needed",
            "guidance_measure_basis": "capital_program_budget_not_cash_capex",
        })
    if metric == "revenue_guidance" and payload.get("amount") is None and re.search(r"\b20\d{2}\s+Guidance\s+Low\s+High\s+GAAP revenue\s+\$", excerpt, re.I):
        payload["extraction_review_required"] = "table-column-and-unit-context-required"
    payload["payload_json"] = json.dumps(payload, separators=(",", ":"))
    return payload


def extract_metric_events(guidance_lib, ticker, period, filing_date, source_url, source_file, metric, excerpt):
    """One original quote may contain multiple targets or GAAP/adjusted EPS.

    Preserve each metric occurrence and deduplicate only identical semantics;
    an empty headline must not hide the later quantified target.
    """
    # Explicitly different reporting bases are separate source statements, not
    # alternative numbers that can be averaged or cross-bound within one row.
    if metric == "revenue_guidance" and re.search(r"\bOn a GAAP basis\b", excerpt, re.I) and re.search(r"\bOn a pro forma adjusted constant currency basis\b", excerpt, re.I):
        clauses = re.split(r"(?<=\.)\s+(?=On a (?:GAAP|pro forma adjusted constant currency) basis\b)", excerpt, flags=re.I)
        if len(clauses) > 1:
            return [event for clause in clauses for event in extract_metric_events(guidance_lib, ticker, period, filing_date, source_url, source_file, metric, clause)]
    positions = [position for name, position in guidance_lib.metric_names(excerpt) if name == metric]
    if not positions:
        match = dict(METRICS)[metric].search(excerpt)
        positions = [match.start() if match else 0]
    events = [extract_metric_event(guidance_lib, ticker, period, filing_date, source_url, source_file, metric, excerpt, position) for position in positions]
    events = guidance_lib.deduplicate_sentence_events(events)
    primary = max(events, key=lambda event: (
        any(event.get(key) is not None for key in ("amount", "per_share_value", "growth_yoy", "margin_pct")),
        event.get("guidance_subject") == "company_total",
        event.get("actual_or_guidance") == "guidance",
    ))
    for event in events:
        if event is not primary:
            event["metric_occurrence"] = event["metric_position"]
            event["id"] = hashlib.sha256(f"{event['id']}|metric-position:{event['metric_position']}".encode()).hexdigest()[:24]
            event.pop("payload_json", None)
            event["payload_json"] = json.dumps(event, separators=(",", ":"))
    return events


def forward_company_guidance_event(event):
    """Classify the evidence before considering parser quality or currency."""
    if event.get("actual_or_guidance") != "guidance":
        return False
    if event.get("guidance_subject") not in {"company_total", "company_total_or_unspecified"}:
        return False
    if event.get("guidance_scope") not in {"full_year", "quarter", "annual", "fiscal_year"}:
        return False
    evidence = str(event.get("evidence_excerpt") or event.get("value_text") or "")
    if not FORWARD.search(evidence) or HISTORICAL_GUIDANCE.search(evidence):
        return False
    return True


def finite_guidance_number(value):
    return isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value)


def resolved_guidance_currency(event):
    if re.fullmatch(r"[A-Z]{3}", str(event.get("currency") or "")):
        return event["currency"]
    resolution = event.get("currency_resolution") or {}
    if resolution.get("status") == "dated_issuer_reporting_currency" and resolution.get("evidence"):
        return resolution.get("currency")
    return None


def guidance_event_review_reason(event):
    """An unresolved quantified event is incomplete review, not absent guidance.

    The model importer may resolve a bare dollar from dated issuer financial
    evidence. This official scanner does not independently certify that evidence;
    it retains the raw event and blocks coverage until currency review is done.
    Percentage-only guidance needs no monetary currency.
    """
    if not forward_company_guidance_event(event):
        return None
    if noncash_capital_budget_evidence(event):
        # The quotation itself establishes why this is research-only. A parser
        # quality label by itself never supplies this exception.
        return None
    if event.get("extraction_review_required"):
        return "source_table_context_required"
    if event.get("quality_status") == "currency_conflict":
        return "guidance_currency_conflict"
    if any(finite_guidance_number(event.get(key)) for key in ("amount", "per_share_value")) and not re.fullmatch(
        r"[A-Z]{3}", str(resolved_guidance_currency(event) or "")
    ):
        return "guidance_currency_unresolved"
    if event.get("quality_status") != "clear" and any(
        finite_guidance_number(event.get(key))
        for key in ("amount", "per_share_value", "growth_yoy", "growth_qoq", "margin_pct")
    ):
        return "quantified_guidance_not_clear"
    return None


def usable_guidance_event(event):
    """Coverage requires certified quantified forward guidance, not row count."""
    return bool(
        forward_company_guidance_event(event)
        and event.get("quality_status") == "clear"
        and not noncash_capital_budget_evidence(event)
        and not guidance_event_review_reason(event)
        and any(finite_guidance_number(event.get(key))
                for key in ("amount", "per_share_value", "growth_yoy", "growth_qoq", "margin_pct"))
    )


def guidance_coverage_counts(events):
    usable = [event for event in events if usable_guidance_event(event)]
    review_reasons = [reason for event in events if (reason := guidance_event_review_reason(event))]
    official_types = {"official_issuer_sec_filing", "official_uk_company_filing", "official_issuer_results_release"}
    return {
        "events": len(events),
        "periods": len({event.get("fiscal_period") for event in events if event.get("fiscal_period")}),
        "usableEvents": len(usable),
        "usableOfficialEvents": sum(event.get("source_type") in official_types for event in usable),
        "researchEvents": len(events) - len(usable),
        "reviewRequiredEvents": len(review_reasons),
        "reviewRequiredReasons": {reason: review_reasons.count(reason) for reason in sorted(set(review_reasons))},
    }


def scan_issuer(ticker: str, config: dict, cache_dir: Path):
    session = build_session()
    guidance_lib = guidance_module()
    events = []
    filing_count = 0
    filing_errors = 0
    access_errors = []
    reviewed_documents = 0
    recognized_period_documents = 0
    unknown_period_documents = 0
    periods = set()
    seen_accessions = set()
    try:
        cik = config["cik"]
        try:
            submission = get_json(
                session,
                f"https://data.sec.gov/submissions/CIK{cik}.json",
                cache_dir / ticker / "submission.json",
            )
        except Exception as error:
            return ticker, [], {
                "filings": 0,
                "filingErrors": 1,
                "periods": 0,
                "submissionError": str(error),
            }
        record_sets = [submission["filings"]["recent"]]
        for archive in submission["filings"].get("files") or []:
            name = archive.get("name")
            if not name:
                continue
            try:
                record_sets.append(get_json(
                    session,
                    f"https://data.sec.gov/submissions/{name}",
                    cache_dir / ticker / "submission-archives" / name,
                ))
            except Exception:
                filing_errors += 1
                access_errors.append({
                    "archive": name,
                    "error": "Submission archive could not be read.",
                })
        for records in record_sets:
            for filing in filing_rows(records, config["start"], config.get("as_of")):
                if filing["accession"] in seen_accessions:
                    continue
                seen_accessions.add(filing["accession"])
                filing_count += 1
                document_errors = []
                try:
                    documents = list(accession_documents(
                        session,
                        cik,
                        filing,
                        cache_dir / ticker,
                        document_errors,
                    ))
                except Exception as error:
                    filing_errors += 1
                    access_errors.append({
                        "accession": filing["accession"],
                        "document": "index.json",
                        "error": str(error),
                    })
                    continue
                access_errors.extend(document_errors)
                filing_errors += len(document_errors)
                if not documents and not document_errors:
                    filing_errors += 1
                    access_errors.append({
                        "accession": filing["accession"],
                        "error": "no_supported_filing_documents",
                    })
                for document_name, source_url, html in documents:
                    lines = clean_lines(html or "")
                    if not lines:
                        filing_errors += 1
                        access_errors.append({
                            "accession": filing["accession"], "document": document_name,
                            "error": "empty_filing_document",
                        })
                        continue
                    reviewed_documents += 1
                    # Exhibits may carry the fiscal-period token omitted by a
                    # generic primary wrapper. Preserve the same filing date.
                    period = fiscal_period(lines, {**filing, "primary": document_name}) or fiscal_period([], filing)
                    candidate_guidance = list(guidance_lines(lines, ticker))
                    if period is None:
                        unknown_period_documents += 1
                        if candidate_guidance:
                            filing_errors += 1
                            access_errors.append({
                                "accession": filing["accession"], "document": document_name,
                                "error": "guidance_without_identifiable_fiscal_period",
                            })
                        continue
                    recognized_period_documents += 1
                    for metric, excerpt in candidate_guidance:
                        payloads = extract_metric_events(
                            guidance_lib,
                            ticker,
                            period,
                            filing["filing_date"],
                            source_url,
                            f"SEC:{filing['accession']}:{document_name}",
                            metric,
                            excerpt,
                        )
                        events.extend(payloads)
                        periods.add(period)
        if reviewed_documents == 0:
            filing_errors += 1
            access_errors.append({"error": "no_reviewed_filing_documents"})
        elif recognized_period_documents == 0:
            filing_errors += 1
            access_errors.append({"error": "no_identifiable_fiscal_periods"})
        return ticker, events, {
            "filings": filing_count,
            "filingErrors": filing_errors,
            "accessErrors": access_errors,
            "periods": len(periods),
            "reviewedDocuments": reviewed_documents,
            "recognizedPeriodDocuments": recognized_period_documents,
            "unknownPeriodDocuments": unknown_period_documents,
        }
    finally:
        session.close()


def resolve_guidance_reporting_currencies(events, financial_rows):
    """Resolve symbols only from issuer facts already visible at disclosure.

    Quoted currency remains null for bare symbols. Currency facts and their
    dates are stored separately; model and release auditor reconstruct them
    independently from the dated financial source, never static identities.
    """
    facts = collections.defaultdict(list)
    for row in financial_rows:
        payload = json.loads(row["payload_json"])
        source = payload.get("sourceRecord") or {}
        available = str(row["available_at"])
        try:
            iso_date(available)
        except argparse.ArgumentTypeError:
            continue
        if source.get("candidateReviewStatus") == "pending_currency" or payload.get("currencyReviewStatus") == "pending_currency":
            facts[row["ticker"]].append((available, []))
            continue
        evidence = []
        for field, value in [("sourceFinancialStatementCurrency", payload.get("sourceFinancialStatementCurrency")),
                             ("reportingCurrency", payload.get("reportingCurrency")),
                             ("sourceRecord.sourceCurrency", source.get("sourceCurrency")),
                             ("sourceRecord.reportingCurrency", source.get("reportingCurrency"))]:
            if re.fullmatch(r"[A-Z]{3}", str(value or "")):
                evidence.append({"currency": value, "field": field, "availableAt": available,
                                 "source": source.get("sourceUrl") or source.get("dataset"),
                                 "sourceTicker": source.get("sourceTicker") or row["ticker"]})
        facts[row["ticker"]].append((available, evidence))
    resolved = []
    for original in events:
        event = dict(original)
        if not event.get("currency") and any(finite_guidance_number(event.get(key)) for key in ("amount", "per_share_value")) and (event.get("currency_resolution") or {}).get("status") != "conflicting_currency":
            visible = [item for item in facts[event["ticker"]] if item[0] <= event["observed_at"]]
            latest = max((item[0] for item in visible), default=None)
            evidence = [fact for date, items in visible if date == latest for fact in items]
            currencies = {item["currency"] for item in evidence}
            if len(currencies) == 1 and all(item.get("source") for item in evidence):
                event["currency_resolution"] = {"status": "dated_issuer_reporting_currency", "currency": next(iter(currencies)),
                                                "originalQuotedCurrency": None, "evidence": evidence,
                                                "policy": "Original quote preserved; closest prior/same-date issuer reporting-currency facts agree across financial dimensions."}
                event["payload_json"] = json.dumps({key: value for key, value in event.items() if key != "payload_json"}, separators=(",", ":"))
        resolved.append(event)
    return resolved


def align_events_to_financial_periods(source_db: Path, events: list[dict], as_of: str | None = None) -> list[dict]:
    """Attach filing guidance to the nearest issuer financial release.

    Filing headings can mention a future quarter and are therefore not a safe
    fiscal-period key.  The issuer's first-visible financial date is the PIT
    boundary and provides the stable quarter assignment.
    """

    by_ticker: dict[str, list[tuple[dt.date, str]]] = collections.defaultdict(list)
    with sqlite3.connect(f"{source_db.resolve().as_uri()}?mode=ro", uri=True) as connection:
        for ticker, fiscal_period, available_at in connection.execute(
            """
            SELECT ticker, fiscal_period, MIN(available_at)
            FROM pit_financial_periods
            WHERE (? IS NULL OR available_at <= ?)
            GROUP BY ticker, fiscal_period
            ORDER BY ticker, MIN(available_at)
            """,
            (as_of, as_of),
        ):
            try:
                by_ticker[str(ticker).upper()].append(
                    (dt.date.fromisoformat(str(available_at)), str(fiscal_period))
                )
            except (TypeError, ValueError):
                continue

    aligned = []
    for event in events:
        try:
            observed = dt.date.fromisoformat(str(event["observed_at"]))
        except (KeyError, TypeError, ValueError):
            aligned.append(event)
            continue
        candidates = by_ticker.get(str(event.get("ticker", "")).upper(), [])
        nearest = min(candidates, key=lambda item: abs((item[0] - observed).days), default=None)
        if nearest and abs((nearest[0] - observed).days) <= 45:
            event = {**event, "fiscal_period": nearest[1]}
            identity_parts = [
                    str(event.get(key) or "")
                    for key in (
                        "ticker",
                        "fiscal_period",
                        "observed_at",
                        "metric_name",
                        "evidence_excerpt",
                    )
                ]
            if event.get("metric_occurrence") is not None:
                identity_parts.append(f"metric-position:{event['metric_occurrence']}")
            event["id"] = hashlib.sha256("|".join(identity_parts).encode()).hexdigest()[:24]
            payload = {
                key: value for key, value in event.items() if key != "payload_json"
            }
            event["payload_json"] = json.dumps(payload, separators=(",", ":"))
        aligned.append(event)
    with sqlite3.connect(f"{source_db.resolve().as_uri()}?mode=ro", uri=True) as connection:
        connection.row_factory = sqlite3.Row
        financial_rows = connection.execute("SELECT ticker,available_at,payload_json FROM pit_financial_periods WHERE (? IS NULL OR available_at<=?)", (as_of, as_of)).fetchall()
    return resolve_guidance_reporting_currencies(aligned, financial_rows)


def main():
    args = parse_args()
    events = []
    coverage = {}

    issuers = issuer_targets(
        args.source_db, args.target_db, args.manifest,
        guru_manifest_path=args.guru_manifest, tickers=args.tickers,
        start_date=args.start_date, as_of=args.as_of,
    )
    if not issuers:
        print(json.dumps({"status": "no_targets", "events": 0, "coverage": {}, "asOf": args.as_of}))
        return
    args.cache_dir.mkdir(parents=True, exist_ok=True)
    workers = max(1, min(args.workers, 3))
    with concurrent.futures.ThreadPoolExecutor(max_workers=workers) as executor:
        futures = {
            executor.submit(scan_issuer, ticker, config, args.cache_dir): ticker
            for ticker, config in issuers.items()
        }
        for future in concurrent.futures.as_completed(futures):
            ticker, issuer_events, issuer_coverage = future.result()
            events.extend(issuer_events)
            coverage[ticker] = issuer_coverage
            print(
                f"{ticker}: {issuer_coverage['filings']} filings, "
                f"{len(issuer_events)} guidance events, "
                f"{issuer_coverage['filingErrors']} access errors",
                file=sys.stderr,
                flush=True,
            )

    failed_tickers = sorted(ticker for ticker, result in coverage.items() if result.get("filingErrors", 0))
    successful_issuers = {ticker: config for ticker, config in issuers.items() if ticker not in failed_tickers}
    # An incomplete scan cannot erase or replace an already reviewed source.
    events = [event for event in events if event["ticker"] in successful_issuers]
    for event in events:
        config = successful_issuers[event["ticker"]]
        if not config["start"] <= event["observed_at"] <= config["as_of"]:
            raise ValueError(f"Official guidance outside requested filing window: {event['ticker']} {event['observed_at']}")
    events = align_events_to_financial_periods(args.source_db, events, args.as_of)

    with sqlite3.connect(args.source_db) as connection:
        ensure_schema(connection)
        for ticker, config in successful_issuers.items():
            connection.execute(
                """
                DELETE FROM pit_guidance_events
                WHERE source_type='official_issuer_sec_filing'
                  AND ticker=? AND observed_at>=? AND observed_at<=?
                """,
                (ticker, config["start"], config["as_of"]),
            )
        for event in events:
            connection.execute(
                """
                INSERT OR REPLACE INTO pit_guidance_events (
                  id, ticker, fiscal_period, observed_at, metric_name,
                  actual_or_guidance, amount, unit, currency, growth_yoy,
                  growth_qoq, margin_pct, value_text, quality_status,
                  extraction_confidence, speaker, source_url, evidence_excerpt,
                  source_file, source_type, extraction_version, payload_json
                ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """,
                (
                    event["id"], event["ticker"], event["fiscal_period"],
                    event["observed_at"], event["metric_name"],
                    event["actual_or_guidance"], event["amount"], event["unit"],
                    event["currency"], event["growth_yoy"], event["growth_qoq"],
                    event["margin_pct"], event["value_text"], event["quality_status"],
                    event["extraction_confidence"], event["speaker"],
                    event["source_url"], event["evidence_excerpt"],
                    event["source_file"], event["source_type"],
                    event["extraction_version"], event["payload_json"],
                ),
            )
        for ticker in issuers:
            stored_events = connection.execute(
                """
                SELECT payload_json, source_type, quality_status
                FROM pit_guidance_events
                WHERE ticker=? AND observed_at<=?
                """,
                (ticker, args.as_of),
            ).fetchall()
            counts = guidance_coverage_counts([
                {**json.loads(payload_json), "source_type": source_type, "quality_status": quality_status}
                for payload_json, source_type, quality_status in stored_events
            ])
            count, periods = counts["events"], counts["periods"]
            coverage[ticker].update(counts)
            filing_errors = coverage[ticker].get("filingErrors", 0)
            if filing_errors:
                connection.execute(
                    """
                    UPDATE pit_guidance_coverage
                    SET guidance_periods=?, guidance_events=?, status=?, note=?
                    WHERE ticker=?
                    """,
                    (
                        periods, count, "official_guidance_review_incomplete",
                        f"Official filing review had {filing_errors} access errors; previously stored evidence was retained. Review window: {issuers[ticker]['start']} through {args.as_of}.",
                        ticker,
                    ),
                )
            elif counts["reviewRequiredEvents"]:
                failed_tickers.append(ticker)
                connection.execute(
                    """
                    UPDATE pit_guidance_coverage
                    SET guidance_periods=?, guidance_events=?, status=?, note=?
                    WHERE ticker=?
                    """,
                    (
                        periods, count, "official_guidance_review_incomplete",
                        f"{counts['reviewRequiredEvents']} forward quantified company guidance events need review: "
                        f"{json.dumps(counts['reviewRequiredReasons'], sort_keys=True)}. "
                        "Raw evidence retained; unresolved monetary currency is not no-quantified-guidance coverage. "
                        f"Review window: {issuers[ticker]['start']} through {args.as_of}.",
                        ticker,
                    ),
                )
            elif counts["usableEvents"]:
                status = "covered_official_filing" if counts["usableOfficialEvents"] else "covered"
                connection.execute(
                    """
                    UPDATE pit_guidance_coverage
                    SET guidance_periods=?, guidance_events=?, status=?, note=?
                    WHERE ticker=?
                    """,
                    (
                        periods, count, status,
                        f"Event-visible transcript and/or official issuer filing guidance; observed filing/call date is the PIT boundary. Official review window: {issuers[ticker]['start']} through {args.as_of}.",
                        ticker,
                    ),
                )
            else:
                status = "no_quantified_official_guidance"
                note = f"Official issuer filings reviewed from {issuers[ticker]['start']} through {args.as_of}; no clear, scoped forward company guidance suitable for the valuation model. {counts['researchEvents']} research-only evidence rows retained."
                connection.execute(
                    """
                    UPDATE pit_guidance_coverage
                    SET guidance_periods=?, guidance_events=?, status=?, note=?
                    WHERE ticker=?
                    """,
                    (
                        periods,
                        count,
                        status,
                        note,
                        ticker,
                    ),
                )
        failed_tickers = sorted(set(failed_tickers))
        connection.execute(
            "INSERT OR REPLACE INTO pit_source_metadata (key,value) VALUES (?,?)",
            ("official_sec_guidance_version", IMPORT_VERSION),
        )
        connection.execute(
            "INSERT OR REPLACE INTO pit_source_metadata (key,value) VALUES (?,?)",
            ("official_sec_guidance_imported_at", dt.datetime.now(dt.timezone.utc).isoformat()),
        )
        connection.execute(
            "INSERT OR REPLACE INTO pit_source_metadata (key,value) VALUES (?,?)",
            ("official_sec_guidance_last_scope", json.dumps({"issuers": issuers, "failedTickers": failed_tickers}, sort_keys=True)),
        )
        connection.commit()

    print(json.dumps({
        "status": "incomplete" if failed_tickers else "complete",
        "events": len(events),
        "coverage": coverage,
        "asOf": args.as_of,
        "issuers": issuers,
        "failedTickers": failed_tickers,
        "sourceDb": str(args.source_db),
        "version": IMPORT_VERSION,
    }, indent=2))
    if failed_tickers:
        raise RuntimeError(f"Official guidance review incomplete for: {', '.join(failed_tickers)}")


if __name__ == "__main__":
    main()
