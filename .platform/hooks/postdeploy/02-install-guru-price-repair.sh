#!/usr/bin/env bash
set -euo pipefail
umask 077

s3_uri="${GURU_PRICE_REPAIR_S3_URI:-}"
expected_sha="${GURU_PRICE_REPAIR_SHA256:-}"
snapshot_id="${GURU_PRICE_REPAIR_SNAPSHOT_ID:-}"
encrypted_snapshot_id="${GURU_PRICE_REPAIR_ENCRYPTED_SNAPSHOT_ID:-}"
source_volume_id="${GURU_PRICE_REPAIR_SOURCE_VOLUME_ID:-}"
release_id="${GURU_PRICE_REPAIR_RELEASE_ID:-}"
runtime_db="${SQLITE_DB_PATH:-/var/app/data/thesisforge.sqlite}"
runtime_dir="$(dirname "${runtime_db}")"
app_dir="${GURU_APP_DIR:-/var/app/current}"
operator="${GURU_PRICE_REPAIR_OPERATOR:-eb-postdeploy}"
backup_bucket="${PIT_BACKUP_BUCKET:-thesisforge-production-378477120101-us-east-1}"
log_file="${GURU_PRICE_REPAIR_LOG_FILE:-/var/log/guru-price-repair.log}"

exec > >(tee -a "${log_file}") 2>&1

if [ -z "${s3_uri}${expected_sha}${snapshot_id}${encrypted_snapshot_id}${source_volume_id}${release_id}" ]; then
  echo "no Guru price-repair artifact configured; skipping"
  exit 0
