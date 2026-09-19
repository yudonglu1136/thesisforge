# Retained issuer profile provenance — 2026-09-06

Outcome: all **532 retained modeled issuers** have verifiable prior-release profile provenance. This is **not** a new source, model-output or release approval. No database or review status was changed.

## What was independently matched

The tracked `server/reports/valuation-audit-ledger.json` is byte-identical to Git commit `3588ce473798296cd9c8862466f81cff4ee53fb0`. Its original model implementation was last changed in ancestor `2ba8c91384c19d2218052ef0a1305ba46db65724`.

The complete production backup `runtime-production-20260905.sqlite` was read in a read-only transaction. Every one of its **31,953** model nodes was included in a full input/output signature. For each of 532 issuers, the audit checked the ledger's profile, node count, first period, latest period, latest as-of date and latest fair value. The ledger reports value to two decimals; the comparison rounds the unrounded baseline value to exactly that declared precision, not an arbitrary financial tolerance.

Both the explicit profile selection and every profile parameter were compared against the original Git implementation and S&P universe manifest. All **532** remain identical. There are **zero** profile-selection or profile-parameter discrepancies requiring a new profile judgment. Of the inherited ledger dispositions, **212** were pass and **320** were explained watch; watch flags remain attached rather than being relabeled clean pass. RKLX is the single non-applicable ETF and is excluded from the 532 modeled issuers.

## Source changes must not inherit approval

| Scope | Result | Permitted inference |
| --- | ---: | --- |
| Retained financial amounts | 532 unchanged issuer slices | Amount preservation only |
| Financial evidence/provenance | 526 changed issuer slices | Fresh currency/FX/evidence review remains required |
| Guidance evidence | 531 changed issuer slices | Fresh official-source, semantic, scope and PIT review remains required |
| New financial/guidance/FX/output approvals inherited | 0 | None |

The six unchanged financial-evidence slices are AZN, BA.L, DGE.L, LSEG, PDD and TSM. BA.L is the sole unchanged guidance-evidence slice. Unchanged evidence also does not bypass a stricter current validation rule.

The existing current-rule diagnostic of the exact baseline is **blocked**, including guidance lineage/classification/currency failures and 182 stored comparison-price unit mismatches. Those findings remain open. A historical ledger pass cannot certify their resolution. The shared implementation has changed since the original release; full candidate rebuilding, independent model checks and the two-run release gate are still required even though the profile parameters are unchanged.

## Binding identifiers

- Tracked ledger SHA256: `ab86e85d2be60c4f86dea0483ee35781e0b06ae31d8840960a98384acf6dbafd`
- Original model implementation SHA256: `ad3cc3a47822868ef263131f1278eb05698a10f24e049592a938c184f4d2b8d2`
- Original S&P universe SHA256: `6b31c3a5281b1199e5f956d08f4a96c134ba82b83fb735dcc280f976429b1086`
- Complete baseline model signature, using release-verifier canonicalization: `16925a5d4cc0ea156e6040aebb42ad4a95f08a1f592ee0095273367ce7a5dee2`
- Raw complete model-row signature, including stored run timestamps: `14d92c4eac226dc08e9da43b2848fe43163dc08a42a28ab8c604ef5435ff7458`
- Private per-issuer/per-node report SHA256: `a082107e589c54663140a6e33043787c09bbba92f5263300e6b64fde81bef098`

Private report: `output/guru-valuation-expansion-2026-09-05/inherited-issuer-review-provenance-20260906.json`. It contains each issuer's settings hashes, ledger entry hash, full model signature, each individual node's input/output hashes, preserved watch disposition, source-state record and financial/guidance change hashes. It does not contain a mutation instruction.

## Reproduction and tests

```sh
node scripts/audit-inherited-issuer-provenance.mjs \
  --baseline output/guru-valuation-expansion-2026-09-05/runtime-production-20260905.sqlite \
  --source output/guru-valuation-expansion-2026-09-05/additive-full-rebuild-v2-20260906/source.sqlite \
  --ledger server/reports/valuation-audit-ledger.json \
  --git-commit 3588ce473798296cd9c8862466f81cff4ee53fb0 \
  --expected-model-signature 16925a5d4cc0ea156e6040aebb42ad4a95f08a1f592ee0095273367ce7a5dee2 \
  --prior-audit output/guru-valuation-expansion-2026-09-05/runtime-production-audit.json \
  --out /a/new/private/provenance-report.json

node --test scripts/audit-inherited-issuer-provenance.test.mjs
```

Six tests pass: unchanged explained-watch inheritance without approval escalation; changed/missing profiles or parameters; exact count/period/date/value checks; no implicit profile fallback; full model-input binding despite unchanged latest fair value; and canonical-versus-raw treatment of dynamic run timestamps.

Safe next step: consume these bindings as **prior profile provenance only**, preserve the separate source/economic/model-release gates, and require fresh validation of the changed candidate. Do not replace the pending records with a blanket `reviewed` update.
