#!/usr/bin/env bash
# Weekly cleanup of media the bot downloaded (voice, photos, documents) from
# the plugin state inbox. Files older than MEDIA_KEEP_DAYS are deleted; the
# agent is expected to have saved anything worth keeping into its library.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf

MEDIA_DIR="${TELEGRAM_STATE_DIR:?TELEGRAM_STATE_DIR unset}/inbox"
KEEP_DAYS="${MEDIA_KEEP_DAYS:-30}"
LOGFILE="$LOG_DIR/media-cleanup.log"
mkdir -p "$LOG_DIR"

if [ ! -d "$MEDIA_DIR" ]; then
  echo "$(date -Is) $MEDIA_DIR not found, skip" >> "$LOGFILE"
  exit 0
fi

before=$(find "$MEDIA_DIR" -type f | wc -l)
deleted=$(find "$MEDIA_DIR" -type f -mtime +"$KEEP_DAYS" -print -delete | wc -l)
echo "$(date -Is) cleanup: before=$before deleted=$deleted keep_days=$KEEP_DAYS" >> "$LOGFILE"
