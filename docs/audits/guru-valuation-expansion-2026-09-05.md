# Guru valuation coverage expansion — 2026-09-05

## Decision and release status

**RELEASE BLOCKED — selected repairs and isolated model checks completed; coverage remediation is incomplete and zero new valuations are released or deployed.**

The screenshot's TBBB gap is real: a Guru security identity and local financial
history do not automatically create an active, reviewed valuation model. The
new additive Guru universe is separate from the S&P manifest. CROX, POWL, SOFI
and CRDO have reviewed private inputs and reproducible isolated candidates
(177 total model nodes). They have NOT passed the complete additive production
release. TBBB remains unreviewed for generic historical modeling; its independently
checked current economic scenario now has a normal, priced snapshot adapter,
but is not integrated into the atomic release. No commit, GitHub push,
AWS valuation migration or Vercel deployment was made. Existing production
coverage remains 533 snapshots / 532 positive values, not expanded coverage.

The model-audit workflow separated reported data, management guidance, analyst
assumptions, economic claims and release approval. In particular, it prevented
using a generic high-margin operating-company DCF for a thin-margin IFRS retailer.

## September 6 latest verified checkpoint — not complete

The latest complete economic replay uses the currency-70 V32 source and the
reviewed four-company manifest. Two actual V5 imports each contain **537
snapshots / 32,130 model nodes**. Reads taken after both writers stopped have
identical model and snapshot signatures; this proves deterministic computation,
not correct assumptions or release approval. The prior V3 signature report is
not the current attestation because English Q&A enrichment subsequently changed
one of its candidate files.

The full V5 diagnostic passes arithmetic, dated financial/model inputs,
retained guidance lineage, unexpected reporting-gap and temporal-jump checks.
It still fails guidance eligibility and Q&A checks. The exact, overlapping
finding counts are:

| Check | Unresolved findings |
| --- | ---: |
| Source currency | 33 |
| Quantified original evidence | 449 |
| Semantic classification | 181 |
| Guidance coverage-summary reconciliation | 2 |
| Research-only evidence selected into models | 904 |
| Monetary contributor reconciliation | 392 |
| Other scalar contributor reconciliation | 399 |
| Scalar research-exclusion reconciliation | 420 |
| Usable quantified guidance not consumed or explained | 201 |

These overlap and are **not** counts of distinct incorrect companies. There
are 365 distinct tickers with a guidance finding. Whole-platform coverage is
still incomplete; only CRDO, CROX, POWL and SOFI have new reviewed historical
model candidates. TBBB remains a separate current-only scenario candidate.

Seventy exact monetary events now have independently verified dated primary
currency evidence. The last batch adds DIS 14 / legacy Cigna 4 and reduces
currency flags from 51 to 33 with the same checker; it approves neither their
amounts nor their use in an economic model. Raw quotes, dates, amounts,
financial rows and unrelated data remain unchanged by that currency batch.

The named-month-quarter regression is repaired and checked in actual models.
STX's 2024-Q2, Q3, Q4 and 2025-Q1 nodes again retain quarterly revenue guidance
of $1.65bn, $1.85bn, $2.10bn and $2.30bn respectively. The candidate Q3-to-Q4
fair-value ratio changes from 4.9697 to 3.1144; no source amount or chart point
was manually edited. This is a parser regression repair, not approval of a
STX investment thesis.

A separate V33 EPS draft preserves 71 original IDs, eight existing siblings
and three newly retained genuine occurrences. It is **not integrated** into
the V32 source. Four explicit current targets pass independent review; four
malformed transcript targets and one ELV lower bound remain open. Root fixed
the additional audit defect where setting an ambiguous scalar to null could
hide a declared pending original-source review. All four actual unresolved
events now fail explicitly; 244 focused Node tests pass. The underlying
original-source ambiguity is not thereby resolved.

The actual strict verifier was also run with its normal gates enabled. It
passed integrity, non-valuation table counts, the complete ticker set and
tracked comparison-price coverage, then stopped on 61 snapshot local-path
leaks in newly retained comparison-price evidence. The importer now converts
those source origins to artifact references while retaining original hashes,
prices and private originals. A regression test and both new V5 actual imports
pass the path check: **61 affected snapshots → zero path leaks**, with the
complete economic-model signature unchanged from V4. The default strict
verifier now advances beyond that gate and correctly stops on Q&A completeness.

