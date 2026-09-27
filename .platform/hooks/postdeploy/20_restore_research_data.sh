#!/usr/bin/env bash
set -euo pipefail
# Public immutable data only. A pinned, operator-approved release restores a new
# API instance; never select latest or rewind a separately activated version.
key="$(/opt/elasticbeanstalk/bin/get-config environment -k THESISFORGE_RESEARCH_RELEASE_KEY 2>/dev/null || true)"
if [[ -z "$key" ]]; then exit 0; fi
if [[ ! "$key" =~ ^fact-os/published/releases/[a-f0-9]{64}\.json$ ]]; then
  echo 'Invalid Research restore release key' >&2; exit 1
fi
if [[ -f /var/app/data/fact-os/research-active.json ]]; then
  echo 'Existing Research activation retained; no automatic rollback.'
  exit 0
fi
cd /var/app/current
/opt/thesisforge-fact-os/bin/python scripts/fact-os-api-install.py \
  --bucket thesisforge-production-378477120101-us-east-1 \
  --candidate-key "$key" --expected-release none --scope research
