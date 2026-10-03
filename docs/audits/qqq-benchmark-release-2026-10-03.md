# QQQ benchmark production release — 2026-10-03

## Scope and result

Nasdaq/QQQ universe now includes QQQ alongside SPY and both rule portfolios.
Range changes rebase the benchmark and its risk/return statistics. Other
universes retain SPY. Existing strategy selections, trades, ledgers and curve
values were checked unchanged against the parent bundle.

Code commit: `974f5049a921a810760487592e805f347a5e200e` (trunk, pushed).
Frontend: `dpl_Bph9Sy2MSz73sNqXwKNkxZ2wZJcE`, Ready. Both public domains were
independently inspected and resolve to
`thesisforge-6ak2u7vgz-yudonglu1136s-projects.vercel.app`.
Backend EB version: `qqq-benchmark-974f504`.

Data release:
`aaaecfcad9bc35597deebdbeef506bfde549542d02face520fda165e940b176d`.
Strategy generation:
`a6f121caa294f1e3c89c9294ff661a6df9b83c8d19d14b088756b4dc4d2953a8`.
Bundle identity:
`70e425304a2f8ee37a77e7a9d09cfc18455a4fcc770b4589e970d723e92b3012`.
Nasdaq snapshot:
`6c8fd3c2789990ca7269e2f198983032a7668066ef59278e0200ade176f97f49`.

The manual benchmark-only build used the immutable, previously verified
canonical snapshot, not the mutable writer database. It added 15,482,503 bytes
of derived artifacts; no database copies, historical deletion or private
account operations were performed. This was not a new 14-source sync.

## Production evidence

- Build SSM: `77b2f71a-f962-42c2-84d8-0971d60f1e87`.
- Prepare SSM: `5382d51f-365e-4a97-bd64-32bc5b3dd357`.
- Install SSM: `9aeed1c1-6b31-429e-a474-0f409e245b99`; actual API ACK verified
  all six groups, canonical reads, Fundamentals and public analysis readiness,
  and the three-universe atomic curve/ledger bundle.
- Publication finalization: `749fc6bb-9a16-4b4e-9bb2-c5ad6d70fea5`; existing
  publisher accepted the actual ACK and stale-worker fence. S3 active release
  and installed active release match the ID above.
- Actual `webapp` OS-user read: `9d173cae-91a4-4864-80a9-6b9c202af421` returned
  ready QQQ benchmark, 1,696 observations, 2020-01-02 through 2026-10-01.
- API disk free after installation: 1,188,196,352 bytes, above the enforced
  1 GiB reserve but still tight (97% used).
- Eight concurrent public health requests completed in approximately
  2.28–2.34 seconds, returning the existing 503 status. Guru curves and legacy
  price_points freshness remain failed; this is not an all-platform-green claim.
- Unauthenticated investment route returned 401; public internal route 404.

## Tests

- Full Node server suite: 1,771 pass, 0 fail, 15 skipped (1,786 total).
- Flutter full suite: 654 pass; focused bilingual/mobile tests: 21 pass.
- Flutter analyze, i18n audit and production build passed.
- Performance tests: 60 pass. Targeted Python pipeline tests: 13 pass.
- Fact OS storage audit passed; root layout audit retained 11 pre-existing
  findings without deleting unrelated directories or data.

## Explicit remaining gates

Authenticated production browser verification is pending login. Both browser
sessions showed the login page; no authentication bypass was used. Widget
tests are not substituted for a completed logged-in production walkthrough.

Worker code `974f504` is staged and was used for the real immutable-input
benchmark build, but `/opt/fact-os/current` remains `5057558`. The required
manual 14-source/six-group worker-upgrade gate has not passed. The old worker
does not guarantee QQQ retention on a future refresh. Do not describe QQQ daily
automation as deployed or scheduled acceptance as complete. The public
Scheduler was not modified during this release. Today's prior scheduled
failure on holdings is not repaired by the benchmark-only publication.
`data-ready/latest.json` was deliberately not relabeled as a new successful
daily sync. Worker receipt is retained at
`/var/lib/fact-os/data/audit/qqq-benchmark-974f504.json`.

## Recovery

Prior frontend: `dpl_G3K2aeVqbEZv21SvmB5UvCZfMkx7`; prior backend:
`rule-daily-5057558`. Prior data release:
`e9a012aacd0fea66cee5feecb6656e6b26a9ba65cb281c55ca8b06480114da5c`.
Retain immutable releases. Any rollback must use the existing verified
installer/ACK publication path; do not overwrite curve or ledger files in place.
