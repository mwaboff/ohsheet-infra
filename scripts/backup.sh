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

# Dump, compress, encrypt in one pipeline. Write to a unique temp file and
# rename on success: a second run on the same day (apply-infra's pre-deploy
# backup after the nightly one) replaces today's file atomically, overlapping
# runs never share a file, and a failed run never clobbers a good backup. The
# dot-prefixed name keeps temp files out of the prune glob below.
find "$BACKUP_DIR" -maxdepth 1 -name '.pg-*.tmp' -mmin +120 -delete  # leaked by killed runs
TMPFILE=$(mktemp --suffix=.tmp "$BACKUP_DIR/.pg-${TODAY}.XXXXXX")
trap 'rm -f "$TMPFILE"' EXIT
docker compose -f /srv/ohsheet/compose.yaml exec -T postgres \
    pg_dump -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" \
  | gzip \
  | gpg --batch --yes --symmetric --cipher-algo AES256 \
        --passphrase-file "$PASSPHRASE_FILE" \
        --output "$TMPFILE"
mv -f "$TMPFILE" "$OUTFILE"

dump_size=$(stat -c%s "$OUTFILE")

# Sanity check: warn if suspiciously large
if [ "$dump_size" -gt 524288000 ]; then
    emit_event "BackupRun" "warn" "backup size ${dump_size}B > 500MB"
fi

# Prune: keep the last 30 days of nightly dumps (each is ~1 MB). The previous
# scheme kept "the oldest file >= 7 days old", which froze on the very first
# backup ever taken instead of rolling weekly.
cd "$BACKUP_DIR"
cutoff=$(date -d "30 days ago" +%F)
for f in pg-*.sql.gz.gpg; do
    [ -e "$f" ] || continue
    file_date=${f#pg-}
    file_date=${file_date%.sql.gz.gpg}
    if [[ "$file_date" < "$cutoff" ]]; then
        rm -f -- "$f"
    fi
done

emit_event "BackupRun" "success" "size=${dump_size}B file=${OUTFILE}"
echo "[$(date)] SUCCESS: ${OUTFILE} (${dump_size}B)" >> "$LOG"