Normal English-Q&A enrichment was then run on two new copies, leaving the
pre-enrichment V5 databases frozen. Both copies have 32,130 coverage statuses,
1,287 Q&A-bearing periods and 7,340 pairs. Their model and snapshot signatures
are identical and the economic-model signature is unchanged. The Q&A checker
now reports 108 pairs missing Chinese (the new CRDO history) plus a missing
current complete translation audit. Existing Chinese text is not automatically
approved by being present; scoped reviewed replacements are retained separately.

The final source/target-bound Q&A package is
`prior-qa-frozen-handoff-v4-20260906/`. It contains 289 consumable fields: 73
full-field semantic reviews, three local CRDO expression corrections and 213
retained exact earlier CRDO reviews rechecked mechanically. The same final v8
guards were rerun on all 14,678 reconstructed targets: 13,684 mechanically pass
and 994 require investigation. Mechanical success is not full semantic or
provenance approval: 14,389 fields remain outside the approved subset. Three
internally inconsistent English sources are preserved as warnings, not silently
repaired into financial facts. All seven final package files reproduce byte for
byte; 42 targeted Python and six JavaScript tests pass. None of this package
has been attached to production.

Latest full server suite: **1,031 passed**. Performance/transport: **41 passed**
(overlapping the server suite, not 41 additional unique tests). Frontend has
122 passing tests; analyzer, i18n, Ontology checks and the production web build
pass. No production browser verification or release-audit pass is claimed.

Frozen V5 private evidence is under
`additive-full-rebuild-v30-four-20260906/`:

- `model-consumption-v5-source70-reviewed-audit.json`
- `model-consumption-v5-source70-two-run-signatures.json`
- `model-consumption-v5-source70-qa-checkpoint.json`

Source SHA-256:
`528fa292ba9a9a3e934aa02f8afd1217cdd47439e2cd5ce21a099ea2f0ebd55c`.
Model signature:
`f31c734c64bdf8575cecd99c16111002f2ee449a01c103005dcf97f7b9669ad5`.
Pre-enrichment V5 snapshot signature:
`ac676fda711990696aa34f49c25554116561ad720e573591e54be53bd7f05116`.
English-enriched copy snapshot signature:
`bd3127fe7de59cbccfa4d61c0f7874b561c78e47a0d3c0b1e44f61d295fda314`.
No production data was replaced, and no GitHub push or deployment occurred.

## Earlier September 6 completion checkpoint

This checkpoint supersedes the earlier source-stage counts below; it is still
not a release or an assertion that all Guru securities are covered.

- CRDO has two independently prepared 19-node candidates with identical model
  and snapshot signatures and no isolated audit failures. Every node has a Q&A
  coverage status; 108 pairs are bilingual and one period explicitly lacks a
  local transcript. See `crdo-valuation-gap-2026-09-06.md`.
- The other three reviewed additions retain 158 isolated audited nodes. The
  full additive import now completes: **537 snapshots and 32,130 model nodes**,
  retaining the 533-security baseline and adding four exact securities. This
  is successful private model generation, not a release-audit pass.
- The 532 old issuer profiles are bound to the prior Git-tracked audit and
  exact model signature. Only unchanged profile/parameter review is inherited;
  new financial, guidance, currency and model outputs are not approved by this.
- Twelve previously incomplete official-guidance reviews and the scoped DGE
  dated-currency repairs are merged without altering unrelated inputs. Thirty-
  four original-document-bound monetary-guidance currency repairs are applied
  to the additive source. Financial rows, claims, source amounts and dates stay
  exact. These changes do not touch Guru prices or backtests.
- The pre-v31 536-issuer source audit has 86,439 events, 15,958 usable and 70,481
  research events; official coverage has zero missing/incomplete rows. It still
  reports 650 flags: 68 currency, 410 quantified-evidence, 172 semantic and two
  summary mismatches. Flags are not a count of proven wrong stock valuations.
  Shared-parser improvements are under separate replay and review.
- The original comparison-price blocker is resolved in a private seed: 76
  exact same-day source conflicts across 61 tickers were reconciled to original
  paid closes. All 537 snapshot-price merges pass. No tolerance changed and
  the separate Guru `price_points` table and backtests remain exact.
- The first full independent model diagnostic has zero arithmetic/source-date
  model failures or unexpected modelable-period gaps, but **fails the guidance
  consumption audit**. It found 8,900 selections of research-only evidence
  (8,197 distinct IDs), chiefly unresolved target periods; overlapping scalar
  and contributor flags must not be counted as distinct wrong valuations.
  Producer repairs are pending actual full-model regression. Old strict source
  flags, stale replay lineage and bilingual-Q&A approval also remain blockers.
