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

Deployment identity and production checks will be recorded after publication; the pre-release checks above alone do not constitute online acceptance.
