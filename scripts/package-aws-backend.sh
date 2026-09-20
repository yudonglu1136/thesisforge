#!/usr/bin/env bash
set -euo pipefail

version="${1:-$(git rev-parse --short HEAD)}"
zip_path="${AWS_PACKAGE_PATH:-/tmp/thesisforge-${version}.zip}"
db_path="${SQLITE_DB_PATH:-server/data/guru-analysis.sqlite}"
pit_migration_path="${PIT_MIGRATION_PATH:-server/data/valuation-pit-migration.sqlite.gz}"
include_sqlite_db="${INCLUDE_SQLITE_DB:-0}"

# The standalone module is retired. Reject stale release flags before reading
# source data or replacing an existing archive; never bundle a hidden service.
if [ "${INCLUDE_ONTOLOGY_SNAPSHOT:-0}" = "1" ]; then
  echo "error: Ontology is retired; INCLUDE_ONTOLOGY_SNAPSHOT is not supported" >&2
  exit 1
fi

# Reject an unverified working tree before replacing any existing package.
# git archive HEAD otherwise silently omits locally tested fixes/new modules.
node scripts/check-production-source.mjs >&2

rm -f "$zip_path"
git archive --format=zip --output="$zip_path" HEAD

if [ "${INCLUDE_FRONTEND_DIST:-0}" = "1" ]; then
  if [ -d dist ]; then
    zip -qr "$zip_path" dist
  else
    echo "warning: dist/ is missing; AWS package requested frontend fallback but no dist/ exists" >&2
  fi
fi

if [ "$include_sqlite_db" != "1" ]; then
  echo "info: skipping SQLite DB in AWS package; set INCLUDE_SQLITE_DB=1 to bundle a seed database" >&2
elif [ -f "$db_path" ]; then
  if [ "$db_path" = "server/data/guru-analysis.sqlite" ]; then
    zip -q -u "$zip_path" "$db_path"
  else
    tmp_dir="$(mktemp -d)"
    trap 'rm -rf "$tmp_dir"' EXIT
    mkdir -p "$tmp_dir/server/data"
    cp "$db_path" "$tmp_dir/server/data/guru-analysis.sqlite"
    (cd "$tmp_dir" && zip -q -u "$zip_path" server/data/guru-analysis.sqlite)
  fi
else
  echo "warning: SQLite DB not found at $db_path; AWS package will start with an empty local DB" >&2
fi

if [ "${INCLUDE_PIT_MIGRATION:-0}" = "1" ]; then
  if [ ! -f "$pit_migration_path" ]; then
    echo "error: PIT valuation migration artifact not found at $pit_migration_path" >&2
    exit 1
  fi
  tmp_pit_dir="$(mktemp -d)"
  mkdir -p "$tmp_pit_dir/server/data"
  cp "$pit_migration_path" "$tmp_pit_dir/server/data/valuation-pit-migration.sqlite.gz"
  if [ -f "${pit_migration_path%.sqlite.gz}.manifest.json" ]; then
    cp "${pit_migration_path%.sqlite.gz}.manifest.json" \
      "$tmp_pit_dir/server/data/valuation-pit-migration.manifest.json"
  fi
  (cd "$tmp_pit_dir" && zip -q -u "$zip_path" server/data/valuation-pit-migration.*)
else
  echo "info: skipping PIT valuation migration; set INCLUDE_PIT_MIGRATION=1 for a valuation release" >&2
fi

echo "$zip_path"
