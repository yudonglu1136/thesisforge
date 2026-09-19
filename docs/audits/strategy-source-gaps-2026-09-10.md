# Strategy source-data repair — 2026-09-10

## Exact screenshot: a real history boundary

Reproduced Dev Kantesaria / Li Lu / Samantha McLemore, Top 5, 27% premium
filter, redistribute, KMLM 30%, 1×, 10 bps, 2021-08-28–2026-08-28.
The failure is `manager_history_unavailable`, Samantha, 2021-08-30.

The SEC submissions directory for CIK 0001854794 has no older archive files.
Its first filing is the 2021 Q4 original, published 2022-02-14:
[SEC filing index](https://www.sec.gov/Archives/edgar/data/1854794/000108514622001017/0001085146-22-001017-index.htm).
The firm's [biography](https://patientcapitalmanagement.com/bio/samantha-mclemore)
distinguishes Patient Capital's launch from its subsequent acquisition of the
Miller Opportunity Equity business. A predecessor's fund or firm book is not
silently substituted for Patient Capital's 13F history.

Reducing Top N cannot solve this boundary. The engine now returns the first
stored report/publication date and source URL. EN/ZH UI explains the date rather
than suggesting a smaller Top N. The requested dates, rules and user saves are
unchanged. No synthetic pre-filing holdings or waiting-period returns are added.

A diagnostic-only request over the common history, 2022-02-15–2026-08-28,
returns ready with 1,138 sessions and 100% minimum execution coverage at the
same 27% threshold. This is NOT the requested five-year result and was not
applied to the user's rules. The user was asked to choose a common-history or
explicit waiting-in-cash policy; no policy change has been authorized.

## Actual missing prices recovered

The first-failure inventory across the existing 3,458-case regression identified
resolved ticker histories with missing sessions. Public provider daily records
recovered 17,159 observations for 31 symbols in two append-only generations.
The second generation additionally repairs IBM's explicitly NULL adjusted
prices, preserving the original raw NULL records as evidence.

Validation before accepting any row:

- Exact provider symbol, USD currency, equity/ETF type and unique daily dates.
- At least 60 independently stored overlap sessions.
- Every overlapping split-adjusted close agrees within 0.001%.
- Every valid overlapping adjusted price supports one constant level scale
  within 0.001%; no inconsistent return-series splice is accepted.
- Only actual upstream rows on existing SPY sessions enter the database.
- No existing raw price, holding, valuation, financial, guidance or account
  row is changed. No ticker/CUSIP identity or corporate action is guessed.
- Raw response, hash, URL, observation timestamp and normalized prices are
  stored; per-symbol scale and overlap evidence are in `provider-audit.json`.

Both generation checks: SQLite integrity `ok`, zero foreign-key violations,
zero canonical source writes, zero changed existing price rows. Only
`source_documents`, `price_series` and `price_observations` fingerprints change.
The original database and both new generations remain available for rollback.

Active local generation:
`23f205a28065a925fead7e2b06b56071fed3f8d0111772befe66453b6be6a786`.
Local API 8789 uses the new private database; existing owner-portfolio wiring
is preserved. Local frontend 5186 includes the corrected boundary explanation.
No production database changes, Git push or deployment.

## Explicit unresolved cases

ARCH, FCAU and JHG provider histories return HTTP 404; EA's returned series has
insufficient independent overlap. These are not filled with another ticker's
prices. FISV retains one unavailable source session. Older unresolved CUSIPs,
manager-entity conflicts and unreconciled original filings remain blocked.
CTA history before ETF inception and manager history before the first public
filing cannot be manufactured. This repair is not an all-configurations-pass claim.

## Verification and reproducibility

Private evidence directories outside Git:

- `/Users/yudonglu/Documents/strategy-data-repair-20260910/`
- `/Users/yudonglu/Documents/strategy-data-repair-20260910-v2/`

The append-only recovery CLI takes a source warehouse, actual regression
failure inventory and a NEW private output directory:

```sh
node scripts/repair-strategy-price-gaps.mjs SOURCE.sqlite CASES.jsonl NEW_PRIVATE_DIRECTORY
node scripts/verify-strategy-full-matrix.mjs CANDIDATE.sqlite NEW_REGRESSION_DIRECTORY
```

Unit/widget verification: 61 focused backend tests, all 454 Flutter tests,
18,000 synthetic parameter combinations, analyze, bilingual audit, Ontology
verification/tests and both standard and local-preview builds passed.
Synthetic cases test calculation invariants, not real source-data completeness.

### Final real-data population regression

All 3,458 planned configurations completed against the active generation:

| Outcome | Before | After |
| --- | ---: | ---: |
| Ready | 2,035 | 2,070 |
| Blocked by source/history requirements | 1,423 | 1,388 |
| Runtime errors | 0 | 0 |

There are 35 newly ready configurations and zero previously ready configurations
that became blocked. Missing, unexpected, duplicate and invalid test cases are
all zero. This is the enumerated regression population, not an exhaustive test of
every possible combination. Its completeness gate remains **fail**, because
1,388 configurations are still blocked:

| First reported blocker | Configurations |
| --- | ---: |
| Execution coverage below 90% | 763 |
| Filing classifications not verified | 243 |
| Manager history unavailable at requested start | 216 |
| Manager identity mismatch | 121 |
| CTA history unavailable | 27 |
| Corporate-action transition needs review | 9 |
| Conflicting security identity | 6 |
| Missing active price | 3 |

Counts describe configurations, not unique missing records, and use the first
failure encountered; resolving one may expose another. Missing real source data
and genuinely unavailable pre-inception history must not be conflated.

Three already-ready curve hashes changed, all for the same Stan Moss Top 10,
10-year, valuation-off, no-CTA case. TJX at 2016-08-29 was formerly unavailable
with zero stock weight; the recovered actual price makes its 10% allocation
executable. Restoring only the old TJX price maps exactly reproduces all three
original curve hashes. This counterfactual impact audit passes; it does not
turn the separate completeness gate into a pass or hide the changed results.

The local HTTP/worker parity suite also passes for 42 cases spanning all 28
managers and representative mixed rules. Statuses and curve hashes match the
offline generation. Anonymous access is denied; zero user rules were saved.

Final evidence: `regression/summary.json`, `comparison.json`, `curve-impact.json`
and `http-verification.json` in the private v2 evidence directory above.

### Browser verification

The real five-year three-manager request still displays the explicit history
boundary. English and Chinese, desktop (1440×1000) and mobile (390×844), were
checked in the rebuilt local frontend. First-publication copy wraps on mobile;
manager controls remain reachable; returned browser error logs were empty.
Screenshots `history-boundary-zh.jpg` and
`history-boundary-mobile-zh-detail.jpg` are in the private v2 directory.
The browser uses the 30% preset; the exact screenshot's 27% setting was verified
independently through HTTP. No shorter-period result was passed off as five years.
