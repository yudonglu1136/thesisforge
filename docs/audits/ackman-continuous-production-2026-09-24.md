# Ackman continuous-history production acceptance — 2026-09-24

## Outcome

The Ackman quantitative-proxy strategy now has one continuous daily series from
2013-01-02 through 2026-09-21 in both the all-market and S&P 500 universes. The
published artifacts contain no availability gap in 2013, 2014, or the 2019
Celgene acquisition interval.

This remains a research simulation built from public holdings and deterministic
execution rules. It is not Bill Ackman's audited portfolio or reported return.

## Root cause and treatment

The previous replay stopped between 2019-11-20 and 2020-01-01 because the
Celgene consideration included a BMY contingent value right (`BMYRT`) for which
the licensed price history has no usable series. The official transaction terms
gave each Celgene share $50 cash, one BMY share, and one BMYRT right. The BMY
2019 Form 10-K reports BMYRT's first trading price as $2.30 on 2019-11-21.

The replay now carries the BMY share and models a deterministic first-trade
liquidation of the right at $2.30 less the strategy's standard 25 bp execution
cost ($2.29425 net). It does not synthesize a daily CVR series and does not label
the modeled disposal as an actual Ackman transaction. Runtime validation fails
closed if the supporting evidence or corporate-action chain is absent or
changed.

Primary evidence:

- Celgene 8-K: https://www.sec.gov/Archives/edgar/data/816284/000110465919065939/tm1923405d1_8k.htm
- Bristol-Myers Squibb 2019 Form 10-K: https://www.sec.gov/Archives/edgar/data/14272/000001427220000082/bmy-20191231x10xk.htm

## Published artifacts

| Universe | Artifact SHA-256 | Coverage | Gaps |
| --- | --- | --- | --- |
| All market | `f54f6a0727e6f56f5d6c01bf69f6a1d44cd4996617272e8d915b86a9a36da95b` | 2013-01-02 → 2026-09-21 | none |
| S&P 500 | `6c0b226a63084fb86e4b5a33c28f4d43c6212a8049a180fe34534bbdf66d32de` | 2013-01-02 → 2026-09-21 | none |

Full-range research outputs for the Ackman proxy:

| Universe | Observations | Return | CAGR | Volatility | Sharpe (0% RF) | Max drawdown |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| All market | 3,450 | 468.66% | 13.51% | 20.22% | 0.730 | -33.34% |
| S&P 500 | 3,450 | 343.29% | 11.47% | 19.48% | 0.657 | -36.25% |

## Verification

- Python strategy-history tests: 5/5 passed for each universe.
- Focused Node suites: 49 passed.
- Full Node suite: 1,735 passed, 15 skipped, 0 failed.
- Performance suite: 60 passed.
- Flutter focused strategy tests: 17 passed.
- Flutter analyzer, i18n validation, and production web build: passed.
- Full Flutter suite: 608 passed; 32 pre-existing Discover-lens assertions
  remain outside this change.
- Fact OS content audit: passed; zero raw duplicates and no source writes.
- Repository-layout audit retains 11 pre-existing findings for legacy valuation
  storage and retired sibling directories; no data was deleted to hide them.
- Local browser verification covered desktop English and 390 px Chinese.
- Production API replay, run as the `webapp` runtime identity, passed all-market
  and S&P 500 full-range, 2013-only, 2014-only, half-range, 101-day, and two-day
  checks, including exact P&L reconciliation.
- Eight concurrent production health probes succeeded.
- `thesisforge.tech` and `www.thesisforge.tech` serve the same production
  JavaScript SHA-256:
  `e417bfdaccb146e41eab19fdacef9d8af88b9ae1b645fd0a5bac43e436e9b6e8`.

## Release identities and rollback

- Runtime commit: `b19106efe7b52730f4084789ea5f17b601ac31ae`
- Vercel deployment: `dpl_BnS9AQMj39QqWZaaJTiGBFcoA8on`
- Elastic Beanstalk application version: `ackman-cvr-b19106e`
- Backend package SHA-256:
  `8acbe672b18f6fb8fb7f00f374f4f9d634a6c48b3426bae62906ea97a7a6313f`
- Previous Vercel deployment: `dpl_2ARhrsCdfp5dbNR5ND8H9mg494zW`
- Previous Elastic Beanstalk version: `intervals-3db689d`

The production environment reached Ready/Green. `/api/health` is reachable and
reports all 14 required database tables, but its aggregate status is currently
`stale` because the market-price source is dated 2026-09-18 and has crossed its
120-hour warning threshold. This freshness warning is independent of the Ackman
history correction and is intentionally not suppressed.
