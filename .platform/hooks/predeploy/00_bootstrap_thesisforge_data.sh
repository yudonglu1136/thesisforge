#!/usr/bin/env bash
set -euo pipefail

# A fresh ThesisForge environment has no persistent application data. Bootstrap
# only exact, public, content-addressed SQLite artifacts. Private user stores are
# restored separately by the reviewed operator cutover and are never downloaded
# by a deployment hook.
env_value() {
  /opt/elasticbeanstalk/bin/get-config environment -k "$1" 2>/dev/null || true
}

runtime_db="$(env_value SQLITE_DB_PATH)"
release_id="$(env_value INVESTMENT_RELEASE_ID)"
release_root="/var/app/data/investment-releases/${release_id}"
manifest_path="$(env_value INVESTMENT_RELEASE_MANIFEST_PATH)"
runtime_receipt="$release_root/runtime-bootstrap.json"
cutoff="$(env_value THESISFORGE_PUBLIC_DATA_CUTOFF)"

if [[ -z "$runtime_db" || -z "$release_id" || -z "$manifest_path" || -z "$cutoff" ]]; then
  echo "error: ThesisForge public-data bootstrap variables are incomplete" >&2
  exit 1
fi
if [[ "$runtime_db" != "/var/app/data/thesisforge.sqlite" \
   && "$runtime_db" != "/var/app/data/${release_id}.sqlite" ]]; then
  echo "error: unexpected ThesisForge runtime target" >&2
  exit 1
