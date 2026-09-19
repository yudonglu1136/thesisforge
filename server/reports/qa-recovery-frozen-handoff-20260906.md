# QA recovery: bounded frozen handoff, 2026-09-06

Status: **not a full-platform release approval**. No production database, default universe, AWS or Git remote was changed by this lane.

## Exact result

The final artifact directory is `output/guru-valuation-expansion-2026-09-05/prior-qa-frozen-handoff-v4-20260906`. Earlier handoff directories are intermediate checkpoints and must not supply final counts.

| Scope | Count | Meaning |
| --- | ---: | --- |
| Current exact English source fields | 14,678 | Original 14,462 retained, plus 216 CRDO fields; no new field lacks a candidate translation |
| Full-field bilingual semantic review this batch | 73 | 52 currency-related fields and 21 terminology/language fields, reviewed against their complete English source by Codex; not a claim of human review |
| Additional targeted CRDO expression fixes | 3 | Q2-to-Q3 income direction; PCIe Gen six representation; November representation and give-or-take timing |
| Other CRDO targets | 213 | Prior exact cache/audit provenance retained and current numeric/language checks rerun; **not newly full-field semantic-reviewed** |
| Scoped source/target-bound consumable cache | 289 | Only this exact subset passes current source/target hash binding and final-text numeric replay |
| Remaining source fields | 14,389 | Pending; not promoted by a historical aggregate pass or by current mechanical checks |

All 14,678 actual targets were rechecked with the same final v8 guard after exact-source-SHA merging of the reviewed repairs:

| Final v8 mechanical result | Count |
| --- | ---: |
| Strict numeric/terminology check | 13,483 |
| Exact monetary-range punctuation/whitespace equivalence | 138 |
| Explicit quarter/FY representation equivalence | 63 |
| Total mechanically checked | 13,684 |
| Numeric mismatch requiring investigation | 994 |

These are mechanical counts, not semantic approval counts. The 994 includes unsupported representations as well as possible real errors; this batch did not resolve or classify every remaining field. No global non-currency quantity grammar was deployed. The 289 scoped targets are included in the 13,684 mechanical passes.

The old v5 recovery grouping remains in the ledger for traceability only (13,346 strict/65 equivalent/978 mismatch within the pending tail). It is not the final current-v8 count.

## What changed

- Currency token boundaries no longer swallow the `t` in `to` or the `T` in `TAM`, which previously inflated dollars into trillions.
- Explicit legal shared-scale monetary ranges are protected atomically, preserving both endpoint scales. Ordinary `or`, `vs`, unrelated metrics, mixed currencies, revision-by phrases and years are not blindly joined into a range.
- Explicit plural monetary units such as `$8 billions` are handled without losing scale. The full v8 source comparison found 236 recipe changes, including 51 original monetary-scope changes. The bounded repaired batch still totals 52 because the intermediate v6 plural-unit regression was also explicitly repaired and retained in provenance.
- Editorial repairs include Costco's $10 monthly benefit/$150 basket ownership reversal; AMAT's 1.3 million wafers; JBL's million-share counts and profit-versus-revenue bridge; APH's company-versus-automotive revenue ownership; NVDA GW versus MW; ANET mid-teens versus single digits; and reported margin versus dates/decades.
- The final-target checker also rejects unbound digits adjacent to Chinese text. A source/target pair cannot be accepted merely because the same numeric regex failed to notice extra digits.
- The enricher now audits the exact target it attaches. Existing Chinese text cannot silently override a different audited cache value. Every used English question/answer remains in the source audit, including fields with existing Chinese.

The three targeted CRDO corrections retain the original generation audit, old target hash, explicit reason and new target hash in `crdo-qa-reviewed-v3-20260906/editorial-manifest.json` and `audit.json`. An earlier Qwen mechanical pass did not prevent the discovered Q2/Q3 relationship reversal.

## Source limitations retained, not repaired into facts

`source-warnings.json` contains 18 exact source-bound warnings. Three are classified as internal source inconsistencies:

1. HPE: the same English answer contains both `$1.85-$1.95` and `$185-$195`. The decimal discrepancy was not silently fixed.
2. EQIX: the source calls the metric monthly recurring revenue (MRR), then says `$667 million a day`. No daily/monthly inference or annualization is authorized.
3. JBL: the final share-count discussion says end of 2024, then again 2024 while discussing management through FY2025. The year was not rewritten.

Other warnings include unscaled shorthand dollar amounts, `Q1Q`, `$6 billin`, and an ambiguous speaker/phone reference. These translations are not an official-guidance or factual-source attestation; none of these transcript quantities may be imported as reviewed valuation inputs based on this work.

