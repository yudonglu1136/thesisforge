# Financial API append attempt — 2026-09-11

Status: **blocked by provider entitlement; no financial data appended**.

## Requested scope and observed state

Append newly available financial statements across the existing local research
universe, preserving historical point-in-time rows. AVGO is the regression case.
No production deployment, provider purchase, price refresh, model substitution or
user-scenario write was performed.

Runtime inspected read-only:
`/Users/yudonglu/Documents/investment-market-reviewed-20260911/runtime.sqlite`.
`valuation_pit_financials` contains 65,038 ARQ/ART rows over 532 distinct tickers;
these are not 65,038 distinct fiscal periods. Maximum `available_at` is
2026-08-27. Source metadata records a paid API refresh on 2026-08-28.

AVGO's latest retained financial and model period is 2026-Q2, period end
2026-05-03, provider availability 2026-06-09. The live local research endpoint
returns that same period even at `asOf=2026-09-11` (HTTP 200). This is missing
source/model data, not merely an old browser cutoff or a rendering issue.

Jansen's already-downloaded fundamentals parquet agrees: AVGO has Q2 ARQ/ART,
and the full local ARQ/ART data's latest datekey and lastupdated are 2026-08-27.
There is no newer AVGO row in that local paid-data export to append.

Official SEC 8-K accession `0001730168-26-000076` states that Broadcom released
third-quarter results on 2026-09-02 for the quarter ended 2026-08-02:
https://www.sec.gov/Archives/edgar/data/1730168/000173016826000076/avgo-20260902.htm

## Provider access result

The existing Jansen `modern_us.sharadar.SharadarClient` loaded its configured key
without printing it. One bounded request for `fundamentals`, ticker AVGO,
dimensions ARQ/ART and availability dates 2026-08-01 through 2026-09-11 returned:

`HTTP 403: {"error":"Exceeds free tier","description":"Please sign up at /subscribe."}`

This proves the tested key/request is not entitled; it does not establish whether
the subscription expired, the key is wrong, or a different account is subscribed.
No bulk requests or destination transaction followed that denial. The complete
population's upstream freshness remains unverified. Old rows were not overwritten
and a new refresh-success timestamp was not written.

## Reproducible read-only checks

```sql
SELECT COUNT(DISTINCT ticker), COUNT(*), MAX(available_at)
FROM valuation_pit_financials;

SELECT ticker, fiscal_period, dimension, available_at, report_period
FROM valuation_pit_financials
WHERE ticker='AVGO' ORDER BY available_at DESC LIMIT 6;

SELECT ticker, fiscal_period, as_of_date, financial_available_at, model_version
FROM valuation_pit_model_runs
WHERE ticker='AVGO' ORDER BY as_of_date DESC LIMIT 3;
```

Local read: `GET /api/investment/research/AVGO?asOf=2026-09-11`.
Credentials must remain local; the diagnostic report intentionally omits them.

## Required continuation

Restore financial-data API entitlement or explicitly choose an audited alternate
source. Then freeze the current full ticker union, back up the local database,
fetch all bounded ARQ/ART batches into an isolated candidate, reconcile identical
keys and preserve earliest PIT observations, append only genuinely new periods,
and refresh dependent read models atomically after their normal verification.
Do not run the legacy combined financial/price refresh directly against runtime:
its price UPSERT is outside this financial-only request. SEC release evidence can
be recorded separately, but must not silently replace Sharadar PIT financials.
Never overwrite saved user assumptions while refreshing reported actuals.
