#!/usr/bin/env bash
set -euo pipefail

# This is intentionally opt-in. The Sharadar release must be the active,
# fully bound runtime before any retired public artifact can be removed.
# Private user stores live under /var/app/data/user-portfolios and are never
# inspected, enumerated, or modified here.
if [ "${THESISFORGE_DELETE_RETIRED_YAHOO_PUBLIC_DATA:-false}" != "true" ]; then
  echo "retired Yahoo public-data cleanup is disabled"
  exit 0
fi

expected_release="thesisforge-20260920-v3"
expected_runtime="/var/app/data/${expected_release}.sqlite"
expected_root="/var/app/data/investment-releases/${expected_release}"

if [ "${INVESTMENT_RELEASE_ID:-}" != "${expected_release}" ] ||
   [ "${SQLITE_DB_PATH:-}" != "${expected_runtime}" ] ||
   [ "${INVESTMENT_SOURCE_DB_PATH:-}" != "${expected_root}/research.sqlite" ] ||
   [ "${STRATEGY_DATA_DB_PATH:-}" != "${expected_root}/strategy.sqlite" ] ||
   [ "${STRATEGY_COMPOSITION_PRICE_DB_PATH:-}" != "${expected_root}/composition.sqlite" ]; then
  echo "error: refusing retired-data cleanup because the complete Sharadar release is not active" >&2
  exit 1
fi

for required in \
  "${expected_runtime}" \
  "${expected_root}/research.sqlite" \
  "${expected_root}/strategy.sqlite" \
  "${expected_root}/composition.sqlite" \
  "${expected_root}/manifest.json"; do
  if [ ! -f "${required}" ] || [ -L "${required}" ]; then
    echo "error: refusing retired-data cleanup because a Sharadar artifact is missing or symbolic: ${required}" >&2
    exit 1
  fi
done

private_root="/var/app/data/user-portfolios"
for retired in \
  "/var/app/data/thesisforge.sqlite" \
  "/var/app/data/thesisforge.sqlite-wal" \
  "/var/app/data/thesisforge.sqlite-shm"; do
  if [ -e "${retired}" ]; then
    rm -f -- "${retired}"
  fi
done

for retired_root in \
  "/var/app/data/investment-releases/thesisforge-20260920-v1" \
  "/var/app/data/investment-releases/redesign-20260912-v1"; do
  if [ -e "${retired_root}" ]; then
    case "${retired_root}" in
      "${private_root}"|"${private_root}"/*|"${expected_root}")
        echo "error: protected path reached retired-data cleanup" >&2
        exit 1
        ;;
    esac
    rm -rf -- "${retired_root}"
  fi
done

echo "retired Yahoo public runtime and release artifacts removed; private user stores unchanged"