## Provenance

The original full-platform cache bytes were not found. The original metadata's cache SHA `cfe70f1cc70945dda59a06cdeab835fe87a9035fcfa873c26cff2fdb4c1bce5f` and audit SHA `ee6522b4223e6f42291de669eeb081e1b5aafa6f081090a3efc2970c20961fe1` are preserved only as prior aggregate attestations, not as proof of each recovered target's generation.

Recovery is tied to baseline database SHA `48ebd5798d59e1914273fe39a4811bae7db4e9c15547d1c9da8da54f731ff6d4` and the stationary English-enriched candidate SHA `21cf83722413151883f96e5a5864c2f8257c26fb2ff897690c8bcad92617a184`. Recovery-cache SHA is `6332d7113204fedbaf162ff3a03ac2cb28527ce5da79c63c3d791889a4254489`.

Each final field records exact English/Chinese hashes, its source package cache/audit hashes, old recovery target hash, original row references, final protected-token replay proof, and semantic review granularity. Original local Qwen prompt versions differ across packages; the merged audit deliberately has no fabricated single prompt hash. The 14,389 pending fields retain only source-bound recovery/check evidence, not consumption approval.

| Final v4 file | SHA-256 |
| --- | --- |
| `cache.json` — 289 scoped targets | `d6730596c9e5e4dfc4c4cb66a05890e610e4927a0eb0216a66a757ebd0e82d23` |
| `audit.json` | `3622e01708e7e16745f240c83bdc7d60cc320c89daeab11af423fe7b74eec7d0` |
| `handoff-summary.json` | `a78dd249974b9d7b10aeb277e179eeb28de29f76e821297819f3f20d0fe64c34` |
| `pending-source-index.json` | `d18167d92936ba193d3504456f94b3788a7731668f0984256db6c6cf86a91f8a` |
| `full-v8-guard-ledger.json` | `72c34d7616593c873b586b9ce0ac8b27b229c4b46825a52507db87d3a79f3b85` |
| `source-warnings.json` | `a70b5ae6d614c94b4d2445e546df4268f137334e3691440ed988e77c1550eb52` |
| `reconstructed-cache-NOT-FULLY-APPROVED.json` | `6e7c853db5f6f1c2a5067e95bb14321eabd2e1363ea8effbad01d2fb3abca718` |

## Replay and tests

From the repository root, use a new output directory. This command does not run a model, fetch data, translate online, or write any valuation database:

```sh
python3 scripts/freeze-reviewed-qa-recovery-handoff.py \
  --recovery output/guru-valuation-expansion-2026-09-05/prior-qa-recovery-v2-20260906 \
  --package output/guru-valuation-expansion-2026-09-05/prior-qa-guard21-reviewed-v3-20260906 \
  --package output/guru-valuation-expansion-2026-09-05/prior-qa-currency33-reviewed-20260906 \
  --package output/guru-valuation-expansion-2026-09-05/prior-qa-money19-reviewed-20260906 \
  --package output/guru-valuation-expansion-2026-09-05/crdo-qa-reviewed-v3-20260906 \
  --output /tmp/guru-qa-final-handoff-replay-new
```

The generator pins the exact reviewed cache/audit bytes, rejects unknown or conflicting sources, reruns actual-target guards, and creates a full pending source index. A self-asserted `approved` field in an altered cache/audit pair is not sufficient.

```sh
python3 -m unittest \
  scripts/test_translate_valuation_qa_mlx.py \
  scripts/test_qa_currency_suffix_repair.py \
  scripts/test_recover_valuation_qa_snapshot_cache.py \
  scripts/test_review_valuation_qa_translations.py \
  scripts/test_review_prior_qa_currency_editorial.py \
  scripts/test_freeze_reviewed_qa_handoff.py
node --test server/valuationQaTranslationIntegrity.test.js
```

Result: 42 Python tests and 6 JavaScript tests passed. They cover currency word boundaries/plurals, legal and rejected ranges, exact source/target tampering, forbidden pending-status promotion, extra digits, cache-versus-attached-text integrity, and explicit economic ownership corrections. Numeric checks are explicitly not claimed to detect arbitrary semantic reversals; reviewed byte bindings and exact editorial records address the known examples.

The freeze command was independently rerun into `/tmp/guru-qa-final-replay.BjYDuJ/replay`; `diff -rq` against the final v4 directory exited 0 with no differences across all seven generated files. No source database was touched during either replay.

Full-platform publication remains blocked pending the unreconciled source/QA work. This lane is frozen at the bounded checkpoint rather than marking the product “fully covered.”
