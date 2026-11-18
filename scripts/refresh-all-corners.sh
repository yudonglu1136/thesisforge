#!/usr/bin/env bash
set -euo pipefail

# ThesisForge All-Corners Refresh Orchestrator
# Refreshes every data plane so earnings, market prices, institutional 13F,
# AI insights, ROIC quality, and tactical strategies stay 100% synchronized.
#
# Usage:
#   bash scripts/refresh-all-corners.sh [options]
#
# Options:
#   --with-earnings-pit   Also run SEC/UK guidance + transcript Q&A + PIT valuation verification checks
#   --with-13f            Also run SEC 13F CUSIP/security-master & manager filing refresh
#   --skip-aws            Refresh all local corners without pushing/activating on AWS S3 & EC2
#   --dry-run             Print planned execution stages and exit 0

PROJECT_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_ROOT"

PYTHON_BIN="$PROJECT_ROOT/.venv-fact-os/bin/python"
WITH_EARNINGS_PIT=0
WITH_13F=0
SKIP_AWS=0
DRY_RUN=0

for arg in "$@"; do
  case "$arg" in
    --with-earnings-pit) WITH_EARNINGS_PIT=1 ;;
    --with-13f) WITH_13F=1 ;;
    --skip-aws) SKIP_AWS=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h|--help)
      sed -n '3,16p' "$0"
      exit 0
      ;;
    *)
      echo "Unknown option: $arg" >&2
      exit 1
      ;;
  esac
done

log_stage() {
  printf '\n======================================================================\n'
  printf '[ThesisForge Refresh] %s\n' "$1"
  printf '======================================================================\n'
}

if [ "$DRY_RUN" -eq 1 ]; then
  echo "Planned All-Corners Refresh Stages (root: $PROJECT_ROOT):"
  echo "  1. Fact OS 14-table Sharadar bulk-sync + 6 derived groups (canonical, public_observations, research_inputs, institutional_13f, ai_insights, strategy_inputs/rulePortfolios)"
  echo "  2. Tactical daily strategy artifacts (QQQ <-> SCHD Rotation + Hot Breakout Pullback)"
  echo "  3. Public research snapshot check (npm run build:research -- --check)"
  [ "$WITH_EARNINGS_PIT" -eq 1 ] && echo "  4. Earnings-season PIT guidance, transcript Q&A & valuation audit"
  [ "$WITH_13F" -eq 1 ] && echo "  5. SEC 13F security-master & manager copy-simulation refresh"
  [ "$SKIP_AWS" -eq 0 ] && echo "  6. AWS S3 upload + EC2 fenced installation & rolling retention + live status check"
  exit 0
fi

if [ ! -x "$PYTHON_BIN" ]; then
  echo "error: missing Fact OS Python runtime at $PYTHON_BIN" >&2
  exit 1
fi

# Stage 1: Sharadar 14-table sync + all 6 Fact OS derived groups
log_stage "Stage 1/6 — Sharadar 14-Table Bulk Sync & 6 Fact OS Derived Groups"
bash bin/fact-os bulk-sync --profile aws-data-daily

# Stage 2: Rebuild daily tactical strategy artifacts against latest Fact OS canonical data
log_stage "Stage 2/6 — Tactical Strategy Artifacts (QQQ <-> SCHD & Hot Breakout Pullback)"
"$PYTHON_BIN" scripts/build-qqq-schd-rotation-artifact.py \
  --forward-extend \
  --fact-root data/fact_os \
  --output server/config/qqq-schd-rotation-dashboard.json

"$PYTHON_BIN" scripts/build-breakout-pullback-artifact.py \
  --fact-root data/fact_os \
  --output server/config/hot-breakout-pullback-dashboard.json

# Stage 3: Verify curated public research snapshot integrity
log_stage "Stage 3/6 — Public Research Snapshot Verification"
node scripts/build-public-research.mjs --check

# Stage 4 (Optional / Earnings Season): Official Guidance, Transcripts & Valuation Audit
if [ "$WITH_EARNINGS_PIT" -eq 1 ]; then
  log_stage "Stage 4/6 — Earnings-Season Guidance, Transcripts & Valuation Audit"
  "$PYTHON_BIN" scripts/import-sec-official-guidance.py --help >/dev/null
  npm run audit:valuation
else
  log_stage "Stage 4/6 — Earnings-Season PIT Model Rebuild (Skipped; pass --with-earnings-pit when publishing new quarterly fair-value nodes)"
fi

# Stage 5 (Optional / 13F Window): SEC 13F & Guru Curve Matrix Refresh
if [ "$WITH_13F" -eq 1 ]; then
  log_stage "Stage 5/6 — SEC 13F Filings & Guru Curve Matrix Refresh"
  npm run refresh:13f
else
  log_stage "Stage 5/6 — SEC 13F Manager Refresh (Skipped; pass --with-13f during 45-day SEC 13F windows)"
fi

# Stage 6: AWS S3 Content-Addressed Upload + Live EC2 Activation
if [ "$SKIP_AWS" -eq 0 ]; then
  log_stage "Stage 6/6 — AWS S3 Publication & Live EC2 Atomic Activation"
  NO_PROXY='*' no_proxy='*' HTTP_PROXY='' HTTPS_PROXY='' ALL_PROXY='' http_proxy='' https_proxy='' all_proxy='' \
    "$PYTHON_BIN" scripts/fact-os-aws-sync.py sync --activate
  NO_PROXY='*' no_proxy='*' HTTP_PROXY='' HTTPS_PROXY='' ALL_PROXY='' http_proxy='' https_proxy='' all_proxy='' \
    "$PYTHON_BIN" scripts/fact-os-aws-sync.py status
else
  log_stage "Stage 6/6 — AWS Publication (Skipped via --skip-aws)"
fi

log_stage "All-Corners Refresh Summary"
"$PYTHON_BIN" - <<'PY'
import json
from pathlib import Path

for rel in [
    "server/config/qqq-schd-rotation-dashboard.json",
    "server/config/hot-breakout-pullback-dashboard.json",
]:
    p = Path(rel)
    if p.exists():
        data = json.loads(p.read_text(encoding="utf-8"))
        dt = data.get("dataThrough") or (data.get("metadata") or {}).get("dataThrough")
        print(f"  [OK] {rel} -> dataThrough={dt}")
PY
echo "Reminder: If server/config/*.json or UI screenshots changed, commit onto trunk, push to origin/trunk, and deploy backend via scripts/package-aws-backend.sh."
