#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"
release_root="${THESISFORGE_LOCAL_RELEASE_ROOT:-$project_root/data/releases/thesisforge-20260920-v3}"

# Match the redesigned production workflow in local development. Public facts
# use the one canonical runtime database; user events stay in the private store.
export INVESTMENT_WORKFLOW_ENABLED="${INVESTMENT_WORKFLOW_ENABLED:-true}"
export API_AUTH_DEV_BYPASS="${API_AUTH_DEV_BYPASS:-true}"
export SQLITE_DB_PATH="${SQLITE_DB_PATH:-$release_root/research.sqlite}"
export INVESTMENT_SOURCE_DB_PATH="${INVESTMENT_SOURCE_DB_PATH:-$release_root/research.sqlite}"
export STRATEGY_DATA_DB_PATH="${STRATEGY_DATA_DB_PATH:-$release_root/strategy.sqlite}"
export STRATEGY_COMPOSITION_PRICE_DB_PATH="${STRATEGY_COMPOSITION_PRICE_DB_PATH:-$release_root/composition.sqlite}"
export INVESTMENT_DB_PATH="${INVESTMENT_DB_PATH:-$project_root/server/data/user-portfolios/investment.sqlite}"
export FACT_OS_ROOT="${FACT_OS_ROOT:-$project_root/data/fact_os}"
# The redesigned workflow reads stored PIT artifacts on demand. Do not launch
# legacy background capture/backtest jobs merely by opening a local preview.
export PORTFOLIO_NAV_AUTO_CAPTURE="${PORTFOLIO_NAV_AUTO_CAPTURE:-false}"
export GURU_BACKTEST_AUTO_REFRESH="${GURU_BACKTEST_AUTO_REFRESH:-false}"
export DIVIDEND_CALENDAR_AUTO_REFRESH="${DIVIDEND_CALENDAR_AUTO_REFRESH:-false}"

for release_file in "$SQLITE_DB_PATH" "$INVESTMENT_SOURCE_DB_PATH" \
  "$STRATEGY_DATA_DB_PATH" "$STRATEGY_COMPOSITION_PRICE_DB_PATH"; do
  if [ ! -f "$release_file" ]; then
    echo "error: missing local Sharadar release artifact: $release_file" >&2
    exit 1
  fi
done

exec node "$project_root/server/index.js"
