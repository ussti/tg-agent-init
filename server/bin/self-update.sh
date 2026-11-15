#!/usr/bin/env bash
# self-update.sh -- run /update or /restart on behalf of the Telegram plugin.
#
# Usage: self-update.sh update|restart
#
# The plugin starts this detached (setsid, no TMUX, output appended to
# $LOG_DIR/self-update.log). The agent unit has KillMode=process, so this
# script survives the restart it causes. When done it writes
# $AGENT_WS/state/self-update.json:
#   {"action":"update","rc":0,"version":"abc1234","chat_id":"...","finished_at":"..."}
# and whichever plugin process is alive reports it to the owner and removes it.
# SELF_UPDATE_CHAT_ID (optional) is the chat that asked.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf

readonly RESTART_WAIT_S="${SELF_UPDATE_RESTART_WAIT_S:-120}"
readonly POLL_S=3
ACTION="${1:-}"
STATE_DIR="${AGENT_WS:?AGENT_WS unset}/state"
RESULT="$STATE_DIR/self-update.json"
UNIT="$AGENT_NAME-agent.service"

say() { echo "[self-update $(date -Is)] $*"; }

# write_result RC: atomic write so the plugin never reads half a file.
write_result() {
  local rc="$1" version=""
  [ -r "$STATE_DIR/kit-version" ] && version="$(tr -d '\n' < "$STATE_DIR/kit-version")"
  mkdir -p "$STATE_DIR"
  jq -n --arg action "$ACTION" --argjson rc "$rc" --arg version "$version" \
    --arg chat_id "${SELF_UPDATE_CHAT_ID:-}" --arg at "$(date -Is)" \
    '{action: $action, rc: $rc, version: $version, finished_at: $at}
      + (if $chat_id == "" then {} else {chat_id: $chat_id} end)' > "$RESULT.tmp"
  mv -f "$RESULT.tmp" "$RESULT"
  say "result written: action=$ACTION rc=$rc version=${version:-?}"
}

main_pid() { systemctl show -p MainPID --value "$UNIT" 2>/dev/null || echo 0; }

do_update() {
  local kit_dir=""
  [ -r "$STATE_DIR/kit-dir" ] && kit_dir="$(tr -d '\n' < "$STATE_DIR/kit-dir")"
  if [ -z "$kit_dir" ] || [ ! -f "$kit_dir/update.sh" ]; then
    say "kit repo not found (state/kit-dir is '${kit_dir:-empty}'); run ./update.sh by hand once"
    write_result 3
    return 0
  fi
  say "running $kit_dir/update.sh"
  local rc=0
  # update.sh refuses to run inside the agent's own tmux session.
  env -u TMUX -u TMUX_PANE bash "$kit_dir/update.sh" --ws "$AGENT_WS" || rc=$?
  write_result "$rc"
}

do_restart() {
  local old new waited=0
  old="$(main_pid)"
  if [ -z "$old" ] || [ "$old" = 0 ]; then
    say "$UNIT is not running"
    write_result 1
    return 0
  fi
  say "stopping main process $old; systemd brings the agent back"
  kill "$old" || { write_result 1; return 0; }
  while [ "$waited" -lt "$RESTART_WAIT_S" ]; do
    sleep "$POLL_S"
    waited=$((waited + POLL_S))
    new="$(main_pid)"
    if [ -n "$new" ] && [ "$new" != 0 ] && [ "$new" != "$old" ]; then
      say "agent is back as $new"
      write_result 0
      return 0
    fi
  done
  say "agent did not come back within ${RESTART_WAIT_S}s"
  write_result 1
}

case "$ACTION" in
  update) do_update ;;
  restart) do_restart ;;
  *) echo "usage: $0 update|restart" >&2; exit 2 ;;
esac
