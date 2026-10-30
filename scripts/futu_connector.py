"""Run on the user's Mac beside logged-in OpenD. Token stays in memory.

python3 scripts/futu_connector.py --account-id 123 --firm FUTUSECURITIES
Only outbound HTTPS snapshot uploads; no listening port or trading operations.
"""
import argparse
import getpass
import json
import math
import time
import urllib.request
from futu_read_only import read_local_account


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def clean(value):
    if isinstance(value, dict):
        return {str(k): clean(v) for k, v in value.items()}
    if isinstance(value, list):
        return [clean(v) for v in value]
    if hasattr(value, "item"):
        return clean(value.item())
    if isinstance(value, float) and not math.isfinite(value):
        return None
    return value


def main():
    parser = argparse.ArgumentParser(description="Read-only Futu snapshot connector")
    parser.add_argument("--account-id", required=True)
    parser.add_argument("--firm", default="FUTUSECURITIES")
    parser.add_argument("--port", type=int, default=11111)
    parser.add_argument("--interval", type=int, default=900,
                        help="seconds between uploads; minimum 60")
    parser.add_argument("--once", action="store_true")
    args = parser.parse_args()
    token = getpass.getpass("ThesisForge connector token (hidden): ").strip()
    opener = urllib.request.build_opener(NoRedirect())
    while True:
        try:
            report = clean(read_local_account(args.account_id, args.firm, args.port))
            request = urllib.request.Request(
                "https://www.thesisforge.tech/api/broker-connector/futu",
                data=json.dumps(report, allow_nan=False).encode(),
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"},
                method="POST")
            with opener.open(request, timeout=30) as response:
                result = json.loads(response.read(4096))
            if result.get("ok") is not True:
                raise RuntimeError("upload_rejected")
            print("Read-only snapshot synchronized.", flush=True)
        except KeyboardInterrupt:
            return
        except Exception:
            # Never echo SDK errors, account contents or credential URLs.
            print("Sync failed. Check OpenD login, selected account and connector expiry.", flush=True)
            if args.once:
                raise SystemExit(1)
        if args.once:
            return
        time.sleep(max(60, args.interval))


if __name__ == "__main__":
    main()
