#!/bin/bash
set -euo pipefail
# Only install the read runtime. No provider key or writer database belongs here.
dnf install -y python3.12 python3.12-pip amazon-ssm-agent
if [[ ! -x /opt/thesisforge-fact-os/bin/python ]]; then
  python3.12 -m venv /opt/thesisforge-fact-os
fi
/opt/thesisforge-fact-os/bin/pip install 'duckdb==1.4.4' 'httpx==0.28.1' 'boto3==1.42.70'
systemctl enable --now amazon-ssm-agent
install -d -m 0700 -o webapp -g webapp /var/app/data/fact-os-leases
