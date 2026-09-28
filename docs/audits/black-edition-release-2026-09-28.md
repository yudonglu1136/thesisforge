# Black Edition frontend release

User approved publication of the local Black Edition on 2026-09-28.

Scope: shared investment-workspace palette, typography, navigation, TF mark, AI Insights charts and responsive table headings. Existing calculations, data stores, saved research and backend code are unchanged. The approved theme is now enabled by default. The previous theme remains available through an explicit `BLACK_EDITION_PREVIEW=false` build.

Validation before release:

- Full Flutter suite: 647 passed.
- `flutter analyze`: no issues.
- `npm run audit:i18n`: passed.
- Production build uses `AUTH_DEV_BYPASS=false`, same-origin API and the existing Supabase production configuration. Local preview output is not the deployment artifact.
- Local visual/interaction evidence and source reference: `docs/brand/black-edition-2026-09-28/design-qa.md`.
- Only the listed frontend/assets/docs changes are in scope. No AWS deployment, data sync, API activation, schema change or private-account operation.

Rollback baseline: both public domains resolved to Vercel deployment `dpl_3Vi8grotsa19Re8GeMTYQdLdNx3J`, `https://thesisforge-g8ygn4cvx-yudonglu1136s-projects.vercel.app`, before release. If frontend verification fails, restore both aliases to that verified deployment. Do not roll back or rewrite backend/user data.

## Production publication and verification

- Application commit: `65607d33ea4845f2966f6515c6fbd9569fc9afe2`, pushed to `trunk`.
- Vercel production deployment: `dpl_CU57JnFkAVriB6NMivJw2osR2ZR5`, READY.
- Deployment URL: https://thesisforge-pd4e9102z-yudonglu1136s-projects.vercel.app
- Both `thesisforge.tech` and `www.thesisforge.tech` were inspected and resolve to that deployment. Both app shells returned HTTP 200 with the Vercel server header.
- Both domains serve `main.dart.js` SHA-256 `539062fba1667b86cdbd1d5ac3aaf5b07edc1a5ce9759c512074abde269b5126`, identical to the tested production build. Supabase configuration is present; unauthenticated `/api/investment/workspace` returns HTTP 401.
- Eight concurrent public health requests completed, but health is NOT green: HTTP 503, `guru_backtests` failed (0/57 current displayable curves), and `market_prices` stale (source date 2026-09-18). Database, Guru data, and valuation modules are healthy. A follow-up against the previous production deployment returned the same module states, confirming this frontend-only release did not introduce the backend readiness failure. No thresholds were relaxed and no backend/data jobs were run.
- In-app browser and Chrome both rendered the real production login page. Neither currently has an authenticated session; authenticated production dashboard visual acceptance remains pending. Local authenticated preview checks do not substitute for this pending check.
- Frontend publication succeeded; this receipt does not claim full-platform health or authenticated end-to-end acceptance. The rollback deployment above remains available.
