# Four Guru additions — staged, not published

Status: **Needs revision / publication blocked.** The running preview and its
serving databases have not been changed. This is not a completed live import.

## Exact requested scope

| Investor | Reporting firm | SEC CIK | Available original quarters | Parsed quarters |
| --- | --- | --- | ---: | ---: |
| William Heard | Heard Capital LLC | 0001796409 | 27 | 27 |
| Evan McGoff | DOCK STREET ASSET MANAGEMENT INC | 0001172779 | 97 | 61 |
| Michael Cuggino | PACIFIC HEIGHTS ASSET MANAGEMENT LLC | 0001323414 | 83 | 82 |
| John Stamas | Defender Capital, LLC. | 0001766929 | 31 | 31 |

All series end at the reported quarter 2026-06-30, with actual publication and
acceptance timestamps retained. First available report dates are respectively
2019-12-31, 2002-03-31, 2005-12-31 and 2018-12-31. These are available firm
histories, not assertions of continuous personal-manager tenure.

Identity evidence:

- Heard: [firm leadership](https://www.heardcapital.com/senior-leadership/) and
  [SEC submissions](https://data.sec.gov/submissions/CIK0001796409.json).
- McGoff: [Dock Street](https://dockstreet.com/),
  [firm ADV](https://reports.adviserinfo.sec.gov/reports/ADV/111163/PDF/111163.pdf),
  and [SEC submissions](https://data.sec.gov/submissions/CIK0001172779.json).
  Firm history predates McGoff's tenure; the profile explicitly says so.
- Cuggino: [firm team](https://permanentportfoliofunds.com/our-team.html) and
  [SEC submissions](https://data.sec.gov/submissions/CIK0001323414.json).
  Filing-agent accession prefixes are not used as reporting CIKs. This 13F
  sleeve is not the full Permanent Portfolio allocation.
- Stamas: [Defender team](https://defendercapital.us/our-team/) and
  [SEC submissions](https://data.sec.gov/submissions/CIK0001766929.json).
  John Stamas is the CIO; the similarly named private-fund entity with CIK
  0001565991 is not the reporting firm used here.

## Implemented within the existing system

- Four catalog entries using existing fields, bilingual names/tags/notes,
  canonical IDs and 144-pixel portrait assets. No new UI components, scoring
  system or product schema fields.
- The existing SEC pipeline now reads strictly identifiable legacy text
  information tables. Exact CIK/accession/report-date guards prevent filing-agent
  or similarly named entity contamination. Unreadable rows, missing identifiers,
  unsupported amendments and conflicting legacy totals fail closed.
- Exact attachment resolution handles SEC archive filenames prefixed with the
  same accession number; it does not select arbitrary similarly named files.
- Heard's `EQUITIES` class label participates in the existing value-unit
  inference. This corrects 2020 Q4–2021 Q3 values from thousands to dollars,
  while whole-dollar filings remain unscaled. Options, the five-row minimum and
  existing ratio threshold remain unchanged.
- Defender's historical BioTime common-share CUSIP 09066L105 is linked to the
  continuing Lineage shares, using the issuer's
  [2019 name-change 8-K](https://www.sec.gov/Archives/edgar/data/876343/000149315219012036/form8-k.htm).
  It is not treated as a merger cash payout or an AgeX holding.
- Scoped staging, curve-preflight and audit scripts are repeatable and do not
  write serving databases. The existing SEC CUSIP manifest builder accepts an
  explicit manager allowlist; its default full-population behavior is unchanged.

## Data and calculation checks

The 201 parsed quarter books have no detected duplicate accession, duplicate
report quarter or duplicate aggregated holding ID. Shares and values are finite;
common-long weights and table/common-value totals reconcile internally.

An independent staged-output audit completed **6,243 checks** of current
holdings/ranks/weights, exposure top-10 ranks, concentration and raw
quarter-over-quarter share changes, with no arithmetic discrepancies. Exposure
histories use the existing 40-quarter capacity: 27 / 40 / 40 / 31 returned.
This check does not assert that source documents are error-free or that older
excluded quarters have been recovered.

The unchanged original-only policy excludes 13 amendments rather than merging
them into the original books. Raw SEC responses remain outside Git with URL,
fetch timestamp and SHA-256 receipts. All 600 cached source receipts passed
integrity checks.

## Unresolved source exceptions

- Dock Street: 36 older original filings fail the legacy parser because of
  missing CUSIPs or unreconciled source totals. Example: 2002 Q2 accession
  0001172779-02-000005 has a five-thousand-dollar table/cover discrepancy.
- Pacific Heights: 2008 Q1 accession 0000357298-08-000020 has 73 table rows but
  a cover entry count of 72. It is retained as an exception, not silently accepted.
- Heard: the 2021 Q1/Q2/Q3 original cover totals differ from summed reported
  rows by −3 / −2 / +6 thousand dollars. The unit fix does not repair these
  differences. 2020 Q4 reconciles after unit normalization. These cover checks
  are a targeted sample, not a full cover-total audit of every filing.

Consequently, **201 parsed out of 238 original quarters is not a complete,
source-reconciled historical backfill**. No missing identifier, holding or dollar
amount was fabricated to fill the remaining gaps.

## Performance preflight and release blocker

Candidate-only diagnostics using the existing engine produced:

| Manager | 5Y strict | 10Y strict | Separate proxy when strict unavailable |
| --- | --- | --- | --- |
| William Heard | insufficient_data | insufficient_data | proxy_ready for both |
| Evan McGoff | ready | ready | not needed |
| Michael Cuggino | insufficient_data | insufficient_data | proxy_ready for both |
| John Stamas | ready | ready | not needed |

Heard has historical execution-coverage gaps. Pacific Heights has historical
coverage gaps and a missing active FRCB price. No price interpolation, zero-return
substitution, reduced coverage threshold or new manager exception was introduced.
These are diagnostic artifacts from multiple generations, not a release-ready
shared-generation matrix. The 10Y option uses available history for younger firms.

The additions-only security-master candidate contains 387 observed CUSIPs,
305 resolved and 82 unresolved. It is **not installed and must not replace the
existing full security master**. Integration requires preserving existing records
and provenance, then recomputing dependent outputs.

The unmodified running preview already reports **0/56 current displayable
required curves** on 2026-09-12. The existing atomic catalog bootstrap requires
fresh 5Y/10Y outcomes for every enabled manager. Adding these four yields 64
required outcomes. Publishing therefore requires a broader existing-catalog
refresh, which was not performed under the instruction to leave unrelated data
unchanged. The atomic gate was not bypassed.

The strategy warehouse append, live API/UI readback, full release build and
atomic publication are still outstanding. The four profiles are in source code
and staging, not yet visible as installed Gurus in the running website.

## Tests and preservation

- `node --test server/*.test.js`: **1,472 passed**, zero failures.
- Four relevant Flutter suites: **35 passed**, including portrait fallbacks,
  Guru study/holdings and portfolio-Guru integration.
- `flutter analyze --no-pub`: no issues.
- Scoped `git diff --check`: clean.
- All 38 non-target catalog profiles match the pre-addition catalog exactly.
- Serving dashboard, Guru asset/snapshot/exposure, strict-backtest and proxy
  tables match the preflight database clone by row count and content hash.
- Serving SQLite `PRAGMA integrity_check`: `ok`.

Machine-readable evidence: [guru-additions-2026-09-12.json](guru-additions-2026-09-12.json).
Private source/candidate artifacts are in the sibling `guru-additions-20260912`
directory. Existing owner-portfolio, valuation and strategy data were not changed.

## Resuming safely

Resolve original-source exceptions with dated primary evidence, preserve existing
security-master entries when integrating additions, and obtain scope approval for
the required catalog-wide refresh. Then use the existing atomic bootstrap and
strategy warehouse importer, verify the four profiles through the API/UI, and
rerun the complete release checks. Do not publish the staged files directly or
treat this audit as an installer expectation/pass marker.
