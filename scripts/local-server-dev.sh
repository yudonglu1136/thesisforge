#!/usr/bin/env bash
set -euo pipefail

project_root="$(cd "$(dirname "$0")/.." && pwd)"

# Match the redesigned production workflow in local development. Public facts
# use the one canonical runtime database; user events stay in the private store.
export INVESTMENT_WORKFLOW_ENABLED="${INVESTMENT_WORKFLOW_ENABLED:-true}"
export API_AUTH_DEV_BYPASS="${API_AUTH_DEV_BYPASS:-true}"
export INVESTMENT_SOURCE_DB_PATH="${INVESTMENT_SOURCE_DB_PATH:-$project_root/server/data/guru-analysis.sqlite}"
export INVESTMENT_DB_PATH="${INVESTMENT_DB_PATH:-$project_root/server/data/user-portfolios/investment.sqlite}"
export FACT_OS_ROOT="${FACT_OS_ROOT:-$project_root/data/fact_os}"
# The redesigned workflow reads stored PIT artifacts on demand. Do not launch
# legacy background capture/backtest jobs merely by opening a local preview.
export PORTFOLIO_NAV_AUTO_CAPTURE="${PORTFOLIO_NAV_AUTO_CAPTURE:-false}"
export GURU_BACKTEST_AUTO_REFRESH="${GURU_BACKTEST_AUTO_REFRESH:-false}"
export DIVIDEND_CALENDAR_AUTO_REFRESH="${DIVIDEND_CALENDAR_AUTO_REFRESH:-false}"

exec node "$project_root/server/index.js"
