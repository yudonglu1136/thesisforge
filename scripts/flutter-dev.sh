#!/usr/bin/env bash
set -euo pipefail

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
add_define "API_BASE_URL" "${API_BASE_URL:-${VITE_API_BASE_URL:-http://127.0.0.1:8787}}"
add_define "AUTH_DEV_BYPASS" "${AUTH_DEV_BYPASS:-${VITE_AUTH_DEV_BYPASS:-true}}"
add_define "INVESTMENT_WORKFLOW_ENABLED" "${INVESTMENT_WORKFLOW_ENABLED:-${VITE_INVESTMENT_WORKFLOW_ENABLED:-true}}"

flutter run -d web-server --web-hostname 127.0.0.1 --web-port 5174 "${defines[@]}"
