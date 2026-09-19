# Discover: adjustable long-term growth quality

Implemented locally, 2026-09-10. No production deployment or valuation-model
replacement. This is an explicit research screen, not a buy recommendation.

## What the user controls

- Quarterly revenue YoY minimum (default 15%).
- Quality on/off; presets: Growth only, Durable ROIC, Cash-backed.
- Latest 3, 5 or 10 complete fiscal years; ROIC threshold (default 15%);
  required number of passing years (default every year, 5/5).
- Optional minimum FCF margin, CFO/net-income conversion and operating margin.
  Each enabled additional factor must pass in **every** selected year.
- Cash-backed preset: 5/5 years ROIC >=15%, FCF margin >=5% in all five years,
  and CFO/positive net income >=80% in all five years.
- Numeric edits apply on Enter or blur; invalid edits remain visibly invalid
  drafts and do not change the applied screen. Decimal thresholds are retained.
- Rules persist in the URL across navigation/reload; they do not update platform
  valuation assumptions, create private investment decisions, or write accounts.

Default ranking is highest **worst-year ROIC**, not the largest latest revenue
jump. Users can still change sorting. Company rows show passing years; the detail
panel exposes annual figures and availability dates, average and minimum ROIC.
Quarterly financial evidence and the existing personal-valuation workflow remain.

## Jansen references and controlling source

Inspected `jansen_us_firm_replication/modern_us/factor_definitions.py`, the
Sharadar pipeline, schemas of `modern_historical_quality_panel.parquet`, current
raw SF1 parquet observations, and vendor `raw/indicators.csv.zip` definitions.
The historical panel contains `hist_roic_avg_60`, `hist_roic_worst_60`,
`hist_roic_stability_60`, `hist_roic_positive_share_60` and ROIC durability/quality
composites. Its build implementation was not found in the inspected source.
Its composite ranks are **not** represented as five annual observations or as
verified after-tax ROIC. The older factor-definition composite combines several
profitability proxies and is marked approximate in that project.

The new screen borrows the durability/multiple-factor approach, not an opaque
rank. It calculates persistence from original paid as-reported annual evidence.

**Provider ROIC is pre-tax EBIT / average invested capital**, not NOPAT ROIC.
Vendor invested capital = debt + assets - intangibles - cash - current liabilities.
Nonpositive/missing capital and provider-ratio reconciliation failures produce
null ROIC, never a passing zero. Provider ratios are stored as fractions, not
whole percentages. The UI explicitly labels the pre-tax basis and notes that
small capital bases and excluded intangibles can inflate returns.

FCF margin = (CFO + signed cash-flow capex) / positive revenue. Cash conversion =
CFO / positive consolidated net income; losses do not create a meaningful positive
conversion ratio. Operating margin = operating income / positive revenue.
These cash flows are not labeled verified parent FCFE. Average ROIC is the
arithmetic mean of equal-weight annual observations, not pooled EBIT/capital.

## Storage, PIT and coverage

`scripts/import-investment-quality.py` imports into the existing local runtime:

- `investment_quality_annual`: exact canonical/source tickers, fiscal year,
  period end, earliest availability, ART dimension, ratios, raw denominators and
  numerators, machine-readable issues and source-record SHA-256.
- `investment_quality_metadata`: source, construction, version, import timestamp,
  record and ticker counts.

Use the paid SF1 **ART at fiscal Q4**, one non-overlapping TTM/FY observation per
year. Never sum ART, use MR dimensions, count monthly carried values as years, or
replace an invalid first publication with a healthier later restatement.
Ambiguous same-date first publications abort the import. Symbol mappings come
from the existing audited financial mapping; no guessed aliases or substitute
stocks. Import replaces only the two importer-owned quality tables' content.
It does not edit any valuation, Guru, portfolio, user or price table.

