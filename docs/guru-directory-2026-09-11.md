# Discover Guru directory and linked selection

## Scope

The existing manager study now includes a complete portrait directory below
the two scatterplots. This is a UI revision, not a new return calculation or
change to stored backtests. The directory takes the union of the Guru catalog,
comparable study rows and unavailable study entries, keyed by manager ID.

At the verified local cutoff 2026-09-10, the directory contains 29 managers:
28 comparable simulations plus Nick Sleep / Qais Zakaria without a comparable
simulation. The latter remains browsable with missing metrics displayed as an
em dash, never zero or an invented plotted point.

## Interaction contract

- Inspection is independent of the maximum-three comparison shortlist.
  Chart clicks and portrait/name clicks never implicitly add or remove people
  from that shortlist. Explicit Compare buttons and the Add a Guru picker
  manage comparison membership.
- Both charts use the same inspected ID. The inspected point has a mint ring
  and label even when it is not in the shortlist; other comparison points keep
  their blue rings. The inspected point is drawn last to remain selectable.
- Clicking a chart point or shortlist portrait reveals the matching directory
  row. That row has a mint portrait ring, selected semantics, left border and
  text status, and expands a quarter selector and holdings action. The return
  link reveals the highlighted charts again.
- Directory portraits inspect in place. Direct Holdings opens that manager;
  the expanded quarter action opens the exact selected filing. API responses
  retain existing cutoff/manager/serial checks.
- The search and numeric/method filters are shared by charts and directory.
  Directory ordering can be turnover ascending, CAGR descending, Sharpe
  descending or name. Missing values sort last. Reset restores the whole
  catalog. Sorting does not recalculate financial measures.
- Comparison errors, missing simulations, loading and no-match states remain
  distinct. Holdings entry points remain available without simulation metrics.
- Existing selection callbacks preserve independent inspection, comparison,
  sort and quarter across in-app navigation; no account or strategy writes are
  introduced by selection.

## Verification

- 16 targeted Flutter tests: portrait list completeness; independent fourth
  inspection; explicit comparison cap; both chart selections; exact quarterly
  route; missing simulations; shared search/reset/sort; stale responses; EN/ZH
  layouts at 390, 1000 and 1223 pixels, including 150% mobile text.
- Full Flutter suite, static analysis, bilingual audit, ontology source/built
  verification, ontology tests, and four read-only Guru study backend tests.
- Both production and loopback-only development preview builds verified.
- Browser checks: 29/29 directory population; 1/29 after searching Li Lu and
  29/29 after reset; fourth inspection with a three-person shortlist;
  chart-to-portrait auto-reveal; portrait-to-chart highlighting; Dev Kantesaria
  2026 Q1 opens the report published 2026-05-15, rather than the latest quarter.
- Final native browser captures: `output/guru-directory-20260911/desktop-en.jpg`,
  `mobile-en.jpg` and `mobile-zh.jpg`; desktop 1487×1058, mobile 390×844.
  No browser error entries on the verified page. Full suite: 459 passing.

The dashboard skill guided the linked-selection design, common filter scope,
explicit missing-data treatment and rendered verification. Existing Flutter
components, real portraits and financial definitions were retained.

Local preview: http://127.0.0.1:5186/?view=discover&discoverTab=managers&asOf=2026-09-10&lang=en
No deployment, source-database changes or portfolio/account writes.
