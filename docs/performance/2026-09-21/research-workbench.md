# Research workbench verification and performance — 2026-09-21

## Scope

This report covers the local Research refactor at the `2026-09-21` point-in-time cutoff. It verifies the company/facts entry path, published-model reconciliation, personal 5Y/10Y FCFE and operating FCFF worksheets, reverse valuation, evidence navigation, and fact-only company behavior. Production deployment was intentionally excluded.

## Measured local API behavior

Measurements use the authenticated local API on `127.0.0.1:8787` and the canonical local Sharadar/Fact OS release.

| Request | Result rows / coverage | Response bytes | Warm response |
| --- | ---: | ---: | ---: |
| `/api/investment/companies?search=AA&limit=120` | 119 bounded identities | 21,996 | 1.0 ms |
| `/api/investment/research/AMZN?asOf=2026-09-21` | 67 model-history nodes; 360 of 900 price points | 114,748 | 9.9 ms |
| `/api/investment/research/AA?asOf=2026-09-21` | Fact OS company; 13 fact-history nodes; 274 price points; no model | 44,158 | 54 ms |

The fact-only AA payload was 417,005 bytes before overview projection and is 44,158 bytes after projection, an 89.4% reduction. The model-backed AMZN payload was 221,563 bytes before compact history/price projection and is now approximately 115 KB, about 48% smaller. A cold fact-only build was measured at approximately 3.2 seconds; the same request after repository and workbench caches was under 10 ms in repeated checks. Cold Fact OS materialization remains the main local latency boundary.

## Performance changes

- Company lookup is server-filtered and bounded instead of transferring the full directory to the browser.
- The Fact OS company index is point-in-time bounded and includes companies without valuation models.
- Overview responses carry only the four unit-safe decision metrics; full quarterly/annual facts load on demand.
- Price history is projected to `{date, value, currency, source, priceType}` and capped at 360 endpoint-preserving observations.
- Historical model nodes no longer repeat full source/model payloads.
- Documents, full financial history, 13F institution history, and individual model ledgers are separate lazy requests.
- Company search is debounced and stale searches do not replace a newer result.
- The selected historical model ledger is fetched only on explicit report inspection and never changes the research cutoff or personal scenario.

## Deterministic calculation checks

- AMZN 2026-Q2 stored fair value reconciles to `235.6928225956114` per share.
- Normalized earnings power: `90,592.07222972096m / 10,903m × 28.366266291421454 = 235.69282259561143`.
- The FCFE DCF component is `not_applicable`, has stored weight `0`, and is displayed as `N/A / Excluded`, never as a zero-dollar valuation.
- Five- and ten-year FCFE preserve negative explicit cash flow as financing need.
- Operating FCFF uses the full bridge: revenue → EBIT → cash tax → NOPAT + D&A − capex − ΔNWC → FCFF → WACC → enterprise value → equity bridge → per-share value.
- Reverse DCF solves one variable at a time, reports bounds/convergence, checks monotonicity, and substitutes the result back through the forward engine. The growth × mature-margin curve is presented as non-unique price explanations.

## Verification

- `flutter analyze`: pass, no issues.
- Flutter Research/company-search/valuation tests: 57 passed.
- Focused backend Research/workflow/company/fundamental tests: 136 passed in the full suite; 77 passed after the final fact-only correction.
- Fact OS point-in-time company index test: pass.
- `npm run build`: pass; final verified web bundle SHA-256 is `207ca91304cdec4b9716bdc60bce8391433ac70976b0f1924059494d5818fbc1`.
- Real-browser checks: AMZN published ledger, 10Y operating FCFF, AA without a platform model, English/Chinese, and 390×844 layout.

## Honest coverage boundaries

- Fact OS financial facts are the sole financial-fact source. Missing facts remain missing; no zero fill is used.
- Research document records currently provide event classification and verified links only. No stored body means no source-text summary or quote-level locator.
- Fact-only companies can be searched, analyzed, and saved as research records. A missing platform model does not generate a value, gap, or editable model by implication.
- 13F remains delayed disclosure. Split-normalized shares, portfolio weights, and missing-filing states are distinct; they are not real-time trades or fund flows.
- Company-specific KPIs, management explanations, segment forecasts, and economic peer cohorts are shown as research gaps until verified evidence exists.
- Operating FCFF bridge defaults are editable analyst assumptions. A zero bridge input means “assumed zero pending evidence,” not a reported fact.
- The first cold Fact OS request can still take seconds on local disk. Warm navigation is fast because the immutable source generation and compact workbench response are cached.
