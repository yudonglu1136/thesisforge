# Black Edition entry points and Admin integration

## Scope

The approved Black Edition was applied to the investment workspace, but login,
the legacy Admin shell, startup screen and browser/install icons still used the
old green branding. This release shares the existing white mark across those
entry points, uses black neutral surfaces, and embeds the existing Admin
dashboard in the workspace navigation. It does not change API authorization,
private account data, financial calculations or Fact OS installation.

Admin uses a separate widget identity so entering/leaving it cannot reuse a
stale workspace page. Account changes continue to discard the Admin payload;
late responses cannot restore another account's view. No production auth bypass
is enabled.

## Verification

- Flutter full suite: 652 passed.
- Admin suite with production workflow enabled: 15 passed, including exact
  owner/session gating, account switches, late responses, navigation, Chinese
  and English at 390 and 1280 pixels.
- Flutter analyze: no issues.
- i18n literal audit: passed.
- Performance/transport regressions: 60 passed.
- Brand asset/source/build regression tests: 5 passed.
- Production Flutter web build: passed with workflow enabled and auth bypass
  false; compiled main SHA-256
  `27371c93e663cac094e4fd7694a3136f6b54d24707fd12f84048e56520fb226b`.
- Real browser, isolated production build: English desktop and Chinese 390px
  login checked; black background, white mark and white Google button rendered.
- Admin UI tested with synthetic fixtures, not copied private user data.

## Release / rollback

Frontend-only Vercel release from trunk; no AWS redeploy or data writes.
Previous production deployment retained for rollback:
`dpl_9apbfTPpgvYcgorfKeH3aKkFxV8d`
(`thesisforge-mh7xyl7nf-yudonglu1136s-projects.vercel.app`).
At this source commit, push/deployment and live UI verification are pending;
record their actual results after publication. Both public aliases must resolve
to the same verified deployment. Production Admin browser validation still
requires an existing authorized owner session; fixture checks are not a claim
of live private-account validation.

The separately recorded Sep 29 scheduled public-data activation failure is not
repaired by this frontend branding change.
