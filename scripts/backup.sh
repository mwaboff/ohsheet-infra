#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
source /usr/local/lib/ohsheet/emit-event.sh

# Load secrets from .env
set -a
# shellcheck disable=SC1091
source /srv/ohsheet/.env
set +a

BACKUP_DIR=/var/backups/postgres
PASSPHRASE_FILE=/root/.backup-passphrase
TODAY=$(date +%F)
OUTFILE="$BACKUP_DIR/pg-${TODAY}.sql.gz.gpg"
LOG=/var/log/pg-backup.log

emit_event "BackupRun" "start" "beginning backup for ${TODAY}"

# Pre-flight: abort if less than 2GB free
available_mb=$(df -BM "$BACKUP_DIR" | awk 'NR==2 {print $4}' | tr -d M)
if [ "$available_mb" -lt 2048 ]; then
    emit_event "BackupRun" "abort" "only ${available_mb}MB free, refusing pg_dump"
    echo "[$(date)] ABORT: only ${available_mb}MB free" >> "$LOG"
    exit 1
fi

# Dump, compress, encrypt in one pipeline
docker compose -f /srv/ohsheet/compose.yaml exec -T postgres \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  | gzip \
  | gpg --batch --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" \
        --output "$OUTFILE"

dump_size=$(stat -c%s "$OUTFILE")

# Sanity check: warn if suspiciously large
if [ "$dump_size" -gt 524288000 ]; then
    emit_event "BackupRun" "warn" "backup size ${dump_size}B > 500MB"
fi

# Prune: keep today, yesterday, and oldest file >= 7 days old
cd "$BACKUP_DIR"
all_files=$(ls -1 pg-*.sql.gz.gpg | sort)
today_file="pg-${TODAY}.sql.gz.gpg"
yesterday_file="pg-$(date -d yesterday +%F).sql.gz.gpg"

# Find oldest file that's at least 7 days old
weekly_keep=""
for f in $all_files; do
    file_date=${f#pg-}
    file_date=${file_date%.sql.gz.gpg}
    age_days=$(( ( $(date +%s) - $(date -d "$file_date" +%s) ) / 86400 ))
    if [ "$age_days" -ge 7 ]; then
        weekly_keep="$f"
        break
    fi
done

for f in $all_files; do
    if [ "$f" != "$today_file" ] && [ "$f" != "$yesterday_file" ] && [ "$f" != "$weekly_keep" ]; then
        rm -f "$f"
    fi
done

emit_event "BackupRun" "success" "size=${dump_size}B file=${OUTFILE}"
echo "[$(date)] SUCCESS: ${OUTFILE} (${dump_size}B)" >> "$LOG"
