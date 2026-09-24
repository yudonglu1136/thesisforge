# Rule portfolios: requested 2013 history

## Superseding implementation — 2026-09-24

The earlier blocked attempt below is retained as history. The new candidate
actually reconstructs 2013 and 2014; it does not relabel the old 2023 curve.
Release identity and production acceptance are recorded separately after deployment.

- Snapshot `f54f6a0727e6f56f5d6c01bf69f6a1d44cd4996617272e8d915b86a9a36da95b`,
  schema `investor-style-dashboard-v4`, 2,703,806 bytes.
- Quality Rank: 3,450 observed sessions, 2013-01-02 through 2026-09-21.
- Ackman: 3,450 continuous observed sessions, 2013-01-02 through 2026-09-21.
  Net total return is 468.6646%, CAGR 13.5095%, maximum drawdown -33.3436%,
  annualized volatility 20.2208%, and 0%-risk-free Sharpe 0.7303.
- Both 2013 and 2014 calendar selections have 252 observed sessions. All 2023+
  selected tickers, scores and target weights are unchanged from the preceding
  published snapshot. Financial data remains current-vintage reconstruction,
  not strict archived-vintage PIT or actual Ackman fund performance.
- First/last date controls, slider, and explicit **2013 / 2014** shortcuts update
  both strategies' return, risk, win rate, payoff, turnover, distribution and
  stock-level buy/sell/mark analysis. Missing history is explained bilingually.
- Daily extension understands the v4 coverage contract and rejects any
  unaccounted corporate-action interval rather than inserting a null or restart.
  New quarterly selections still require the existing reviewed rebuild; this
  change does not create a second daily timer or rewrite user strategies.

### Exact action accounting

