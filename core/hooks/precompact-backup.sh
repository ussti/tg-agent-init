#!/usr/bin/env bash
# precompact-backup.sh -- canonical R9 reversibility-impl hook.
# Copies the conversation transcript to off-session storage before Claude Code
# compacts it. Non-blocking (always exit 0) — backup is best-effort, never
# blocks compaction.
#
# Input: PreCompact JSON via stdin with session_id, transcript_path, trigger.
# Output: $BACKUP_DIR/$trigger-$session_id-$timestamp.jsonl
# Retention: keep last 60 files (~30 days at typical compaction frequency).
set -euo pipefail

BACKUP_DIR="${BACKUP_DIR:-$CLAUDE_PROJECT_DIR/.claude/backups/transcripts}"
LOG_FILE="$CLAUDE_PROJECT_DIR/.claude/logs/precompact-backup.log"
RETENTION=60

mkdir -p "$BACKUP_DIR" "$(dirname "$LOG_FILE")"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE" 2>/dev/null || true
}

INPUT=$(cat)
TRANSCRIPT=$(echo "$INPUT" | jq -r '.transcript_path // empty')
SESSION=$(echo "$INPUT" | jq -r '.session_id // "unknown"')
TRIGGER=$(echo "$INPUT" | jq -r '.trigger // "unknown"')

if [ -z "$TRANSCRIPT" ] || [ ! -f "$TRANSCRIPT" ]; then
    log "skip: transcript_path missing or not a file ($TRANSCRIPT)"
    exit 0
fi

TS=$(date -u +%Y%m%dT%H%M%SZ)
DEST="$BACKUP_DIR/${TRIGGER}-${SESSION}-${TS}.jsonl"

if cp "$TRANSCRIPT" "$DEST" 2>/dev/null; then
    SIZE=$(wc -c < "$DEST" | tr -d ' ')
    log "ok: $TRIGGER session=$SESSION size=${SIZE}B -> $(basename "$DEST")"
else
    log "fail: cp $TRANSCRIPT -> $DEST"
fi

COUNT=$(find "$BACKUP_DIR" -maxdepth 1 -name '*.jsonl' -type f 2>/dev/null | wc -l)
if [ "$COUNT" -gt "$RETENTION" ]; then
    REMOVE=$((COUNT - RETENTION))
    find "$BACKUP_DIR" -maxdepth 1 -name '*.jsonl' -type f -printf '%T@ %p\n' \
        | sort -n | head -n "$REMOVE" | awk '{print $2}' \
        | xargs -r rm -f
    log "retention: pruned $REMOVE old transcript(s)"
fi

exit 0