- The full normal English Q&A enrichment now covers all 32,130 nodes with an
  explicit status and attaches 7,340 pairs. This does not assert 32,130 local
  transcripts exist. Recovered old Chinese text still needs exact cache/output
  binding and current guard checks; old aggregate approval is not inherited.
- The v32 old-source delta and CRDO's actual replay of 18 original transcripts
  are merged into a new source: 86,520 events. Source/financial/profile/coverage
  invariants remain exact outside those explicit transcript changes. Currency
  evidence additions remain a separate, hash-bound lane, not numeric approval.
- TBBB's current-only snapshot now includes the original September 4 paid quote
  with independent SEP security-currency evidence. Its two renderer replays are
  byte-identical; cash-flow assumptions and fair value are unchanged by price.
  The summary API preserves its scenarios, null financing-stress target and
  bilingual cautions without returning full source/forecast payloads. It still
  has only one approved current scenario point, not a historical DCF curve.
- Latest whole-server checkpoint is 917 passing tests (before subsequent lane
  additions). Whole-Flutter is **122 passes** including current-only EN/ZH
  desktop/mobile tests; analyzer and i18n pass. Current API performance/transport
  regression suite is **41 passes**, including summary byte-budget checks.
  Final all-repository gates, two full deterministic imports, a zero-P0/P1
  ledger and production checks are pending.

Private scaffold: `additive-full-rebuild-v30-four-20260906/` under the expansion
output directory. Its `source-profile-currency34.sqlite` hash is
`7f68d3e40c32c9f3fe38f712f55c837dcb94045ef4b9db3e0961e2a6eb43bdcb`;
the exact four-company composed manifest hash is
`7776e10497275daf5798f4ef48d1489ab95bbc2c42359a730b0c86f2dc28f112`.
Neither artifact grants release approval or activates production coverage.

## Actual user-visible coverage and full-book inventory

The later read-only inventory supersedes any claim that the initial 304-name
batch represents the whole platform. These populations have different grains
and must not be added together:

| Population | Total | Matches a published valuation | Missing valuation | Other identity problems |
| --- | ---: | ---: | ---: | ---: |
| Current main dashboard clickable research targets | 749 | 301 | 448 | 117 additional identity keys outside the 749 |
| Dashboard plus single-Guru snapshots and latest Q2 position trajectories | 754 | 301 | 453 | 128 additional identity keys |
| Above plus all stored historical position trajectories | 883 | 350 | 533 | 427 additional identity keys; nine of the 883 are issuer-text fallbacks |
| Complete snapshot-designated official Q2 common-long books | 3,555 CUSIPs | 429 | 884 resolver-ticker candidates without valuations | 2,242 without old-resolver tickers |

The complete Q2 book uses all information-table rows for 28 managers: 4,715
manager-by-CUSIP positions before cross-manager deduplication. Nick Sleep's
2014 book is excluded. All snapshot-designated original tables were obtained,
but SEC submissions were not refreshed to rule out newer amendments. Matching
a published snapshot proves routing coverage only, not model correctness or
current API/browser success.

The local metadata follow-up examined all 38,764 SF1/SEP metadata rows, using
exact nine-character CUSIPs only. Of the 2,242 old-resolver gaps, **2,022 have
one exact local permaticker/ticker candidate**, none have multiple permaticker
candidates, and 220 have no SF1/SEP match. Twenty-seven candidates are marked
delisted. These are identity-review candidates, not approved models; the 220
are not proved absent from ETF/SFP metadata, which was not queried. Of the
884 old-resolver candidates, 57 rely on issuer-name overrides rather than
exact CUSIPs. At least 49 full-book CUSIPs are known funds/ETPs and must not
receive a generic operating-company DCF.

The inventory also found nine issuer-name-as-ticker research entries, seven
managers whose saved holdings stop at 80 rows, and four stored summaries with
preferred/unit/warrant classification differences from the current raw-table
rules. These findings are **not yet repaired**; no Guru table was changed.

Private reproducible inventory: `guru-visible-valuation-coverage-20260905-v2.json`
(SHA-256 `d8a5459b7195e5b62637ec773beb021fc1c42c6f7b225239b1c811a28891c68b`).
Exact local candidate audit: `guru-full-book-local-exact-cusip-20260905.json`
(SHA-256 `cc67ca4c4c7a99a19d9b55be89d3697e42314b7b08746d77f75c8e729ce264f0`).
Raw licensed metadata and financial histories remain ignored and private.