- QCOR: $30 + 0.897 MNK shares. SEC completion was after the 2014-08-14 close;
  first ex-security session is 2014-08-15. Canonical successor identity is MNKKQ.
  [Completion filing](https://www.sec.gov/Archives/edgar/data/891288/000119312514310400/d772821d8k.htm).
- CNVR: $15.14 + **0.07037** ADS shares, 2014-12-10, base consideration (no
  invented election). Canonical successor identity is BFH. The rounded vendor
  0.07 ratio is not used.
  [SEC terms](https://www.sec.gov/Archives/edgar/data/1080034/000110121514000309/form_8k.htm).
- NSR1: $33.50 cash, 2017-08-08, not the earlier vendor date.
  [Completion filing](https://www.sec.gov/Archives/edgar/data/1265888/000119312517251307/d434981d8k.htm).
- Existing audited ATVI $95 cash settlement is preserved. Adjusted-price units
  are explicitly reconciled. Merger cash is not a fictitious sale; successor
  purchases only trade the amount not already received in the stock exchange.
- CELG: $50 cash + one BMY share + one BMYRT CVR. The CVR is not omitted and
  no synthetic daily series is fabricated. Bristol Myers Squibb's 2019 10-K
  reports the first November 21, 2019 BMYRT trade at $2.30; the model explicitly
  liquidates the right at that observable price, charges the same 25bp one-way
  cost ($2.29425 net), and carries the BMY share in adjusted-price units.
  [SEC completion](https://www.sec.gov/Archives/edgar/data/816284/000110465919065939/tm1923405d1_8k.htm).
  [BMY 2019 10-K](https://www.sec.gov/Archives/edgar/data/14272/000001427220000082/bmy-20191231x10xk.htm).
  The authorized canonical source still has no BMYRT price rows; this explicit
  first-trade disposition is a research-model assumption, not an actual Ackman
  trade or a claim that daily CVR history exists.

### Fresh verification

Independent Python share/cash/action/fee replay matches every published daily
NAV (3,450 per strategy) across one continuous segment. Real Fact OS full-range
attribution reconciles to net returns within 2e-14. The CELG transition preserves
the BMY stock claim and separately settled cash/CVR proceeds; merger cash is not
sold again at the next rebalance.

| Range | Quality net return | Ackman net return | Quality one-way turnover | Ackman one-way turnover |
| --- | ---: | ---: | ---: | ---: |
| 2013-01-02–2013-12-31 | 29.5175% | 40.5537% | 135.1428% | 206.3482% |
| 2014-01-02–2014-12-31 | 26.0207% | 20.0893% | 93.5400% | 166.1713% |

Ranges start at the selected closing mark, except an independent inception
includes its initial entry fee. Prices are adjusted simulation prices, not raw
historical trade quotes. Full-span Ackman metrics are now available under the
disclosed first-trade CVR disposition.

Local browser exercised real 2013/2014 data, both distributions, trade details,
EN/ZH desktop and 390px mobile. Focused Flutter: 17 passing; analyze, i18n and
production build pass. Full Flutter: 608 passing / the existing 32 adjacent
failures (not suppressed). Full Fact OS storage audit passes; repository layout
still reports 11 pre-existing findings. No source database or user data changed.
Full Node suite: 1,735 passing / 15 skipped / zero failures; performance suite:
60 passing. Ten Python rule/universe tests pass. No assertion was removed.
Initial local cold canonical range replay was approximately 39 seconds.
The first deployed AWS replay then exceeded 240 seconds: hundreds of singular
price histories repeatedly scanned the full immutable archive. This was **not**
accepted as a successful production attribution check.

The follow-up changes only the read path: `get_price_histories` performs one
bounded scan per canonical price table, retaining security identities, date
bounds, complete-backfill gates, alias conflict checks, explicit price basis
and pinned generation. Compact date/value/source-ticker points remain traceable
to full immutable facts by generation + table + natural key. No source data,
selection, published daily NAV, costs or analysis formula changes.

Fresh local full canonical replay takes about 3 seconds cold; subsequent ranges
take tens of milliseconds. All six windows reconcile, including both requested
calendar years and the continuous 2019 acquisition interval. These are **local** timings,
not production latency claims. Production acceptance requires another actual
`webapp` replay plus the authenticated browser, not only a green deploy.

Bounded extraction: 84,275 company-quarter rows / 3,457 tickers / 55 quarters;
1,090,085 observed price rows / 360 symbols. Source generation remains
`134e95b9d4e40564d3b3af62f177f98a80fb8df4ac30f1c79a8504d870e0ca29`.
Raw panels/prices remain outside Git, under a bounded temporary audit directory.
Replay commands use explicit panel, candidates, rate history, original feature
adapter, reviewed selection archive and corporate-action ledger; they never
fetch or mutate facts during replay. The source/replay hashes are in the snapshot.

Rollback: restore EB application version `distribution-930795e` and Vercel
deployment `dpl_4cd8qCuhKUnu1mDV7XnNzqyc8kiV` on **both** domains. This is a
code-plus-small-derived-snapshot release: no database migration, configuration
secret change, raw fact installation or private portfolio mutation is required.

## Earlier attempt: blocked, not published

The requested first market session is **2013-01-02**, not January 1 (a market
holiday). This is an extension of the existing Quality Rank and Ackman proxy
rules, not a new strategy or a relabeling of the 2023 chart.

The published snapshot is unchanged. No production deployment or new return
series is claimed by this audit.

## Changes prepared

- `scripts/extract-rule-portfolio-panel.py`: read-only extraction from the
  pinned canonical Parquet catalog into bounded temporary output.
- `scripts/build-rule-portfolio-candidates.py`: reconstruct the existing beta
  and quality candidate population for all requested quarters, without
  changing the ranking policy.
- `scripts/build-rule-portfolio-inputs.py`: remove the fixed 2023 cut,
  default to 2013, accept an explicit `--start`, and reject incomplete candidate
  quarter coverage. Compare selected quality tickers against the existing
  archived pre/post-2023 selection schedules.
- `scripts/test_rule_portfolio_history.py`: three fresh passing tests for the
  default start, explicit shorter range, invalid/empty ranges, and incomplete
  quarter coverage.

## Actual extraction and replay evidence

- Repository baseline: `cc5062d1f1e260b5e076abbd309469be78b71e90`.
- Pinned Fact OS generation:
  `134e95b9d4e40564d3b3af62f177f98a80fb8df4ac30f1c79a8504d870e0ca29`.
- 84,275 company-quarter panel rows, 3,457 distinct tickers, 55 quarters.
- 64,761 quality candidate rows; 55 selection quarters for each rule.
- No selected financial publication date after its signal date was accepted.
- 358 selected symbols; 1,068,817 observed price rows (including the
  previously reviewed successor symbols and SPY).
- Requested price span: 2013-01-02 through 2026-07-01. July 2026's latest
  selection remains an immature return window, as in the published product.
- A full replay against the **committed** engine stopped at the first missing
  active price: QCOR, 2014-08-15. The candidate snapshot was not written.

Independent quarter-by-quarter checks against that same committed engine:

| Rule | Successful mature quarters | Unresolved quarters / securities |
| --- | ---: | --- |
| Quality Rank | 52 / 54 | 2014-Q2 QCOR; 2023-Q3 ATVI |
| Ackman proxy | 50 / 54 | 2014-Q2 QCOR; 2014-Q3 CNVR; 2017-Q2 NSR1; 2019-Q3 CELG |

These are diagnostic counts, **not** an accepted partial backtest. Never
discard the failed holdings, renormalize their weights, forward-fill prices,
or concatenate individually successful quarters into a published NAV.

ATVI's already-audited cash action exists in the current published history;
the newly used targets-only archive does not carry that receipt. It must be
explicitly preserved when the extended artifact is assembled. This diagnostic
does not indicate that the current published ATVI interval is broken.

## Remaining blockers

1. `server/backtestEngine.js` and its test already contain an uncommitted
   stock-plus-cash change predating this work. Neither file was modified or
   committed by this task. Integrating it requires resolving ownership first,
   then independently checking mixed cash/stock turnover and transaction fees;
   a passing terminal-NAV test alone is insufficient.
2. Historical corporate-action receipts need to be verified and included in
   both portfolios, with adjusted-price unit conversion and successor prices.
   The source actions contain QCOR (30 USD + 0.897 MNK shares), CNVR
   (15.14 USD + 0.07 successor shares), NSR1 (33.50 USD cash), and ATVI
   (95 USD cash). Legal date versus first ex-security trading session must be
   reconciled explicitly.
3. **CELG cannot be accounted for with just 50 USD + one BMY share.** The
   issuer's November 20, 2019 completion announcement also specifies one
   tradable contingent value right per share, trading as **BMYRT** from
   November 21. The pinned canonical stock dataset has BMY and CELG prices,
   but no BMYRT series. Omitting the right or using its eventual expired value
   during 2019 would misstate historical NAV.

Primary sources checked in this run:

- [Mallinckrodt completion announcement, SEC exhibit](https://www.sec.gov/Archives/edgar/data/1567892/000119312514310394/d773422dex992.htm).
- [Bristol Myers Squibb acquisition completion and CVR terms](https://news.bms.com/news/details/2019/Bristol-Myers-Squibb-Completes-Acquisition-of-Celgene-Creating-a-Leading-Biopharma-Company/default.aspx).
- [FRED DGS10 source](https://fred.stlouisfed.org/series/DGS10); rates used for
  reconstruction only at or before the signal date.

Current-vintage financial values and current security classification retain
the existing exploratory-research limitation. Historical publication-date
checks do not make this strict archived-vintage PIT.

## Release gates still required

Complete action accounting and independent daily NAV/cost reconciliation;
confirm unchanged 2023+ selections; update and verify any per-series history
coverage contract; test desktop/mobile and EN/ZH rendering; only then replace
the derived snapshot and follow the normal release process. If BMYRT cannot
be sourced, expose a clearly separate validated common-period comparison;
do not claim both strategies have verified continuous 2013 history.

Storage layout audit still reports the same 11 pre-existing layout findings
(legacy sibling projects and `valuation-pit-source.sqlite`). Nothing was
deleted to silence that audit. No raw/canonical facts or user stores were
modified. Temporary panels and bounded price extracts are not source facts.

## Final checks in this attempt

- Python history-window regression tests: **3 passed**.
- Node snapshot + authenticated-route regression tests: **7 passed** against
  the unchanged published snapshot. The initial route attempt lacked local
  dependencies; after offline installation, the sandbox blocked binding a
  loopback port. The approved rerun passed. Neither issue was suppressed.
- Full Fact OS storage-content audit: **passed**, receipt
  `data/fact_os/audit/rule-history-2013-storage-20260924.json`.
- `git diff --check`: passed.
- Full 2013 replay: **failed closed**, as described above. No candidate
  snapshot was written. No frontend, data publication, commit, push or
  production deployment has been performed for this extension.
- Existing published snapshot SHA-256 remains
  `6f800cc44e5239b362451feb1b472625792e04236b4a6b00d28cdc6de2c7eb5b`.

Reconstruction fingerprints:

| Input | SHA-256 |
| --- | --- |
| Feature panel | `296150ce255ca1b06b193ec78f59ff133597f50f5a82a3975b64f3f94dc4e05f` |
| Quality candidates | `cb878aac41d6a092cce8c5a6832b692329fd4c114b10a6f9fcdc19a64cb9372a` |
| Rate history | `c363778b4121bd275e1abdbadd55ea9264b6fc3aa8c8749ed096226bb8035bae` |
| Observed price extract | `609f05adec4c9dce078686460e045035fcf8628c1d401a4e53482c429dbf6c6d` |

The task-owned 319 MiB temporary extraction is reproducible and is removed at
handoff. Scripts and this audit remain; original archives, databases, source
Parquet, published returns and other tasks' files are retained.
