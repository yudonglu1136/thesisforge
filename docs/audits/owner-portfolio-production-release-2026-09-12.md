# Owner Admin and portfolio preservation — production release

Released 2026-09-12. This is the reviewed account-safety code release, not the full local investment/factor/CTA application or a research-database replacement. The broader launch remains NO-GO until its separate data and infrastructure gates pass.

## Released artifacts

- Published trunk: `70b2ec2f339ae5cadd8aca696dd63c2372a3f517` (43 reviewed files, based on actual production `730dc21`). The large unrelated dirty local worktree was preserved, not packaged.
- AWS EB: `guru-owner-portfolio-20260912-70b2ec2`, `guru-analysis-api-prod`, Ready/Green.
- Vercel production: `dpl_JDRwWxSeNaq3GkE9wDXmsbrKTEbE`, READY.
- URL: https://thesisforge.tech ; https://www.thesisforge.tech . The stale www alias was corrected to the same release.
- Vercel artifact: https://fundamental-analysis-71mrzlyzk-yudonglu1136s-projects.vercel.app . Flutter production compilation took 37.7 seconds; total Vercel build/deployment duration was not separately measured.
- Code ZIP SHA-256: `ec739972a36418a7e61f856c5be1df9fbf1b7d33dc1b80cf8ba81acfe3b64031`.
- Frontend main.dart.js SHA-256, verified on both domains: `7a3f172e5758a4d0bd96bfa02a3bd0a879d1b6e6a0b2082dab4e4f58935d2159`.
- No database seeds, private stores, PIT imports, Ontology snapshots, frontend dist or real environment files were included in the AWS ZIP. Existing example environment templates remain source files.
- AWS configuration SHA-256 before and after: `0d121fd4ab6c7ecce6f960af5c9d72aa39591d85a39bd94d6c9f019cafe80ddc`. All configuration values, including original secret bytes and database paths, were unchanged.

## Account behavior

- Admin requires the server-verified identity of `luyudong1136@gmail.com`. Environment admin lists, anonymous/local-dev identities and client/body claims cannot grant access. Non-owner authorization is covered by automated tests; no other real customer's session was impersonated for testing.
- Owner's actual logged-in browser successfully rendered the production Admin console. An unauthenticated browser rendered the login boundary; Admin and Portfolio APIs returned 401/no-store. The internal user-data route returned 404/no-store. Portfolio responses vary on Authorization.
- Identity switches/signout clear old private state and invalidate in-flight results. Header navigation is bounded rather than overflowing at tested widths.
- Complete last-good broker reports are persisted using tenant-bound authenticated encryption. Failed/partial sync retains the dated report and never claims fresh success. No new financial source was substituted.

## Original-user preservation

The operator initialized reports only after the exact AWS version was Ready/Green, using the original application UID, environment, subject IDs, HMAC mapping and connection revisions. Runtime hashes were verified against the release. This operation did not replace any database and did not backfill NAV from current positions.

- 17 observed users, 2 connected accounts, 14 tenant databases (distinct populations).
- 2/2 broker reports persisted; 0 failures; report date 2026-09-11.
- 14 original owner mappings and 14 original tenant databases retained.
- 2 connection ciphertexts retained exactly.
- All 29 original NAV rows retained exactly, including metadata timestamps.
- 2 additive encrypted report rows; no old report removed.

The same exact preservation comparison passed between independently restored pre-deployment and post-deployment backups: zero missing databases, zero missing NAV rows, zero changed NAV values and zero changed NAV metadata. The read-only comparator is retained locally at `/private/tmp/tf-owner-release.L8Gx0Z/compare-preservation.mjs`; it emits aggregate counts only.

## Backup and rollback

Both checkpoints are encrypted in the existing private AWS bucket and were downloaded and independently restored with integrity/schema/digest checks. Both original credential envelopes decrypt; the second restore also verified both new report envelopes. The outer recovery key is private local custody, not uploaded beside the backup or committed.

| Checkpoint | Generation | Databases | Restored bytes | Encrypted objects |
| --- | --- | ---: | ---: | ---: |
| Before release | 4b7817cc-4c21-43cd-a0f4-16a216bc929d | 16 | 581632 | 18 |
| After release and priming | 8b7f7fd7-73cb-45a1-af98-b1db0f998f47 | 16 | 729088 | 18 |

Private recovery locations (outside Git): `/Users/yudonglu/Documents/thesisforge-private-user-recovery-20260912` and `/Users/yudonglu/Documents/thesisforge-private-user-recovery-postdeploy-20260912`. Protect these directories and their recovery keys; do not share them as release artifacts.

Encrypted EBS rollback copy `snap-064779969926f9020` was completed. Original AWS code version `guru-admin-20260906-730dc21` and Vercel `dpl_GmvxhpLbZNtgiVkTrgwiyFT8bAJ5` are retained. A code rollback must preserve additive user tables and subsequent user writes, never restore an old user database over current state.

Temporary UUID-tagged SSH access was own-/32 only; the final security-group readback showed no inbound port-22 rules. No new RDS, instance or load balancer was provisioned. Storage/request usage still incurs normal usage charges.

## Verification and limitations

- Exact AWS Node 22.22.3: full backend suite 554/554; performance/transport/static regression suite 41/41; operator suite 21/21.
- Both main and clean release full Flutter suites and analyses passed after the final nested-sync-response fix; 18 dedicated sync/UI cases passed. i18n and Ontology checks passed. Production dependency audit: 0 vulnerabilities.
- Public artifact hashes match the tested prebuilt frontend. Source provenance gate passed with a clean checkout and the actual remote trunk commit.
- Post-deployment error-log scan for the exact Vercel release found one `DEP0169 url.parse()` deprecation warning on the expected anonymous Admin 401. No application exception was present in that bounded scan. Log drains were not audited; continuous monitoring/SLA is not established by this check.
- Public `/api/health` still returns 503 for the pre-existing Guru simulation readiness problem. At 17:57 UTC its older production catalog reported 0/56 current displayable curves (pre-release sample was 1/56). Database, Guru data, valuation, market-price and Ontology modules reported healthy. Market source date was 2026-09-11 with 2,895,549 rows. No research data was replaced and no health gate was weakened.
- This is a real off-host backup checkpoint, not an installed recurring backup schedule. Consistency is per database, not cross-database atomicity. Full local investment release, full strategy/data acceptance, HTTPS-only upstream migration and recurring recovery operations remain separate work. Financial API refresh remains paused per user instruction.
