#!/usr/bin/env bash
set -euo pipefail

mkdir -p /var/app/data
chown webapp:webapp /var/app/data || true
chmod 775 /var/app/data

# Ensure 2 GiB swap on <= 4 GiB instances so burst DuckDB/SQLite reads never
# wedge the kernel in file-backed page-fault thrashing.
mem_kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 0)"
avail_kb="$(df -Pk /var 2>/dev/null | awk 'NR==2 {print $4}' || echo 0)"
if [ "${mem_kb:-0}" -gt 0 ] && [ "${mem_kb:-0}" -lt 4194304 ] && [ "${avail_kb:-0}" -gt 6291456 ]; then
  if ! swapon --show 2>/dev/null | grep -q '/var/swapfile'; then
    if [ ! -f /var/swapfile ]; then
      dd if=/dev/zero of=/var/swapfile bs=1M count=2048 status=none
      chmod 600 /var/swapfile
      mkswap /var/swapfile >/dev/null
    fi
    swapon /var/swapfile || true
  fi
  grep -q '/var/swapfile' /etc/fstab || echo '/var/swapfile swap swap defaults 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null 2>&1 || true
  echo 'vm.swappiness=10' > /etc/sysctl.d/99-thesisforge-swap.conf
fi