API selects records available by the workspace cutoff, at most ten annual
observations per company. Quality windows require consecutive fiscal years,
300–430-day adjacent year-end gaps and a latest year-end no older than 550 days.
Those are explicit operational freshness/continuity guardrails, not return-tested
quality thresholds. Missing or invalid inputs for any enabled factor make the
screen incomplete, not passed. Missing endpoints are not zero and are not
backfilled. Acquisitions, disposals and reporting changes still need diligence.

Local import: **13,688 rows / 530 exact tickers**. ROIC unavailable in 528 historical
rows (527 invalid/missing capital, one missing/formula mismatch). Seven additional
records fail FCF reconciliation/availability. These are retained with issues.
Only affected windows/factors fail; invalid history is never deleted.

The old Growth screen unintentionally excluded `multi_method_growth` and
`revenue_stage` companies. Its operating-company allowlist now matches the
Fundamentals backend: those two plus `operating_company`. Financial and
customer-cash models remain excluded. This is a discovery-scope repair, not
a model-method change.

Reproducible import:

```bash
python3 scripts/import-investment-quality.py \
  --source /Users/yudonglu/Documents/jansen_us_firm_replication/data/sharadar/parquet/fundamentals \
  --db output/investment-workflow-20260908/runtime.sqlite
```

A future deployment must explicitly include the quality import/table layer; code
alone cannot populate it. An absent table degrades to missing quality coverage,
not invented figures. Existing cached opportunities invalidate on SQLite's
external data-version change after import.

## Observed results at 2026-08-28, Guru report quarter 2026-06-30

Universe: 573 securities in disclosed Guru holdings/exits. Growth >=15%:

| Scope / rule | Growing | Pass | Fail | Incomplete |
|---|---:|---:|---:|---:|
| Original model-route subset, 5/5 ROIC >=15% | 55 | 21 | 31 | 3 |
| Corrected operating universe, 5/5 ROIC >=15% | 88 | 24 | 57 | 7 |
| Corrected operating universe, 4/5 ROIC >=15% | 88 | 31 | 50 | 7 |

Incomplete 5Y windows: GEV, RDDT, ARM, TEM, FER, TKO, SNDK. They remain discoverable
with quality disabled. Full-history missing coverage is not reported as zero.

MSFT FY2022–2026 ROIC: 35.6%, 37.0%, 40.7%, 37.9%, 38.6%; average 37.96%,
minimum 35.6%, passes all five years. NVDA FY2022–2026: 28.1%, 11.7%, 78.3%,
116.1%, 119.7%; fails 5/5, passes 4/5. MU and CVX's rapid latest growth does not
override weaker historical ROIC. WAT remains eligible because it actually passes
the ROIC rule; the screen does not pretend to remove acquisition/base effects.

One local cold factor read: ~62ms for 530 companies (10-year cap); not an SLA.
The existing full discovery endpoint also reads historical books/prices/models,
so this number is not presented as full-page load latency.

## Verification

- Importer: signed capex and ratios, positive denominators, nulls, availability,
  ART/Q4 only, earliest-vintage selection, conflicts; five tests.
- Backend: optional table, cutoff boundaries, no MR records, ten-year cap, stale
  series, exact identity and null denominators; three new tests. Investment
  backend suite: 123 tests passed.
- Frontend: sustained vs high-average distinction, 3/5/10 windows, partial-year
  requirement, missing/duplicate/skipped/stale/future records, optional cash
  factors, boundaries, query round-trip, malformed inputs, operating-route
  allowlist, decimal/invalid drafts and EN/ZH presets.
- Four research-lens regression tests include desktop and 390px EN/ZH layouts,
  evidence and valuation round-trips. Targeted suite: 52 tests passed.
- Analyzer, i18n audit and release web build passed. Native browser checked real
  MSFT annual data, default 24 matches, 4/5 yielding 31, NVDA filtered search and
  FY2023 shortfall, plus Chinese 390×844 controls. No account decisions saved.
- Final complete Flutter regression: **420 tests passed**. The real-browser
  NVDA quality → personal valuation → Back to candidates workflow retained the
  same ticker, cutoff and rules; no financial inputs or accounts were saved.
