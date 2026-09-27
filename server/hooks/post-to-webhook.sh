#!/usr/bin/env bash
# Hook router: reads Claude hook JSON from stdin, injects chatId and POSTs it
# to the plugin webhook (status, hot memory). Best-effort — never fails the
# hook, except that on Stop it may return 2 from the silent-reply check, which
# makes the harness continue the turn so the agent actually replies.
#
# Active only inside the plugin TUI, where run-agent.sh exported the webhook
# token; anywhere else it no-ops. The token travels in a header, not argv.
set -uo pipefail  # no -e: the hook must not fail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_DIR="${LOG_DIR:-${TMPDIR:-/tmp}}/activity"
LOG="$LOG_DIR/hook-post.log"
mkdir -p "$LOG_DIR"

TOKEN="${TELEGRAM_PLUGIN_WEBHOOK_TOKEN:-${TELEGRAM_WEBHOOK_TOKEN:-}}"
URL="${TELEGRAM_PLUGIN_WEBHOOK_URL:-http://127.0.0.1:${TELEGRAM_WEBHOOK_PORT:-8089}/hooks/agent}"
CHAT_ID="${TELEGRAM_PLUGIN_CHAT_ID:-${OWNER_CHAT_ID:-}}"

if [ -z "$TOKEN" ] || [ -z "$CHAT_ID" ]; then
  echo "[$(date -Is)] SKIP not a plugin session (no webhook token or chat id)" >> "$LOG"
  exit 0
fi

# agentId is omitted on purpose: the webhook only enforces it when present.
BODY=$(jq -c --argjson cid "$CHAT_ID" '. + {chatId: $cid}' 2>>"$LOG") || {
  echo "[$(date -Is)] ERR jq-parse" >> "$LOG"
  exit 0
}

HOOK_EVENT=$(printf '%s' "$BODY" | jq -r '.hook_event_name // "unknown"' 2>/dev/null)

HTTP_CODE=$(printf '%s' "$BODY" | curl -sS -o /dev/null -w '%{http_code}' \
  --connect-timeout 2 --max-time 5 \
  -X POST -H "Content-Type: application/json" \
  -H "Authorization: Bearer ${TOKEN}" \
  --data-binary @- "$URL" 2>>"$LOG") || HTTP_CODE="000"

echo "[$(date -Is)] $HOOK_EVENT http=$HTTP_CODE" >> "$LOG"

# Stop: block a turn that ended without a reply tool call (2 retries, then a
# direct Bot API alert to the owner). Synchronous: exit 2 continues the turn.
if [ "$HOOK_EVENT" = "Stop" ]; then
  python3 "$HERE/silent-reply-check.py" "$BODY" "$CHAT_ID" >> "$LOG"
  [ "$?" -eq 2 ] && exit 2
fi

exit 0
