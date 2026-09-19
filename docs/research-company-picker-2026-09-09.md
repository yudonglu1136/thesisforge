# Research company picker — local delivery

Scope: the user's screenshot of the ticker-only Switch company dialog. The
Research workspace, Guru functionality and valuation methodology are unchanged.

## Interaction

- Search stored issuer name or exact ticker, ignoring case/outer whitespace;
  multiple words must all match. Exact ticker ranks before prefix/name matches.
- Real existing `StockLogo` assets, full source name, stored model date. Current
  company first; up to six successfully viewed session tickers precede the
  remaining alphabetical directory. No fabricated popularity or investment rank.
- Click once, or use arrows and Enter. Escape/close cancel. Clicking the current
  company does not reload or prompt to discard its scenario. Actual company
  changes still call the existing `allowLeaveDraft` guard.
- The dialog fits its content up to a bounded height. Its top stays anchored as
  results change; one match no longer leaves a large empty panel. Mobile date
  labels move below company names. List rows adapt to larger type and scroll
  within the remaining viewport when a software keyboard is open.
- Read failure/12-second timeout offers retry. Unknown search does not submit a
  guessed ticker; missing coverage remains missing.

## Data and boundary

`GET /api/investment/companies?asOf=YYYY-MM-DD` uses existing authenticated,
private/no-store preview routes. Returns only ticker, issuer name, latest stored
model date and `stored_model` coverage, not chart/financial/transcript payloads.
Known financial and guidance dates cannot exceed each model date or the cutoff.
Snapshot/model duplicates collapse to one ticker.

Names reuse the project's existing S&P/Guru issuer catalogs, with stored
snapshot-name fallback for remaining identities. Names are current reference
metadata, not asserted historical legal names. Catalog membership alone cannot
create coverage. A model row is not certification that full source-lineage checks
will pass: those remain in `source.company()` when the company is opened. The
pre-existing LSEG lineage issue is not changed or disguised by this picker.

The source connection stays read-only. A bounded three-cutoff, source-version
cache returns clones and invalidates on database writes; response is ~52 KB for
532 companies in this local 2026-08-28 extract. Query keystrokes filter this index
locally, without another request or a calculation. No paid-data/source database,
saved user decision or valuation assumptions were rewritten.

## Verification

- 12 dedicated picker tests: matching/ranking, bilingual desktop/phone, logos,
  keyboard selection/Escape, no results/clear, read failure/retry, cutoff mismatch,
  future rows, timeout/disposal, large text with keyboard insets, long-list scroll.
- Existing Research tests now select by issuer name and exercise cutoff and
  unsaved-draft preservation, including clicking the current company.
- Full Flutter suite: 309 passed. Investment backend: 64 passed (5 new catalog
  tests). Performance regression suite: 41 passed. Analyze, i18n and web build pass.
- Real browser: TSLA → search NVIDIA → NVDA; cutoff remains 2026-08-28; reopening
  marks TSLA as Recent. EN/ZH mobile and full/single-result layout inspected.

Evidence: `output/personal-valuation-20260909/company-switch-*.jpg` and root
`design-qa.md`. Development-auth preview only; no commit, push or deployment.
