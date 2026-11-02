# Admin repair — 2026-10-07

## Reproduced

The authenticated production Admin page loads, but selects the most recently
signed-in user even when no portfolio is connected. It then displays empty
portfolio analytics as zero values. Legacy operational freshness checks also
misclassify quarterly public datasets using daily job thresholds.

## Changes

- Prefer a registered portfolio on initial selection, preserving an explicit selection.
- Show an honest unconnected-account state without requesting portfolio analysis.
- Project the existing cached public-health verification into Admin health for
  Guru facts, published valuations, Guru curves and market prices. Keep actual
  failures and private operational job states; do not weaken authentication.

## Verification

The new selection test failed against the old implementation before the repair.

- Node full suite: 1,773 passed, 15 skipped, zero failed.
- Flutter full suite: 655 passed.
- Targeted backend tests: 23 passed; targeted Admin widget tests: 34 passed.
- Performance suite: 60 passed.
- Flutter analyze, i18n audit, production frontend build and diff whitespace check passed.

## Release status

Not deployed. This record does not certify a production repair. The latest
read-only API capacity observation was 965,382,144 free bytes, below the public
data installer's 1 GiB reserve. No files, old generations or private account
data were deleted; no capacity expansion or production mutation was performed.
Guru curve and price freshness failures remain separate unresolved operational
conditions, and are still displayed rather than converted to healthy.
