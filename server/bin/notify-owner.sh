#!/usr/bin/env bash
# Send a short service alert to the agent owner through the agent's own bot.
# Used by ratewatch (dropped message), auth-monitor (login dead) and the
# silent-reply check. Throttled: the same text goes out at most once per
# NOTIFY_THROTTLE_S. Never prints the bot token; exit 0 unless the send failed.
#
# Usage: notify-owner.sh <source> <text>
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf

SOURCE_TAG="${1:-${AGENT_NAME:-agent}}"
TEXT="${2:-}"
THROTTLE_S="${NOTIFY_THROTTLE_S:-600}"
MAX_TEXT_CHARS=600
STATE="${LOG_DIR:?LOG_DIR unset}/notify-owner.history"
LOG="$LOG_DIR/notify-owner.log"
API_BASE="${TELEGRAM_API_BASE:-https://api.telegram.org}"

mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >> "$LOG"; }

[ -n "$TEXT" ] || { echo "usage: $0 <source> <text>" >&2; exit 2; }
[ -n "${OWNER_CHAT_ID:-}" ] || { log "SKIP: OWNER_CHAT_ID unset"; exit 0; }

digest="$(printf '%s|%s' "$SOURCE_TAG" "$TEXT" | sha256sum | cut -c1-16)"
now="$(date +%s)"
last="$(awk -v d="$digest" '$1 == d { t = $2 } END { print t + 0 }' "$STATE" 2>/dev/null || echo 0)"
if (( now - last < THROTTLE_S )); then
  log "THROTTLED: $SOURCE_TAG ${TEXT:0:40}"
  exit 0
fi

bot_token="$(conf_value "$(channel_conf)" TELEGRAM_BOT_TOKEN)"
[ -n "$bot_token" ] || { log "SKIP: bot token unreadable"; exit 0; }

message="[${AGENT_NAME:-agent} / $SOURCE_TAG] ${TEXT:0:$MAX_TEXT_CHARS}"
# Token goes to curl through a config on stdin, so it never shows in ps output.
if printf 'url = "%s/bot%s/sendMessage"\n' "$API_BASE" "$bot_token" \
  | curl -sS --max-time 10 -o /dev/null -K - \
      --data-urlencode "chat_id=$OWNER_CHAT_ID" --data-urlencode "text=$message"; then
  printf '%s %s\n' "$digest" "$now" >> "$STATE"
  tail -200 "$STATE" > "$STATE.tmp" && mv "$STATE.tmp" "$STATE"
  log "SENT: $SOURCE_TAG ${TEXT:0:40}"
else
  log "FAILED: $SOURCE_TAG ${TEXT:0:40}"
  exit 1
fi
