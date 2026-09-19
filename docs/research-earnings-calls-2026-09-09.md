# Quarterly earnings research — local delivery, 2026-09-09

## Delivered

- Research → Financials & sources now exposes a fiscal-quarter selector with
  previous/next controls, Quarter recap, Management guidance and Call Q&A.
- Overview/Valuation management snippets link to this quarterly workspace.
- Reuses the existing PIT model history and stored bilingual transcript Q&A
  from the old terminal. It does not generate a new call summary, extract new
  transcripts, translate online, or change any valuation/model data.
- Recap compares four reported metrics and like-method published model nodes.
  It does not attribute the model change solely to the call. The lower latest
  financial-evidence table is separately labeled with its own fiscal period.
- All stored questions for the selected quarter are shown as expandable items;
  full stored answers, speaker/date and external source remain accessible.
  These are extracts, not a claim to have the complete transcript.
- Quarter browsing is an isolated read-only component: it does not change the
  global as-of date or personal forecast, and performs no save/write requests.

## Source availability actually checked

Local cutoff: 2026-08-28. No data refresh was performed.

| Security / period | Available quarters | Stored Q&A | Guidance excerpts |
| --- | ---: | ---: | ---: |
| NVDA FY2027 Q2 | 67 | 0 | 4 |
| NVDA FY2027 Q1 | 67 | 6, bilingual | 3 |
| NVDA FY2026 Q4 | Same history | 6, bilingual | 3 |
| GOOGL latest | 67 | 6 | Not part of focused visual check |
| ISRG latest | 67 | 0 | Not part of focused visual check |

NVDA Q2's existing coverage status is `transcript_not_in_source`. The UI keeps
the results and guidance and explicitly reports absent Q&A; it does not reuse
Q1 content. The fiscal label is FY2027 Q2, not calendar 2026 Q2.

An additional LSEG smoke check hits the **pre-existing** `sourceNode`
`missing_period_end` gate in the common PIT adapter. It remains blocked rather
than inventing a period end. This change does not assert all-security data
coverage or repair that separate financial-lineage issue.

## API and temporal safeguards

`GET /api/investment/research/:ticker/earnings?asOf=YYYY-MM-DD&period=YYYY-QN`

- Authenticated, private/no-store, exact ticker and fiscal-period matching.
- Quarter menu comes only from PIT model nodes available by the chosen cutoff.
- Only the selected quarter's transcript object is extracted from the stored
  snapshot, not all historical answers or unrelated fields.
- Call/research-availability dates and each question's ticker, quarter and
  call date are validated independently. Future, mismatched and undated call
  evidence fails closed. Guidance must belong to the selected reporting
  quarter and be available by that model node.
- Later guidance target years never select the call. Q&A remains
  `includedInValuationInputs: false` and the archive is labeled retrospective.
- Client validates returned ticker/cutoff/period, handles a 12-second timeout,
  hides stale content on failure and discards out-of-order responses. Retry
  retains the requested quarter. No DCF or saved hypothesis state is touched.

## Verification results

- Flutter: **297 passed**, including 8 new tests for bilingual desktop/phone
  flows, all three tabs, exact dropdown selection, error/retry, response races,
  identity mismatch and empty coverage. No writes are permitted by the fixture.
- Backend investment suites: **59 passed**, including 6 new tests for fiscal
  identity, cutoff boundaries, Q&A availability, missing-vs-zero, comparable
  method changes, authenticated routes and unchanged source JSON.
- Transport/performance regression suite: **41 passed**.
- `flutter analyze`, `npm run audit:i18n`, release web build: passed.
- Real browser: selected FY2027 Q1 with arrows and FY2026 Q4 with the dropdown;
  verified Q&A count/content, Chinese expansion and 390×844 layout. No captured
  browser console errors. Desktop 1487×1058 checked visually.
- Screenshots in `output/personal-valuation-20260909/`:
  `earnings-qa-desktop-en.jpg`, `earnings-mobile-en.jpg`,
  `earnings-mobile-zh-expanded.jpg`.

### New-route local load characterization

NVDA FY2027 Q1, local SQLite/API, 3 runs × 60 samples, concurrency 20:

| Run | p50 ms | p95 ms | JSON bytes | Distinct hashes in run |
| --- | ---: | ---: | ---: | ---: |
| 1 | 379.09 | 422.68 | 51,127 | 1 |
| 2 | 367.05 | 596.80 | 51,127 | 1 |
| 3 | 370.50 | 388.40 | 51,127 | 1 |

Median-run p95: 422.68ms under 20 concurrent requests. This is a new endpoint,
not an optimization comparison or a production latency claim. Existing
landing/research payloads and their caching contracts were not changed.

## Deployment boundary

Local backend restarted with its existing isolated preview databases and
scheduled writers disabled; frontend rebuilt to the existing port-5184 local
preview. No GitHub push, AWS deployment, Vercel deployment or production data
mutation. The local dev-bypass build must not be deployed to production.
