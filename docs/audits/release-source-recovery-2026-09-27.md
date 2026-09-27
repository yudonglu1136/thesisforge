# Release source and Discover test recovery — 2026-09-27

## Scope and authorization

The user authorized repair of the 29 failing legacy Discover tests and the
dirty/untracked source packaging blocker. No production success is implied by
this source-recovery record; deployment and live activation require separate
verification.

## Test migration

The retired four-lens Discover card UI is not restored. Its evidence tests now
exercise the current Fact OS Fundamentals entry and Business, Financials,
Valuation and 13F panels at desktop and 390px widths in both languages.
Assertions retain evidence visibility, missing-data boundaries, lazy holdings
loading, no implicit saves, navigation context and zero render exceptions.
Financial quality unit tests remain unchanged. Threshold UI tests now exercise
the actual constrained growth/profit/cash dropdowns, serialized cutoff/filter
values and clear behavior rather than removed free-text controls.

Fresh complete Flutter suite: **645 passed, zero failed**. Local raw log:
`/private/tmp/thesisforge-release-full-20260927.log`.

## Recoverable preservation of unrelated work

Before archiving, relevant application threads were checked for concurrent
repository work and source paths were inventoried and hashed. The 866
untracked files and the unrelated modified `design-qa.md` were preserved under:

`output/worktree-archive-20260927-7159afb/`

The archive contains 867 files (129,143,324 bytes), their original relative
paths, SHA-256 hashes, sizes, timestamps, the original HEAD and the tracked
baseline hash. Every move was hash-verified. The receipt reports
`verified: true` at `2026-09-27T17:40:40.515Z`. No database, Parquet tree,
credentials or production data was moved or deleted. The tracked design QA
file was restored byte-for-byte to its committed baseline through a patch;
its unrelated edits remain in the archive. No reset, stash or checkout was used.

Recovery, from the canonical repository only:

```sh
node output/worktree-archive-20260927-7159afb/archive.mjs restore
```

Restore verifies hashes and refuses to overwrite occupied untracked targets
or changed tracked targets. It preserves the archive. Do not garbage-collect
this archive as a temporary build directory. It is intentionally excluded from
Git and production packaging; no other task's implementation is included in
this release commit.

## Remaining boundaries

The prior storage audit's legacy database/sibling-directory findings are not
fixed by this archive and were not removed to force a pass. The recovery does
not certify daily source freshness, Guru simulation readiness or production
latency. Existing immutable facts, saved research and private portfolio stores
are unchanged.
