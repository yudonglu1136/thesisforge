# Backend recovery release preparation — 2026-09-27

Scope: public-analysis recovery, Portfolio background failure/version handling,
and frozen-price-vintage attribution for published rule portfolios. Frontend
changes and the 32 previously reported Flutter failures are **not** included
in this backend-only release. No historical model or strategy curve is rewritten.

## Gates completed

- Full backend (preceding batch, same application changes): 1,755 passed,
  15 skipped, zero failed.
- Required performance/transport regression suite: 60 passed. This is not a
  controlled latency benchmark and does not certify a p95 improvement.
- Archive installer plus targeted financial/queue/artifact tests: 30 passed.
- Real three-universe archive installed in a separate bounded temporary path:
  exact manifest `2e12b6a17897b9e8aa0fc295bd964e97096255ba92edb973ccf40738a6b1afbd`.
  Integrity, immutable/idempotent installation and rollback-manifest retention
  checked. Installation alone is not API activation.

## Production before-state, read-only checks

- EB: `thesisforge-api-prod`, `strategy-visible-90c2e09`, Ready/Green.
- Serving instance: `i-0eabc67533fb38fca`.
- Fact OS stack's `ApiInstanceId` still points to `i-0896b2f2f421b847b`.
  Do not dispatch installation to that stale target. Updating the stack target
  is a separate reviewed operation, not proof that current data is active.
- Private data-ready release:
  `ecb74372780f94328d3bc0c996741847ef689f73d31a80f72dddd44476fc734c`,
  scheduled 2026-09-25 04:30 UTC, six groups verified;
  `actualApiActivation=not_requested`. This has not advanced since the prior audit.

## Installation / rollback sequence (not yet executed in production)

1. Obtain a clean committed/published trunk source under the existing provenance
   gate. Preserve unrelated dirty/untracked work; no implicit stash/reset/removal.
2. Retain the previous EB version and data pointer; create required rollback
   material before activation. No user database or encryption-key replacement.
3. Deploy API code, then stage only manifest-listed archive objects through the
   existing private S3 namespace; verify compressed hashes and source identity.
4. Run `scripts/install-rule-ledger-archive.mjs --source <staging>
   --root /var/app/data/rule-ledgers --sha256 <exact-manifest-sha>` on the serving
   API host. Run archive verification as `webapp` as well. Publish files before
   manifest; preserve hash-named files and `manifests/<sha>.json` for rollback.
   A stale `.install.lock` requires checking that its writer has ended before
   explicit recovery; never automatically delete an occupied lock.
5. Run the existing full `fact-os-api-install.py`, with exact candidate/fence.
   Its actual-UID read, 14-table coverage, all-group identities and eight-artifact
   live ACK must pass; do not broaden Research-only activation or weaken ACK.
6. Verify authenticated Fundamentals, opportunities, strategy attribution in
   all three universes, Research, and Portfolio through the public frontend.
   Keep failed Guru/data freshness states honest; do not label health green
   solely because EB is green.
7. If activation fails, restore the prior pointer/EB version, retain new immutable
   objects for diagnosis, and preserve any user edits made during the release.

Current deployment status: **pending**. Other task files still block the source
gate; a user clarification on recoverable archival/ownership was requested.
No production write or secret-value access was performed during these checks.
