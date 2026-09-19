# Discover: steadily rising value

## Decision and scope

Replace the third Discover collection's single-revision momentum screen with a
multi-quarter consistency screen. The user wants sustained model-value progress,
not a ranking dominated by one large quarterly revision. This changes selection
and presentation only: no source rows, published valuation, personal scenarios,
13F books, or backtests are written. Internal URL `collection=revision` remains
compatible; the other collections remain unchanged.

## Metric contract — steady-value-v1

Source: local `valuation_pit_model_runs`, scalar extraction at requested `asOf`.
Grain: one ticker / fiscal quarter, taking the last model observation visible at
the cutoff. Financial and guidance availability must not exceed the model date.
Multiple revisions within one fiscal quarter never count as multiple quarters.
The original last-two-node comparison is preserved independently.

Use the latest 8 consecutive fiscal quarters, never an older passing window.
All values must be finite and positive, with matching nonempty formula, model
version, currency, and economic route. Formula includes published blend weights.
Dates must increase, and the most recent observation must be at most 180 days old.
Missing quarters, changed bases, missing values, and stale histories fail closed.

Let V[i] be quarter i's stored model value and r[i] = V[i]/V[i-1] - 1:

| Metric | Definition | Initial policy |
| --- | --- | --- |
| Rising quarters | Count of r[i] > 0.0025 | At least 6 of 7 transitions |
| Total value growth | V[7]/V[0] - 1 | At least 10% |
| Maximum drawdown | max(1 - V[i]/max(V[0..i])) | At most 10% |
| Largest quarterly move | max(abs(r[i])) | At most 20% |
| Single-step gain share | max(max(log(1+r[i]),0)) / sum(max(log(1+r[i]),0)) | At most 40%; absent gains fail |
| Revision variation | Population SD of the 7 r[i] | Tie-break only, not annualized |

Default ranking: more rises, then lower drawdown, then lower variation, then
ticker. There is no composite score or reward for the largest latest jump.
The 0.25% rise tolerance avoids counting rounding-sized movements. Eight
quarters balance continuity and coverage; six rises permit one modest setback.
Drawdown/jump/concentration guards reject reversals and near-flat paths lifted
by one event. These are explicit product defaults, not empirically validated
return predictors or investment recommendations.

The screen describes historical replay of a stored model version. It is not a
contemporaneously issued historical recommendation, audited business-quality
rating, stock-return series, or standalone DCF claim. A smooth normalized model
can still be economically wrong. The screen does not independently adjust stock
splits, spinoffs, or other corporate actions; identity/basis uncertainty requires
Research inspection. No curves are smoothed or repaired to qualify.

## UX and chart contract

- Collection: **Steadily rising value / 估值稳步提升**.
- Card examples and result rows emphasize rising-quarter count and drawdown.
- Threshold chips visible above search; full rules and the observed gain share
  expand alongside the chart. Existing manager/coverage/search filters remain.
- Detail: four metrics, eight-point straight-segment index chart (first = 100),
  labelled focused y-axis, fiscal-quarter selection with exact currency/share
  values and availability dates, plus an accessible full quarterly table.
- Existing latest model revision/financial comparison stays expandable; Research
  CTA and the long-run price-versus-value chart remain. Empty searches hide the
  prior selection, rather than implying it passed the filter.
- Desktop uses side-by-side list/detail. Mobile shows key screening metrics in
  each row and drills into a full-width detail; two-column metric layout.
- Native Flutter primitives; no generated imagery, price-based valuation inputs,
  canvas interpolation, or invented missing observations.

## Local source acceptance (asOf 2026-08-28, manager quarter 2026/Q2)

573 disclosed securities; old latest-revision >=5% screen: 108; new steady screen:
43. Of the 573, 379 lack a qualifying *comparable history* (including no model,
insufficient history, changed method, etc.); they are not all missing securities.
194 have evaluable histories; 151 fail one or more numerical rules.

| Example | Rising steps | Max drawdown | Largest step | Result |
| --- | ---: | ---: | ---: | --- |
| MSFT | 7/7 | 0.00% | 5.42% | Included |
| ISRG | 7/7 | 0.00% | 16.42% | Included |
| GE | 5/7 | 12.45% | 71.19% | Excluded: reversals/jump/concentration |
| PSX | 3/7 | 34.10% | 81.62% | Excluded: reversals/jump/concentration |
| CVNA | Not comparable | — | — | Excluded: historical blend-method changes |

Default leaders: ETN, VRSN, AXP, MSFT, ZS. This is a descriptive ranking, not a
buy list. Source rows and model outputs are unchanged.

## Verification

- Backend: 120 investment tests passed, including 9 new trend/SQL regressions.
  Covers steady/flat/falling/zigzag/one-jump paths, peak-recovery drawdown, missing
  values, every comparability field, quarter gaps and duplicates, future input
  availability, separate adjacent-node comparison, and no cherry-picked window.
- Flutter: 413 full-suite tests passed. New tests assert stable-first sorting,
  jump/missing-history exclusion, exact quarter selection and table, and rules.
  Existing four-lens EN/ZH tests exercise 1487, 1280, and 390 px layouts.
- Analyzer, bilingual audit, 41 performance/transport regression tests, and
  release web build passed. No production performance improvement is claimed.
- Real in-app browser: local desktop and 390x844, EN/ZH, populated list, MSFT
  quarter selection ($259.84 at FY2025-Q1 vs $330.54 at FY2026-Q4), PSX empty
  search hiding old detail, visible native curve and navigation controls.
- Local preview on 5186 with backend 8789. No deployment or personal-data writes.
