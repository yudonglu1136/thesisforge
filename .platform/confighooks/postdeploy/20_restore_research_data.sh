#!/usr/bin/env bash
set -euo pipefail
exec bash /var/app/current/.platform/hooks/postdeploy/20_restore_research_data.sh
