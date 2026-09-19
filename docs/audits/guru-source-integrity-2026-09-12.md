# Guru source integrity: release remains blocked

Verified at 2026-09-12 21:26 UTC. This is a source investigation and bounded parser repair, not a completed Guru refresh or production deployment. The companion JSON contains exact source URLs, hashes, values and local evidence paths.

## Confirmed source defects

### Defender 2022 Q1: original amount is wrong

The official original `0001766929-22-000002`, accepted 22 April 2022 at 15:42:08 UTC, gives MIRION (`60471A101`) a reported value of **628,200 thousand USD** for 60,000 shares. Its table and cover both total 915,127 thousand USD, so an ordinary sum check does not detect the error.

The official `13F-HR/A` `0001766929-22-000003`, accepted 7 June 2022 at 18:46:01 UTC, explicitly identifies amendment 1 as a **RESTATEMENT**. Its MIRION value is **628 thousand USD**, with the same shares. All 36 parsed rows and every other field are identical. The single value change exactly explains the revised 287,555 thousand USD cover total.

The current pipeline excludes amendments before fetching their cover semantics. Merely installing the missing MIR security mapping would price an erroneous 68.6462% book weight and could turn a coverage failure into a misleading curve. Substituting the June correction into April would introduce look-ahead. Neither action was taken.

### Defender 2025 Q3: all identifiers are placeholders

The official source `0001766929-25-000005`, accepted 29 October 2025 at 15:36:04 UTC, contains 35 issuer rows but every raw CUSIP is `000000nan`. The existing parser aggregated these unrelated issuers into one $298,184,693 holding. In the earlier `guru-additions-20260912/john-stamas.json` staging artifact, a later exact issuer fallback supplied `COST`, while the aggregate retained Berkshire's issuer label, producing a false 100% position. This is not a claim that the live UI holds 100% COST.

The release owner's independent read-only query of the final strategy warehouse confirms the same invalid one-row aggregation is marked classification-verified, but its ticker is **null/unresolved**, not COST. This fail-closed resolution avoids that specific fabricated tradable position; it does not make the source aggregation correct.

The official submission response contains 35 filings from 8 February 2019 through 9 July 2026, no archived submission files, and only that original accession for report date 2025-09-30. No corrective amendment was found in this source as of the verification time. Absence of a correction is not permission to invent identifiers.

## Implemented, tested, not published

- Economic placeholder identifiers now raise `invalid_13f_identifier` before ticker resolution and aggregation. The exception carries accession, report date, filer CIK, source URL and exact source-body SHA.
- Both historical holdings and exposure refresh abort on this source corruption. They cannot skip it and silently carry a previous book into a purportedly complete curve.
- Zero-valued empty-book sentinels remain valid. Existing legitimate duplicate aggregation, share-class rules, and Pabrai's precisely scoped eight-character identifier exception are unchanged.
- Targeted Node 22 tests: **46 passed, zero failed**. A mocked SEC history test proves that the error propagates beyond parsing with its source identity.
- No production or local runtime database was modified. No canonical mappings, backtest method versions, old curve labels, coverage thresholds, or private user records were changed.

## Readiness and next implementation boundary

The existing isolated diagnostic covers all 32 enabled managers × 5Y/10Y. It reports 29 strict-ready, 33 proxy-ready and two failed Stamas rows. Its security identity is `holding-resolution-v1-cb446ae272b57a41`; it is not a shared-generation publication attestation. The newly confirmed source defects mean that “add the missing mappings and rerun” is insufficient.

A correct general amendment implementation must be designed and tested as a method-policy change:

1. Preserve original and amended raw documents separately, verify each cover's original/restatement/new-holdings semantics, filer, report period, acceptance time and totals. Ambiguous amendments remain blocked.
2. Build an event-time book, not one overwritten row per report quarter. A verified restatement becomes usable only after its actual acceptance; multi-CIK aggregation must use the components public at each event.
3. Detect an invalid original using information available at that time. Keeping the prior valid book requires an explicit, audited policy and visible stale/source-rejection event. Knowledge of a later amendment alone cannot retrospectively justify a decision on the earlier date. Until that policy is implemented, reject the affected backtest rather than manufacture continuity.
4. Require authoritative exact-identifier repairs for the 2025 Q3 placeholder table. Do not recover them by fuzzy name, arbitrary row order, or an unrelated later filing.
5. Rebuild source-aligned research and strategy candidates, then compute the full 64-row matrix using a new method/security identity and one publication generation. Validate source preservation, timing, attribution, prices and UI. Only then perform an atomic install with rollback and storage preflight.

The four additions also retain 37 unresolved older original-filings in their staging audit (36 Dock Street and one Pacific Heights). Those are distinct full-history limitations, not completed backfill. The original 29-profile public research release and the newer 33-manager strategy warehouse remain incompatible until a complete source-aligned bundle is audited.
