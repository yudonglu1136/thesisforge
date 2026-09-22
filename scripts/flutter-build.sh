#!/usr/bin/env bash
set -euo pipefail

load_env_file() {
  local file="$1"
  if [ ! -f "$file" ]; then
    return
  fi

  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    if [ -z "$line" ] || [[ "$line" == \#* ]] || [[ "$line" != *=* ]]; then
      continue
    fi

    local key="${line%%=*}"
    local value="${line#*=}"
    key="${key#"${key%%[![:space:]]*}"}"
    key="${key%"${key##*[![:space:]]}"}"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    value="${value%\"}"
    value="${value#\"}"
    value="${value%\'}"
    value="${value#\'}"

    if [ -n "$key" ] && [ -n "$value" ] && [ -z "${!key+x}" ]; then
      export "$key=$value"
    fi
  done < "$file"
}

load_env_file ".env.production.local"
load_env_file ".vercel/.env.production.local"

defines=()

add_define() {
  local key="$1"
  local value="$2"
  if [ -n "$value" ]; then
    defines+=("--dart-define=$key=$value")
  fi
}

add_define "SUPABASE_URL" "${SUPABASE_URL:-${VITE_SUPABASE_URL:-}}"
add_define "SUPABASE_ANON_KEY" "${SUPABASE_ANON_KEY:-${VITE_SUPABASE_ANON_KEY:-}}"
add_define "API_BASE_URL" "${API_BASE_URL:-${VITE_API_BASE_URL:-}}"
add_define "AUTH_DEV_BYPASS" "${AUTH_DEV_BYPASS:-${VITE_AUTH_DEV_BYPASS:-false}}"
resolved_investment_workflow="${INVESTMENT_WORKFLOW_ENABLED:-${VITE_INVESTMENT_WORKFLOW_ENABLED:-false}}"
if [ "$resolved_investment_workflow" != "true" ] && [ "$resolved_investment_workflow" != "false" ]; then
  echo "INVESTMENT_WORKFLOW_ENABLED must be true or false." >&2
  exit 1
fi
# Opt in only after the matching authenticated API and data migration are ready.
# This build-time flag contains no user data and never enables auth bypass.
add_define "INVESTMENT_WORKFLOW_ENABLED" "$resolved_investment_workflow"

resolved_auth_bypass="${AUTH_DEV_BYPASS:-${VITE_AUTH_DEV_BYPASS:-false}}"
resolved_supabase_url="${SUPABASE_URL:-${VITE_SUPABASE_URL:-}}"
resolved_supabase_key="${SUPABASE_ANON_KEY:-${VITE_SUPABASE_ANON_KEY:-}}"

if { [ "${VERCEL_ENV:-}" = "production" ] || [ "${NODE_ENV:-}" = "production" ]; } && [ "$resolved_auth_bypass" != "false" ]; then
  echo "Production builds must set AUTH_DEV_BYPASS=false." >&2
  exit 1
fi

if [ "${resolved_auth_bypass}" != "true" ]; then
  if [ -z "$resolved_supabase_url" ] || [ -z "$resolved_supabase_key" ]; then
    echo "Missing production Supabase config. Set SUPABASE_URL and SUPABASE_ANON_KEY, or VITE_SUPABASE_URL and VITE_SUPABASE_ANON_KEY." >&2
    exit 1
  fi
fi

node scripts/build-public-research.mjs --check
build_output="${FLUTTER_BUILD_OUTPUT:-dist}"
if [ -n "${FLUTTER_BUILD_OUTPUT:-}" ]; then
  if [ -e "$build_output" ] || [ -L "$build_output" ]; then
    echo "Isolated build output must not already exist; refusing to overwrite it." >&2
    exit 1
  fi
else
  rm -rf dist
fi
flutter build web --release --base-href / --output "$build_output" --no-wasm-dry-run "${defines[@]}"
node scripts/verify-workflow-artifact.mjs "$build_output" "$resolved_investment_workflow"
