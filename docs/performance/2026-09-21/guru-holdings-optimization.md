# Guru holdings first-paint optimization

## Scope

- Runtime: Node v26.7.0.
- Read-only snapshot: `data/releases/thesisforge-20260920-v3/research.sqlite` (2.9 GB).
- Cutoff: 2026-09-21.
- Three independent runs, 60 HTTP samples per run, concurrency 20.
- Twelve report quarters intentionally exceed the bounded caches.
- Baseline: the old full Opportunities computation (ownership + every PIT valuation + quality + prices).
- Optimized: ownership-only Guru matrix followed by a separate selected-company detail request.

## Median of three runs

| Path | Wall median | Wall p95 | Server p95 |
| --- | ---: | ---: | ---: |
| Full Opportunities baseline | 7,454.9 ms | 13,534.5 ms | 1,080.6 ms |
| Guru holdings matrix | 135.1 ms | 166.6 ms | 10.0 ms |

Wall p95 improved 98.77%; server p95 improved 99.07%. The selected-company
detail path measured 27.1–29.3 ms in three cold ticker checks. These are local
measurements and are not production-network claims.

The ownership projection was byte-semantically equivalent in all 180 paired
samples. The 655-row initial response is 836,159 identity bytes and 83,858 gzip
bytes (89.97% saved), with semantic SHA-256
`81ad2b9ae4eaf0e5fddaef22051dffafe5b1aea0968620f94182a4d13a61ea0e`.

## Capital-structure review

The UI classification is deliberately not an investment score. “Permanent” is
reserved for structures with primary-source evidence that the manager-level
book is not subject to ordinary outside-investor redemption.

- Strict permanent capital: Warren Buffett / Berkshire Hathaway; Tom Gayner /
  Markel; Chamath Palihapitiya / Social Capital; George Soros / Soros Fund
  Management.
- Mixed capital: Bill Ackman / Pershing Square (closed-ended PSH plus other
  manager pools); Baillie Gifford (investment trusts plus open-ended funds).
- Owner/family capital, not strict permanent: Stanley Druckenmiller / Duquesne;
  David Tepper / Appaloosa.
- Historical vehicle: Nick Sleep & Qais Zakaria / Nomad.
- External/client capital or no verified permanent basis: the remaining 24
  profiles.

The server returns the category, bilingual explanation, evidence URL and
classification version with every Guru profile. The left rail can filter these
classes and persists the selection.

## Verification

- `node --test server/guruCapitalStructures.test.js server/investmentOpportunities.test.js`
- `node --test server/investmentWorkflow.test.js server/investmentSource.test.js server/investmentOpportunities.test.js server/guruCapitalStructures.test.js`
- `flutter test test/investment_guru_holdings_test.dart test/investment_guru_study_test.dart`
- `npm run test:performance`
- `flutter analyze`

Raw benchmark results are in `guru-holdings-run-1.json` through
`guru-holdings-run-3.json`. Reproduce with:

```sh
node scripts/benchmark-guru-holdings.mjs --samples 60 --concurrency 20
```
