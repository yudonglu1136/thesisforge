#!/usr/bin/env bash
set -euo pipefail
# Public immutable data only. A pinned, operator-approved release restores a new
# API instance; never select latest or rewind a separately activated version.
# A verified public-daily release already serves Research. Never reinstall an
# older scoped recovery generation after the operator retires its pointer.
if python3 - <<'PY_CHECK'
import json
from pathlib import Path
p = Path('/var/app/data/fact-os/active.json')
if not p.exists():
    raise SystemExit(1)
a = json.loads(p.read_text())
required = {'canonical', 'research_inputs', 'strategy_inputs', 'ai_insights',
            'institutional_13f', 'public_observations'}
ready = (a.get('state') == 'verified' and a.get('activationScope') == 'public-daily'
         and set(a.get('groups', {})) == required
         and all(Path(g.get('root', '/nonexistent')).is_dir()
                 for g in a['groups'].values()))
raise SystemExit(0 if ready else 1)
PY_CHECK
then
  echo 'Verified public-daily Research retained; scoped recovery skipped.'
  exit 0
fi
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
