#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source /usr/local/lib/ohsheet/emit-event.sh

LOG=/var/log/ohsheet/disk.log

read -r used_pct used_mb total_mb <<EOF
$(df -BM / | awk 'NR==2 {gsub("%","",$5); gsub("M","",$3); gsub("M","",$2); print $5, $3, $2}')
EOF

if [ "$used_pct" -gt 90 ]; then
    status="critical"
elif [ "$used_pct" -ge 80 ]; then
    status="warn"
else
    status="ok"
fi

message="root filesystem at ${used_pct}% (${used_mb}M / ${total_mb}M)"
emit_event "DiskCheck" "$status" "$message"
echo "[$(date -u +%FT%TZ)] ${status} ${message}" >> "$LOG"