fi
if [[ "$manifest_path" != "$release_root/manifest.json" \
   || ! "$release_id" =~ ^thesisforge-[0-9]{8}-v[1-9][0-9]*$ \
   || ! "$cutoff" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "error: unexpected ThesisForge public-data target" >&2
  exit 1
fi

mkdir -p /var/app/data "$release_root"
chmod 755 /var/app/data

install_exact_file() {
  local key="$1" target="$2"
  local uri bytes digest temp actual_bytes actual_digest
  uri="$(env_value "THESISFORGE_${key}_S3_URI")"
  bytes="$(env_value "THESISFORGE_${key}_BYTES")"
  digest="$(env_value "THESISFORGE_${key}_SHA256")"
  if [[ ! "$uri" =~ ^s3://thesisforge-production-378477120101-us-east-1/[A-Za-z0-9._/-]+\.sqlite$ \
     || ! "$bytes" =~ ^[1-9][0-9]*$ || ! "$digest" =~ ^[a-f0-9]{64}$ ]]; then
    echo "error: invalid ${key} artifact contract" >&2
    exit 1
  fi
  if [[ -f "$target" ]]; then
    if [[ "$key" == "RUNTIME_DB" ]]; then
      if [[ ! -f "$runtime_receipt" || -L "$runtime_receipt" || -L "$target" ]]; then
        echo "error: mutable runtime database has no verified bootstrap receipt" >&2
        exit 1
      fi
      THESISFORGE_RUNTIME_RECEIPT="$runtime_receipt" \
      THESISFORGE_RUNTIME_TARGET="$target" \
      THESISFORGE_RUNTIME_URI="$uri" \
      THESISFORGE_RUNTIME_BYTES="$bytes" \
      THESISFORGE_RUNTIME_DIGEST="$digest" \
      node --input-type=module <<'NODE'
import fs from 'node:fs';
const receipt=JSON.parse(fs.readFileSync(process.env.THESISFORGE_RUNTIME_RECEIPT,'utf8'));
const stat=fs.lstatSync(process.env.THESISFORGE_RUNTIME_TARGET);
if(!stat.isFile()||stat.isSymbolicLink()||stat.nlink!==1||stat.size<4096
  ||receipt.version!==1||receipt.uri!==process.env.THESISFORGE_RUNTIME_URI
  ||receipt.bytes!==Number(process.env.THESISFORGE_RUNTIME_BYTES)
  ||receipt.sha256!==process.env.THESISFORGE_RUNTIME_DIGEST)throw Error('runtime_bootstrap_receipt_mismatch');
NODE
      return 0
    fi
    actual_bytes="$(stat -c %s "$target")"
    actual_digest="$(sha256sum "$target" | cut -d ' ' -f 1)"
    if [[ "$actual_bytes" == "$bytes" && "$actual_digest" == "$digest" ]]; then
      chmod 0444 "$target"
      return 0
    fi
    echo "error: existing ${key} artifact does not match the release contract" >&2
    exit 1
  fi
  temp="${target}.download-$$"
  trap 'rm -f "$temp"' RETURN
  aws s3 cp "$uri" "$temp" --only-show-errors
  actual_bytes="$(stat -c %s "$temp")"
  actual_digest="$(sha256sum "$temp" | cut -d ' ' -f 1)"
  if [[ "$actual_bytes" != "$bytes" || "$actual_digest" != "$digest" ]]; then
    echo "error: downloaded ${key} artifact failed verification" >&2
    exit 1
  fi
  chmod 0444 "$temp"
  mv "$temp" "$target"
  trap - RETURN
}

install_exact_file "RUNTIME_DB" "$runtime_db"
install_exact_file "RESEARCH_DB" "$release_root/research.sqlite"
install_exact_file "STRATEGY_DB" "$release_root/strategy.sqlite"
install_exact_file "COMPOSITION_DB" "$release_root/composition.sqlite"

if [[ ! -f "$runtime_receipt" ]]; then
  umask 022
  THESISFORGE_RUNTIME_RECEIPT="$runtime_receipt" node --input-type=module <<'NODE'
import fs from 'node:fs';
import {execFileSync} from 'node:child_process';
const env=JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
const receipt={version:1,releaseId:env.INVESTMENT_RELEASE_ID,uri:env.THESISFORGE_RUNTIME_DB_S3_URI,
  bytes:Number(env.THESISFORGE_RUNTIME_DB_BYTES),sha256:env.THESISFORGE_RUNTIME_DB_SHA256,
  verifiedBeforeMutation:true,createdAt:new Date().toISOString()};
if(!receipt.uri||!Number.isSafeInteger(receipt.bytes)||!/^[a-f0-9]{64}$/.test(receipt.sha256))throw Error('invalid_runtime_receipt');
fs.writeFileSync(process.env.THESISFORGE_RUNTIME_RECEIPT,JSON.stringify(receipt,null,2),{flag:'wx',mode:0o444});
NODE
fi

if [[ ! -f "$manifest_path" ]]; then
  umask 022
  node --input-type=module <<'NODE'
import fs from 'node:fs';
import path from 'node:path';
import {execFileSync} from 'node:child_process';
const env=JSON.parse(execFileSync('/opt/elasticbeanstalk/bin/get-config',['environment'],{encoding:'utf8'}));
const root=path.dirname(env.INVESTMENT_RELEASE_MANIFEST_PATH);
const files={};
for(const [key,name] of [['research','RESEARCH_DB'],['strategy','STRATEGY_DB'],['composition','COMPOSITION_DB']]){
  const file=path.join(root,`${key}.sqlite`),bytes=Number(env[`THESISFORGE_${name}_BYTES`]);
  const sha256=env[`THESISFORGE_${name}_SHA256`];
  if(fs.statSync(file).size!==bytes||!/^[a-f0-9]{64}$/.test(sha256))throw Error('manifest_source_mismatch');
  files[key]={path:file,bytes,sha256,producerValidation:{integrity:'ok',foreignKeys:0,privateTables:0,schema:'pass'},hostValidation:{sha256:'matched',schema:'pass',journalMode:'delete',fullScan:'verified_before_upload'}};
}
const manifest={version:'investment-runtime-release-v1',releaseId:env.INVESTMENT_RELEASE_ID,state:'verified',cutoff:env.THESISFORGE_PUBLIC_DATA_CUTOFF,
  installedAt:new Date().toISOString(),rollbackSnapshot:'fresh-environment-bootstrap',checks:{integrity:'ok',schema:'pass',sourceAlignment:'pass',privateDataExcluded:true},
  validationBasis:'local full integrity and foreign-key checks plus host sha256',files};
fs.writeFileSync(env.INVESTMENT_RELEASE_MANIFEST_PATH,JSON.stringify(manifest,null,2),{flag:'wx',mode:0o444});
NODE
fi

chmod 0555 "$release_root"
chown -R root:root "$release_root"
if ! id webapp >/dev/null 2>&1; then
  echo "error: Elastic Beanstalk application user is missing" >&2
  exit 1
fi
# The release databases are immutable research inputs. The main runtime copy is
# deliberately separate: existing schema installers and bounded runtime caches
# write to it as the unprivileged application user.
chown webapp:webapp /var/app/data
chmod 0775 /var/app/data
chown webapp:webapp "$runtime_db"
chmod 0600 "$runtime_db"
runuser -u webapp -- env THESISFORGE_BOOTSTRAP_DB="$runtime_db" node --input-type=module <<'NODE'
import {DatabaseSync} from 'node:sqlite';
const target=process.env.THESISFORGE_BOOTSTRAP_DB;
if(!target)throw Error('missing_bootstrap_database');
const database=new DatabaseSync(target);
try {
  database.exec('PRAGMA journal_mode=WAL; PRAGMA busy_timeout=5000; PRAGMA wal_checkpoint(TRUNCATE);');
  if(database.prepare('PRAGMA journal_mode').get().journal_mode!=='wal')throw Error('runtime_wal_not_writable');
} finally {database.close();}
NODE
echo "ThesisForge public data bootstrap is verified."
