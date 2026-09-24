# Rule portfolios: requested 2013 history

## Superseding implementation — 2026-09-24

The earlier blocked attempt below is retained as history. The new candidate
actually reconstructs 2013 and 2014; it does not relabel the old 2023 curve.
Release identity and production acceptance are recorded separately after deployment.

- Snapshot `76f0a490efb29aaadcc84ea5015f095d63891bd75e3cd8cc4ddff4f38a406e0b`,
  schema `investor-style-dashboard-v4`, 2,702,802 bytes.
- Quality Rank: 3,450 observed sessions, 2013-01-02 through 2026-09-21.
- Ackman: 3,422 observed sessions in two **independently funded** segments:
  2013-01-02–2019-11-19 and 2020-01-02–2026-09-21. The 28-session gap remains
  null. Cross-gap return/risk/attribution is unavailable, never compounded.
- Both 2013 and 2014 calendar selections have 252 observed sessions. All 2023+
  selected tickers, scores and target weights are unchanged from the preceding
  published snapshot. Financial data remains current-vintage reconstruction,
  not strict archived-vintage PIT or actual Ackman fund performance.
- First/last date controls, slider, and explicit **2013 / 2014** shortcuts update
  both strategies' return, risk, win rate, payoff, turnover, distribution and
  stock-level buy/sell/mark analysis. Missing history is explained bilingually.
- Daily extension understands the v4 segments, preserves the historical gap,
  and does not classify a quarter spanning missing observations as complete.
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
- CELG: the $50 + BMY share does **not** replace the missing BMYRT CVR.
  [SEC completion](https://www.sec.gov/Archives/edgar/data/816284/000110465919065939/tm1923405d1_8k.htm).
  No verified daily CVR series was found in the authorized canonical input;
  no interpolation, zero substitution or losing-stock exclusion was used.

### Fresh verification

Independent Python share/cash/action/fee replay matches every published valid
daily NAV (3,450 Quality / 3,422 Ackman), including segment restarts. Real Fact OS
range attribution reconciles to net returns within 2e-14. Replaying the daily
refresh against the same 3,450-session input preserves NAV and gap coverage.

| Range | Quality net return | Ackman net return | Quality one-way turnover | Ackman one-way turnover |
| --- | ---: | ---: | ---: | ---: |
| 2013-01-02–2013-12-31 | 29.5175% | 40.5537% | 135.1428% | 206.3482% |
| 2014-01-02–2014-12-31 | 26.0207% | 20.0893% | 93.5400% | 166.1713% |

Ranges start at the selected closing mark, except an independent inception
includes its initial entry fee. Prices are adjusted simulation prices, not raw
historical trade quotes. Full-span Ackman metrics are intentionally unavailable.

Local browser exercised real 2013/2014 data, both distributions, trade details,
EN/ZH desktop and 390px mobile. Focused Flutter: 14 passing; analyze, i18n and
production build pass. Full Flutter: 601 passing / the existing 32 adjacent
failures (not suppressed). Full Fact OS storage audit passes; repository layout
still reports 11 pre-existing findings. No source database or user data changed.
Full Node suite: 1,725 passing / 15 skipped / zero failures; performance suite:
60 passing. Three Python history-window tests pass. No assertion was removed.
Local cold canonical range replay is approximately 39 seconds; cached requests
26–153ms. These are **local** timings, not production latency claims.

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
