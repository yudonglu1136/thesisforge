# Questrade and Futu read-only accounts

These connections coexist with IBKR. Their dated snapshots are displayed in the
Portfolio Questrade / Futu dialogs. They are **not yet included in the IBKR
valuation, return or risk analysis**. Different currencies are never summed.
No order, cancellation, transfer or trading-unlock method is implemented.

## Questrade

Generate a personal API refresh token in the official Questrade API Centre.
Paste it only into the authenticated website's Questrade dialog. Do not paste
passwords or tokens into chat, command arguments, source files or logs.
Connect & sync stores the rotating session encrypted in the owner's existing
private SQLite store, separately from IBKR. Sync now reads accounts, per-currency
balances and positions. Reads do not fabricate a return history. Failed syncs
retain the last dated snapshot and are marked failed. Daily Questrade scheduling
is not wired yet; the UI offers explicit synchronization.

## Futu on this Mac

Install and log in to the official OpenD desktop gateway. Keep it bound to
loopback, with port 11111 private. The connector never unlocks trading.
Install the official `futu-api` Python SDK in an isolated virtual environment
(do not modify system Python). In Portfolio > Futu generate a connector token.
From the project root, run:

```sh
tmp/futu-connector-venv/bin/python scripts/futu_connector.py --account-id YOUR_ACCOUNT_ID --firm FUTUSECURITIES
```

Use the exact real account ID, not an account index. For moomoo US use `FUTUINC`;
other supported firms are `FUTUSG` and `FUTUAU`. The hidden terminal prompt takes
the connector token. It stays only in process memory. The process uploads every
15 minutes while running, with OpenD logged in; use `--once` for one sync. It
does not install a background service, modify login items or store broker
passwords. The token lasts 30 days. Regenerate it to revoke the old token, or
disconnect in the website to revoke all uploads. A sleeping/offline Mac does
not update; the displayed retrieval timestamp remains unchanged.

The capability authorizes **uploads only** for that owner's Futu snapshot and
cannot read existing holdings or use other API endpoints. All transfers use
HTTPS to the fixed production domain, with redirects refused. No public OpenD
port or inbound connection to the Mac is required.

## Verification status

Synthetic adapter/storage/recovery tests do not prove that a real broker
account has connected. Production deployment, a user-authorized token entry,
and a real OpenD snapshot must be verified before claiming those results.

Official references:
- https://www.questrade.com/api/documentation/authorization
- https://www.questrade.com/api/documentation/rest-operations/account-calls/accounts-id-balances
- https://openapi.futunn.com/futu-api-doc/en/trade/get-position-list.html
- https://openapi.futunn.com/futu-api-doc/en/trade/get-funds.html
