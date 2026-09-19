# Launch data gate — 2026-09-13

Status: **HOLD — no new production promotion in this verification turn.**

The redesigned frontend was already deployed in the preceding rollout. This
record does not certify complete data readiness, and does not supersede the
failure results below. Tests passing is not a data publication certificate.

## Verified live state

- Both thesisforge.tech and www.thesisforge.tech serve the same redesigned
  main.dart.js artifact, SHA-256
  `817cc6b776adef75d3ada775a9df1fdfab671b6b14be08a485425b64d511e8f3`.
  Its compiled workflow-enabled marker and build metadata match.
- AWS remains on `guru-redesign-20260912-47973e1`; the public data release is
  `redesign-20260912-v1`. No new release, git push, AWS data mutation, index
  installation or private-portfolio mutation was performed in this turn.
- Anonymous investment, portfolio and admin requests remain 401/no-store;
  internal operations remain inaccessible. This is not authenticated end-user
  acceptance. Existing owner-only administration was not changed.
- AWS root free space was 14,552,014,848 bytes (14.55 GB decimal). Services were
  active, no release upload remnants were found, and the previously removed
  inactive raw audit copy had not returned. The compressed recovery copy and
  existing rollback snapshots were preserved.
- Three immutable deployed public artifacts have exact local counterparts.
  Read-only business-key checks on those counterparts covered 36 selected
  tables: research 12, strategy 20, composition 4. Duplicate-key groups,
  null/empty keys and foreign-key violations were zero; source fingerprints
  were unchanged. The full key/count receipt is
  [public business-key audit](public-business-key-audit-2026-09-13.json).
  This checks row-key integrity, not economic truth, all
  possible semantic duplicates, or complete history. Repeated observations in
  purpose-specific derived stores are not automatically accidental duplicates.
- Previously verified encrypted user-data backups remain available. No user
  account, broker credential or private holding was replaced with local data.

## Failed release gates

### 1. Official Defender sources require repair, not just security mapping

See [source integrity audit](guru-source-integrity-2026-09-12.md) and its JSON
receipt for exact official URLs, source hashes and evidence.

The 2022 Q1 original MIR row reported 628,200 in thousands of USD for 60,000
shares; a later official restatement reported 628 with the same shares. This
single-row change reconciles the entire cover-total difference. The June
restatement cannot be used as information available at the April filing date.
The amended table was independently checked against its cached bytes.

The 2025 Q3 original has 35 unrelated issuer rows with the same placeholder
CUSIP, `000000nan`. Existing aggregation collapsed them into one position.
The installed-byte-identical strategy warehouse marks that one row unresolved,
not a tradable COST position. The false COST mapping occurred in an earlier
staging artifact and is not a claim about the live UI. No official corrective
amendment was found in the reviewed submission response.

New parser guards reject positive-economic placeholder identifiers before
resolution and aggregation. Historical holdings and exposure loaders propagate
the failure instead of silently skipping the affected quarter. This bounded
code repair does not retroactively repair stored rows or implement amendment
event-time policy.

### 2. Redesigned Guru data is incomplete and has stale cache identities

The new frontend reads the isolated research database; legacy /api/health
reads a different SQLite database. Passing schema compatibility on one does
not certify readiness of the other.

The installed research artifact has 29 of the required 33 manager exposure
profiles. William Heard, Evan McGoff, Michael Cuggino and John Stamas remain
missing from the redesigned research profile bundle. Required curves are
derived from 32 enabled managers and 5Y/10Y windows: 64 rows, not a selected
handful. At current security identity, 56 stored strict rows are incompatible
and eight are missing, so none of those stored rows constitutes a current
release-ready result.

A separate earlier isolated recomputation reports 62/64 displayable diagnostic
rows, with Stamas failing both windows. It is not a shared-generation release
attestation and does not resolve the newly established source defects. The
four-manager staging audit also retains 37 unresolved older original filings;
full historical backfill cannot be claimed.