## Frozen scope and inputs

| Measure | Result |
|---|---:|
| Released valuation-only baseline | 533 tickers; 532 positive fair values |
| Latest selected book | 2026-Q2 |
| Exact-identity local-data gaps in that selected book | 304 |
| Additional identity gaps / fund securities | 9 / 16 |
| Additional unresolved CUSIPs | 17 |
| Raw earliest ARQ/ART rows staged | 34,339 |
| Normalized candidate financial rows | 34,289 |
| Covered / annual-only / external-FX-required financial inputs | 296 / 6 / 2 |
| Issuer economic reviews pending | 304 |
| Local transcript files / issuers / extracted raw events | 108 / 7 / 728 |
| Newly approved / published fair values | 0 / 0 |

The 304 pending states above belong to the mother input stage, not the separate
reviewed manifest. Later work has generated three isolated models (158 nodes),
and current-only research modules for TBBB, IOT and SPOT. Neither count is a
production coverage claim. The financial/source cutoff is September 5, 2026;
latest comparison prices for the three-company batch are September 4.

The security master covers historical **top-60 common-long positions per filing**,
not all live holdings of every Guru. These counts must never be called complete
platform-wide coverage, especially for large quantitative portfolios.

Security-master record SHA-256:
`5838ab5b17dbcba1c89a951e074ff046cf84c202536dd96527c9275c68de5e26`.

Read-only valuation baseline SHA-256:
`1f4fd44f8535ffc47aae4be4697d55e41a04f3762c9d8bb462715be535719044`.
It is a valuation-only audit copy, **not** a complete production backup. The
repository's small runtime SQLite file is also not the complete production dataset.

A separate existing September 3 AWS backup was downloaded read-only. Its Guru
snapshot table contains only 29 profiles and large-manager holdings are capped
at 80 displayed rows. It does not cover the current 38-profile catalog or the
complete underlying books. It must not replace production or be described as a
fresh release/rollback backup. A NEW complete September 5 production backup was
subsequently obtained using temporary, source-IP-restricted EIC/SSH access.
It contains all 38 Guru snapshots, 533 valuation snapshots and 31,953 model
nodes. Integrity checks passed; independent S3 and SSH copies have the same
compressed SHA-256:
`20f943ce3b670739e6ee2430689cec3f98fc502b17b5e354c73bbcd2f7d996d9`.
The original EBS snapshot `snap-0e3bdae40a1791605` and encrypted rollback copy
`snap-09929a2bc5b5f6885` both completed. Backups remain private and retained.
The exact temporary TCP/22 rule `sgr-0e8d11f6d45e3c0df` was revoked and verified
absent; the generated local SSH keys and remote temporary helper were removed.
No application database or production valuation data was modified.
The final local read-back also streamed the retained gzip through its trailer
and compared the complete decoded file with the integrity-checked SQLite:
2,739,396,608 identical bytes, uncompressed SHA-256
`48ebd5798d59e1914273fe39a4811bae7db4e9c15547d1c9da8da54f731ff6d4`.

Licensed inputs and generated candidates are retained only under ignored
`output/guru-valuation-expansion-2026-09-05/`; no licensed financial/price history
was added to Git. The baseline was not modified.

## Implemented controls

- Exact CUSIP/local identity inventory; funds, missing identifiers, absent prices,
  and unreviewed economic profiles remain separate dispositions.
- Additive reviewed Guru manifest and profile resolver, preserving the S&P
  issuer/share-class invariant and all existing tracked extras.
- New, non-overwriting input stages with raw source preservation, explicit
  reporting-currency conversion, and a mandatory issuer-review gate. PEN and
  KZT stay blocked because no approved ECB pair exists for those currencies.
- Scoped official SEC review with target CIK validation, date windows, 6-K
  earnings-document discovery, and source-owned evidence replacement only.
  Failed reviews retain prior evidence and return a nonzero exit status.
- Currency/quality ambiguity cannot be relabeled as "no guidance." Bare `$`
  does not establish USD. Percentage-only guidance requires no FX conversion.
- Revenue growth cannot take same-store sales, store counts or segment revenue
  as the total-company metric. Fiscal results year and guidance target year stay
  separate.
