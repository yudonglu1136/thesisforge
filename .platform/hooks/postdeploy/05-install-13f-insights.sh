#!/usr/bin/env bash
set -euo pipefail
umask 077

runtime_root="/var/app/data/13f-insights/releases"
environment_json="$(/opt/elasticbeanstalk/bin/get-config environment)"
config_value() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" <<<"${environment_json}"
}

release_id="${THESISFORGE_13F_INSTALL_RELEASE_ID:-$(config_value THESISFORGE_13F_INSTALL_RELEASE_ID)}"
database_url="${THESISFORGE_13F_INSTALL_DB_URL:-$(config_value THESISFORGE_13F_INSTALL_DB_URL)}"
manifest_url="${THESISFORGE_13F_INSTALL_MANIFEST_URL:-$(config_value THESISFORGE_13F_INSTALL_MANIFEST_URL)}"
gzip_sha="${THESISFORGE_13F_INSTALL_GZIP_SHA256:-$(config_value THESISFORGE_13F_INSTALL_GZIP_SHA256)}"
database_sha="${THESISFORGE_13F_INSTALL_DB_SHA256:-$(config_value THESISFORGE_13F_INSTALL_DB_SHA256)}"
database_bytes="${THESISFORGE_13F_INSTALL_DB_BYTES:-$(config_value THESISFORGE_13F_INSTALL_DB_BYTES)}"
unset environment_json

if [ -z "${release_id}${database_url}${manifest_url}${gzip_sha}${database_sha}${database_bytes}" ]; then
  echo "no 13F sidecar install configured; skipping"
  exit 0
fi
if [[ ! "${release_id}" =~ ^13f-insights-[0-9]{8}-v[1-9][0-9]*$ ]] ||
   [[ ! "${gzip_sha}" =~ ^[a-f0-9]{64}$ ]] ||
   [[ ! "${database_sha}" =~ ^[a-f0-9]{64}$ ]] ||
   [[ ! "${database_bytes}" =~ ^[1-9][0-9]{5,9}$ ]]; then
  echo "error: invalid 13F sidecar release identity or byte contract" >&2
  exit 1
fi

python3 - "${release_id}" "${database_url}" "${manifest_url}" <<'PY'
import sys
from urllib.parse import urlparse

release_id, database_url, manifest_url = sys.argv[1:]
allowed = {
    "thesisforge-production-378477120101-us-east-1.s3.amazonaws.com",
    "thesisforge-production-378477120101-us-east-1.s3.us-east-1.amazonaws.com",
}
for url, name in ((database_url, "13f-insights.sqlite.gz"), (manifest_url, "manifest.json")):
    parsed = urlparse(url)
    expected = f"/investment-releases/{release_id}/{name}"
    if parsed.scheme != "https" or parsed.hostname not in allowed or parsed.path != expected or not parsed.query:
        raise SystemExit("invalid_13f_sidecar_presigned_url")
PY

target="${runtime_root}/${release_id}"
stage="${runtime_root}/.${release_id}.part"
database="${target}/13f-insights.sqlite"
manifest="${target}/manifest.json"

