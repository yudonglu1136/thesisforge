# ThesisForge redesign — local implementation report

Date: 2026-09-08. This report covers the implemented core journey from `product-redesign-blueprint-2026-09-08.md`, not completion of every proposed page or production deployment.

## Preview

http://127.0.0.1:5184/?view=discover&asOf=2026-06-01&lang=en

Frontend: 127.0.0.1:5184. Local API: 127.0.0.1:8787. Both services are kept running for inspection. The preview uses a local development authentication bypass and must not be uploaded as a production build.

## Implemented experience

1. **Home:** a research attention queue, continuation of saved work, and two clear entry points: Guru holdings and fundamentals.
2. **Discover:** searchable responsive cards for 29 managers, canonical avatars, following, real dated filings, quarter selection, and selected-holding trajectories in shares, weight, or reported value. The next action opens research with the exact source filing attached.
3. **Research:** compact issuer identity, explicit information cutoff and entry provenance, actual price / valuation history, and an explanation of the latest model-input changes. Detailed financials and sources are progressively disclosed.
4. **Valuation:** editable five-year forecast worksheet, separate scenario templates, reverse-expectation controls, calculation audit, and immutable saved versions. Mobile shows the result before the longer input table. Published blended value and the standalone FCFE calculation remain distinct.
5. **Decision:** explicit action selection, optional monitoring rules, position inputs only when relevant, an unsaved-edit guard, and source-backed immutable decision records.
6. **Portfolio / review:** positions, decision journal, Guru comparison, and original-versus-last-confirmed review modes. Each Then vs Now comparison holds its selected assumptions constant. Saving a review does not overwrite the original decision.
7. **Strategies:** explicit manager selection and Top 1–3 configuration with clearly labelled saved/default previews. No unchosen manager is silently included.

The shared shell uses the selected Graphite direction, a compact navigation rail, consistent typography and canonical logos. English and Chinese remain supported. The core layout was checked at desktop and 390px mobile widths.

## Provenance and financial safeguards

- Missing values remain missing rather than becoming zero.
- Guru quarter selection survives navigation and direct URL reload; research and saved decisions preserve the actual entry accession instead of attributing the latest filing.
- Reported 13F value is labelled as such, not manager AUM or inferred purchase cost.
- Scenario edits invalidate a prior saved-version association. Ownership confirmation remains mandatory for saving.
- This redesign does not replace or recalibrate the underlying financial valuation engine. Visual clarity is not certification of the economic reasonableness of every existing model output.

## Verification

| Check | Result |
| --- | --- |
| Full Flutter suite | 183 passed |
| Workflow widget tests within that suite | 52 passed |
| Backend workflow tests | 33 passed |
| Targeted Flutter analysis | No issues |
| Final web release build | Passed |
| Whitespace / patch check | Passed |
| Browser core journey | Passed |

The browser journey used Bill Ackman's 2025 Q4 filing, selected AMZN, switched trajectory metrics, opened research, edited and saved a scenario, recorded Pass, and saved a Maintain review. SQLite inspection verified the exact accession and three immutable local QA events. Additional release checks covered MSFT Overview, valuation input disclosure, Home, Strategies, and mobile language switching.

All three newly written ledger events are explicitly marked LOCAL QA. They exist only in `output/investment-workflow-20260908/decisions.sqlite`. Runtime source data is isolated in `output/investment-workflow-20260908/runtime.sqlite`; no production user ledger was changed.

A scroll-persistence experiment introduced an ExpansionTile type error. Regression tests caught it and it was reverted before the final passing suite and release build. Selection/provenance restoration is implemented; automatic scroll-offset restoration is not.

## Visual evidence

Actual final browser screenshots are in `output/product-build-20260908/`:

- `11-discover-final.jpg`: manager discovery.
- `08-msft-overview.jpg`: price/value history and changes.
- `07-msft-value-revised.jpg`: desktop forecast worksheet.
- `06-mobile-value-revised.jpg`: mobile result-first valuation.
- `09-home.jpg`: research home.
- `10-strategies.jpg`: explicit strategy setup.
- `12-discover-mobile-zh.jpg`: mobile Chinese discovery.

The source and implementation were compared together twice at matched dimensions. The resulting desktop table-width and mobile result-order corrections are documented in the current-run section of `../design-qa.md`.

## Not claimed as finished

- The complete 17-page blueprint and all proposed future analytics.
- A new implementation of full backtests or the industry graph: the existing terminal remains accessible, with a notice that its cutoff can differ.
- Full extraction of every holding in every historical filing; visible bounds and missing-data states are retained.
- Production authentication / login-return verification, formal accessibility certification, Git push, or AWS / frontend production deployment.

This delivery is a working local core flow for review, not a production release.