- Independent original-evidence audits reconstruct metric ownership, date,
  currency, ranges and model selection. Every research-only event retains an
  ID, rejection explanation and original-excerpt hash. Aggregate growth now
  carries the actual contributing source IDs.
- Scoped transcript merge preserves official evidence and unrelated coverage,
  rejects future events and cross-owner ID collisions, and queues re-review.
- FX cache requests preserve previously cached currencies instead of discarding
  them when a new currency pair is loaded.
- Source/readiness reporting never counts extracted evidence as a released
  model. An incomplete source-only audit exits nonzero.

## Latest repair and audit checkpoint

- Official-source review of the first 16 issuers produced 333 raw events:
  95 independently eligible and 238 research-only at that checkpoint. TFX's
  two flattened tables still lack verified unit/column interpretation. This
  was a source audit, not model-consumption approval.
- CROX historical revenue ($4bn) was incorrectly labeled forward guidance;
  it now remains a historical actual. SOFI's multi-year CAGR cannot become
  next-year company growth. Quarter/full-year ownership, negative margins,
  EPS ranges and employee-versus-revenue growth received original-quote
   regressions. The frozen full-replay parser is v26.
- The new candidate parser briefly interpreted FFIV's FY2025 6.5%–7.5%
  growth target as -0.5%; v25/v26 correctly retain 7%. **Production v17
  already held 7%**: this was a candidate regression, not a production
  valuation repair. ARE EPS versus FFO, ordered parallel per-share values,
  and changes in guidance-range width now have separate economic owners.
  EPS 1.13 is not FFO 8.38; EPS 2.22 is not FFO 7.38; a range shrinking
  from 0.08/0.06 to 0.02 is not an EPS level. All FFO/width research evidence
  remains outside EPS/total-cash-flow inputs.
- Independent review found and fixed a further audit false-negative: a
  width-only sentence cannot excuse missing or incorrect EPS in a later
  sentence. Both the missing-value case and wrong 5.10 extraction from a
  5.10–5.20 range now fail the complete coverage check; correct 5.15 remains
  usable. Original historical EPS and additional width-only sentences remain
  research. The check does not trust producer offsets or selected values.
- An independent SEC statement-unit ledger resolved 30,853 dated targets.
  Every resolved claim was verified against cached original CompanyFacts,
  CIK, accession, filing date and at least two statement categories.
  A NEW full source copy preserves all 65,038 financial rows and appends only
  reporting-currency evidence to 61,706 rows. The main audit independently
  compared every original payload: amounts, source records, FX and dates are
  unchanged. The other 3,332 rows remain unchanged. Ambiguous and missing
  evidence is not converted to USD by assumption.
- Source-currency audit flags fell from 11,264 to 102 after that evidence
  enrichment. This is not a statement that all other source flags are errors
  or that every currency is resolved.
- All 182 previously flagged price differences were independently reconciled
  exactly to original Sharadar `close`. The old checker compared those prices
  with Yahoo rows having a different provider/adjustment basis. The new
  checker resolves the declared source before comparing values, binds PIT
  observations to exact model versions, and keeps strict tolerances. Import
  merging no longer overwrites a paid point merely because Yahoo was read
  last. No Guru price or backtest row was repaired or replaced.
- The model arithmetic/price-lineage inspector passed 31,953 existing nodes,
  including 31,636 stored positive comparison observations. This limited
  inspector does NOT certify guidance, source completeness or deployment.
- Full transcript replay now reports 85,751 unique events, 85,799 extraction
  occurrences and 48 identical duplicates. The original 48-occurrence
  discrepancy was independently reproduced; no conflicting payload was lost.
  Conflicting same-ID payloads now roll back instead of overwriting evidence.
- The v25-to-v26 replay preserved all 65,038 financial records, 533 financial
  coverage rows, 36,489 FX observations, 334 official guidance rows, and all
  86,085 source identities. Original dates, source URLs, excerpts, speakers,
  metric names and source files were independently compared for **every**
  guidance event and remained identical. Both source databases pass SQLite
  integrity checks. This proves preservation, not release approval.

The latest COMPLETE source-only diagnostic, across 532 financial issuers and
86,085 raw guidance events, remains **blocked**:

| Unresolved check family | Flags |
| --- | ---: |
| Quantified evidence / numeric ownership review | 686 |
| Currency review | 102 |
| Scope / subject classification | 209 |
| Issuer review coverage | 12 |
| No-quantified / coverage summary reconciliation | 2 |