validate_release() {
  python3 - "$1" "$2" "${release_id}" "${database_sha}" "${database_bytes}" <<'PY'
import hashlib
import json
import os
import sqlite3
import sys

database, manifest_path, release_id, expected_sha, expected_bytes = sys.argv[1:]
expected_bytes = int(expected_bytes)
if not os.path.isfile(database) or not os.path.isfile(manifest_path):
    raise SystemExit("13f_sidecar_files_missing")
if os.path.getsize(database) != expected_bytes:
    raise SystemExit("13f_sidecar_size_mismatch")
h = hashlib.sha256()
with open(database, "rb") as handle:
    for chunk in iter(lambda: handle.read(1024 * 1024), b""):
        h.update(chunk)
if h.hexdigest() != expected_sha:
    raise SystemExit("13f_sidecar_hash_mismatch")
manifest = json.load(open(manifest_path, encoding="utf-8"))
if (
    manifest.get("version") != "institutional-13f-artifact-v2"
    or manifest.get("releaseId") != release_id
    or manifest.get("state") != "verified"
    or manifest.get("table") != "institutional_13f_insight_snapshots_v2"
    or manifest.get("file", {}).get("path") != database
    or manifest.get("file", {}).get("bytes") != expected_bytes
    or manifest.get("file", {}).get("sha256") != expected_sha
    or manifest.get("checks", {}).get("privateDataExcluded") is not True
    or manifest.get("checks", {}).get("naturalKeyUniqueness") != "pass"
):
    raise SystemExit("13f_sidecar_manifest_mismatch")
connection = sqlite3.connect(f"file:{database}?mode=ro&immutable=1", uri=True)
try:
    tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    if tables != {"institutional_13f_insight_snapshots_v2"}:
        raise SystemExit("13f_sidecar_unexpected_tables")
    if connection.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
        raise SystemExit("13f_sidecar_integrity_failed")
    if connection.execute("PRAGMA foreign_key_check").fetchone() is not None:
        raise SystemExit("13f_sidecar_foreign_key_failed")
    rows = connection.execute("SELECT count(*) FROM institutional_13f_insight_snapshots_v2").fetchone()[0]
    duplicates = connection.execute("""
        SELECT count(*) FROM (
          SELECT report_date,source_generation,count(*) n
          FROM institutional_13f_insight_snapshots_v2
          GROUP BY report_date,source_generation HAVING n>1
        )
    """).fetchone()[0]
    if rows != manifest.get("rows") or rows < 1 or duplicates != 0:
        raise SystemExit("13f_sidecar_rows_invalid")
finally:
    connection.close()
PY
}

mkdir -p "${runtime_root}"
if [ -e "${target}" ]; then
  validate_release "${database}" "${manifest}"
  echo "13F sidecar already verified: ${release_id}"
  exit 0
fi
if [ -e "${stage}" ]; then
  echo "error: partial 13F sidecar requires operator review: ${stage}" >&2
  exit 1
fi

available_bytes="$(df -Pk "${runtime_root}" | awk 'NR==2 {print $4 * 1024}')"
required_bytes="$((database_bytes * 2 + 268435456))"
if [ "${available_bytes}" -lt "${required_bytes}" ]; then
  echo "error: insufficient disk headroom for 13F sidecar" >&2
  exit 1
fi

mkdir "${stage}"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 900 \
  "${database_url}" --output "${stage}/13f-insights.sqlite.gz"
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 120 \
  "${manifest_url}" --output "${stage}/manifest.json"

actual_gzip_sha="$(sha256sum "${stage}/13f-insights.sqlite.gz" | awk '{print $1}')"
if [ "${actual_gzip_sha}" != "${gzip_sha}" ]; then
  echo "error: compressed 13F sidecar hash mismatch" >&2
  exit 1
fi
gzip -t "${stage}/13f-insights.sqlite.gz"
gzip -dc "${stage}/13f-insights.sqlite.gz" > "${stage}/13f-insights.sqlite"
rm "${stage}/13f-insights.sqlite.gz"
stage_bytes="$(stat -c '%s' "${stage}/13f-insights.sqlite")"
stage_sha="$(sha256sum "${stage}/13f-insights.sqlite" | awk '{print $1}')"
if [ "${stage_bytes}" != "${database_bytes}" ] || [ "${stage_sha}" != "${database_sha}" ]; then
  echo "error: expanded 13F sidecar byte contract mismatch" >&2
  exit 1
fi

# The manifest is bound to the final immutable path, so validate through that
# exact pathname only after the atomic directory rename.
chmod 0444 "${stage}/13f-insights.sqlite" "${stage}/manifest.json"
chown root:root "${stage}/13f-insights.sqlite" "${stage}/manifest.json"
mv "${stage}" "${target}"
chmod 0555 "${target}"
validate_release "${database}" "${manifest}"
echo "13F sidecar installed and verified: ${release_id}"
