#!/usr/bin/env bash
set -euo pipefail

# A failed v3 bootstrap can leave verified runtime/research downloads behind
# before the release receipt and manifest are written. Remove only that exact,
# unpublished target while the complete v2 Sharadar release is still active.
# Private user stores are outside every path below and are never enumerated.
env_value() {
  /opt/elasticbeanstalk/bin/get-config environment -k "$1" 2>/dev/null || true
}

active_release="$(env_value INVESTMENT_RELEASE_ID)"
active_runtime="$(env_value SQLITE_DB_PATH)"
if [[ "$active_release" != "thesisforge-20260920-v2" \
   || "$active_runtime" != "/var/app/data/thesisforge-20260920-v2.sqlite" ]]; then
  echo "failed-v3 cleanup not required for active release ${active_release:-unknown}"
  exit 0
fi

active_root="/var/app/data/investment-releases/${active_release}"
for required in \
  "$active_runtime" \
  "$active_root/research.sqlite" \
  "$active_root/strategy.sqlite" \
  "$active_root/composition.sqlite" \
  "$active_root/manifest.json"; do
  if [[ ! -f "$required" || -L "$required" ]]; then
    echo "error: refusing failed-v3 cleanup because active v2 is incomplete: $required" >&2
    exit 1
  fi
done

failed_runtime="/var/app/data/thesisforge-20260920-v3.sqlite"
failed_root="/var/app/data/investment-releases/thesisforge-20260920-v3"
if [[ -f "$failed_root/manifest.json" ]]; then
  echo "error: refusing to remove v3 because a release manifest exists" >&2
  exit 1
fi

rm -f -- "$failed_runtime" "${failed_runtime}-wal" "${failed_runtime}-shm"
rm -rf -- "$failed_root"
echo "unpublished failed-v3 public artifacts removed; private user stores unchanged"