These are audit flags, not counts of proven incorrect valuations. Some still
represent helper false positives; they require original-source resolution.
The v26 assessment marks 15,861 individual events usable and 70,224 research;
it has **not audited their consumption by a new full model release**.
Final source-only audit SHA-256:
`387c2653af3c52ea00d351f30f84a6cfad6f8858a5d37f336aa0233385899c39`.
The independent follow-up rechecked both newly discovered EPS false-negatives,
the valid 5.15 case, forged producer offsets and the historical/width controls.
It found no further issue within that narrow review, not across every remaining
source quotation. Final coverage-checker SHA-256:
`abbc269e111657b99e3ea110f94e3700728ead59840a45f61d9471a3009fe4f9`.
The 12 incomplete transcript coverage states are BA.L, BF.B, BRK.B, CCEP,
DGE.L, ED, ERIE, EXPD, FER, NVR, SPCX and VMRK. Existing official evidence is
preserved but cannot be automatically called a fresh complete source review.

## Two-run isolated model result

`reviewed-three-run4` and `reviewed-three-run5` both report
`model_checks_pass_full_release_pending`: three exact securities, 158 model
nodes, 52 raw guidance rows, no diagnostic failures. Their signatures agree:

- Models: `77fbff378248763d86552b917e9fc1a8df1ef36ca516a77ec02360d9f5b1bafa`
- Snapshots: `cb8f8f61ed3e526669986c0d240e592e27d8e8b7a736d62dd8fab6e50a24511e`

Every node explicitly records transcript/Q&A unavailability; there are no
local CROX/POWL/SOFI transcript files and no fabricated Q&A. These are isolated
candidates, not full runtime replacements. Current-only IOT/SPOT methods and
cash/claims assumptions are documented in `guru-current-iot-spot-2026-09-05.md`.

## Earlier official review checkpoints (superseded by the latest section)

The first scan attempted all 304 issuers in the January 1–September 5, 2026
window. It found 39 issuers with document access/parse failures. A subsequent
207-issuer scoped replay applied the stricter currency/quality rules and merged
the seven local transcript issuers without dropping the other coverage rows.

At that v6 checkpoint, the 304-row coverage ledger contained 17 accepted official
extractions, 156 with no accepted quantified extraction in the scanned window,
and 131 incomplete reviews. **The 156 are not a claim that these companies never
issue guidance.** The independent source-only audit found 2,265 raw events,
492 individually eligible events, and 1,773 research-only events; the batch
still failed. There were also seven specific scope/range conflicts requiring
original-quote review. Later corrections, if any, are recorded in the generated
`guidance-evidence-audit.json`; these checkpoint counts are not a release pass.

The six-issuer correction replay fixed DUOL and ELF percentage-range midpoints,
CHYM's long-term-target classification, IDCC's actual-versus-old-outlook
classification and INIO/NE fiscal scope. INIO/NE monetary currency remains
unresolved. The latest complete 304-row extraction ledger has 17 accepted official
extractions, 155 with no accepted quantified extraction in the scanned window,
and 132 incomplete reviews. A final v7 replay covered **TBBB only**, adding its
capital-budget research event while preserving the two growth-guidance events.
The latest scoped review therefore does not replace the all-issuer denominator;
`latestScopedReviewFailedTickers` is not the all-issuer failure denominator.

That earlier independent source-only check was **blocked**: 2,266 events across
169 issuers and 475 periods; 463 eligible events and 1,803 research events. It
flags 68 quantified-evidence extraction-review cases, 20 semantic-classification
cases and two aggregate coverage reconciliation failures. These flags still need
original-source resolution; they are not all independently confirmed issuer-data
errors. In the separately frozen 45-quote regression set, 42 helper false positives
were corrected and three genuine scope mismatches were retained. That bounded
result must not be reported as a pass for the entire source database.

## TBBB: verified facts versus assumptions

