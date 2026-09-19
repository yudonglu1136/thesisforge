# Strategy valuation linkage repair — 2026-09-11

## Reproduction and cause

The reported mix uses Bill Ackman, Chris Hohn and Dev Kantesaria, a 61% maximum
price/model premium, 30% KMLM with annual rebalancing, 1× exposure, 10 bps traded
cost and 2021-09-10–2026-09-10. The screenshot did not expose Top N. Testing every
Top N from 1 through 10 identified the reported 2022-01-03 failure for Top 1–3.

On that rebalance, GOOG was incorrectly excluded as `no_model`. Both the runtime
and strategy stores have 67 GOOGL model nodes and zero GOOG nodes. The reviewed
S&P universe already identifies GOOG as an Alphabet company-model alias, but
the strategy adapter only loaded/looked up exact ticker keys. Additionally, GOOG
has no valuation snapshot from which the old comparison loader can verify USD.

At decision date 2021-12-31:

| Claim | Own close | PIT model | Premium | Correct outcome at 61% |
|---|---:|---:|---:|---|
| GOOG | 144.67950439453125 | 126.12172528075249 (2021-10-27) | 14.714181% | Eligible |
| LOW | 258.4800109863281 | 148.85650082151625 | 73.643751% | Expensive |
| SPGI | 446.4805908203125 | 239.83917716341335 | 86.158323% | Expensive |

## Narrow correction and invariants

- Exact reviewed claim: GOOG / CUSIP 02079K107 / GOOG execution symbol, resolved
  identity required. The model's source ticker must be GOOGL and currency USD.
- Evidence: [Alphabet 2015 Form 10-K, Note 12](https://www.sec.gov/Archives/edgar/data/1652044/000165204416000012/goog10-k2015.htm),
  filed 2016-02-11, confirms equal per-share economic participation for A/B/C
  classes, except voting rights. The linkage is unavailable before that evidence
  date. Equal economics do **not** mean equal market prices.
- Only when no own-class model exists at the decision date, use the latest
  available company model, retaining its date/version and 550-day freshness gate.
  Do not replace an existing zero, invalid or stale own-class node.
- Obtain GOOG's own split-adjusted **close**, not dividend-adjusted close, from
  the independently verified USD/EQUITY/GOOG provider series. Never borrow the
  GOOGL quote, infer USD, fill missing days or change strict replication returns.
  Existing nonempty comparison evidence is preserved.
- The read-only linkage is shared by structured and legacy strategy adapters;
  canonical model loading does not add GOOGL to holdings or execution prices.
- Model link, original filing URL, exact price field/symbol, quote source hash
  and model date are included in the ledger and held-position snapshots.
- No source databases, published model outputs, saved user rules or production
  services were rewritten. Calculation version changes to
  `strategy-share-class-valuation-20260911-v6`.
- Valuation thresholds, Top N, component budgets, CTA policy, costs and fully
  invested/no-cash requirements remain unchanged.

## UI correction

The mix card now exposes the Guru Top N per manager. Genuine empty-component
failures carry every excluded candidate, decision date, price, model and premium
to the UI (previously present only in the ledger). A blocked run no longer shows
the green “Fully invested” completion claim. Held linked-model positions identify
the company model separately from the held share-class price. English and Chinese
copy and mobile layout tests are included.

## Verification

Real local HTTP, unchanged 61% rule and full five-year window:

- Top 3–10: all ready, each with 1,255 daily points from 2021-09-10 through
  2026-09-10, zero cash in every snapshot.
- Top 3: CTA buy-and-hold, flexible tranches, no CTA, annual DBMF with 1.5×
  leverage, and 60% Guru / 40% QQQ equity mix also ready with all 1,255 points.
- Top 3 / annual KMLM: eight snapshots retain the reviewed GOOG model linkage.
- Top 1 still stops on 2023-10-02: CMG/FICO expensive, CNI no model.
- Top 2 still stops on 2024-01-02: CMG/GE/FICO/SPGI expensive, QSR/CNI no model.
  Runtime and strategy databases were checked: neither CNI nor QSR nor CNR has
  any PIT model node. These are remaining real coverage/rule constraints, not
  evidence of a completed full-investment strategy. No fallback is substituted.

Automated checks: 100 strategy backend tests passed, including the existing
27,000-case synthetic parameter matrix; new exact-claim, source/currency/date,
own-price, own-model precedence, missing-price, exclusion payload, model-loading
and snapshot regression tests. `flutter test --no-pub`: 510 passed. Flutter
analysis, bilingual audit, ontology verification and ontology tests passed.

Preview built with `flutter build web --release --no-pub --no-wasm-dry-run
--output output/strategy-mix-preview-20260911`, local auth bypass/workflow flags
and API base `http://127.0.0.1:8789`. No production build/deploy or `dist` deletion.

Browser verification on the rebuilt English preview: configured the three
managers / Top 3 / 61% / annual KMLM through actual controls, clicked Run backtest,
visually checked the four real daily curves and performance table, then selected
2022-01-03 in the historical dropdown. That snapshot displays GOOG 70%, KMLM 30%,
cash 0%, the company-model/own-share-price distinction, and all eight expensive
exclusions with their contemporaneous model/price dates. Changing the snapshot
did not rerun the strategy or alter its rules. Mobile 390×844 / 150% text and both
languages are covered by the passing widget tests.
