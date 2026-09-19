#!/usr/bin/env python3
"""Extract point-in-time management guidance from downloaded earnings calls.

The extractor is deliberately conservative. It accepts only management/IR
sections, requires forward-looking language, rejects comparisons against old
guidance, and keeps the complete source sentence for auditability.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import sqlite3
from pathlib import Path


DEFAULT_TRANSCRIPT_ROOT = Path(
    os.environ.get(
        "PIT_EARNINGS_TRANSCRIPT_ROOT",
        Path.home() / "Documents/youtube_transcript_db/earnings_transcripts",
    )
)
DEFAULT_TARGET_DB = Path("server/data/guru-analysis.sqlite")
DEFAULT_SOURCE_DB = Path("server/data/valuation-pit-source.sqlite")
EXTRACTION_VERSION = "pit-guidance-rules-v35-owner-ranges-breakeven-pit-cutoff-2026-09-06"

SOURCE_ALIASES = {
    "GOOG": "GOOGL",
}

MANAGEMENT_ROLE = re.compile(
    r"\b(ceo|chief executive|cfo|chief financial|coo|chief operating|president|"
    r"chair(?:man|woman)?|investor relations|\bvp\b|vice president|controller|"
    r"chief accounting|treasurer|general counsel|secretary|founder|co-founder)\b",
    re.I,
)
# Do not reject issuer names such as "Lam Research". Analyst blocks are
# identified by the actual role label, not by a generic company-name token.
EXCLUDED_SPEAKER = re.compile(
    r"\b(operator|analyst|research analyst|equity research|capital markets)\b", re.I
)
FORWARD_LANGUAGE = re.compile(
    r"\b(we (?:now |continue to |still )?(?:expect|anticipate|forecast|project|estimate|"
    r"target|intend|plan)|our (?:outlook|guidance|expectation|target) (?:is|for|remains|"
    r"calls for|continues to be)|guidance (?:is|for|range|remains|reflects|calls for)|"
    r"outlook (?:is|for|remains|calls for)|we are (?:raising|lowering|reaffirming|"
    r"maintaining|updating)|we (?:raise|lower|reaffirm|maintain|update)|"
    r"(?:revenue|sales|free cash flow|fcf|operating (?:income|profit|margin)|gross margin|"
    r"earnings per share|eps|capex|capital expenditure|backlog|bookings|arr|rpo) "
    r"(?:is|are) expected to|we expect .*? (?:to be|between|in the range)|"
    r"we (?:see|look for) .*? (?:growth|margin|revenue|sales|cash flow))\b",
    re.I,
)
HISTORICAL_GUIDANCE = re.compile(
    r"\b(above|below|exceed(?:ed|ing)?|beat|miss(?:ed)?|versus|compared (?:with|to)|"
    r"relative to|within|in line with|consistent with|narrower than|favorable to) "
    r"(?:the |our )?(?:high end of |low end of )?(?:the |our )?"
    r"(?:prior |previous )?(?:guidance|outlook)\b|"
    r"\b(?:came in|was|were|delivered|recorded|generated).*\b(?:guidance|expectation)\b|"
    r"\bguidance (?:we )?(?:provided|gave|issued) (?:last|in the prior)|"
    r"\b(?:projections?|guidance) we gave\b|"
    r"\bmet\b[^.]{0,100}\b(?:guidance|outlook)\b|"
    r"\b(?:last|prior|previous) (?:year|quarter)\b[^.]{0,100}\b(?:was|were|had|included|represented|contributed)\b",
    re.I,
)
DISCLAIMER = re.compile(
    r"forward-looking statements|actual results (?:could|may) (?:differ|vary)|"
    r"risks and uncertainties|do not undertake .* update",
    re.I,
)
CURRENCY_TOKEN = r"(?:\bUS\$|\bU\.?S\.?\s+dollars?\b|\b(?:USD|MXN|GBP|EUR)(?![A-Za-z_])|\bMEX\$|\bMX\$|\bPs\.|\bMexican\s+pesos?\b|£|€|\$)"
CURRENCY_SUFFIX = r"(?:USD|MXN|GBP|EUR|Mexican\s+pesos?|U\.?S\.?\s+dollars?)\b"
AMOUNT_RE = re.compile(
    rf"(?P<currency>{CURRENCY_TOKEN})?\s*(?P<value>\d[\d,]*(?:\.\d+)?)\s*"
    rf"(?P<scale>billion|million|thousand|bn|mm|mn|m|b)\b(?:\s*(?P<currency_suffix>{CURRENCY_SUFFIX}))?",
    re.I,
)
SHARED_SCALE_RANGE_RE = re.compile(
    r"(?:(?P<left_direction>down|negative|minus|up|positive|plus)\s+)?"
    rf"(?P<left_currency>{CURRENCY_TOKEN})?\s*(?P<left>\d[\d,]*(?:\.\d+)?)\s*"
    r"(?P<connector>to|through|[-–—])\s*"
    r"(?:(?P<right_direction>down|negative|minus|up|positive|plus)\s+)?"
    rf"(?P<right_currency>{CURRENCY_TOKEN})?\s*(?P<right>\d[\d,]*(?:\.\d+)?)\s*"
    rf"(?P<scale>billion|million|thousand|bn|mm|mn|m|b)\b(?:\s*(?P<currency_suffix>{CURRENCY_SUFFIX}))?",
    re.I,
)
PERCENT_RE = re.compile(r"(?<![\w.])(?P<value>-?\d+(?:\.\d+)?)\s*%")
PERCENT_RANGE_RE = re.compile(
    r"(?<![\w.])(?P<left>-?\d+(?:\.\d+)?)\s*(?P<left_pct>%)?\s*"
    r"(?:to|[-–—])\s*(?P<right>-?\d+(?:\.\d+)?)\s*%", re.I,
)
NON_EPS_PER_SHARE_OWNER_RE = re.compile(
    r"\b(?:affo|ffo|funds from operations)(?:\s+per\s+(?:diluted\s+)?share\b|"
    r"(?=\s+[^;$\n.]{0,60}\$\d+(?:\.\d+)?(?:\s*(?:to|[-–—])\s*\$?\d+(?:\.\d+)?)?"
    r"\s+per\s+(?:diluted\s+)?share\b))", re.I,
)
PER_SHARE_RANGE_WIDTH_RE = re.compile(
    r"\b(?:narrowed|narrowing|widened|widening)\s+(?:the\s+)?range\s+for\s+"
    r"(?P<owners>[^.;]{1,90}?)\s+from\s+(?:a\s+)?range\s+of\s*"
    rf"(?P<before_currency>{CURRENCY_TOKEN})?\s*(?P<before>\d+(?:\.\d+)?)\s+"
    r"to\s+(?:a\s+)?range\s+of\s*"
    rf"(?P<after_currency>{CURRENCY_TOKEN})?\s*(?P<after>\d+(?:\.\d+)?)\s+per\s+share\b",
    re.I,
)
HISTORICAL_RESULTS_COMPARISON_RE = re.compile(
    r"\b(?:financial\s+)?results?\s+(?:vs\.?|versus|compared (?:with|to))\s+(?:outlook|guidance)\b", re.I,
)
PLUS_MINUS_RE = re.compile(
    r"(?:Â\s*)?±|\+/\-|\+\s+or\s+-|plus\s+or\s+minus",
    re.I,
)
NON_GUIDANCE_AMOUNT_OWNER_RE = re.compile(
    r"\b(?:costs?|expenses?|payments?|savings?|charges?|synergies?|tax expense|"
    r"depreciation and amortization|depreciation|amortization|d\s*&\s*a|"
    r"general and administrative|g\s*&\s*a|freight|foreign exchange|fx|currency headwind|"
    r"debt|dividends?|shareholder returns?|returns? to shareholders?|"
    r"diluted share count|share count|shares|share repurchases?|cash balance|cash on hand|"
    r"available borrowings|liquidity)\b",
    re.I,
)
HISTORICAL_AMOUNT_LEAD_RE = re.compile(
    r"\b(?:came in(?: at)?|grew to|increased to|decreased to|declined to|rose to|"
    r"fell to|reached)\b"
    r"[^,.;]{0,100}?(?:approximately|about|roughly|around|nearly|over|more than|"
    r"less than|at least|of|at|to)?\s*$|"
    r"\b(?:we|they|it|the company|the business|the segment)\s+"
    r"(?:delivered|reported|recorded|generated|achieved)\b[^,.;]{0,100}"
    r"(?:approximately|about|roughly|around|nearly|over|more than|less than|"
    r"at least|of|at|to)?\s*$|"
    r"\b(?:we|the company|the business)\s+closed\b[^,.;]{0,100}\b(?:with|at|of)\s*$|"
    r"\brecord\s+(?:revenue|revenues|sales|earnings|income|cash flow)\s+of\s*$|"
    r"\b(?:net loss|net income|revenue|revenues|sales|operating income|operating profit|"
    r"free cash flow)\b[^,.;]{0,100}\b(?:was|were)\s*$",
    re.I,
)
HISTORICAL_ACRONYM_AMOUNT_LEAD_RE = re.compile(
    r"\b[A-Z][A-Z0-9&.-]{1,9}\s+(?:delivered|reported|recorded|generated|achieved)\b"
    r"[^,.;]{0,100}(?:approximately|about|roughly|around|nearly|over|more than|"
    r"less than|at least|of|at|to)?\s*$"
)
HISTORICAL_AMOUNT_TRAIL_RE = re.compile(
    r"^[^.;]{0,120}\b(?:we|the company|the business)?\s*"
    r"(?:delivered|reported|recorded|generated|achieved)\b",
    re.I,
)
HISTORICAL_COMPARISON_LEAD_RE = re.compile(
    r"\b(?:versus|compared (?:with|to)|relative to|from|what)\b[^.;]{0,120}$",
    re.I,
)
STRICT_FORWARD_VALUE_RE = re.compile(
    r"\bwe\b[^.;]{0,80}\b(?:expect|anticipate|forecast|project|target|intend|plan)\b|"
    r"\b(?:is|are) expected to\b|"
    r"\b(?:raise|raised|raising|lower|lowered|lowering|reaffirm|reaffirmed|"
    r"reaffirming|update|updated|updating|maintain|maintained|maintaining)\b"
    r"[^.;]{0,80}\bguidance\b|"
    r"\b(?:target|goal|plan) of\b",
    re.I,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--transcript-root", type=Path, default=DEFAULT_TRANSCRIPT_ROOT)
    parser.add_argument("--target-db", type=Path, default=DEFAULT_TARGET_DB)
    parser.add_argument("--source-db", type=Path, default=DEFAULT_SOURCE_DB)
    parser.add_argument("--as-of-cutoff", help="ISO date; must equal source as_of_cutoff when present")
    parser.add_argument("--allow-undated-legacy-source", action="store_true",
                        help="Explicit legacy-only opt-in when source has no as_of_cutoff; not release-ready")
    return parser.parse_args()


def resolve_as_of_cutoff(connection: sqlite3.Connection, explicit: str | None = None,
                         allow_legacy: bool = False) -> str | None:
    """Bind extraction to source knowledge time before any source rows change."""
    has_metadata = connection.execute(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pit_source_metadata'"
    ).fetchone()
    row = connection.execute(
        "SELECT value FROM pit_source_metadata WHERE key='as_of_cutoff'"
    ).fetchone() if has_metadata else None
    stored = str(row[0]) if row and row[0] else None
    for value in (stored, explicit):
        if value is not None:
            try:
                parsed = dt.date.fromisoformat(value)
            except (TypeError, ValueError) as exc:
                raise ValueError("Guidance as_of_cutoff must be an ISO YYYY-MM-DD date") from exc
            if parsed.isoformat() != value:
                raise ValueError("Guidance as_of_cutoff must be an ISO YYYY-MM-DD date")
    if stored and explicit and stored != explicit:
        raise ValueError("Explicit guidance cutoff must equal source as_of_cutoff; cannot widen knowledge time")
    cutoff = stored or explicit
    if not cutoff and not allow_legacy:
        raise ValueError("Source as_of_cutoff is required; provide --as-of-cutoff or explicitly opt into --allow-undated-legacy-source")
    return cutoff


def target_tickers(db_path: Path, source_db_path: Path) -> list[tuple[str, str]]:
    if source_db_path.exists():
        with sqlite3.connect(source_db_path) as connection:
            has_coverage = connection.execute(
                "SELECT 1 FROM sqlite_master WHERE type='table' AND name='pit_financial_coverage'"
            ).fetchone()
            if has_coverage:
                return [
                    (str(row[0]).upper(), str(row[1] or row[0]).upper())
                    for row in connection.execute(
                        """
                        SELECT ticker, source_ticker
                        FROM pit_financial_coverage
                        WHERE status IN ('covered', 'annual_only')
                        ORDER BY ticker
                        """
                    )
                ]
    with sqlite3.connect(db_path) as connection:
        return [
            (str(row[0]).upper(), SOURCE_ALIASES.get(str(row[0]).upper(), str(row[0]).upper()))
            for row in connection.execute(
                "SELECT ticker FROM valuation_ticker_snapshots ORDER BY ticker"
            )
        ]


def parse_header(text: str) -> tuple[str | None, str | None, str | None]:
    lines = [line.strip() for line in text.splitlines()[:8] if line.strip()]
    period = None
    observed_at = None
    source_url = None
    for line in lines:
        match = re.search(r"Earnings Call:\s*(Q[1-4])\s*(20\d{2})", line, re.I)
        if match:
            period = f"{match.group(1).upper()}{match.group(2)}"
        if re.fullmatch(r"20\d{2}-\d{2}-\d{2}", line):
            observed_at = line
        if line.startswith(("https://", "http://")):
            source_url = line
    return period, observed_at, source_url


def speaker_sections(text: str):
    body = re.split(r"\n---\s*\n", text)
    for block in body:
        lines = [line.strip() for line in block.splitlines() if line.strip()]
        if len(lines) < 2:
            continue
        speaker = lines[0]
        if not MANAGEMENT_ROLE.search(speaker) or EXCLUDED_SPEAKER.search(speaker):
            continue
        yield speaker, " ".join(lines[1:])


def sentences(text: str):
    for sentence in re.split(r"(?<![Pp][Ss]\.)(?<=[.!?])\s+(?=[A-Z0-9$£€])", text):
        sentence = re.sub(r"\s+", " ", sentence).strip()
        if 35 <= len(sentence) <= 900:
            yield sentence


# Separated per-share units remain per-share economics. This does NOT include
# operating income: operating earnings need their own GAAP/adjusted bridge.
SEPARATED_EPS_OWNER = (
    r"net income(?=\s+(?:(?:per|for)\s+(?:diluted\s+)?share\b|"
    r"[^;$\n.]{0,95}\$\d+(?:\.\d+)?(?:\s*(?:to|[-–—])\s*\$?\d+(?:\.\d+)?)"
    r"?\s+per\s+(?:diluted\s+)?share\b))"
)
METRIC_PATTERNS = (
    ("free_cash_flow_guidance", re.compile(r"free cash flow|\bfcf\b", re.I)),
    ("operating_cash_flow_guidance", re.compile(r"operating cash flow|cash from operations", re.I)),
    ("capex_guidance", re.compile(r"capital expenditure|capital spending|capital investments?|\bcapex\b", re.I)),
    ("gross_margin", re.compile(r"gross margin", re.I)),
    ("operating_margin", re.compile(r"operating margin", re.I)),
    ("ebitda_guidance", re.compile(r"(?:adjusted )?ebitda", re.I)),
    ("operating_income_guidance", re.compile(r"operating income|income from operations|operating profit|(?:adjusted )?\bebit\b", re.I)),
    ("net_income_guidance", re.compile(r"(?:adjusted )?net income(?!\s+per\s+(?:diluted\s+)?share)", re.I)),
    ("eps_guidance", re.compile(r"(?:earnings|net income) per (?:diluted )?share|\beps\b|" + SEPARATED_EPS_OWNER, re.I)),
    ("revenue_guidance", re.compile(r"revenue|sales", re.I)),
    ("backlog_guidance", re.compile(r"remaining performance obligation|\brpo\b|backlog|bookings|billings|\barr\b", re.I)),
)


def metric_names(sentence: str) -> list[tuple[str, int]]:
    matches = []
    for name, pattern in METRIC_PATTERNS:
        for match in pattern.finditer(sentence):
            matches.append((name, match.start()))
    return sorted(matches, key=lambda item: item[1])


ANNUAL_SCOPE_RE = re.compile(
    r"\b20\d{2}\s+(?:total |net |adjusted )?(?:revenue|sales)\s+expected\b|"
    r"full\s*[- ]\s*year|fiscal year|\bfiscal\s+(?:20)?\d{2}\b|this year|annual|for the year|"
    r"\bfy\s*['’]?(?:20)?\d{2}(?:e)?\b|"
    r"(?:outlook|guidance) for (?:fiscal )?20\d{2}|for (?:fiscal )?20\d{2}|"
    r"\b20\d{2}\s+(?:(?:adjusted|net|total|revenue|sales|operating|income|ebitda)\s+){0,5}(?:guidance|outlook)\b",
    re.I,
)
QUARTER_SCOPE_RE = re.compile(
    r"\bq[1-4](?:\s*['’]\d{2}|\s+(?:of\s+)?(?:fy|fiscal(?: year)?)\s*(?:20)?\d{2}(?:e)?)?\b|"
    r"\b(?:first|second|third|fourth)\s+quarter"
    r"(?:\s+(?:of\s+)?(?:(?:fiscal|calendar)(?:\s+year)?\s+|fy\s*)?(?:20)?\d{2})?\b|"
    r"\b(?:january|february|march|april|may|june|july|august|september|"
    r"october|november|december)\s+quarter\b|"
    r"\bnext quarter\b|\bfor the quarter\b",
    re.I,
)
MULTI_YEAR_SCOPE_RE = re.compile(
    r"\bcompounded annual growth\b[^.;]{0,140}\bfrom 20\d{2} to 20\d{2}\b|"
    r"\bby (?:the end of )?20\d{2}\b|\bthrough 20\d{2}\b|"
    r"\bover the (?:next )?(?:two|three|four|five|six|seven|eight|nine|ten|\d+)[ -]years?\b|"
    r"\b(?:two|three|four|five|six|seven|eight|nine|ten|\d+)[ -]year (?:target|plan|period)\b|"
    r"\b(?:annualized )?(?:revenue|sales) run rate\b|\b(?:revenue|sales) cagr\b|"
    r"\brevenue stream by 20\d{2}\b|"
    r"\blong[- ]term\s+(?:(?:gross|operating|profit|revenue|sales|free cash flow|margin|growth)\s+){0,5}(?:targets?|goals?|ambitions?)\b",
    re.I,
)
REVENUE_SUBSET_RE = re.compile(
    r"\b(?:commercial|government|international|segment|services?|subscription|product|"
    r"software|semiconductor|data[ -]center|cloud|advertising|digital|licen[cs]e|"
    r"maintenance|aftermarket|consumer|enterprise|domestic|overseas|regional|"
    r"systemwide|same[- ]store|comparable[- ]store|professional services?|"
    r"installed base management|systems?|other|packaging|china|dram|foundry(?: logic)?|"
    r"retail(?: long-term care)?|brand|event-driven|specialty|distribution|\d{2,4}g)\s+"
    r"(?:revenue|revenues|sales)\b|"
    r"\brevenue from (?:these|the) contracts\b|\brevenues? from reimbursable travel\b|\brevenue from unused\b[^.;]{0,35}\bcommitments\b|\bannual recurring revenue\b|\barr\b",
    re.I,
)
REVENUE_NON_COMPANY_RE = re.compile(
    r"\bliquidity\b[^.]{0,150}\b(?:trailing[- ]12[- ]month|ttm)\s+revenue\b|"
    r"\b(?:asset|property|land|home|portfolio) sales\b|"
    r"\b(?:addressable|global|industry|nand|semiconductor) market\b[^.]{0,100}\brevenue\b|"
    r"\bmarket (?:revenue|revenues|sales)\b|\b(?:revenue|sales) (?:stream|opportunity|pool)\b|"
    r"\b(?:annualized )?(?:revenue|sales) run rate\b|"
    r"\b(?:capital expenditures?|capital spending|capex)\b[^.]{0,100}"
    r"\b\d+(?:\.\d+)?%\s+of\s+(?:total\s+)?revenue\b",
    re.I,
)
REVENUE_DELTA_RE = re.compile(
    r"\b(?:incremental|additional|acquisition-related)\s+(?:revenue|revenues|sales)\b|"
    r"\b(?:lose|lost|forgo|forego)\s+(?:revenue|revenues|sales)\b|"
    r"\b(?:revenue|revenues|sales)[ -](?:related )?(?:impact|headwind|benefit|contribution)s?\b|"
    r"\bcontribut(?:e|es|ed|ing)\b[^.]{0,100}\b(?:revenue|revenues|sales)\b|"
    r"\b(?:contribute|add|reduce|increase|decrease|impact)\b[^.]{0,90}"
    r"\b(?:revenue|revenues|sales)\b[^.]{0,40}\b(?:by|of|from)\b|"
    r"\b(?:impact|effect)s?\b[^.]{0,100}\b(?:on|to)\s+(?:reported\s+)?"
    r"(?:revenue|revenues|sales)\b|"
    r"\b(?:fx|foreign exchange|currency)\b.{0,120}?\b(?:impact|headwind|benefit)s?\b"
    r".{0,80}?\b(?:in|on|to)\s+(?:reported\s+)?(?:revenue|revenues|sales)\b",
    re.I,
)
REVENUE_ACRONYM_SUBSET_RE = re.compile(
    r"\b(?P<name>[A-Z]{2,8})\s+(?:revenue|revenues|sales)\b"
)
REVENUE_STRONG_TOTAL_RE = re.compile(
    r"\b(?:total company|company|consolidated)\s+(?:revenue|revenues|sales)\b",
    re.I,
)
REVENUE_WEAK_TOTAL_RE = re.compile(
    r"\b(?:total|net)\s+(?:revenue|revenues|sales)\b",
    re.I,
)
GUIDANCE_COMPANY_TOTAL_RE = re.compile(
    r"\b(?:total(?: company)?|consolidated|enterprise|aggregate company|company-wide)\b|"
    r"\bcompany\s+(?:adjusted\s+)?(?:operating income|operating profit|free cash flow|fcf)\b",
    re.I,
)


def nearest_subject_match(sentence: str, metric_position: int,
                          candidates: list[tuple[str, re.Pattern, int, bool]],
                          max_distance: int = 140) -> tuple[str, str] | None:
    """Return the closest subject marker for one metric occurrence.

    Transcript sentences often contain both a company-wide guide and a segment
    guide.  Whole-sentence precedence therefore mislabels one of them.  Direct
    phrases such as ``total revenue`` or ``data center revenue`` receive a small
    specificity advantage only after distance to the selected occurrence.
    """
    ranked = []
    for subject, pattern, specificity, require_overlap in candidates:
        for match in pattern.finditer(sentence):
            overlaps = match.start() <= metric_position < match.end()
            if require_overlap and not overlaps:
                continue
            if overlaps:
                distance = 0
            else:
                distance = min(
                    abs(metric_position - match.start()),
                    abs(metric_position - match.end()),
                )
            if distance <= max_distance:
                ranked.append((distance, specificity, subject, match.group(0)))
    if not ranked:
        return None
    _, _, subject, evidence = min(ranked, key=lambda item: (item[0], item[1]))
    return subject, evidence
GUIDANCE_SUBSET_RE = re.compile(
    r"\b(?:segment|division|business unit|business area)\b|"
    r"\b(?:our|the|reporting|business) segments\b|"
    r"\bfrom (?:our |the )?discontinued operations?\b",
    re.I,
)
GUIDANCE_NON_PERIODIC_RE = re.compile(
    r"\b(?:cumulative|aggregate(?! company))\b[^.]{0,80}\b(?:cash flow|fcf)\b|"
    r"\bfinancial capacity\b|\b(?:cost )?savings?\b|\bshare repurchases?\b|"
    r"\b(?:increase|decrease|improve|reduce|lower|impact|change|raise|raising|add)\b"
    r"[^.]{0,120}\b(?:operating income|operating profits?|free cash flow|fcf|ebit)\b"
    r"[^.]{0,35}\bby\b|"
    r"\b(?:operating income|operating profits?|free cash flow|fcf|ebit)\b"
    r"[^.]{0,80}\b(?:increase|decrease|improve|reduce|lower|impact|change|add)\b"
    r"[^.]{0,35}\bby\b|"
    r"\b(?:operating income|operating profits?) guarantees?\b|"
    r"\b(?:incremental|additional)\s+(?:operating income|operating profits?|free cash flow|fcf|ebit)\b|"
    r"\b(?:raise|raising|increase|decrease|reduce|add)\b[^.]{0,100}\bby\b"
    r"[^.]{0,100}\b(?:operating income|operating profits?|free cash flow|fcf|ebit)\b",
    re.I,
)
GUIDANCE_DRIVER_IMPACT_RE = re.compile(
    r"\b(?:impact|effect)s?\b[^.]{0,100}\b(?:on|to)\s+(?:reported\s+)?"
    r"(?:revenue|revenues|sales|ebit|ebitda|operating income|operating profits?|"
    r"free cash flow|fcf)\b(?:\s+and\s+(?:ebit|ebitda|operating income|"
    r"operating profits?|free cash flow|fcf))?",
    re.I,
)
GUIDANCE_LEVEL_REVISION_RE = re.compile(
    r"\b(?:increase|increasing|raise|raising|raised|decrease|decreasing|lower|"
    r"lowering|lowered)\b[^.;]{0,100}\b(?:revenue|revenues|sales|free cash flow|"
    r"fcf|operating income|operating profit|ebit|ebitda|capex|capital expenditures?)\b"
    r"[^.;]{0,80}\bby\b[^.;]{0,70}\bto\b",
    re.I,
)


def nearest_scope(sentence: str, positions: list[int]) -> tuple[str | None, str | None]:
    """Classify scope using the marker nearest the selected metric value.

    A sentence can contain both a full-year amount and a later quarterly amount.
    Whole-sentence scope detection therefore assigns the wrong horizon; the selected
    value position is the point of reference instead.
    """
    if not positions:
        return None, None
    target = sum(positions) / len(positions)
    candidates = []
    quarter_matches = [match for match in QUARTER_SCOPE_RE.finditer(sentence) if not (
        re.search(r"\b(?:performance in|record|as of)\s*$", sentence[max(0, match.start() - 50):match.start()], re.I)
        or re.match(r"\s+performance\b|\s+(?:20\d{2}\s+)?earnings\s+(?:presentation|on)\b", sentence[match.end():], re.I)
    )]
    for scope, pattern in (
        ("quarter", QUARTER_SCOPE_RE),
        ("full_year", ANNUAL_SCOPE_RE),
        ("multi_year_target", MULTI_YEAR_SCOPE_RE),
    ):
        for match in pattern.finditer(sentence):
            if scope == "quarter" and not any(match.span() == valid.span() for valid in quarter_matches):
                continue
            if scope == "full_year" and any(
                match.start() < quarter.end() and match.end() > quarter.start()
                for quarter in quarter_matches
            ):
                continue
            center = (match.start() + match.end()) / 2
            priority = {"quarter": 0, "full_year": 1, "multi_year_target": 2}[scope]
            candidates.append((abs(center - target), priority, scope, match.group(0)))
    if not candidates:
        return None, None
    distance, _, scope, evidence = min(candidates, key=lambda item: (item[0], item[1]))
    if distance > 220:
        # A stated paragraph heading governs later metrics until a new horizon
        # appears. Do not borrow an annual label across a quarter/long-term shift.
        heading = re.match(r"\s*(?:for\s+(?:the\s+)?)?(?:full[- ]year|fiscal(?: year)?|FY)\s*(?:20)?\d{2}(?:e)?\b", sentence, re.I)
        if heading and target <= 600 and not any(
            match.start() >= heading.end() and match.start() <= target
            for pattern in (QUARTER_SCOPE_RE, MULTI_YEAR_SCOPE_RE)
            for match in pattern.finditer(sentence)
        ):
            return "full_year", heading.group(0).strip()
        return None, None
    return scope, evidence


def revenue_guidance_subject(sentence: str, metric_position: int) -> tuple[str, str]:
    """Classify the specific revenue occurrence, not the full sentence."""
    start = max(0, metric_position - 140)
    end = min(len(sentence), metric_position + 90)
    local = sentence[start:end]
    owner = re.match(r"(?:revenues?|sales)\b", sentence[metric_position:], re.I)
    if owner:
        after_owner = sentence[metric_position + owner.end():]
        named_business = re.match(r"\s+(?:for|from)\s+(?:(?:the|our)\s+)?[A-Z][A-Za-z0-9-]*(?:\s+[A-Z][A-Za-z0-9-]*)?\s+business\b", after_owner)
        if named_business:
            return "segment_or_subset", owner.group(0) + named_business.group(0)
        component = re.search(r"\b(?:drag|headwind|tailwind|benefit|impact|contribution)\s+(?:on|to|in)\s*$", sentence[:metric_position], re.I)
        if component:
            return "non_company_or_non_periodic", component.group(0) + owner.group(0)
    driver_impact = nearest_subject_match(
        sentence,
        metric_position,
        [("non_company_or_non_periodic", GUIDANCE_DRIVER_IMPACT_RE, 0, True)],
    )
    if driver_impact:
        return driver_impact
    direct = nearest_subject_match(
        sentence,
        metric_position,
        [
            ("non_company_or_non_periodic", REVENUE_NON_COMPANY_RE, 0, True),
            ("segment_or_subset", REVENUE_SUBSET_RE, 0, True),
            ("non_company_or_non_periodic", REVENUE_DELTA_RE, 1, True),
            ("company_total", REVENUE_STRONG_TOTAL_RE, 0, True),
        ],
    )
    if direct:
        return direct
    nearby_segment = nearest_subject_match(
        sentence,
        metric_position,
        [("segment_or_subset", GUIDANCE_SUBSET_RE, 0, False)],
    )
    if nearby_segment:
        return nearby_segment
    weak_company_total = nearest_subject_match(
        sentence,
        metric_position,
        [("company_total", REVENUE_WEAK_TOTAL_RE, 0, True)],
    )
    if weak_company_total:
        return weak_company_total
    acronym_subset = REVENUE_ACRONYM_SUBSET_RE.search(local)
    if acronym_subset and acronym_subset.group("name") not in {"FY", "GAAP", "IFRS"}:
        return "segment_or_subset", acronym_subset.group(0)
    return "company_total_or_unspecified", local.strip()


def classify_guidance_subject(sentence: str, metric: str, metric_position: int) -> tuple[str, str]:
    if metric == "revenue_guidance":
        return revenue_guidance_subject(sentence, metric_position)
    if metric == "eps_guidance":
        component = eps_component_evidence(sentence, metric_position)
        if component:
            return "non_company_or_non_periodic", component
        owner = re.match(r"(?:eps|(?:earnings|net income) per (?:diluted )?share)", sentence[metric_position:], re.I)
        if owner and re.match(r"\s+(?:(?:headwinds?|benefits?|impacts?|contributions?|drags?)\b|(?:will\s+be\s+)?(?:negatively|positively)\s+impacted\s+by\b)", sentence[metric_position + owner.end():], re.I):
            return "non_company_or_non_periodic", sentence[metric_position:metric_position + owner.end() + 30]
    start = max(0, metric_position - 140)
    end = min(len(sentence), metric_position + 160)
    local = sentence[start:end]
    driver_impact = nearest_subject_match(
        sentence,
        metric_position,
        [("non_company_or_non_periodic", GUIDANCE_DRIVER_IMPACT_RE, 0, True)],
    )
    if driver_impact:
        return driver_impact
    level_revision = next(
        (
            match for match in GUIDANCE_LEVEL_REVISION_RE.finditer(sentence)
            if match.start() <= metric_position < match.end()
        ),
        None,
    )
    # A subsequent EPS share-repurchase assumption is not the economic owner
    # of the already quoted EPS target. Keep subject checks within its clause.
    clause_end = re.search(r"[.;](?=\s+[A-Z]|$)", sentence[metric_position:])
    subject_sentence = sentence[:metric_position + clause_end.start()] if clause_end else sentence
    non_periodic = GUIDANCE_NON_PERIODIC_RE.search(subject_sentence) if not level_revision else None
    if non_periodic:
        return "non_company_or_non_periodic", non_periodic.group(0)
    direct = nearest_subject_match(
        sentence,
        metric_position,
        [
            ("segment_or_subset", GUIDANCE_SUBSET_RE, 0, False),
            ("segment_or_subset", REVENUE_SUBSET_RE, 1, False),
            ("company_total", GUIDANCE_COMPANY_TOTAL_RE, 0, False),
        ],
    )
    if direct:
        return direct
    return "company_total_or_unspecified", local.strip()


def eps_component_evidence(sentence: str, metric_position: int) -> str | None:
    """Direct original EPS bridge ownership, not a blanket driver-word screen."""
    change = eps_change_or_target_evidence(sentence, metric_position)
    if change and change["kind"] == "change_only":
        return change["original_owned_quote"]
    owner = re.match(r"(?:eps|(?:earnings|net income) per (?:diluted )?share)", sentence[metric_position:], re.I)
    if not owner:
        return None
    after = sentence[metric_position + owner.end():]
    driver_after = re.match(r"\s+(?:(?:currency|fx|recycling|tariff)\s+)?(?:headwinds?|tailwinds?|benefits?|impacts?|contributions?|drags?|pickups?|dilution|accretion)\b", after, re.I)
    if driver_after:
        return sentence[metric_position:metric_position + owner.end() + driver_after.end()]
    before = sentence[max(0, metric_position - 220):metric_position]
    driver_before = re.search(
        r"\b(?:headwinds?|tailwinds?|impacts?|benefits?|contributions?|dilution|dilutive)\b"
        r"(?:\s+(?:of|on|to|in|our|the|about|approximately|roughly|favorable|unfavorable|"
        r"negative|positive|or|million|billion|full[- ]year|first|second|third|fourth|quarter|q[1-4]|fiscal|"
        r"20\d{2}|adjusted|non[- ]gaap|diluted|consolidated)|\s*\$-?\d+(?:\.\d+)?"
        r"(?:\s*[-–—]\s*\$?\d+(?:\.\d+)?)?)*\s*$", before, re.I,
    )
    return driver_before.group(0) + owner.group(0) if driver_before else None


def eps_change_or_target_evidence(sentence: str, metric_position: int) -> dict | None:
    """Resolve explicit EPS change grammar before treating a dollar as a level.

    This is a producer-only original syntax parser. A later EPS occurrence has
    its own identity and cannot supply the target for an earlier delta owner.
    Dash-only delta/target transcription remains unresolved, never guessed.
    """
    pattern = next(pattern for name, pattern in METRIC_PATTERNS if name == "eps_guidance")
    owner = pattern.match(sentence, metric_position)
    if not owner:
        return None
    next_owner = pattern.search(sentence, owner.end())
    end = next_owner.start() if next_owner else len(sentence)
    boundary = re.search(r"[.;](?=\s+[A-Z]|$)|[;\n]", sentence[owner.end():end])
    if boundary:
        end = owner.end() + boundary.start()
    values = [v for v in per_share_values(sentence) if owner.end() <= v["position"] < end]
    if not values:
        return None
    first = values[0]
    connector = sentence[owner.end():first["position"]]
    if not re.search(r"\bby\s*$|\b(?:is\s+)?(?:increased|decreased|reduced|raised|lowered)\s*$", connector, re.I):
        return None
    original = sentence[metric_position:end]
    # Current level follows an explicit 'to', possibly after an old-level
    # 'from' clause or a delta range. A dash alone supplies no target marker.
    for index, (left, right) in enumerate(zip(values, values[1:]), start=1):
        between = sentence[left.get("end", left["position"]):right["position"]]
        normalized = re.sub(rf"(?:{RANGE_CURRENCY_TOKEN})\s*$", "", between, flags=re.I)
        target_connector = re.fullmatch(
            r"\s*,?\s*(?:per\s+(?:diluted\s+)?share\s*,?\s*)?to\s+"
            r"(?:(?:a|the)\s+)?(?:(?:new|current)\s+)?"
            r"(?:(?:midpoint|range)\s+of\s+)?(?:between\s+)?(?:(?:greater|more)\s+than\s+)?", normalized, re.I,
        )
        if not target_connector:
            continue
        selected = [right]
        if index + 1 < len(values) and explicit_range_pair(right, values[index + 1], sentence):
            selected.append(values[index + 1])
        lower_bound = bool(re.search(r"\b(?:greater|more)\s+than\s*$", normalized, re.I))
        return {"kind": "current_target", "original_owned_quote": original, "selected_values": selected,
                "change_values": values[:index], "target_kind": "lower_bound" if lower_bound else "range" if len(selected) == 2 else "level"}
    dash_ambiguity = len(values) > 1 and explicit_range_pair(values[0], values[1], sentence) and (
        len(values) > 2 and explicit_range_pair(values[1], values[2], sentence) or
        abs(values[0]["value"]) < 1 <= abs(values[1]["value"])
    )
    return {"kind": "ambiguous_change_vs_target" if dash_ambiguity else "change_only",
            "original_owned_quote": original, "change_values": values,
            "reason": "dash_only_change_and_possible_target_requires_original_primary_source" if dash_ambiguity else "explicit_eps_change_not_absolute_level"}


def explicit_currency(token: str | None) -> str | None:
    token = re.sub(r"\s+", " ", token or "").strip().upper()
    if token in {"MXN", "MX$", "MEX$", "PS.", "MEXICAN PESO", "MEXICAN PESOS"}:
        return "MXN"
    if token in {"USD", "US$", "US DOLLAR", "US DOLLARS", "U.S. DOLLAR", "U.S. DOLLARS"}:
        return "USD"
    return {"£": "GBP", "GBP": "GBP", "€": "EUR", "EUR": "EUR"}.get(token)


def amount_currency(prefix: str | None, suffix: str | None, sentence: str) -> str | None:
    """A bare dollar sign is not an ISO currency, especially for peso issuers."""
    explicit = {value for token in (prefix, suffix) if (value := explicit_currency(token))}
    if len(explicit) > 1:
        return None
    if explicit:
        return next(iter(explicit))
    # Only a single explicit currency in this evidence sentence may disambiguate
    # an unmarked amount. Mixed currency commentary remains unresolved.
    contextual = {value for match in re.finditer(CURRENCY_TOKEN, sentence, re.I)
                  if (value := explicit_currency(match.group(0)))}
    return next(iter(contextual)) if len(contextual) == 1 else None


def amount_values(sentence: str):
    sentence = sentence.replace("Â±", " ±")
    values = []
    shared_range_spans = []
    # Parentheses are signed amounts, including both $(2.1B) and $(2.1)B.
    parenthesized = re.compile(
        rf"(?P<currency>{CURRENCY_TOKEN})?\s*\(\s*(?P<value>\d[\d,]*(?:\.\d+)?)\s*"
        r"(?:(?P<inside_scale>billion|million|thousand|bn|mm|mn|m|b)\s*\)|\)\s*(?P<outside_scale>billion|million|thousand|bn|mm|mn|m|b)\b)", re.I,
    )
    for match in parenthesized.finditer(sentence):
        scale = (match.group("inside_scale") or match.group("outside_scale")).lower()
        multiplier = 1000 if scale in {"billion", "bn", "b"} else 0.001 if scale == "thousand" else 1
        values.append({"value": -float(match.group("value").replace(",", "")) * multiplier,
                       "currency": amount_currency(match.group("currency"), None, sentence),
                       "currency_conflict": False, "text": match.group(0).strip(),
                       "position": match.start(), "end": match.end()})
        shared_range_spans.append(match.span())
    for match in SHARED_SCALE_RANGE_RE.finditer(sentence):
        left_number = float(match.group("left").replace(",", ""))
        if (
            not match.group("left_currency")
            and left_number.is_integer()
            and 1900 <= left_number <= 2100
        ):
            # ``fiscal year 2025 to $1.4 billion`` is a date followed by an
            # amount, not a 2025-to-1.4 monetary range with a shared scale.
            continue
        scale = match.group("scale").lower()
        multiplier = 1000.0 if scale in {"billion", "bn", "b"} else 1.0
        if scale == "thousand":
            multiplier = 0.001
        left_currency = amount_currency(match.group("left_currency"), match.group("currency_suffix"), sentence)
        right_currency = amount_currency(match.group("right_currency"), match.group("currency_suffix"), sentence)
        left_sign = -1 if (match.group("left_direction") or "").lower() in {"down", "negative", "minus"} else 1
        right_sign = -1 if (match.group("right_direction") or "").lower() in {"down", "negative", "minus"} else 1
        left_start = (
            match.start("left_direction")
            if match.group("left_direction")
            else match.start("left_currency") if match.group("left_currency") else match.start("left")
        )
        right_start = (
            match.start("right_direction")
            if match.group("right_direction")
            else match.start("right_currency") if match.group("right_currency") else match.start("right")
        )
        values.extend([
            {
                "value": left_sign * left_number * multiplier,
                "currency": left_currency,
                "currency_conflict": len({value for token in (match.group("left_currency"), match.group("currency_suffix")) if (value := explicit_currency(token))}) > 1,
                "text": sentence[left_start:match.end("left")].strip(),
                "position": left_start,
                "end": match.end("left"),
            },
            {
                "value": right_sign * float(match.group("right").replace(",", "")) * multiplier,
                "currency": right_currency,
                "currency_conflict": len({value for token in (match.group("right_currency"), match.group("currency_suffix")) if (value := explicit_currency(token))}) > 1,
                "text": sentence[right_start:match.end()].strip(),
                "position": right_start,
                "end": match.end(),
            },
        ])
        shared_range_spans.append((match.start(), match.end()))
    for match in AMOUNT_RE.finditer(sentence):
        if any(start <= match.start() and match.end() <= end for start, end in shared_range_spans):
            continue
        raw = float(match.group("value").replace(",", ""))
        scale = match.group("scale").lower()
        multiplier = 1000.0 if scale in {"billion", "bn", "b"} else 1.0
        if scale == "thousand":
            multiplier = 0.001
        currency = amount_currency(match.group("currency"), match.group("currency_suffix"), sentence)
        direction = sentence[max(0, match.start() - 18):match.start()]
        sign = -1 if re.search(r"\b(?:down|negative|minus)\s*$", direction, re.I) else 1
        values.append({
            "value": sign * raw * multiplier,
            "currency": currency,
            "currency_conflict": len({value for token in (match.group("currency"), match.group("currency_suffix")) if (value := explicit_currency(token))}) > 1,
            "text": match.group(0).strip(),
            "position": match.start(),
            "end": match.end(),
        })
    # Some transcripts spell out full-dollar figures instead of a scale word.
    # Require an explicit currency token and at least two valid comma groups;
    # this cannot interpret a fiscal year, share count, or unscaled EPS as a
    # company monetary amount. Preserve offsets into the original quotation.
    full_dollars = re.compile(
        rf"(?P<currency>{CURRENCY_TOKEN})\s*(?P<open>\()?\s*"
        r"(?P<value>\d{1,3}(?:\s*,\s*\d{3}){2,}(?:\.\d+)?)"
        r"(?P<close>\))?(?!\d|,\s*\d)", re.I,
    )
    for match in full_dollars.finditer(sentence):
        if any(value["position"] <= match.start() < value["end"] for value in values):
            continue
        if bool(match.group("open")) != bool(match.group("close")):
            continue
        if re.match(r"\s*(?:billion|million|thousand|bn|mm|mn|m|b)\b", sentence[match.end():], re.I):
            continue
        direction = sentence[max(0, match.start() - 18):match.start()]
        sign = -1 if match.group("open") or re.search(r"\b(?:down|negative|minus)\s*$", direction, re.I) else 1
        values.append({
            "value": sign * float(re.sub(r"[,\s]", "", match.group("value"))) / 1_000_000,
            "currency": amount_currency(match.group("currency"), None, sentence),
            "currency_conflict": False, "text": match.group(0),
            "position": match.start(), "end": match.end(),
        })
    # A spelled-out breakeven endpoint is literal zero, not a second absent
    # monetary amount. Only a direct range connector can borrow its unit.
    for value in list(values):
        suffix = sentence[value["end"]:]
        zero = re.match(r"\s+(?:to|through)\s+(?P<zero>break[- ]?even|zero)\b", suffix, re.I)
        if zero:
            values.append({"value": 0.0, "currency": value["currency"],
                           "currency_conflict": value["currency_conflict"],
                           "text": zero.group("zero"), "position": value["end"] + zero.start("zero"),
                           "end": value["end"] + zero.end("zero"), "literal_zero_endpoint": True})
    return sorted(values, key=lambda value: value["position"])


def per_share_values(sentence: str):
    """Unscaled currency-per-share observations, never total-income millions."""
    pattern = re.compile(
        rf"(?P<currency>{CURRENCY_TOKEN})?\s*(?P<open>\()?\s*(?P<value>\d+(?:\.\d+)?)\s*(?P<close>\))?", re.I,
    )
    cents = list(re.finditer(r"(?<![\w.])(?P<value>\d+(?:\.\d+)?)\s+cents?\s+per\s+share\b", sentence, re.I))
    values = [{"value": float(match.group("value")) / 100, "currency": None,
               "currency_conflict": False, "text": match.group(0),
               "position": match.start(), "end": match.end()} for match in cents]
    for match in pattern.finditer(sentence):
        if not match.group("currency") and "." not in match.group("value"):
            continue
        after = sentence[match.end():match.end() + 45]
        if re.match(r"\s*,\s*\d", after):
            continue  # Never parse the first group of a full-dollar amount as EPS.
        if re.match(r"\s*(?:%|billion|million|thousand|bn\b|mm\b|mn\b|[mb]\b|shares?\b)", after, re.I):
            continue
        if bool(match.group("open")) != bool(match.group("close")):
            continue
        raw = float(match.group("value"))
        values.append({"value": -raw if match.group("open") else raw,
                       "currency": amount_currency(match.group("currency"), None, sentence),
                       "currency_conflict": False, "text": match.group(0).strip(),
                       "position": match.start(), "end": match.end()})
    return values


def percentage_values(sentence: str):
    sentence = sentence.replace("Â±", " ±")
    negative_pairs = [match for match in re.finditer(r"\((?P<left>\d+(?:\.\d+)?)%?\)\s*(?:to|[-–—])\s*\((?P<right>\d+(?:\.\d+)?)%?\)\s*%?", sentence, re.I) if "%" in match.group(0)]
    ranges = []
    range_start = 0
    while pair := PERCENT_RANGE_RE.search(sentence, range_start):
        if not pair.group("left_pct") and 1900 <= float(pair.group("left")) <= 2100:
            # Reject the year without consuming the real range's first token:
            # 'FY2025 to 6.5%-7.5%' must still scan '6.5%-7.5%'.
            range_start = pair.start() + 1
            continue
        ranges.append(pair)
        range_start = pair.end()
    values = [
        {"value": float(match.group("value")), "position": match.start(), "end": match.end()}
        for match in PERCENT_RE.finditer(sentence)
        if not any(pair.start() <= match.start() and match.end() <= pair.end() for pair in ranges + negative_pairs)
    ]
    for pair in negative_pairs:
        values.extend([{"value": -float(pair.group(endpoint)), "position": pair.start(endpoint),
                        "end": pair.end(endpoint), "negative_percentage_range": pair.start()} for endpoint in ("left", "right")])
    for pair in ranges:
        values.extend([
            {"value": float(pair.group("left")), "position": pair.start("left"),
             "end": pair.end("left_pct") if pair.group("left_pct") else pair.end("left")},
            {"value": float(pair.group("right")), "position": pair.start("right"), "end": pair.end()},
        ])
    for value in values:
        before = sentence[max(0, value["position"] - 60):value["position"]]
        direction = re.search(r"\b(down|negative|minus|up|positive|plus)\s+(?:(?:approximately|about|roughly|around)\s+)?$", before, re.I)
        decline = re.search(r"\b(?:decline|decrease|reduction)\s+(?:in\s+)?(?:(?:the|a)\s+)?(?:range\s+(?:of\s+)?)?$", before, re.I)
        if direction and direction.group(1).lower() in {"down", "negative", "minus"} or decline:
            value["value"] = -abs(value["value"])
            value["shared_negative_direction"] = True
        if re.search(r"\(\s*$", before) and re.match(r"\s*\)", sentence[value["end"]:]) or re.search(r"-\s*$", before) and not any(pair.start("right") == value["position"] for pair in ranges):
            value["value"] = -abs(value["value"])
    ordered = sorted(values, key=lambda value: value["position"])
    for left, right in zip(ordered, ordered[1:]):
        if left.get("shared_negative_direction") and re.fullmatch(r"\s*(?:to|[-–—]|and)\s*", sentence[left["end"]:right["position"]], re.I):
            right["value"] = -abs(right["value"])
    return sorted(values, key=lambda value: value["position"])


def is_historical_actual_amount(value: dict, sentence: str) -> bool:
    """Return true when a quoted amount is an actual or comparison base.

    Calls often combine an actual and a forward guide in one sentence.  The
    sentence-level forward-language gate is therefore insufficient: each
    amount must be classified in its own local clause before metric binding.
    """
    position = int(value.get("position", 0))
    end = int(value.get("end", position))
    left = sentence[max(0, position - 180):position]
    if re.search(r"\b(?:provided|contributed|generated)\s+(?:an?\s+)?incremental\s*$", left, re.I):
        return True  # A delivered increment toward a target is not that target.
    right = sentence[end:min(len(sentence), end + 140)]
    if re.search(r"\bguidance\b[^.;]{0,90}\b(?:increased|raised|reduced|lowered)\s+to\b[^;]{0,60}$", left, re.I) and not re.search(r"\bprevious(?:ly)?\b", left.rsplit(" to ", 1)[-1], re.I):
        return False
    if HISTORICAL_AMOUNT_LEAD_RE.search(left) or HISTORICAL_ACRONYM_AMOUNT_LEAD_RE.search(left):
        return True
    if HISTORICAL_COMPARISON_LEAD_RE.search(left) and HISTORICAL_AMOUNT_TRAIL_RE.search(right):
        return True
    if HISTORICAL_COMPARISON_LEAD_RE.search(left) and re.search(
        r"\b(?:last|prior|previous)\s+(?:year|quarter|period)\b",
        right,
        re.I,
    ):
        return True
    if re.search(r"\bachieving\b[^.;]{0,100}$", left, re.I):
        local = sentence[max(0, position - 220):min(len(sentence), end + 120)]
        if not STRICT_FORWARD_VALUE_RE.search(local):
            return True
    return False


def non_guidance_owned_amount_positions(values: list[dict], sentence: str) -> set[int]:
    """Identify amounts owned by costs, savings, shares, or liquidity.

    The owner can precede an amount (``costs of $20 million``) or follow an
    explicit range (``$50-$60 million in underutilization costs``).  In the
    latter form both endpoints must be excluded from the company metric.
    """
    ordered = sorted(values, key=lambda value: value["position"])
    excluded: set[int] = set()
    for owner in NON_GUIDANCE_AMOUNT_OWNER_RE.finditer(sentence):
        prior = [value for value in ordered if value.get("end", value["position"]) <= owner.start()]
        if not prior:
            continue
        right = prior[-1]
        connector = sentence[right.get("end", right["position"]):owner.start()]
        if not re.fullmatch(
            r"\s*(?:(?:of|in|for|from|to)\s+(?:[A-Za-z-]+\s+){0,6}|"
            r"between(?:\s+(?:our|the))?|related to|associated with)?\s*",
            connector,
            re.I,
        ):
            continue
        excluded.add(int(right["position"]))
        if len(prior) < 2:
            continue
        left = prior[-2]
        # Only the literal connector between THESE two monetary values may
        # form a range. A later EPS range dash inside another clause cannot
        # turn revenue's endpoint and the following share count into one pair.
        explicit_range = explicit_range_pair(left, right, sentence)
        if explicit_range and owner.start() - left.get("end", left["position"]) <= 140:
            excluded.add(int(left["position"]))
    return excluded


def preceding_non_guidance_owner_positions(values: list[dict], sentence: str) -> list[int]:
    """Return owner markers that directly introduce a following amount.

    Merely mentioning an excluded expense is not enough.  For example, the
    amount in ``operating income, which excludes expense, to be $300m`` still
    belongs to operating income because the comma closes the expense phrase.
    """
    ordered = sorted(values, key=lambda value: value["position"])
    positions = []
    for owner in NON_GUIDANCE_AMOUNT_OWNER_RE.finditer(sentence):
        following = [value for value in ordered if value["position"] >= owner.end()]
        if not following:
            continue
        value = following[0]
        connector = sentence[owner.end():value["position"]]
        if len(connector) > 100 or re.search(r"[,.;]", connector):
            continue
        direct_quantity = re.fullmatch(
            r"\s*(?:(?:of|at|to|between|in(?: (?:a|the))? range(?: of)?|was|were|is|are|"
            r"will be|to be|to average|averaging|expected to be|projected to be|forecast to be)\s+)?"
            r"(?:(?:approximately|about|roughly|around|north of|over|under)\s+)?",
            connector,
            re.I,
        )
        dated_repurchase_total = (
            re.search(r"share repurchases?", owner.group(0), re.I)
            and re.search(r"\bto\s*$", connector, re.I)
        )
        if not direct_quantity and not dated_repurchase_total:
            continue
        positions.append(owner.start())
    return positions


def direct_following_metric_owner(value: dict, metric_positions: list[int],
                                  sentence: str) -> int | None:
    following = [position for position in metric_positions if position > value["position"]]
    if not following:
        return None
    nearest = min(following)
    connector = sentence[value.get("end", value["position"]):nearest]
    if len(connector) > 45:
        return None
    if not connector.strip():
        preceding = [position for position in metric_positions if position < value["position"]]
        if preceding and value["position"] - max(preceding) < 160 and not re.search(r";|\.(?=\s+[A-Z]|$)", sentence[max(preceding):value["position"]]):
            # A table's next metric is not the owner of the previous range.
            return None
    if re.fullmatch(
        r"\s*(?:(?:of|in|for|from|as)\s+)?(?:approximately\s+)?(?:(?:adjusted|GAAP|non-GAAP|underlying|organic|net)\s+)*",
        connector,
        re.I,
    ):
        return nearest
    return None


def percentage_or_per_share_comparison_prefix(sentence: str, position: int, value_kind: str) -> str:
    prefix = sentence[:position]
    if value_kind == "per_share":
        # Updating/maintaining a previously issued outlook is a current target,
        # not a comparison with the old numeric range. This only affects the
        # comparison detector; every original byte and numeric offset survives.
        prefix = re.sub(
            r"(\b(?:updated|updating|maintain|maintaining|reaffirm|reaffirming)\s+"
            r"(?:(?:our|the)\s+)?)previously\s+(?:issued|provided|disclosed)\b",
            r"\1current", prefix, flags=re.I,
        )
    return re.split(r"[,;]|\.(?=\s+[A-Za-z]|$)", prefix[-150:])[-1]


def values_owned_by_metric(values: list[dict], metric_position: int,
                           all_metrics: list[tuple[str, int]],
                           value_kind: str = "amount",
                           sentence: str = "") -> list[dict]:
    if value_kind == "amount":
        historical_positions = {
            int(value["position"])
            for value in values
            if is_historical_actual_amount(value, sentence)
        }
        non_guidance_positions = non_guidance_owned_amount_positions(values, sentence)
        values = [
            value for value in values
            if int(value["position"]) not in historical_positions | non_guidance_positions
        ]
        ineligible = {"gross_margin", "operating_margin", "eps_guidance"}
        eligible_metrics = sorted(
            ((name, position) for name, position in all_metrics if name not in ineligible),
            key=lambda item: item[1],
        )
    else:
        # A new range can precede the metric while the prior range follows it.
        # Exclude explicit comparison clauses before choosing the nearest pair.
        values = [value for value in values if not (
            re.search(r"\b(?:compared (?:with|to)|versus)\b(?!\s+(?:the\s+)?prior year\b)|\b(?:previous(?:ly)?|originally|prior\s+(?:guidance|range|outlook))\b",
                      percentage_or_per_share_comparison_prefix(sentence, value["position"], value_kind), re.I)
            or re.search(r"^\s*(?:previously|originally)\b|\b(?:previously|originally)\s+(?:provided|issued|expected|guided|forecast|projected|announced\s+(?:guidance|outlook|range))\b|\bprior\s+(?:guidance|range|outlook)\b",
                         re.split(r"[,;]|\.(?=\s+[A-Za-z]|$)", sentence[value.get("end", value["position"]):])[0], re.I)
        )]
        # Per-share tokens cannot participate in a parallel list with revenue
        # or company-income owners, whose scaled amounts are a different unit.
        eligible_metrics = sorted(
            (item for item in all_metrics if value_kind != "per_share" or item[0] == "eps_guidance"),
            key=lambda item: item[1],
        )
        if value_kind == "per_share":
            eligible_metrics = sorted([
                *eligible_metrics,
                *(("ffo_per_share", match.start()) for match in NON_EPS_PER_SHARE_OWNER_RE.finditer(sentence)),
            ], key=lambda item: item[1])
    eligible_positions = [position for _, position in eligible_metrics]
    owner_only_positions = (
        preceding_non_guidance_owner_positions(values, sentence)
        if value_kind == "amount"
        else [match.start() for match in re.finditer(r"\b(?:liquidity|tax(?:es)?|tax rate|interest expense|repurchas(?:e|es|ing)|share repurchases?|shares outstanding|dividends?|assuming|exchange rate)\b", sentence, re.I)]
    )
    if value_kind == "percentage":
        # Employee growth owns its percentage; it is not revenue growth even
        # when the two ranges share a sentence or annual-outlook heading.
        owner_only_positions.extend(match.start() for match in re.finditer(
            r"\b(?:(?:worksite\s+)?employees?|customers?|loans?|room nights?)\s+growth\b|"
            r"(?<!gross )(?<!operating )\bmargins?\b", sentence, re.I
        ))
    all_metric_positions = sorted(set(eligible_positions + owner_only_positions)) or sorted(
        position for _, position in all_metrics
    )
    ordered_values = sorted(values, key=lambda value: value["position"])
    first_value_position = ordered_values[0]["position"] if ordered_values else None
    leading_metrics = [
        (name, position)
        for name, position in eligible_metrics
        if first_value_position is not None and position < first_value_position
    ]
    leading_positions = [position for _, position in leading_metrics]
    simple_parallel_values = (
        len(ordered_values) >= 2
        and all(
            re.fullmatch(
                r"\s*,?\s*(?:and\s+)?",
                sentence[left.get("end", left["position"]):right["position"]],
                re.I,
            )
            for left, right in zip(ordered_values, ordered_values[1:])
        )
    )
    if (
        metric_position in leading_positions
        and len(ordered_values) == len(leading_positions)
        and len(leading_positions) >= 2
        and len({name for name, _ in leading_metrics}) == len(leading_metrics)
        and leading_positions
        and not any(explicit_range_pair(left, right, sentence) for left, right in zip(ordered_values, ordered_values[1:]))
        and (simple_parallel_values or re.search(r"\brespectively\b", sentence, re.I))
    ):
        if value_kind == "per_share" and any(name == "ffo_per_share" for name, _ in leading_metrics):
            # Equal units do not establish the order of different economic
            # metrics. Require the explicit ordinal immediately after the list.
            suffix = sentence[ordered_values[-1].get("end", ordered_values[-1]["position"]):]
            if not re.match(r"\s*,?\s*respectively\b", suffix, re.I):
                return []
        # A later clause can mention a driver such as ``sales conversion``.
        # It must not break the explicit ``EBITDA and operating income are X
        # and Y, respectively`` pairing established before the first value.
        return [ordered_values[leading_positions.index(metric_position)]]
    range_owner_overrides: dict[int, int] = {}
    for left, right in zip(ordered_values, ordered_values[1:]):
        if not explicit_range_pair(left, right, sentence):
            continue
        owner = direct_following_metric_owner(right, all_metric_positions, sentence)
        if owner is None:
            preceding = [
                position for position in all_metric_positions
                if position <= left["position"]
            ]
            owner = max(preceding) if preceding else None
        if owner is not None:
            range_owner_overrides[int(left["position"])] = owner
            range_owner_overrides[int(right["position"])] = owner
    owned = []
    for value in values:
        override = range_owner_overrides.get(int(value["position"]))
        if override is not None:
            if override == metric_position:
                owned.append(value)
            continue
        preceding = [position for position in all_metric_positions if position <= value["position"]]
        nearest_preceding = max(preceding) if preceding else None
        following_owner = direct_following_metric_owner(value, all_metric_positions, sentence)
        if following_owner is not None:
            nearest = following_owner
        elif nearest_preceding is not None and value["position"] - nearest_preceding <= 160:
            nearest = nearest_preceding
        else:
            nearest = min(all_metric_positions, key=lambda position: abs(position - value["position"]))
        if nearest == metric_position:
            if value_kind == "percentage" and abs(value["position"] - metric_position) > 180:
                continue  # A distant allocation/footer percentage is not this metric.
            owned.append(value)
    return sorted(owned, key=lambda value: value["position"])


def plus_minus_center(values: list[dict], sentence: str,
                      metric_position: int | None = None) -> dict | None:
    """Return the quoted center in ``center +/- tolerance`` disclosures.

    The tolerance is not a second endpoint. Averaging both numbers turns
    ``$1.5 billion +/- $50 million`` into $775 million, so the center must be
    selected before ordinary range averaging.
    """
    normalized_sentence = sentence.replace("Â±", " ±")
    candidates = []
    for marker in PLUS_MINUS_RE.finditer(normalized_sentence):
        preceding = [value for value in values if value["position"] < marker.start()]
        if not preceding:
            continue
        center = max(preceding, key=lambda value: value["position"])
        between = normalized_sentence[center.get("end", center["position"]):marker.start()]
        if re.fullmatch(r"[\s,;:()]*", between):
            candidates.append(center)
    if not candidates:
        return None
    if metric_position is None:
        return candidates[0]
    return min(candidates, key=lambda value: abs(value["position"] - metric_position))


def revision_target_value(values: list[dict], sentence: str,
                          metric_position: int) -> dict | None:
    """Select the new level in ``raise by X to Y`` disclosures."""
    ordered = sorted(values, key=lambda value: value["position"])
    candidates = []
    for left, right in zip(ordered, ordered[1:]):
        connector = sentence[left.get("end", left["position"]):right["position"]]
        connector = re.sub(
            rf"(?:{RANGE_CURRENCY_TOKEN})\s*$",
            "",
            connector,
            flags=re.I,
        )
        if not re.fullmatch(
            rf"\s*to\s+(?:{RANGE_QUALIFIER}\s+)?",
            connector,
            re.I,
        ):
            continue
        prefix = sentence[max(0, left["position"] - 180):left["position"]]
        if not re.search(
            r"\b(?:increase|increasing|raise|raising|raised|decrease|decreasing|"
            r"lower|lowering|lowered)\b[^.;]{0,140}\bby\s*$",
            prefix,
            re.I,
        ):
            continue
        candidates.append((left, right))
    if not candidates:
        return None
    _, target = min(
        candidates,
        key=lambda pair: abs(pair[0]["position"] - metric_position),
    )
    return target


RANGE_CURRENCY_TOKEN = rf"(?:{CURRENCY_TOKEN}|JPY|CNY|RMB|CAD|AUD|CHF)"
RANGE_QUALIFIER = r"(?:about|approximately|roughly|around|nearly)"


def explicit_range_pair(left: dict, right: dict, sentence: str) -> bool:
    """Return true only when adjacent values are explicit endpoints."""
    if left.get("negative_percentage_range") is not None and left.get("negative_percentage_range") == right.get("negative_percentage_range"):
        return True
    between = sentence[left.get("end", left["position"]):right["position"]]
    prefix = sentence[max(0, left["position"] - 120):left["position"]]
    normalized = re.sub(
        rf"(?:{RANGE_CURRENCY_TOKEN})\s*$",
        "",
        between,
        flags=re.I,
    )
    if re.fullmatch(
        r"\s*[-–—]\s*(?:(?:up|down|positive|negative|plus|minus)\s+)?",
        normalized,
        re.I,
    ):
        return True
    if re.fullmatch(
        r"\s*(?:to|through)\s*(?:(?:up|down|positive|negative|plus|minus)\s+)?",
        normalized,
        re.I,
    ):
        if not re.search(r"\bfrom\s*$", prefix, re.I):
            return True
        return bool(re.search(r"\b(?:range|ranging|guidance)\b[^.;]{0,60}\bfrom\s*$", prefix, re.I))
    if re.fullmatch(r"\s*(?:,?\s*and)\s*", normalized, re.I):
        introduced = re.search(
            rf"(?:\bbetween|\brange(?:d)?(?:\s+of)?)\s+"
            rf"(?:{RANGE_QUALIFIER}\s+)?(?:{RANGE_CURRENCY_TOKEN}\s*)?$",
            prefix,
            re.I,
        )
        if introduced:
            return True
    low_end = re.search(
        rf"\blow end\b[^.;]{{0,50}}\b(?:to|at|of)\s*"
        rf"(?:{RANGE_QUALIFIER}\s+)?(?:{RANGE_CURRENCY_TOKEN}\s*)?$",
        prefix,
        re.I,
    )
    high_end = re.fullmatch(
        r"\s*,?\s*(?:and\s+)?(?:(?:maintain|maintaining|keep|keeping|raise|raising|"
        r"lower|lowering|leave|leaving)\s+)?(?:the\s+|our\s+)?high end\b"
        r"[^.;]{0,35}\b(?:at|to|of)\s*",
        normalized,
        re.I,
    )
    return bool(low_end and high_end)


def explicit_range_values(values: list[dict], sentence: str,
                          metric_position: int) -> list[dict] | None:
    """Return two endpoints only when the text explicitly describes a range.

    Multiple monetary values joined by ``versus`` or ordinary prose are not a
    range and must never be averaged.  In those cases the value nearest the
    metric owns the guidance observation.
    """
    ordered = sorted(values, key=lambda value: value["position"])
    pairs = [
        (left, right)
        for left, right in zip(ordered, ordered[1:])
        if explicit_range_pair(left, right, sentence)
    ]
    if not pairs:
        return None
    return list(min(
        pairs,
        key=lambda pair: abs(
            ((pair[0]["position"] + pair[1]["position"]) / 2) - metric_position
        ),
    ))


def selected_guidance_values(values: list[dict], sentence: str,
                             metric_position: int) -> list[dict]:
    # "Increased the projection from X% to Y%" states a revision, not the
    # bounds of a new range. An actual range introducer ('range from') retains
    # the normal midpoint behavior below. Only percentage tokens qualify.
    for left, right in zip(sorted(values, key=lambda v: v["position"]), sorted(values, key=lambda v: v["position"])[1:]):
        if not sentence[left["position"]:left["end"]].endswith("%") or not sentence[right["position"]:right["end"]].endswith("%"):
            continue
        before = sentence[max(0, left["position"] - 170):left["position"]]
        if re.fullmatch(r"\s*to\s*", sentence[left["end"]:right["position"]], re.I) and re.search(
            r"\b(?:increase[ds]?|raising|raised|revised|lowered|decreased)\b[^.;]{0,140}\bfrom\s*$", before, re.I
        ) and not re.search(r"\brange\s+from\s*$", before, re.I):
            return [right]
    revised_level = revision_target_value(values, sentence, metric_position)
    if revised_level:
        following = sorted((value for value in values if value["position"] > revised_level["position"]), key=lambda value: value["position"])
        if following and explicit_range_pair(revised_level, following[0], sentence):
            # In 'raise by X to Y-Z', Y-Z is the revised target range; X is
            # only the revision delta. Preserve both target endpoints.
            return [revised_level, following[0]]
        return [revised_level]
    center = plus_minus_center(values, sentence, metric_position)
    if center:
        return [center]
    explicit_range = explicit_range_values(values, sentence, metric_position)
    if explicit_range:
        return explicit_range
    return [min(values, key=lambda value: abs(value["position"] - metric_position))]


def per_share_range_width_evidence(sentence: str, metric_position: int) -> dict | None:
    """A stated change in range width is not an EPS or FFO target level."""
    for match in PER_SHARE_RANGE_WIDTH_RE.finditer(sentence):
        if not match.start("owners") <= metric_position < match.end("owners"):
            continue
        owners = match.group("owners")
        affected = (["eps_guidance"] if any(name == "eps_guidance" for name, _ in metric_names(owners)) else [])
        if NON_EPS_PER_SHARE_OWNER_RE.search(owners):
            affected.append("ffo_per_share")
        if not affected:
            continue
        currencies = {currency for group in ("before_currency", "after_currency")
                      if (currency := amount_currency(match.group(group), None, sentence))}
        return {
            "metric_name": "guidance_range_width", "affected_metrics": affected,
            "amount": None, "per_share_value": None,
            "range_width_before": float(match.group("before")),
            "range_width_after": float(match.group("after")),
            "per_share_basis": "guidance_range_width",
            "unit": "currency_per_share_range_width",
            "currency": next(iter(currencies)) if len(currencies) == 1 else None,
            "currency_resolution": "conflicting_currency" if len(currencies) > 1 else "explicit_currency" if currencies else "source_currency_required",
            "quality_status": "research_only_guidance_range_width",
            "model_exclusion_reason": "guidance_range_width_not_level",
            "included_in_valuation_inputs": False,
            "evidence_excerpt": match.group(0),
        }
    return None


def ffo_per_share_research_evidence(sentence: str, all_metrics: list[tuple[str, int]]) -> list[dict]:
    """Retain separately owned FFO observations without creating a model route."""
    evidence = []
    for owner in NON_EPS_PER_SHARE_OWNER_RE.finditer(sentence):
        width = per_share_range_width_evidence(sentence, owner.start())
        if width:
            evidence.append(width)
            continue
        values = values_owned_by_metric(per_share_values(sentence), owner.start(), all_metrics, "per_share", sentence)
        if not values:
            continue
        selected = selected_guidance_values(values, sentence, owner.start())
        currencies = {value["currency"] for value in selected if value.get("currency")}
        currency = next(iter(currencies)) if len(currencies) == 1 else None
        first_value = min(value["position"] for value in selected)
        last_value = max(value["end"] for value in selected)
        qualifiers = sentence[max(0, owner.start() - 30):owner.start()] + " " + sentence[owner.end():first_value]
        scope, scope_evidence = nearest_scope(sentence, [owner.start(), *[value["position"] for value in selected]])
        evidence.append({
            "metric_name": "ffo_per_share", "amount": None,
            "per_share_value": sum(value["value"] for value in selected) / len(selected) if len(currencies) <= 1 else None,
            "per_share_basis": "adjusted_ffo" if re.search(r"\badjusted\b", qualifiers, re.I) else "ffo",
            "unit": "currency_per_share", "currency": currency,
            "currency_resolution": "conflicting_currency" if len(currencies) > 1 else "explicit_currency" if currency else "source_currency_required",
            "quality_status": "research_only_non_eps_per_share",
            "model_exclusion_reason": "non_eps_per_share_economic_basis",
            "included_in_valuation_inputs": False,
            "guidance_scope": scope, "guidance_scope_evidence": scope_evidence,
            "evidence_excerpt": sentence[min(owner.start(), first_value):max(owner.end(), last_value)],
            "selected_values": selected,
        })
    return evidence


def explicit_period_growth_values(values: list[dict], sentence: str) -> list[dict]:
    """Keep directly quoted sequential and annual growth, including direction.

    This only recognizes explicit labels beside a percentage; an unlabeled
    rate cannot inherit YoY just because another metric is called annual.
    """
    ordered = sorted(values, key=lambda value: value["position"])
    classified = {}
    for value in ordered:
        suffix = sentence[value["end"]:value["end"] + 80]
        match = re.match(r"\s*(?:(?P<before>increase|decrease|decline|growth|reduction)\s+)?(?P<basis>sequential(?:ly)?|year[- ]over[- ]year|quarter[- ]over[- ]quarter|yoy|qoq)(?:\s+(?P<after>increase|decrease|decline|growth|reduction))?\b", suffix, re.I)
        if not match:
            continue
        basis = "qoq" if re.match(r"sequential|quarter|qoq", match["basis"], re.I) else "yoy"
        negative = (match["before"] or match["after"] or "").lower() in {"decrease", "decline", "reduction"}
        classified[value["position"]] = {**value, "value": -abs(value["value"]) if negative else value["value"], "period_basis": basis}
    for left, right in zip(ordered, ordered[1:]):
        if right["position"] in classified and left["position"] not in classified and explicit_range_pair(left, right, sentence):
            label = classified[right["position"]]
            classified[left["position"]] = {**left, "period_basis": label["period_basis"],
                "value": -abs(left["value"]) if label["value"] < 0 else left["value"]}
    return [classified[key] for key in sorted(classified)]


def extract_event(ticker: str, period: str, observed_at: str, source_url: str,
                  file_path: Path, speaker: str, sentence: str, metric: str,
                  metric_position: int, all_metrics: list[tuple[str, int]]) -> dict:
    amounts = values_owned_by_metric(
        amount_values(sentence), metric_position, all_metrics, "amount", sentence
    )
    percentages = values_owned_by_metric(
        percentage_values(sentence), metric_position, all_metrics, "percentage", sentence
    )
    amount = None
    currency = None
    unit = None
    margin_pct = None
    growth_yoy = None
    growth_qoq = None
    per_share_value = None
    per_share_basis = None
    research_per_share_evidence = []
    eps_change = eps_change_or_target_evidence(sentence, metric_position) if metric == "eps_guidance" else None
    range_width_evidence = per_share_range_width_evidence(sentence, metric_position) if metric == "eps_guidance" else None
    value_text = sentence
    selected_values = []
    currency_conflict = False

    if metric == "eps_guidance":
        research_per_share_evidence = [range_width_evidence] if range_width_evidence else ffo_per_share_research_evidence(sentence, all_metrics)
        eps_values = [] if range_width_evidence else values_owned_by_metric(per_share_values(sentence), metric_position, all_metrics, "per_share", sentence)
        midpoint_reference = re.search(r"\band\s+(?:the\s+)?(?:midpoint of the\s+[^.;]{0,65}guidance range|[^.;]{0,65}guidance midpoint)\s+of\s+(?P<target>\$\d+(?:\.\d+)?)", sentence, re.I)
        if sentence.startswith("The difference between ") and midpoint_reference and sum(name == "eps_guidance" for name, _ in all_metrics) == 1:
            # The sole EPS occurrence is the historic comparator; the sentence
            # explicitly gives the new guidance midpoint without repeating EPS.
            eps_values = [value for value in per_share_values(sentence) if midpoint_reference.start("target") <= value["position"] <= midpoint_reference.end("target")]
        if eps_values:
            selected_values = eps_change["selected_values"] if eps_change and eps_change["kind"] == "current_target" else selected_guidance_values(eps_values, sentence, metric_position)
            currencies = {item["currency"] for item in selected_values if item["currency"]}
            currency_conflict = len(currencies) > 1
            per_share_value = None if currency_conflict else sum(item["value"] for item in selected_values) / len(selected_values)
            currency = next(iter(currencies)) if len(currencies) == 1 else None
            unit = "currency_per_share"
            basis_prefix = sentence[max(0, metric_position - 70):metric_position]
            per_share_basis = "adjusted" if re.search(r"\b(?:non[- ]gaap|(?<!split-)(?<!split )adjusted)\b[^.;]{0,55}$", basis_prefix, re.I) else "gaap" if re.search(r"\bgaap\b[^.;]{0,55}$", basis_prefix, re.I) else "unspecified"

    if amounts and metric not in {"gross_margin", "operating_margin", "eps_guidance"}:
        selected_amounts = selected_guidance_values(amounts, sentence, metric_position)
        selected_values = selected_amounts
        currencies = {item["currency"] for item in selected_amounts if item["currency"]}
        currency_conflict = len(currencies) > 1 or any(item.get("currency_conflict") for item in selected_amounts)
        # Never average unlike currencies into one apparently usable scalar.
        amount = None if currency_conflict else sum(item["value"] for item in selected_amounts) / len(selected_amounts)
        currency = next(iter(currencies)) if len(currencies) == 1 else None
        unit = f"{currency or 'reported'} millions"
    if metric in {"gross_margin", "operating_margin"} and percentages:
        selected_percentages = selected_guidance_values(percentages, sentence, metric_position)
        selected_values = selected_percentages
        margin_pct = sum(item["value"] for item in selected_percentages) / len(selected_percentages)
    if metric == "revenue_guidance" and percentages and re.search(
        r"grow|growth|increase|decrease|decline|\b(?:up|down)\b", sentence, re.I
    ):
        percentages = [value for value in percentages if not re.match(
            r"\s*(?:conversion\s+of|of\s+(?:total\s+)?revenue|of\s+(?:the\s+)?(?:revenue|sales)\s+mix)", sentence[value.get("end", value["position"]):], re.I
        )]
        selected_percentages = selected_guidance_values(percentages, sentence, metric_position) if percentages else []
        if not selected_values:
            selected_values = selected_percentages
        growth_yoy = sum(item["value"] for item in selected_percentages) / len(selected_percentages) if selected_percentages else None
        based = explicit_period_growth_values(percentages, sentence)
        if based:
            by_basis = {basis: [item for item in based if item["period_basis"] == basis] for basis in ["yoy", "qoq"]}
            selected_by_basis = {basis: selected_guidance_values(items, sentence, metric_position) if items else [] for basis, items in by_basis.items()}
            growth_yoy = sum(item["value"] for item in selected_by_basis["yoy"]) / len(selected_by_basis["yoy"]) if selected_by_basis["yoy"] else None
            growth_qoq = sum(item["value"] for item in selected_by_basis["qoq"]) / len(selected_by_basis["qoq"]) if selected_by_basis["qoq"] else None

    scope_positions = [metric_position] + [item["position"] for item in selected_values]
    guidance_scope, guidance_scope_evidence = nearest_scope(sentence, scope_positions)
    target_year = None
    if guidance_scope == "full_year":
        target_matches = list(re.finditer(
            r"\b(?P<expected_year>20\d{2})\s+(?:total |net |adjusted )?(?:revenue|sales)\s+expected\b|"
            r"\b(?P<heading_year>20\d{2})\s+(?:(?:adjusted|net|total|revenue|sales|operating|income|ebitda)\s+){0,5}(?:guidance|outlook)\b|"
            r"\b(?:full[- ]year(?: of)?|fiscal(?: year)?|guidance for|outlook for|for(?: fiscal)?)\s*(?P<year>20\d{2})\b|"
            r"\bFY\s*['’]?(?P<fy_year>(?:20)?\d{2})(?:\s*e)?\b(?!\s*A\b)|"
            r"\bfiscal\s+(?P<short_fiscal_year>\d{2})\b|"
            r"\b(?:for\s+)?the year ending\s+[A-Za-z]+\s+\d{1,2},?\s+(?P<ending_year>20\d{2})\b",
            sentence, re.I,
        ))
        target_matches = [match for match in target_matches if not re.search(
            r"\b(?:compared (?:with|to)|versus|over|against|relative to)\s*$", sentence[max(0, match.start() - 35):match.start()], re.I
        )]
        if target_matches:
            target_match = min(target_matches, key=lambda match: min(abs(match.start() - position) for position in scope_positions))
            target_year = int(target_match.group("expected_year") or target_match.group("heading_year") or target_match.group("year") or target_match.group("fy_year") or target_match.group("short_fiscal_year") or target_match.group("ending_year"))
            if target_year < 100:
                target_year += 2000
    elif guidance_scope == "quarter" and guidance_scope_evidence:
        quarter_year = re.search(r"\b20\d{2}\b|\b(?:fy|fiscal(?: year)?)\s*(\d{2})\b", guidance_scope_evidence, re.I)
        if quarter_year:
            target_year = int(quarter_year.group(1)) + 2000 if quarter_year.group(1) else int(quarter_year.group(0))
    guidance_subject, guidance_subject_evidence = classify_guidance_subject(
        sentence, metric, metric_position
    )
    if guidance_scope == "multi_year_target":
        guidance_subject = "non_company_or_non_periodic"
        guidance_subject_evidence = guidance_scope_evidence
    if range_width_evidence:
        guidance_subject = "non_company_or_non_periodic"
        guidance_subject_evidence = range_width_evidence["evidence_excerpt"]
    eps_component = eps_component_evidence(sentence, metric_position) if metric == "eps_guidance" else None
    if eps_component:
        # Preserve the exact component quotation but do not expose a component
        # or neighboring component as an absolute EPS level for consumption.
        per_share_value = None
        selected_values = []
        research_per_share_evidence.append({"metric_name": "eps_component", "evidence_excerpt": eps_component,
            "full_original_quote": sentence, "included_in_valuation_inputs": False,
            "model_exclusion_reason": "eps_component_not_absolute_earnings_level"})

    explicit = bool(re.search(r"\bguidance\b|\boutlook\b|we (?:expect|anticipate|forecast|project)", sentence, re.I))
    eps_change_ambiguous = bool(eps_change and eps_change["kind"] == "ambiguous_change_vs_target")
    if eps_change_ambiguous:
        per_share_value = None
        selected_values = []
        research_per_share_evidence.append({"metric_name": "unresolved_eps_change_vs_target", "evidence_excerpt": eps_change["original_owned_quote"],
            "full_original_quote": sentence, "included_in_valuation_inputs": False,
            "model_exclusion_reason": eps_change["reason"]})
    confidence = 0.94 if explicit and (amounts or percentages) else 0.84 if amounts or percentages else 0.72
    historical_comparison = bool(HISTORICAL_RESULTS_COMPARISON_RE.search(sentence)) and not bool(
        re.search(r"\b(?:we|the company)\s+(?:now\s+)?(?:expect|forecast|anticipate)|\b(?:updated|revised|new)\s+(?:guidance|outlook)\b", sentence, re.I)
    )
    preliminary_actual = bool(re.search(r"\bpreliminary\b[^.;]{0,160}\b(?:financial results|expected results|unaudited)\b|\bpreliminarily estimates\b", sentence, re.I))
    before_metric = sentence[max(0, metric_position - 100):metric_position]
    directly_historical = bool(re.search(r"\b(?:delivered|recorded|achieved|generated)\s+(?:an?\s+)?(?:(?:record|adjusted|strong|net|total)\s+)?$", before_metric, re.I)) or bool(re.search(
        r"\b(?:we|they|it|the company|the group|has|have|had)\s+reported\s+(?:(?:adjusted|net|total)\s+)?$", before_metric, re.I
    ))
    # Present-participle realised performance is not a target; a genuine
    # forward 'expect to be delivering' remains guidance.
    delivering_actual = bool(re.search(r"\bdelivering\s+(?:an?\s+)?$", sentence[max(0, metric_position - 70):metric_position], re.I)) and not bool(re.search(
        r"\b(?:expect(?:s)?|will|anticipate(?:s)?|forecast(?:s)?)\b", re.split(r"[.;](?=\s+[A-Z]|$)", sentence[:metric_position])[-1], re.I
    ))
    directly_historical = directly_historical or delivering_actual
    if re.search(r"\b(?:delivered|reported|recorded|generated|achieved)(?:\s+(?:fiscal|q[1-4]|20\d{2}|first|second|third|fourth|quarter|full[- ]year))+\s+(?:(?:net|total|adjusted)\s+)?$", before_metric, re.I):
        directly_historical = True
    if re.search(r"\b(?:achieved|delivered)\s+(?:another\s+|a\s+)?(?:quarter|year)\s+of\s+(?:record\s+)?$", before_metric, re.I):
        directly_historical = True
    owned_name = next((pattern.match(sentence, metric_position) for name, pattern in METRIC_PATTERNS if name == metric and pattern.match(sentence, metric_position)), None)
    # A retrospective 'better-than-expected' in another sentence is not a
    # forecast. Bind realised performance to this metric, not the paragraph's
    # incidental expectation wording. Infinitive 'to exceed' stays forward.
    if owned_name and re.match(r"\s+(?:(?:has|have|had)\s+)?(?:grew|rose|was|were|increased|decreased|declined|exceeded)\b", sentence[owned_name.end():], re.I):
        directly_historical = True
    clause_before = re.split(r"[.;](?=\s+[A-Z]|$)", sentence[:metric_position])[-1]
    direct_current = bool(re.search(r"\b(?:expect(?:s)?|forecast(?:s)?|anticipat(?:e|es)|will|target(?:s)?)\b", clause_before, re.I))
    if not direct_current and re.search(r"\b(?:the company|we)\s+closed\s+the\s+(?:(?:first|second|third|fourth)\s+quarter|q[1-4])\s+with\s+(?:record\s+)?$", clause_before, re.I):
        directly_historical = True
    if not direct_current and metric in {"revenue_guidance", "free_cash_flow_guidance", "operating_income_guidance"}:
        clause = re.split(r"[.;](?=\s+[A-Z]|$)", clause_before + sentence[metric_position:])[0]
        if re.search(r"\b(?:exceeded|exceeding|met|within|in line with)\b[^.;]{0,110}\b(?:guidance|target|expectations?)\b", clause, re.I):
            directly_historical = True
    if metric == "eps_guidance" and owned_name and re.match(r"\s+of\s+\$[\d.]+\s*,?\s*(?:grew|represents?|representing)\b", sentence[owned_name.end():], re.I) and not re.search(r"\b(?:expect|anticipate|forecast|will)\b", before_metric, re.I):
        directly_historical = True
    historical_table = bool(re.search(r"^Income Statement\s*-\s*20\d{2}[^.]{0,100}\bQTD\b", sentence, re.I)) or bool(
        re.search(r"historical adjusted EPS growth achieved[^.]{0,240}historical adjusted EPS guidance", sentence, re.I)
        and re.search(r"\bActual Adjusted EPS\b.*\bBase EPS for 5-year", sentence, re.I)
    )
    question_only = sentence.rstrip().endswith("?") and bool(re.search(r"\b(?:should we|can you|could you|would you|do you|are you)\b", sentence, re.I))
    historical_comparison = historical_comparison or preliminary_actual or directly_historical or historical_table
    ambiguous_bridge = metric == "ebitda_guidance" and bool(re.search(r"\badjusted EBITDA\s+(?:Key Driver )?Bridge\b.{0,100}\bExchange\b", sentence, re.I))
    if ambiguous_bridge:
        # A flattened bridge/chart must not borrow exchange premiums as EBITDA.
        # Require the complete labelled table before publishing a scalar.
        amount = None
        selected_values = []
    qualitative_range = bool(selected_values) and metric == "revenue_guidance" and bool(re.match(
        r"\s*to\s+(?:up|down)\s+(?:slightly|modestly)\b", sentence[max(item.get("end", item["position"]) for item in selected_values):], re.I
    ))
    if qualitative_range:
        growth_yoy = None
        selected_values = []
    digest = hashlib.sha256(
        f"{ticker}|{period}|{observed_at}|{speaker}|{metric}|{metric_position}|{sentence}".encode()
    ).hexdigest()[:24]
    return {
        "id": digest,
        "ticker": ticker,
        "fiscal_period": period,
        "observed_at": observed_at,
        "metric_name": metric,
        "actual_or_guidance": "question" if question_only else "actual" if historical_comparison else "guidance",
        "amount": amount,
        "per_share_value": per_share_value,
        "per_share_basis": per_share_basis,
        "extraction_review_required": "eps_change_target_original_source_required" if eps_change_ambiguous else "table-layout-owner-context-required" if ambiguous_bridge else None,
        "model_exclusion_reason": "eps_change_target_original_source_required" if eps_change_ambiguous else "eps_component_not_absolute_earnings_level" if eps_component else "guidance_range_width_not_level" if range_width_evidence else "qualitative_range_endpoint_unquantified" if qualitative_range else None,
        "unit": unit,
        "currency": currency,
        "growth_yoy": growth_yoy,
        "growth_qoq": growth_qoq,
        "margin_pct": margin_pct,
        "value_text": value_text,
        "quality_status": "research_only_unresolved_eps_change_target" if eps_change_ambiguous else "research_only_eps_component" if eps_component else "research_only_guidance_range_width" if range_width_evidence else "historical_actual" if historical_comparison else "research_only_qualitative_range" if qualitative_range else "currency_conflict" if currency_conflict else "clear" if selected_values else "ambiguous",
        "currency_resolution": {
            "status": "conflicting_currency" if currency_conflict else "explicit_currency" if currency else "source_currency_required" if amount is not None or per_share_value is not None else "not_monetary",
            "selected_currencies": sorted({item["currency"] for item in selected_values if item.get("currency")}),
            "policy": "Bare $ never establishes USD; unknown monetary currency requires issuer reporting-currency evidence before model use.",
        },
        "extraction_confidence": confidence,
        "speaker": speaker,
        "source_url": source_url,
        "evidence_excerpt": sentence,
        "source_file": str(file_path),
        "source_type": "downloaded_online_earnings_transcript",
        "extraction_version": EXTRACTION_VERSION,
        "guidance_scope": guidance_scope,
        "guidance_target_year": target_year,
        "guidance_scope_evidence": guidance_scope_evidence,
        "guidance_subject": guidance_subject,
        "guidance_subject_evidence": guidance_subject_evidence,
        "metric_position": metric_position,
        "selected_values": selected_values,
        **({"research_per_share_evidence": research_per_share_evidence} if research_per_share_evidence else {}),
        **({"eps_change_evidence": eps_change} if eps_change else {}),
    }


def deduplicate_sentence_events(events: list[dict]) -> list[dict]:
    """Remove repeated metric words without weighting the model by word count."""
    metrics_with_values = {
        event.get("metric_name")
        for event in events
        if any(event.get(field) is not None for field in ("amount", "per_share_value", "growth_yoy", "margin_pct"))
    }
    unique = []
    seen = set()
    for event in events:
        if (
            event.get("metric_name") in metrics_with_values
            and all(event.get(field) is None for field in ("amount", "per_share_value", "growth_yoy", "margin_pct"))
            and not event.get("eps_change_evidence")
        ):
            continue
        key = (
            event.get("metric_name"),
            event.get("amount"),
            event.get("per_share_value"),
            event.get("per_share_basis"),
            event.get("currency"),
            event.get("growth_yoy"),
            event.get("margin_pct"),
            event.get("guidance_scope"),
            event.get("guidance_subject"),
            event.get("metric_position") if event.get("eps_change_evidence") else None,
        )
        if key in seen:
            continue
        seen.add(key)
        unique.append(event)
    return unique


def extract_file(ticker: str, file_path: Path, as_of_cutoff: str | None = None) -> tuple[str | None, list[dict]]:
    text = file_path.read_text(encoding="utf-8", errors="replace")
    period, observed_at, source_url = parse_header(text)
    if not period or not observed_at or not source_url:
        return period, []
    try:
        dt.date.fromisoformat(observed_at)
    except ValueError:
        return period, []
    if as_of_cutoff is not None and observed_at > as_of_cutoff:
        # A later file is not evidence of coverage at the source cutoff.
        # Preserve its real observation date on disk; never backdate it.
        return None, []
    events = []
    for speaker, section in speaker_sections(text):
        for sentence in sentences(section):
            if DISCLAIMER.search(sentence) or HISTORICAL_GUIDANCE.search(sentence):
                continue
            if not FORWARD_LANGUAGE.search(sentence):
                continue
            metrics = metric_names(sentence)
            if not metrics:
                continue
            sentence_events = []
            for metric, position in metrics:
                sentence_events.append(
                    extract_event(
                        ticker, period, observed_at, source_url, file_path, speaker,
                        sentence, metric, position, metrics
                    )
                )
            events.extend(deduplicate_sentence_events(sentence_events))
    return period, events


def ensure_schema(connection: sqlite3.Connection):
    connection.executescript(
        """
        CREATE TABLE IF NOT EXISTS pit_guidance_events (
          id TEXT PRIMARY KEY,
          ticker TEXT NOT NULL,
          fiscal_period TEXT NOT NULL,
          observed_at TEXT NOT NULL,
          metric_name TEXT NOT NULL,
          actual_or_guidance TEXT NOT NULL,
          amount REAL,
          unit TEXT,
          currency TEXT,
          growth_yoy REAL,
          growth_qoq REAL,
          margin_pct REAL,
          value_text TEXT,
          quality_status TEXT NOT NULL,
          extraction_confidence REAL NOT NULL,
          speaker TEXT,
          source_url TEXT NOT NULL,
          evidence_excerpt TEXT NOT NULL,
          source_file TEXT NOT NULL,
          source_type TEXT NOT NULL,
          extraction_version TEXT NOT NULL,
          payload_json TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_pit_guidance_events_ticker_period
          ON pit_guidance_events (ticker, fiscal_period, observed_at);
        CREATE TABLE IF NOT EXISTS pit_guidance_coverage (
          ticker TEXT PRIMARY KEY,
          transcript_files INTEGER NOT NULL,
          transcript_periods INTEGER NOT NULL,
          guidance_periods INTEGER NOT NULL,
          guidance_events INTEGER NOT NULL,
          status TEXT NOT NULL,
          note TEXT
        );
        """
    )


GUIDANCE_EVENT_COLUMNS = (
    "id", "ticker", "fiscal_period", "observed_at", "metric_name",
    "actual_or_guidance", "amount", "unit", "currency", "growth_yoy",
    "growth_qoq", "margin_pct", "value_text", "quality_status",
    "extraction_confidence", "speaker", "source_url", "evidence_excerpt",
    "source_file", "source_type", "extraction_version",
)


def persist_unique_transcript_event(connection: sqlite3.Connection, event: dict) -> bool:
    """Insert once; only an identical complete event is an idempotent repeat.

    Compare both typed columns and the complete payload so a scalar, provenance,
    parser-only field or cross-source collision cannot be silently overwritten.
    The caller owns the transaction; a conflict must roll back the whole import.
    """
    if event.get("source_type") != "downloaded_online_earnings_transcript":
        raise ValueError("Transcript writer cannot persist another guidance source type")
    columns = ",".join(GUIDANCE_EVENT_COLUMNS)
    values = tuple(event[column] for column in GUIDANCE_EVENT_COLUMNS)
    payload = json.dumps(event, separators=(",", ":"), sort_keys=True, allow_nan=False)
    existing = connection.execute(
        f"SELECT {columns},payload_json FROM pit_guidance_events WHERE id=?", (event["id"],)
    ).fetchone()
    if existing is not None:
        try:
            prior_payload = json.dumps(json.loads(existing[-1]), separators=(",", ":"), sort_keys=True, allow_nan=False)
        except (TypeError, ValueError):
            prior_payload = None
        if tuple(existing[:-1]) != values or prior_payload != payload:
            raise ValueError(f"Conflicting guidance event ID {event['id']}; refusing payload or source overwrite")
        return False
    placeholders = ",".join("?" for _ in range(len(values) + 1))
    connection.execute(
        f"INSERT INTO pit_guidance_events ({columns},payload_json) VALUES ({placeholders})",
        (*values, payload),
    )
    return True


def main():
    args = parse_args()
    targets = target_tickers(args.target_db, args.source_db)
    args.source_db.parent.mkdir(parents=True, exist_ok=True)
    with sqlite3.connect(args.source_db) as connection:
        cutoff = resolve_as_of_cutoff(connection, getattr(args, "as_of_cutoff", None),
                                     getattr(args, "allow_undated_legacy_source", False))
        ensure_schema(connection)
        connection.execute(
            "DELETE FROM pit_guidance_events "
            "WHERE source_type='downloaded_online_earnings_transcript'"
        )
        connection.execute("DELETE FROM pit_guidance_coverage")
        total_events = 0
        extracted_occurrences = 0
        covered_periods = set()
        for ui_ticker, source_ticker in targets:
            directory = args.transcript_root / source_ticker
            files = sorted(directory.glob("*.txt")) if directory.exists() else []
            all_periods = set()
            event_periods = set()
            ticker_events = 0
            eligible_files = 0
            for file_path in files:
                period, events = extract_file(ui_ticker, file_path, as_of_cutoff=cutoff)
                if period:
                    eligible_files += 1
                    all_periods.add(period)
                for event in events:
                    if cutoff and event["observed_at"] > cutoff:
                        raise ValueError("Extractor returned guidance after source as_of_cutoff")
                    extracted_occurrences += 1
                    if not persist_unique_transcript_event(connection, event):
                        continue
                    event_periods.add(event["fiscal_period"])
                    covered_periods.add((ui_ticker, event["fiscal_period"]))
                    ticker_events += 1
                    total_events += 1
            if not eligible_files:
                status, note = "missing_transcripts", "No valid downloaded transcript available by the source cutoff."
            elif not ticker_events:
                status, note = "no_explicit_guidance", "Transcripts present; no forward management guidance passed conservative rules."
            else:
                status, note = "covered", "Management-only, event-dated transcript guidance."
            connection.execute(
                "INSERT INTO pit_guidance_coverage VALUES (?,?,?,?,?,?,?)",
                (ui_ticker, eligible_files, len(all_periods), len(event_periods), ticker_events, status, note),
            )
        connection.execute(
            "INSERT OR REPLACE INTO pit_source_metadata (key, value) VALUES (?, ?)",
            ("guidance_extraction_version", EXTRACTION_VERSION),
        )
        connection.execute(
            "INSERT OR REPLACE INTO pit_source_metadata (key, value) VALUES (?, ?)",
            ("guidance_extracted_at", dt.datetime.now(dt.timezone.utc).isoformat()),
        )
        connection.execute(
            "INSERT OR REPLACE INTO pit_source_metadata (key, value) VALUES (?, ?)",
            ("guidance_as_of_cutoff", cutoff or "undated_legacy_not_release_ready"),
        )
        connection.commit()
        statuses = dict(connection.execute(
            "SELECT status, COUNT(*) FROM pit_guidance_coverage GROUP BY status"
        ))
    print(json.dumps({
        "tickers": len(targets),
        "events": total_events,
        "extractedOccurrences": extracted_occurrences,
        "duplicateOccurrences": extracted_occurrences - total_events,
        "tickerPeriods": len(covered_periods),
        "coverage": statuses,
        "sourceDatabase": str(args.source_db),
        "extractionVersion": EXTRACTION_VERSION,
        "asOfCutoff": cutoff,
        "undatedLegacyNotReleaseReady": cutoff is None,
    }, indent=2))


if __name__ == "__main__":
    main()
