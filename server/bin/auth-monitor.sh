#!/usr/bin/env bash
# Alert the owner when the agent's Claude login is dead: the OAuth access token
# in $CLAUDE_CONFIG_DIR has expired AND the credentials file has not been
# refreshed for STALE_HOURS. The next message would then fail with 401 until
# someone runs /login. Deterministic file check, no model calls.
# Edge-triggered: one alert on the transition, one on recovery. Cron: every 6h.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf || exit 1

CRED="${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR unset}/.credentials.json"
STATE_FILE="$AGENT_WS/state/auth-monitor.state"
LOG_FILE="$LOG_DIR/auth-monitor.log"
STALE_HOURS="${AUTH_STALE_HOURS:-18}"

mkdir -p "$(dirname "$STATE_FILE")" "$LOG_DIR"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"; }

prev="unknown"; [ -f "$STATE_FILE" ] && prev="$(<"$STATE_FILE")"

new="$(python3 - "$CRED" "$STALE_HOURS" <<'PY'
import json, os, sys, time
cred, stale_h = sys.argv[1], float(sys.argv[2])
try:
    with open(cred) as f:
        d = json.load(f)
    o = d.get("claudeAiOauth", d)
    exp = o.get("expiresAt", 0)
    expired = bool(exp) and exp < time.time() * 1000
    stale = (time.time() - os.path.getmtime(cred)) > stale_h * 3600
    print("needs_login" if (expired and stale) else "ok")
except Exception:
    print("unknown")  # no file (token-only auth) or unreadable: never alert
PY
)"
log "auth=$new (prev=$prev)"
[ "$new" = "unknown" ] && exit 0

if [ "$new" != "$prev" ] && [ "$prev" != "unknown" ]; then
  if [ "$new" = "needs_login" ]; then
    text="Claude login is dead (OAuth not refreshed for ${STALE_HOURS}h+); the bot will fail on the next message. Fix: ssh to the server, tmux attach -t ${PLUGIN_SESSION_NAME}, run /login."
  else
    text="Claude login is alive again."
  fi
  "$HERE/notify-owner.sh" auth-monitor "$text" && log "alert sent: $new" || log "alert FAILED"
fi
echo -n "$new" > "$STATE_FILE"
