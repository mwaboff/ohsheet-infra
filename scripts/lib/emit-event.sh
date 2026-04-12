# shellcheck shell=bash
# /usr/local/lib/ohsheet/emit-event.sh
emit_event() {
    local event_type="$1" status="$2" message="$3"
    printf '{"timestamp":"%s","eventType":"%s","status":"%s","host":"%s","message":%s}\n' \
        "$(date -u +%FT%TZ)" \
        "$event_type" \
        "$status" \
        "$(hostname)" \
        "$(printf '%s' "$message" | jq -Rs .)" \
        >> /var/log/ohsheet/events.jsonl
}
