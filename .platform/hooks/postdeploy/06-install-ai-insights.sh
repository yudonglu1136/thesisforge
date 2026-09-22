#!/usr/bin/env bash
set -euo pipefail
umask 077

runtime_root="/var/app/data/ai-insights/releases"
environment_json="$(/opt/elasticbeanstalk/bin/get-config environment)"
config_value() {
  python3 -c 'import json,sys; print(json.load(sys.stdin).get(sys.argv[1], ""))' "$1" <<<"${environment_json}"
}
release_id="${THESISFORGE_AI_INSIGHTS_INSTALL_RELEASE_ID:-$(config_value THESISFORGE_AI_INSIGHTS_INSTALL_RELEASE_ID)}"
archive_url="${THESISFORGE_AI_INSIGHTS_INSTALL_ARCHIVE_URL:-$(config_value THESISFORGE_AI_INSIGHTS_INSTALL_ARCHIVE_URL)}"
archive_sha="${THESISFORGE_AI_INSIGHTS_INSTALL_ARCHIVE_SHA256:-$(config_value THESISFORGE_AI_INSIGHTS_INSTALL_ARCHIVE_SHA256)}"
archive_bytes="${THESISFORGE_AI_INSIGHTS_INSTALL_ARCHIVE_BYTES:-$(config_value THESISFORGE_AI_INSIGHTS_INSTALL_ARCHIVE_BYTES)}"
unset environment_json

if [ -z "${release_id}${archive_url}${archive_sha}${archive_bytes}" ]; then
  echo "no AI Insights sidecar install configured; skipping"
  exit 0
fi
if [[ ! "${release_id}" =~ ^ai-insights-[0-9]{8}-v[1-9][0-9]*$ ]] ||
   [[ ! "${archive_sha}" =~ ^[a-f0-9]{64}$ ]] ||
   [[ ! "${archive_bytes}" =~ ^[1-9][0-9]{3,9}$ ]]; then
  echo "error: invalid AI Insights release contract" >&2
  exit 1
fi
python3 - "${release_id}" "${archive_url}" <<'PY'
import sys
from urllib.parse import urlparse
release_id, url = sys.argv[1:]
parsed = urlparse(url)
allowed = {
    "thesisforge-production-378477120101-us-east-1.s3.amazonaws.com",
    "thesisforge-production-378477120101-us-east-1.s3.us-east-1.amazonaws.com",
}
if (parsed.scheme != "https" or parsed.hostname not in allowed
        or parsed.path != f"/investment-releases/{release_id}/ai-insights.tar.gz" or not parsed.query):
    raise SystemExit("invalid_ai_insights_presigned_url")
PY

target="${runtime_root}/${release_id}"
mkdir -p "${runtime_root}"
# The installer runs as root while the Node web process runs as webapp. Keep
# release contents read-only, but make both parent directories traversable so
# the runtime can resolve and verify the configured immutable release.
chmod 0755 "$(dirname "${runtime_root}")" "${runtime_root}"
if [ -e "${target}" ]; then
  node /var/app/current/scripts/install-ai-insights-artifact.mjs --source "${target}" --target "${target}" >/dev/null
  echo "AI Insights sidecar already installed: ${release_id}"
  exit 0
fi
download="$(mktemp -d "${runtime_root}/.${release_id}.download.XXXXXX")"
trap 'rm -rf "${download}"' EXIT
curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 300 \
  "${archive_url}" --output "${download}/ai-insights.tar.gz"
if [ "$(stat -c '%s' "${download}/ai-insights.tar.gz")" != "${archive_bytes}" ] ||
   [ "$(sha256sum "${download}/ai-insights.tar.gz" | awk '{print $1}')" != "${archive_sha}" ]; then
  echo "error: AI Insights archive byte contract mismatch" >&2
  exit 1
fi
python3 - "${download}/ai-insights.tar.gz" "${release_id}" <<'PY'
import sys, tarfile
archive_path, expected_root = sys.argv[1:]
roots = set()
with tarfile.open(archive_path, "r:gz") as archive:
    for member in archive.getmembers():
        if member.issym() or member.islnk() or member.name.startswith("/") or ".." in member.name.split("/"):
            raise SystemExit("unsafe_ai_insights_archive")
        if member.name and member.name != ".":
            roots.add(member.name.split("/", 1)[0])
if roots != {expected_root}:
    raise SystemExit("invalid_ai_insights_archive_root")
PY
mkdir "${download}/source"
tar -xzf "${download}/ai-insights.tar.gz" -C "${download}/source"
source_root="${download}/source/${release_id}"
node /var/app/current/scripts/install-ai-insights-artifact.mjs \
  --source "${source_root}" --target "${target}" >/dev/null
chown -R root:root "${target}"
find "${target}" -type f -exec chmod 0444 {} +
find "${target}" -type d -exec chmod 0555 {} +
echo "AI Insights sidecar installed and verified: ${release_id}"