The new read-only `scripts/audit-investment-guru-readiness.mjs` checks the
actual dynamic catalog, manager/filer joins, snapshot/exposure consistency,
both required windows, current methods and security identity, strict/proxy
quality and linkage, turnover reconciliation, common SPY sessions, dates and
explicit publication generation. It refuses WAL inputs before SQLite opens
and does not initialize a legacy/private database. A diagnostic without
generation and not-before arguments must fail publication readiness.

### 3. Actual AWS health exceeds its existing deadline

An exact production-path read-only profile took 13,049.52 ms, above the 8,000 ms
health worker deadline. Valuation summaries consumed 5,164.96 ms, price
summaries 3,439.46 ms and the unchanged 64-row curve audit 4,239.69 ms. The
audit correctly reported all 64 current-generation rows failing; speeding it
up must not change that result.

The prepared fix adds four optional indexes and equivalent scalar aggregate
queries. It does not cache a healthy answer, weaken the matrix, raise worker
memory/deadline caps, or create indexes at request/startup time. Index
installation is an explicit backed-up, exact-file-identity maintenance action.
Its local benchmark does not certify production timing and it has not been
installed on AWS. Reserve index/WAL space in the next storage preflight.

## Tests and scope

- Clean release-clone backend suite: 1,263/1,263 passed, as recorded by the
  backend task.
- SEC/13F targeted tests: 46/46 in the clean clone; 48/48 in the main worktree,
  which contains two additional pre-existing tests and a legacy source parser.
  Those unrelated main-worktree changes were preserved, not silently copied
  into the release closure.
- New Guru readiness tests: 13/13 independently rerun by the release owner;
  16/16 with the existing read-only compatibility smoke.
- Existing performance regression tests: 53/53 passed. In a same-database
  health-only benchmark (three runs of 60 requests per mode, concurrency 20),
  median P95 fell from 1,165.96 to 218.59 ms (81.25%); all 360 responses had
  identical complete hashes. This is not production timing or a replacement
  for the separate seven-route HTTP performance gate. See
  [health performance evidence](../performance/2026-09-13/health-indexes.md).
- Root review: parser diff, read-only readiness implementation/tests, index
  definitions and explicit maintenance installer; tracked diff whitespace
  check passed.

## Required before the next push

- [x] Verify deployed frontend identity and both domain aliases.
- [x] Recheck duplicate business keys and current AWS disk headroom.
- [x] Preserve user stores, encrypted backups and existing rollback copies.
- [x] Block invalid identifier aggregation and silent historical omission.
- [x] Add a distinct redesigned-Guru readiness gate.
- [x] Prepare a semantics-preserving health performance fix and tests.
- [ ] Implement and audit a general amendment event-time policy. Preserve
  originals and restatements separately, with actual acceptance timestamps.
  Handling a rejected original requires an explicit source-quality policy;
  later corrections cannot be backdated.
- [ ] Obtain authoritative exact identifier repairs for Defender 2025 Q3,
  resolve the older original-source gaps, and rebuild derived rows. Do not
  use guessed identities, silently omit quarters, or relabel old curves.
- [ ] Build one source-aligned public research/strategy candidate with all
  required profiles and a new publication generation. Fully recompute and
  validate the 64-row required matrix; do not exclude failing managers.
- [ ] Revalidate actual financial freshness separately when the paid financial
  API is renewed. Prices through 2026-09-11 do not imply updated financials.
- [ ] Run storage preflight and idempotent installation planning. The current
  14.55 GB free does not support blindly retaining another complete 8.4 GB
  public release while honoring the existing 10 GiB headroom floor.
- [ ] Take fresh verified private backups/completed rollback snapshot before
  any production mutation, install only the audited release/index changes,
  and verify full data health plus production performance.
- [ ] Complete authenticated desktop/mobile portfolio, Guru, strategy and
  admin-isolation acceptance; only then mark the release ready.

No additional infrastructure budget was introduced. Existing online service
remains in place; there is no background deployment scheduled by this record.
