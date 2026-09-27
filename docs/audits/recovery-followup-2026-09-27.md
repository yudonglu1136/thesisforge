# Recovery follow-up — 2026-09-27

This is an incremental record, not a completed-release attestation.

## Repairs tested locally

- Operator encrypted user-backup tool resolves the current Ready production EB
  environment instead of targeting retired instance `i-0896b2f2f421b847b`.
  Wrong application/environment, ambiguous instances and an Updating environment
  fail closed. Existing account, security-group, host-key, encrypted-object and
  isolated-restore checks remain intact. Eight tests pass.
- Native query retries no longer shorten a provider Retry-After greater than
  60 seconds. Numeric and HTTP-date headers are supported; a delay over the
  bounded 300-second per-retry budget fails without retrying early. Existing
  extraction completeness/revision checks remain intact. Sync and sync-plan:
  48 tests pass. This is not proof that all production 429s are resolved.

## Actual AWS scheduled execution

Execution `606ab89b-c8ae-44e7-8e10-a8bbc28d81da`, scheduled for
`2026-09-27T04:30:00Z`, failed with `FactOsDailyDataNotVerified`.
SSM `fb0872c8-d3a2-49b7-ab02-961a81aecaf8` ran 04:30:34–05:17:46 UTC,
exit 2. Capacity check reported 69,761,372,160 free bytes.

Successful/unchanged sources: tickers, fundamentals, actions, holdings_ticker,
holdings_investor, events, insiders, descriptions, metrics, sp500.
Failed: stocks, daily, holdings (HTTP 429); funds (upstream changed during
verification). Prior history retained. Staging run
`0e8871ea54cf4fd0cdb11cfecfae3e574b8820e506ec557ea373fecd7daa509d`
failed. No six-group success or API activation is claimed.

## Pending gates

- Actual encrypted backup was rejected by the execution safety reviewer pending
  explicit permission for private account DB export, private S3 destination,
  temporary source-IP-only SSH ingress and isolated restoration. No retry or
  workaround was executed. No live database was replaced.
- New retry code has not been deployed to the daily worker or live-run verified.
- Global activation, Guru current-curve acceptance and storage reconciliation
  remain incomplete.
- Chrome signed-in Home successfully rendered existing Portfolio snapshot and
  holdings; no broker sync was invoked. Other page acceptance is ongoing.
- Signed-in production rule portfolios render 2013-01-02–2026-09-21 curves,
  but stock attribution remains unavailable, leaving win rate, payoff and
  turnover blank even after Retry attribution. This is a release blocker.
- Production 13F displays the existing institutional dataset. Fundamentals
  displays "Financial analysis is being prepared" with no company results;
  the clearer loading state is not a completed functional repair.
- User waived new SPY/KMLM parameter questions and requested existing website
  rules. Do not invent contributions or claim an unrun threshold experiment.