fi
if [[ ! "${s3_uri}" =~ ^s3://thesisforge-production-378477120101-us-east-1/guru-price-repairs/[A-Za-z0-9._/-]+\.json\.gz$ ]]; then
  echo "error: Guru price-repair S3 URI is outside the private release prefix"
  exit 1
fi
if [[ ! "${expected_sha}" =~ ^[a-f0-9]{64}$ ]]; then
  echo "error: Guru price-repair SHA-256 is invalid"
  exit 1
fi
if [[ ! "${snapshot_id}" =~ ^snap-[a-f0-9]{8,}$ ]] ||
   [[ ! "${encrypted_snapshot_id}" =~ ^snap-[a-f0-9]{8,}$ ]] ||
   [[ ! "${source_volume_id}" =~ ^vol-[a-f0-9]{8,}$ ]] ||
   [[ ! "${release_id}" =~ ^guru-curves-[A-Za-z0-9._-]{8,80}$ ]]; then
  echo "error: Guru price-repair snapshot, volume, or release identity is invalid"
  exit 1
fi
if [ ! -f "${runtime_db}" ]; then
  echo "error: runtime database is missing"
  exit 1
fi
if [ ! -d "${app_dir}" ]; then
  echo "error: application directory is missing"
  exit 1
fi

install_marker="${runtime_dir}/.guru-price-repair-${expected_sha}.installed"
success_marker="${runtime_dir}/.guru-price-repair-${expected_sha}.done"
install_report="${runtime_dir}/.guru-price-repair-${expected_sha}.install.json"
prewarm_report="${runtime_dir}/.guru-price-repair-${expected_sha}.prewarm.json"
if [ -f "${success_marker}" ]; then
  echo "Guru price-repair release already passed every required manager/window curve; marker=${success_marker}"
  exit 0
fi

if [ -z "${INTERNAL_CRON_SECRET:-}" ]; then
  environment_json="$(/opt/elasticbeanstalk/bin/get-config environment)"
  INTERNAL_CRON_SECRET="$(python3 -c 'import json,sys; print(json.load(sys.stdin).get("INTERNAL_CRON_SECRET", ""))' <<<"${environment_json}")"
  unset environment_json
  export INTERNAL_CRON_SECRET
fi
if [ -z "${INTERNAL_CRON_SECRET:-}" ]; then
  echo "error: internal cron secret is unavailable to the loopback release runner"
  exit 1
fi

if [ ! -f "${install_marker}" ]; then
  imds_token="$(curl -fsS --max-time 5 -X PUT \
    -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token)"
  current_instance_id="$(curl -fsS --max-time 5 \
    -H "X-aws-ec2-metadata-token: ${imds_token}" \
    http://169.254.169.254/latest/meta-data/instance-id)"
  unset imds_token
  instance_json="$(aws ec2 describe-instances --instance-ids "${current_instance_id}" --region us-east-1 --output json)"
  current_root_volume="$(python3 -c '
import json,sys
instance=json.load(sys.stdin)["Reservations"][0]["Instances"][0]
root=instance["RootDeviceName"]
matches=[row.get("Ebs",{}).get("VolumeId","") for row in instance.get("BlockDeviceMappings",[]) if row.get("DeviceName")==root]
print(matches[0] if len(matches)==1 else "")
' <<<"${instance_json}")"
  unset instance_json
  if [ -z "${current_instance_id}" ] || [ "${current_root_volume}" != "${source_volume_id}" ]; then
    echo "error: configured source volume is not the running instance root volume"
    exit 1
  fi

  source_snapshot_state="$(aws ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --region us-east-1 --query 'Snapshots[0].State' --output text)"
  source_snapshot_volume="$(aws ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --region us-east-1 --query 'Snapshots[0].VolumeId' --output text)"
  source_snapshot_owner="$(aws ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --region us-east-1 --query 'Snapshots[0].OwnerId' --output text)"
  source_snapshot_release="$(aws ec2 describe-snapshots --snapshot-ids "${snapshot_id}" --region us-east-1 --query 'Snapshots[0].Tags[?Key==`GuruPriceRepairRelease`].Value | [0]' --output text)"
  rollback_snapshot_state="$(aws ec2 describe-snapshots --snapshot-ids "${encrypted_snapshot_id}" --region us-east-1 --query 'Snapshots[0].State' --output text)"
  rollback_snapshot_encrypted="$(aws ec2 describe-snapshots --snapshot-ids "${encrypted_snapshot_id}" --region us-east-1 --query 'Snapshots[0].Encrypted' --output text)"
  rollback_snapshot_owner="$(aws ec2 describe-snapshots --snapshot-ids "${encrypted_snapshot_id}" --region us-east-1 --query 'Snapshots[0].OwnerId' --output text)"
  rollback_snapshot_release="$(aws ec2 describe-snapshots --snapshot-ids "${encrypted_snapshot_id}" --region us-east-1 --query 'Snapshots[0].Tags[?Key==`GuruPriceRepairRelease`].Value | [0]' --output text)"
  rollback_snapshot_source="$(aws ec2 describe-snapshots --snapshot-ids "${encrypted_snapshot_id}" --region us-east-1 --query 'Snapshots[0].Tags[?Key==`GuruPriceRepairSourceSnapshot`].Value | [0]' --output text)"
  if [ "${source_snapshot_state}" != "completed" ] ||
     [ "${source_snapshot_volume}" != "${source_volume_id}" ] ||
     [ "${source_snapshot_owner}" != "378477120101" ] ||
     [ "${source_snapshot_release}" != "${release_id}" ] ||
     [ "${rollback_snapshot_state}" != "completed" ] ||
     [ "${rollback_snapshot_encrypted}" != "True" ] ||
     [ "${rollback_snapshot_owner}" != "378477120101" ] ||
     [ "${rollback_snapshot_release}" != "${release_id}" ] ||
     [ "${rollback_snapshot_source}" != "${snapshot_id}" ]; then
    echo "error: pre-write source and encrypted rollback snapshots are not bound to this release"
    exit 1
  fi

  artifact_gz="$(mktemp "${runtime_dir}/.guru-price-repair.XXXXXX.json.gz")"
  artifact_json="$(mktemp "${runtime_dir}/.guru-price-repair.XXXXXX.json")"
  cleanup() {
    rm -f "${artifact_gz}" "${artifact_json}"
  }
  trap cleanup EXIT
  chmod 600 "${artifact_gz}" "${artifact_json}"

  repair_bucket="thesisforge-production-378477120101-us-east-1"
  repair_key="${s3_uri#s3://${repair_bucket}/}"
  remote_size="$(aws s3api head-object --bucket "${repair_bucket}" --key "${repair_key}" \
    --query ContentLength --output text)"
  if [[ ! "${remote_size}" =~ ^[0-9]+$ ]] || [ "${remote_size}" -gt 5242880 ]; then
    echo "error: remote Guru price-repair artifact exceeds 5 MiB or has invalid metadata"
    exit 1
  fi
  aws s3 cp "${s3_uri}" "${artifact_gz}" --only-show-errors
  compressed_size="$(stat -c %s "${artifact_gz}")"
  if [ "${compressed_size}" -gt 5242880 ]; then
    echo "error: compressed Guru price-repair artifact exceeds 5 MiB"
    exit 1
  fi
  actual_sha="$(sha256sum "${artifact_gz}" | awk '{print $1}')"
  if [ "${actual_sha}" != "${expected_sha}" ]; then
    echo "error: Guru price-repair artifact checksum mismatch"
    exit 1
  fi
  python3 - "${artifact_gz}" "${artifact_json}" <<'PY'
import gzip
import sys

source_path, output_path = sys.argv[1:3]
limit = 5 * 1024 * 1024
with gzip.open(source_path, "rb") as source:
    payload = source.read(limit + 1)
if len(payload) > limit:
    raise RuntimeError("decompressed Guru price-repair artifact exceeds 5 MiB")
with open(output_path, "wb") as output:
    output.write(payload)
PY

  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="${runtime_dir}/backups"
  backup_db="${backup_dir}/guru-analysis-pre-guru-price-${timestamp}.sqlite"
  backup_gz="${backup_db}.gz"
  mkdir -p "${backup_dir}"
  python3 - "${runtime_db}" "${backup_db}" <<'PY'
import sqlite3
import sys

source_path, backup_path = sys.argv[1:3]
source = sqlite3.connect(source_path, timeout=180)
backup = sqlite3.connect(backup_path, timeout=180)
try:
    source.backup(backup)
    integrity = backup.execute("PRAGMA integrity_check").fetchone()[0]
    if integrity != "ok":
        raise RuntimeError(f"backup integrity check failed: {integrity}")
finally:
    backup.close()
    source.close()
print("consistent pre-write SQLite backup created")
PY
  gzip -9 "${backup_db}"
  aws s3 cp "${backup_gz}" "s3://${backup_bucket}/database-backups/$(basename "${backup_gz}")" --only-show-errors || \
    echo "warning: SQLite backup upload failed; completed EBS snapshots remain available"

  cd "${app_dir}"
  node scripts/install-guru-price-repair.mjs \
    --artifact="${artifact_json}" \
    --snapshot-id="${snapshot_id}" \
    --encrypted-snapshot-id="${encrypted_snapshot_id}" \
    --source-volume-id="${source_volume_id}" \
    --release-id="${release_id}" \
    --operator="${operator}" \
    --base-url="http://127.0.0.1:${PORT:-8080}" \
    --output="${install_report}"
  touch "${install_marker}"
  chmod 600 "${install_marker}" "${install_report}"
fi

read -r records_sha installed_at strict_method proxy_method security_master < <(python3 - "${install_report}" <<'PY'
import json
import sys

report = json.load(open(sys.argv[1], encoding="utf-8"))
expectations = report.get("expectations") or {}
print(
    report.get("recordsSha256", ""),
    report.get("installedAt", ""),
    expectations.get("strictMethodVersion", ""),
    expectations.get("proxyMethodVersion", ""),
    expectations.get("securityMasterVersion", ""),
)
PY
)
if [[ ! "${records_sha}" =~ ^[a-f0-9]{64}$ ]] ||
   [ -z "${installed_at}" ] || [ -z "${strict_method}" ] ||
   [ -z "${proxy_method}" ] || [ -z "${security_master}" ]; then
  echo "error: Guru price-repair installation report lacks bound release identities"
  exit 1
fi

cd "${app_dir}"
node scripts/prewarm-guru-curves.mjs \
  --base-url="http://127.0.0.1:${PORT:-8080}" \
  --windows=5,10 \
  --refresh-generation="${records_sha}" \
  --not-before="${installed_at}" \
  --strict-method-version="${strict_method}" \
  --proxy-method-version="${proxy_method}" \
  --security-master-version="${security_master}" \
  --refresh-timeout-ms="${GURU_PREWARM_REFRESH_TIMEOUT_MS:-1500000}" \
  --output="${prewarm_report}" \
  --success-marker="${success_marker}"
chmod 600 "${prewarm_report}" "${success_marker}"
echo "Guru price repair and 5Y/10Y prewarm passed every required manager/window curve; artifact=${expected_sha}"