The [March 11 official FY2025 release](https://www.sec.gov/Archives/edgar/data/1978954/000119312526102363/tbbb_4q25_earnings_relea.htm)
provides **FY2026 total revenue growth of 29%–32%**. The arithmetic midpoint is
30.5%; it is not a management monetary revenue or FCF target. Both the table and
paragraph are now stored with the original March observation date, FY2025/Q4
reporting period, and FY2026 target. The Q2 release must not falsely re-date or
reaffirm that earlier guide.

The [Q1 management discussion, p.9](https://www.sec.gov/Archives/edgar/data/1978954/000119312526241914/tbbb-ex99_2.htm)
also contains a **FY2026 capital investment budget of MXN 5,250m**, including
3,555m for new stores and 490m for four distribution centers. The 1,205m residual
is unclassified, not a disclosed maintenance-capex amount. Q1 deployment was
1,089.705m, whereas cash PPE purchases were 706.574m. The program includes noncash
investment; its full-year cash-only portion remains unresolved. The economic
evidence module now preserves this budget and its May 27 availability date,
with an explicit not-consumed reason pending the cash/noncash financing bridge.
Do not describe TBBB as having no capital-investment guidance or treat the entire
budget as a second deduction on top of related lease payments.

The [TBBB Q2 2026 earnings release](https://www.sec.gov/Archives/edgar/data/1978954/000119312526346965/6k_tbbb_2q26_earnings_re.htm),
together with the [FY2025 annual report](https://www.sec.gov/Archives/edgar/data/1978954/000119312526140232/tbbb-20251231.htm),
it reconciles the local trailing figures as FY2025 + H1 2026 − H1 2025:

| Cash-flow bridge, MXN million | Amount |
|---|---:|
| CFO | 7,011.837 |
| Net PPE capex | −3,772.646 |
| Unadjusted CFO minus PPE | 3,239.191 |
| Financing-classified lease principal | −885.754 |
| Financing-classified lease interest | −1,637.335 |
| Other debt cash interest | −110.792 |
| Intangible investment | −27.855 |
| Intermediate cash after these deductions | 577.455 |

**577.455 is not normalized FCFE or management FCF guidance.** Noncash-financed
equipment, sustainable reinvestment, future equity grants and financing policy
still require a forecast. Supplier-finance repayments must not be deducted
again when the supplier payment already passed through operating cash flow.

TBBB is a directly listed common share, not an ADR. The official June share
count is 121,187,774 across economic classes; the local basic share input differs.
Conditional awards and options are separate claims. Existing awards cannot both
be charged as an expense and counted again through dilution. A company example
using a $35 share price cannot become a fixed DCF denominator.

The [FY2025 option schedule](https://www.sec.gov/Archives/edgar/data/1978954/000119312526140232/R52.htm)
provides individual historical strikes and maturities, including legacy terms
running to 2036–2053. The June roll-forward by individual tranche is not yet
reconciled. The candidate's two rounded weighted-average pools therefore model
only a simplified conditional exercise scenario, not exact dilution: some
individual options can be in the money below a pool's average strike. The
explicit USD 25m sensitivity reserve did not establish their time value. Those
early pooled-option experiments are superseded as the latest research route.

The newer, still-unreleased underwriting module uses a conservative
172,019,688 current-claim upper bound, an explicit future-award schedule,
lease/interest-adjusted cash flows, a cash/noncash investment bridge, separate
USD deposits and local working cash, a stub period and dated ECB FX. It
calculates a base scenario of $5.5527 and upside scenario of $7.8521. The
downside is a funding-deficit scenario, not a financed positive target price.
These are analyst assumptions and research scenarios, not company guidance,
not exact option fair values and not an approved platform price. Integration,
independent full-release checks and historical availability policy remain open.

The standalone candidate module recomputes source revenue growth and solves
option dilution using its own intrinsic value, never market price. In the real
local latest-eight-period window, one comparator lacks revenue and is explicitly
omitted; seven valid comparisons give 35.06349% normalized reporting-currency
growth. A 25% weight on the 30.5% management guide produces 33.92262% before later
forecast assumptions. The actual guide is therefore used, but not allowed to
replace all of the financial trend.

Earlier **unapproved sensitivity experiments** were computed with explicit cash
margin, future-grant cost, option reserve, Ke/g, stub-period and constant-FX
assumptions. They are not a defensible target-price interval and are not exposed
as platform fair values. Their full inputs/outputs live in
`tbbb-unapproved-scenarios.json`. Repeating the experiment produced the identical
SHA-256 `664e9710042825d719a7ae2e3454c61693bd98c4be6deebb69888f7140d67e06`
after attaching the newly verified capital budget and its not-consumed reason.
This is scenario reproducibility, **not** the required two-run release audit.

## Remaining release blockers

1. Resolve the audited visible/full-book identity gaps and confirm latest
   accessions, security classes and historical validity. The initial 304-name
   stage is only a bounded starting batch. Fix issuer-text research targets
   without silently substituting a different stock or claiming an approved
   valuation from a metadata match.
2. Finish issuer-by-issuer profile, reporting-currency history and quoted-security
   claim review; activate only reviewed entries. Do not map payment processors,
   lenders, REITs, pre-revenue biotech or asset-heavy retailers to generic DCFs.
3. Resolve official-file failures and ambiguous monetary/scope evidence using
   original issuer filings or IR releases. Re-run independent evidence checks.
4. Complete TBBB's current-model release integration and reviewed
   historical-node treatment. Integrate the independently audited economic cash field without
   a downstream CFO-minus-capex recomputation overwriting it.
5. Audit continued applicability of older annual guidance across later reporting
   quarters; preserve original dates and withdrawal/supersession rules. The
   current period-keyed production path is not proof of such carry-forward.
6. Build two complete, deterministic release candidates against a fresh runtime
   baseline; pass the strict ledger, all-ticker history, unchanged non-valuation
   tables, bilingual Q&A, API and browser checks before any deployment.
7. Resolve the actual EB/public-proxy readiness failure. The earlier 21:42 UTC
   eight-request burst timed out at 15 seconds with no response. A NEW burst at
   21:59 UTC returned eight identical HTTP 503 responses in 3,741–3,783 ms, all
   identifying `guru-analysis-dashboard`. Database, Guru data, valuation, market
   prices and Ontology were healthy. Guru curves were not: 14/56 current and
   displayable (10 strict, four proxy), with 42 freshness failures. This later
   result establishes response recovery at that observation time, not a fix
   for the earlier unexplained timeout or a healthy full platform. The eight
   response payloads shared SHA-256
   `556f3f67a5ab95a5cb7ea93260894f3f7ed97f767bfece4907bda2194ccb2ddb`.
   No health code, curve data, freshness threshold, service restart or deployed
   application version was changed. The separate API-subdomain service must
   never substitute for the website/EB readiness check.

## Verification record

The earlier complete server regression passed **648/648** tests. The targeted
Python suites passed **153/153**: guidance 125, coverage/staging/readiness 15,
source builder 9, FX 2 and scoped transcript merge 2. The TBBB economic/candidate
tests are included in the server suite. Broader Python PIT discovery initially
failed because the Jansen environment lacked `pypdf`; using an isolated `pypdf`
overlay with the existing dependencies then passed **112/112** tests, including
the unchanged UK PDF importer. This suite overlaps the targeted totals and is
not additive. The Jansen environment and project dependency manifests were not
modified. Test logs are retained with the private candidates.

The independent financial-ledger audit reconciled the actual read-only valuation
baseline against itself: **65,038 / 65,038 retained raw-period checks, zero
findings**. This confirms baseline compatibility, not a new issuer economic
review or a persisted two-run release ledger.

The latest complete server regression passed **844/844** tests. Price-source
and importer integration, exact model-version binding, historical-guidance
rejection, current-only economic models and negative tests are included.
Four backup tests additionally verify gzip read-back, reject mismatched/truncated
archives and prevent replacement of an existing backup. The targeted Python
run passed **239/239**. Final logs are `server-tests-v26-reviewed-final.log`
and `python-tests-v26-final.log`; the 232-test independent guidance subset
overlaps the server total and must not be added again. Python 3.14 emitted unclosed-connection resource
warnings in test fixtures; a passing count is not a claim of zero warnings.

The legacy all-ticker ledger was also re-run read-only on the NEW complete
production backup: 533 tickers, 31,953 nodes, zero P0/P1 blockers in that ledger,
423 watch groups (1,162 observations), and 7,232/7,232 bilingual Q&A items.
It audits the existing v55 outputs and retains their original model generation
date. It does not certify the unreleased additions or the newer independent
guidance-source checks. Its private output is explicitly named
`runtime-existing-valuation-ledger`, not a new production release ledger.

The actual staged guidance audit remains **blocked**. A full two-run release
database, persistent no-P0/P1 all-ticker ledger, authenticated UI test and
successful deployment have NOT been completed. The existing terminal and its
data have been retained. Neither a unit-test pass nor a source-only audit is
authorization to publish a value.

A sanitized machine-readable counterpart is
`guru-valuation-expansion-2026-09-05.json`. It records the blocked release,
distinct coverage denominators, tested repairs, evidence signatures and
unperformed deployment checks without distributing raw licensed inputs.
