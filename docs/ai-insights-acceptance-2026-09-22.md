# AI Insights acceptance notes — 2026-09-22

## Release candidate

Discover now has an independent AI Insights module, replacing the retired Value
Flow page and service. It includes capital-investment and revenue histories,
YoY/QoQ comparisons, sector heatmaps, contributor breakdowns, company rankings,
two-to-four-company comparison, score-input/source drilldown, day-precision
historical cutoffs, Research context, English PNG reports and company-metric CSV.

Local verification used the normal development frontend and API with the
canonical Fact OS root. The release contains no copied source database or
private user data.

The artifact contains 59 companies (9 capital investment, 28 hardware, 22
software), 4,478 quarterly financial rows and 142 corporate-action records.
Published generation:
`b8c7e5105b5885fa99692e0c036a39dedac5e93f17885d6582463889e33b12f0`.
Its data SHA-256 is
`220d4d86a0260a9c97ee3fed48e54685fa3a86445a624313bb6bba1379dc73b1`.
Its dependency fingerprint is
`9d65f770414e4d82ac272b3c212c0c04470cb96bad1c44742e8b2e69f75ae0da`.
Same-input replay preserved artifact/manifest bytes and modification times;
receipt: `data/fact_os/audit/ai-insights-20260922T054748-82f296d5.json`.

The existing daily Fact OS sync command now publishes the artifact only after
relevant fundamentals, ticker identity or corporate-action inputs succeed and
are complete. Price-only and unrelated syncs explicitly skip the rebuild. No
second scheduler was added. See
[operations](ai-insights-operations.md) for the refresh and deployment contract.

## Passed checks

| Check | Result |
| --- | --- |
| Python artifact, sync and sync-plan tests | 56 passed |
| AI Insights Node API/metrics/routes tests | 19 passed |
| Workflow and AI route integration regression | 66 passed |
| Previously reported adjacent Flutter failures | 11 repaired and reverified |
| Retirement routing tests | 6 passed, 1 skipped: Caddy binary unavailable |
| Final focused Flutter UI and navigation tests | 15 passed, including desktop/mobile export-preview geometry |
| Final Flutter static analysis | No issues |
| i18n audit | Passed |
| Performance suite | 60 passed |
| Isolated build and static budget checks | 9 passed |
| Local web build and whitespace check | Passed |
| Full Fact OS storage audit | Passed; existing 13.8 GB canonical store checked, no duplicate raw copies or deletions |

The release-candidate compiled bundle SHA-256 is
`800c36a2cb565a65d47808e9e290d8151036ec0270810ab4b9bcc184a1200922`.
Storage audit receipt:
`data/fact_os/audit/ai-insights-storage-20260922-implementation.json`.
The full storage audit preceded the final derived-artifact enrichment; that
enrichment did not change canonical source storage.

## Browser acceptance

Verified against the running local app and real Fact OS artifact:

- Desktop overview, capex bars, revenue growth comparison, heatmap and YoY/QoQ
  switching render and update coherently.
- CRDO/ALAB comparison retains actual report periods and disclosure dates.
  Company details expose raw score inputs, weights, contributions and source IDs.
- At cutoff `2026-06-30`, undisclosed `2026Q2` CRDO/ALAB values become missing;
  selecting `2026Q1` shows the earlier disclosed facts. Restoring the cutoff and
  quarter restores the later snapshot.
- Earnings-quality ranking filtered to ALAB retains hardware peer rank 20 and
  score 33.4, rather than recalculating a rank of one from the search result.
- English and Chinese mobile navigation render at 390 × 844. The report preview
  now fits both mobile and desktop widths without cropping the right edge.
- English report downloaded from the actual Save PNG control: 2560 × 6762 PNG,
  visually inspected as a standalone report with no application controls.
  Download was repeated after the responsive-preview change. The automation
  download-event listener initially timed out after three seconds, but the
  actual saved PNG was independently found and inspected.
- Company CSV downloaded and parsed: 50 hardware/software rows, including ALAB,
  MU, CRDO, AVGO, LITE and VRT, with snapshot and source fields.

Downloads are named `ai-insights-2026Q2-2026-09-22-en.png` and
`ai-insights-2026Q2-2026-09-22.csv` under the local Downloads directory.
An initial preview load during compilation produced a transient script-load
error; completed-build interaction and exports succeeded afterward.

## Existing storage-layout audit limitation

`npm run audit:storage-layout` did not pass. It reports the existing
`server/data/valuation-pit-source.sqlite` runtime database and retired sibling
workspaces (`fundamental-analysis`, `fundamental-analysis-sp500`,
`guru-intelligence` and dated `thesisforge-private-*` directories). These were
not deleted or moved as part of this feature. This repository-layout audit is
separate from the successful canonical Fact OS storage audit above.

