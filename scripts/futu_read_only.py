"""Read-only OpenD adapter. No passwords, trade unlocks, orders or public port.

Called by a future authenticated local connector; this module deliberately has
no CLI that prints private account data and no unauthenticated HTTP listener.
"""
from datetime import datetime, timezone


class FutuReadError(RuntimeError):
    pass


def read_account(context, sdk, account_id):
    """Read exactly one explicitly selected REAL account from an existing SDK context."""
    if isinstance(account_id, bool) or not str(account_id).isdigit() or int(account_id) <= 0:
        raise FutuReadError("futu_account_required")
    account_id = int(account_id)

    def rows(result):
        status, frame = result
        if status != sdk.RET_OK:
            # SDK errors may include account details; never expose raw messages.
            raise FutuReadError("futu_read_failed")
        return frame.to_dict(orient="records")

    accounts = rows(context.get_acc_list())
    matches = [a for a in accounts if str(a.get("acc_id")) == str(account_id)
               and a.get("trd_env") == sdk.TrdEnv.REAL]
    if len(matches) != 1:
        raise FutuReadError("futu_real_account_not_found")
    funds = rows(context.accinfo_query(acc_id=account_id, trd_env=sdk.TrdEnv.REAL,
                                      currency=sdk.Currency.USD, refresh_cache=True))
    positions = rows(context.position_list_query(acc_id=account_id, trd_env=sdk.TrdEnv.REAL,
                                                refresh_cache=True))
    if len(funds) != 1:
        raise FutuReadError("futu_invalid_funds")
    return {"provider": "futu", "access": "read_only", "account": matches[0],
            "retrievedAt": datetime.now(timezone.utc).isoformat(),
            "funds": funds[0], "positions": positions}


def read_local_account(account_id, security_firm, port=11111):
    """Connect only to loopback; OpenD itself handles the user's login locally."""
    import futu as sdk
    firms = {name: getattr(sdk.SecurityFirm, name) for name in
             ("FUTUSECURITIES", "FUTUINC", "FUTUSG", "FUTUAU")
             if hasattr(sdk.SecurityFirm, name)}
    if security_firm not in firms or type(port) is not int or not 1 <= port <= 65535:
        raise FutuReadError("futu_invalid_gateway_configuration")
    context = sdk.OpenSecTradeContext(host="127.0.0.1", port=port,
                                      security_firm=firms[security_firm])
    try:
        return read_account(context, sdk, account_id)
    finally:
        context.close()
