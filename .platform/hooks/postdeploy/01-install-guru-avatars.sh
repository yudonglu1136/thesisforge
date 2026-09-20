#!/usr/bin/env bash
set -euo pipefail

app_dir="${GURU_APP_DIR:-/var/app/current}"
runtime_db="${SQLITE_DB_PATH:-/var/app/data/thesisforge.sqlite}"

if [ ! -d "${app_dir}" ]; then
  echo "error: application directory is missing: ${app_dir}" >&2
  exit 1
fi
if [ ! -f "${runtime_db}" ]; then
  echo "error: runtime database is missing: ${runtime_db}" >&2
  exit 1
fi
if [ ! -f "${app_dir}/server/installGuruAvatars.js" ]; then
  echo "error: strict Guru avatar installer is missing" >&2
  exit 1
fi

node_bin="$(command -v node)"
cd "${app_dir}"

if id webapp >/dev/null 2>&1; then
  runuser -u webapp -- env SQLITE_DB_PATH="${runtime_db}" "${node_bin}" server/installGuruAvatars.js
else
  SQLITE_DB_PATH="${runtime_db}" "${node_bin}" server/installGuruAvatars.js
fi

echo "Guru avatar catalog validated and installed into ${runtime_db}"
