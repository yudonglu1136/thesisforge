# Admin health repair — 2026-11-02

Admin incorrectly displayed aggregate dataset failure as API availability and
classified quarterly Guru/model data using daily-job age limits. The repair
reuses the bounded public health audit for those datasets, retaining actual
curve and price failures. API response availability is separate. Source dates
are displayed separately from last completed jobs. Unknown jobs stay unknown
without configuration evidence. Legacy Guru prices are explicitly named.

The unconnected-account state skips portfolio analysis instead of presenting
zero values as a real portfolio. Default selection prefers a connected account.
No private production account data was read for this repair.

The existing asynchronous internal release verifier retains its reader lease
until completion and responds 202 while preparing. The committed installer
supports polling 202. Preparing is never accepted as an ACK.

Validation: Node 1790 passed / 15 skipped / 0 failed; 660 Flutter tests;
60 performance tests; Flutter analyze, bilingual literal audit and production
build passed. The 11 focused release/health tests also passed.
Production deployment is pending; untracked unrelated work blocks the existing
source guard. Automatic approval rejected ignoring those directories without
explicit scope confirmation. All files remain untouched.

Actual diagnosis: Guru curves and legacy prices remain stale. Reviewed valuation
has an age warning and is not automatically recertified. Daily Fact OS release
is separate from Guru curve/model publication. These alerts remain visible.