## Historical adjacent regressions — resolved

The 11 failures recorded below were reproduced and repaired rather than
suppressed. Six Research cases now assert the current valuation workspace, the
Fundamentals case follows the current search-reset flow, and the four Guru cases
follow the lazy directory → comparison → manager-selection flow. The real
390px Guru callout overflow was also fixed with a responsive stacked layout.
All four Guru language/viewport variants now pass. The original diagnosis is
retained below as an audit trail of what was fixed.

Command run against the shared working tree:

```sh
flutter test test/investment_workflow_test.dart test/investment_explorer_test.dart --reporter expanded
```

Historical result before the fixes: **83 passed, 11 failed**. Full local output is retained at
`/private/tmp/ai-insights-adjacent-flutter.log`. Flutter required access to its
installed SDK cache; the test command itself completed normally with exit code 1.

The cases did not exercise the new AI Insights panel. Inspection pointed
to earlier Research, Fundamentals and Guru changes already present in the
working tree or committed product. No clean before-change baseline was run, so
this is a source-based diagnosis rather than a claim that a baseline test run
proved every failure pre-existing. The affected tests and responsive Guru
callout were then updated to the current product flow and re-run successfully.

### Exact failing tests

| Test file | Exact test name | Failure |
| --- | --- | --- |
| `test/investment_workflow_test.dart` | `connected desk real entry tasks and valuation AppLanguage.zh Size(1487.0, 1058.0)` | Missing personal-DCF heading at line 629 |
| `test/investment_workflow_test.dart` | `connected desk real entry tasks and valuation AppLanguage.zh Size(1280.0, 720.0)` | Missing personal-DCF heading at line 629 |
| `test/investment_workflow_test.dart` | `connected desk real entry tasks and valuation AppLanguage.zh Size(390.0, 844.0)` | Missing personal-DCF heading at line 629 |
| `test/investment_workflow_test.dart` | `connected desk real entry tasks and valuation AppLanguage.en Size(1487.0, 1058.0)` | Missing personal-DCF heading at line 629 |
| `test/investment_workflow_test.dart` | `connected desk real entry tasks and valuation AppLanguage.en Size(1280.0, 720.0)` | Missing personal-DCF heading at line 629 |
| `test/investment_workflow_test.dart` | `connected desk real entry tasks and valuation AppLanguage.en Size(390.0, 844.0)` | Missing personal-DCF heading at line 629 |
| `test/investment_explorer_test.dart` | `fundamentals workbench replaces the revenue-only screen and resets search` | Missing obsolete Fundamentals heading at line 837 |
| `test/investment_workflow_test.dart` | `populated Guru selection and trajectory AppLanguage.zh Size(1487.0, 1058.0)` | `Add a Guru` is not present before loading comparison; line 816 |
| `test/investment_workflow_test.dart` | `populated Guru selection and trajectory AppLanguage.zh Size(390.0, 844.0)` | Same missing lazy comparison control |
| `test/investment_workflow_test.dart` | `populated Guru selection and trajectory AppLanguage.en Size(1487.0, 1058.0)` | Same missing lazy comparison control |
| `test/investment_workflow_test.dart` | `populated Guru selection and trajectory AppLanguage.en Size(390.0, 844.0)` | Same missing lazy comparison control, plus the overflow below |

### Diagnosis and applied follow-up

- The six connected-desk cases successfully open Research and retain the tested
  manager provenance, then expect `Your assumptions. Your valuation.` / `你的假设，你的估值。`
  without opening the current **My DCF / 我的 DCF** subtab. The heading remains in
  `personalValueWorkspace()` in `lib/investment_valuation.dart`. Other tests in
  the same file already open that subtab explicitly.
- The Fundamentals case expects `Strong businesses. Your shortlist.`, a
  `Reset filters` action and the old `ACC` fixture. The current product heading
  is `Business change research`; the reused fixture returns `UBER` and `FACT`.
  Search now has its own clear icon and threshold filters have a separate clear
  action. The case now tests that current workflow.
- The four Guru cases expect `Add a Guru` immediately after entering Guru.
  `GuruDiscoveryDesk` now loads the style/performance comparison only after the
  `load-guru-study` button is pressed. The tests now load it, add from the
  directory and select the manager before inspecting quarterly holdings.
- A genuine, separate responsive issue was also observed: the English Guru
  comparison invitation at width 390 overflows **14 pixels to the right** in
  `lib/investment_guru_holdings.dart:122`. Its fixed horizontal row combines an
  icon, wrapped description and `Load comparison` button. That file is unchanged
  by AI Insights and had no working-tree diff when inspected. A responsive
  layout now stacks the action below the explanatory copy on narrow screens;
  the exception was not swallowed.

Focused AI Insights API, artifact, PIT, ranking and UI acceptance remain
separate from these repaired adjacent regressions.
