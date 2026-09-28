# ThesisForge Black Edition — local design QA

Date: 2026-09-28. Scope: opt-in visual direction, not a production release or full platform acceptance.

## Reference and implementation comparison

Reference: the black-background edition in the chat **设计13F数据分析功能**, and its first black chart reference at `/tmp/codex-remote-attachments/01a0c249-10ce-7602-8409-034ac84f91e9/A3C66447-B158-4C86-8CDD-D3E80A250EB3/1-照片-1.jpg`.
Article reference: `/Users/yudonglu/Documents/investment-portfolio-essay/black-edition-2026-09-27/qa/page-01.png`.

The source chart and implementation screenshot were inspected together in the same visual comparison pass. This is an adaptation of the black/white editorial art direction to an interactive research terminal, not a pixel-copy of a two-panel article chart. No reference financial values were imported into the application.

Implementation evidence: `docs/brand/black-edition-2026-09-28/desktop-overview.png`, `desktop-capex.png`, `desktop-growth.png`, `desktop-rankings.png`, `mobile-en.png`, `mobile-zh.png`.

## Findings and fixes

1. Typography: the prior Inter declaration had no bundled Inter asset. Added a separately named, licensed TFInter variable font for preview only; tabular figures for data and an explicit chart-label font. Reduced excessive heading weight and tightened large-title tracking.
2. Spacing: a widened sidebar caused two English desktop regression failures (5.4px overflow). Restored the established 216px shell width. All 117 focused tests then passed.
3. Browser-only typography: language changes exposed a 3.8px ranking-header overflow. Allowed preview headings to flex/wrap; repeated English/Chinese switching produced no new rendering errors. Earlier hot-restart disposed-view messages were development-session artifacts, not silently counted as a clean full-session console.
4. Colors: black background, near-black surfaces, white content, muted gray metadata and thin gray rules now match the source direction. Blue/green separate data series; amber retains its existing comparison/warning meaning, red remains loss/error. Existing color-blind behavior is retained.
5. Assets: replaced the preview brand mark with an actual generated white TF raster asset; original production mark retained. Inspected it at desktop/mobile display sizes: crisp, no placeholder geometry or text clipping.
6. Copy: all existing bilingual research wording, dates, caveats, coverage and evidence labels retained. No fabricated data or simplified financial claims introduced for visual polish.

## Verification

- Focused Flutter suite: AI Insights, Research, workflow — 117 passed after shell fix; AI Insights alone also passed 17/17 after header work.
- Flutter analysis: no issues. Bilingual literal audit: passed.
- Local web release compilation: passed; not uploaded or deployed.
- Real local API data loaded, including capital-investment series and company rankings.
- Browser: 1280×720 desktop and 390×844 English/Chinese layouts inspected.
- Exercised chart quarterly-data expansion, YoY/QoQ switching, ranking navigation, language switching and company detail overlay.
- Final bilingual ranking-header check: no new console errors during the checked interaction window.

## Boundaries

This is the local design-preview gate only. It does not claim a new financial audit, production health verification, a completed whole-product redesign of every bespoke chart, or private Portfolio testing. Existing wide financial tables retain horizontal scrolling on narrow screens. User approval of the new identity remains pending.

Final result: passed for the scoped local visual preview; no unresolved P0/P1/P2 findings in the inspected surfaces. Production unchanged.
