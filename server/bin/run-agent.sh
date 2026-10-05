#!/usr/bin/env bash
# Run the agent under systemd: Claude TUI in a tmux pane with the dashi-channel
# plugin (bun MCP server) as its child. The TUI needs a PTY, hence tmux; this
# script holds the unit's main process and exits non-zero when bun, the
# webhook port or the tmux session disappears, so Restart=always respawns the
# whole stack.
#
# All paths come from agent.conf (see lib.sh). Secrets are read inside the
# pane from $SECRETS_DIR and never pass through this script's argv or log.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf

SESSION="${PLUGIN_SESSION_NAME:?PLUGIN_SESSION_NAME unset}"
WORKDIR="${PLUGIN_DIR:?PLUGIN_DIR unset}"
CLAUDE_BIN="${CLAUDE_BIN:?CLAUDE_BIN unset}"
LIBRARY_DIR="${LIBRARY_DIR:?LIBRARY_DIR unset}"
LOG_DIR="${LOG_DIR:?LOG_DIR unset}"
MODEL="${AGENT_MODEL:-opus}"
WEBHOOK_PORT="${TELEGRAM_WEBHOOK_PORT:-8089}"
CHANNEL_CONF="$(channel_conf)"
AUTH_CONF="$(auth_conf)"
RUN_USER="$(id -un)"

DEV_PROMPT_TIMEOUT_S=30
BUN_TIMEOUT_S=60
PORT_TIMEOUT_S=30
MONITOR_INTERVAL_S=10
PANE_COLS=200
PANE_ROWS=50

# Private messages are delivered through the plugin's file inbox: the plugin
# commits each DM as a JSON file under $DM_STATE_DIR/chats/<id>/inbox and one
# watcher per chat pastes it into this pane with a verified Enter. An MCP
# notification alone can leave the text in the composer unsent. One list
# feeds both the plugin env and the watchers — a chat listed for the plugin
# but not watched would strand messages on disk.
DM_STATE_DIR="${DM_STATE_DIR:-$AGENT_WS/state/dm-inbox}"
DM_CHAT_IDS="${DM_CHAT_IDS:-${OWNER_CHAT_ID:?OWNER_CHAT_ID unset}}"
WATCHER="$WORKDIR/src/chats/hooks/multichat-entrypoint.sh"
WATCHER_LOG="$LOG_DIR/dm-inbox-watcher.log"
WATCHER_PIDS=""

mkdir -p "$LOG_DIR" "$DM_STATE_DIR"

log() { printf '[%s] [run-agent] %s\n' "$(date -Is)" "$*"; }

start_watchers() {
  [ -f "$WATCHER" ] || { log "WARNING: watcher missing at $WATCHER"; return 1; }
  WATCHER_PIDS=""
  local chat_id pid
  for chat_id in $(printf '%s' "$DM_CHAT_IDS" | tr ',' ' '); do
    [ -n "$chat_id" ] || continue
    mkdir -p "$DM_STATE_DIR/chats/$chat_id/inbox"
    # Through bash on purpose: upstream ships the file without +x.
    CHAT_ID="$chat_id" \
    MULTICHAT_STATE_DIR="$DM_STATE_DIR" \
    MULTICHAT_WATCH_ONLY=1 \
    MULTICHAT_TARGET_PANE="$SESSION" \
      bash "$WATCHER" >>"$WATCHER_LOG" 2>&1 &
    pid=$!
    WATCHER_PIDS="$WATCHER_PIDS $pid"
    log "dm inbox watcher started (chat $chat_id, PID $pid)"
  done
  [ -n "$WATCHER_PIDS" ] || { log "WARNING: no DM chat ids configured"; return 1; }
}

cleanup() {
  local pid
  for pid in $WATCHER_PIDS; do kill "$pid" 2>/dev/null || true; done
  log "cleanup: killing tmux session $SESSION"
  tmux kill-session -t "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

# bun_pids: plugin servers of THIS agent — our user, comm "bun", server.ts in
# args, and cwd inside our plugin dir. A cmdline-only match could hit another
# agent's plugin on the same host.
bun_pids() {
  local pid
  for pid in $(ps -eo pid,user,comm,args 2>/dev/null \
      | awk -v u="$RUN_USER" '$2 == u && $3 == "bun" && $0 ~ /server\.ts/ {print $1}'); do
    [ "$(readlink "/proc/$pid/cwd" 2>/dev/null)" = "$WORKDIR" ] && printf '%s\n' "$pid"
  done
  return 0
}

port_listening() {
  ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":${WEBHOOK_PORT}\$"
}

dump_pane() {
  log "--- last 30 lines of tmux pane ---"
  tmux capture-pane -t "$SESSION" -p -S -30 2>/dev/null | tail -30 \
    | while IFS= read -r line; do log "TUI: $line"; done
}

# 1. Sanity checks
[ -f "$CHANNEL_CONF" ] || { log "FATAL: missing channel config in SECRETS_DIR"; exit 1; }
[ -x "$CLAUDE_BIN" ]   || { log "FATAL: missing $CLAUDE_BIN"; exit 1; }
[ -d "$WORKDIR" ]      || { log "FATAL: missing $WORKDIR"; exit 1; }
[ -d "$LIBRARY_DIR" ]  || { log "FATAL: missing $LIBRARY_DIR"; exit 1; }
command -v tmux >/dev/null || { log "FATAL: tmux not installed"; exit 1; }

# 2. Reap leftovers from a crashed run: two bun servers would fight over the
# bot token (getUpdates conflict). Claude TUIs are matched by the dev-channels
# flag AND our library dir, so other agents' TUIs survive.
log "reaping leftover plugin processes"
for pid in $(bun_pids); do kill "$pid" 2>/dev/null || true; done
ps -eo pid,user,comm,args 2>/dev/null \
  | awk -v u="$RUN_USER" -v lib="$LIBRARY_DIR" \
      '$2 == u && $3 == "claude" && $0 ~ /--dangerously-load-development-channels/ && index($0, lib) {print $1}' \
  | xargs -r kill 2>/dev/null || true
tmux kill-session -t "$SESSION" 2>/dev/null || true
sleep 2

# 3. Fresh tmux session, fixed size so the TUI renders predictably.
log "starting tmux session $SESSION"
tmux new-session -d -s "$SESSION" -c "$WORKDIR" -x "$PANE_COLS" -y "$PANE_ROWS"

# 4. Launch the TUI. The pane sources agent.conf and the channel config itself;
# the optional account OAuth token is a fallback for an expired per-agent login.
KEYS_CONF="$(keys_conf)"
LAUNCH_CMD="set -a; . '$TG_AGENT_CONF'; . '$CHANNEL_CONF'"
[ -f "$KEYS_CONF" ] && LAUNCH_CMD+="; . '$KEYS_CONF'"
LAUNCH_CMD+="; set +a"
LAUNCH_CMD+="; export TELEGRAM_DM_DELIVERY_MODE=inbox TELEGRAM_DM_DELIVERY_STATE_DIR='$DM_STATE_DIR' TELEGRAM_DM_DELIVERY_CHAT_IDS='$DM_CHAT_IDS'"
if [ -f "$AUTH_CONF" ]; then
  LAUNCH_CMD+="; export CLAUDE_CODE_OAUTH_TOKEN=\$(sed -n 's/^CLAUDE_CODE_OAUTH_TOKEN=//p' '$AUTH_CONF' | head -1 | tr -d '\"')"
fi
# office runtime begin: document-skills run python from the kit venv and require() node
# libraries installed into ~/.local by kit/install-kit.sh
OFFICE_VENV="$HOME/.local/share/agent-kit/office-venv"
[ -d "$OFFICE_VENV/bin" ] && LAUNCH_CMD+="; export PATH='$OFFICE_VENV/bin':\"\$PATH\""
LAUNCH_CMD+="; export NODE_PATH='$HOME/.local/lib/node_modules'"
# office runtime end
LAUNCH_CMD+="; export CLAUDE_CONFIG_DIR='${CLAUDE_CONFIG_DIR:?CLAUDE_CONFIG_DIR unset}'"
LAUNCH_CMD+="; exec '$CLAUDE_BIN' --model '$MODEL' --permission-mode bypassPermissions"
LAUNCH_CMD+=" --add-dir '$LIBRARY_DIR' --dangerously-load-development-channels server:dashi-channel"
log "launching Claude TUI (model $MODEL)"
tmux send-keys -t "$SESSION" "$LAUNCH_CMD" Enter

# 4b. The TUI asks to confirm development channels on every launch and has no
# flag to skip it. Accept it by its unique marker.
DEV_PROMPT_MARKER="I am using this for local development"
dev_seen=0
for i in $(seq 1 "$DEV_PROMPT_TIMEOUT_S"); do
  if tmux capture-pane -t "$SESSION" -p 2>/dev/null | grep -qF "$DEV_PROMPT_MARKER"; then
    log "dev-channels prompt after ${i}s — accepting"
    tmux send-keys -t "$SESSION" "1" Enter
    dev_seen=1
    break
  fi
  sleep 1
done
[ "$dev_seen" -eq 1 ] || log "WARNING: dev-channels prompt not seen in ${DEV_PROMPT_TIMEOUT_S}s"

# 5. Wait for the bun MCP server.
for i in $(seq 1 "$BUN_TIMEOUT_S"); do
  if [ -n "$(bun_pids)" ]; then
    log "bun started (PID $(bun_pids | head -1) after ${i}s)"
    break
  fi
  sleep 1
done
if [ -z "$(bun_pids)" ]; then
  log "FATAL: bun did not start within ${BUN_TIMEOUT_S}s"
  dump_pane
  exit 1
fi

# 5b. Wait for the webhook port: hooks post Stop/UserPromptSubmit there and
# hot memory is written from it. Without it memory silently stops.
for i in $(seq 1 "$PORT_TIMEOUT_S"); do
  if port_listening; then
    log "webhook port $WEBHOOK_PORT listening after ${i}s"
    break
  fi
  sleep 1
done
if ! port_listening; then
  log "FATAL: webhook port $WEBHOOK_PORT not listening within ${PORT_TIMEOUT_S}s"
  dump_pane
  exit 1
fi

# 5c. Watchers start after the TUI is up (their readiness gate needs a prompt)
# and after the webhook (so injected messages are memorized).
start_watchers || true

# 6. Monitor loop.
log "monitoring; exit non-zero on bun / port / tmux loss"
while true; do
  # A dead watcher is respawned, not escalated: queued DMs wait on disk.
  if [ -n "$WATCHER_PIDS" ]; then
    down=0
    for pid in $WATCHER_PIDS; do kill -0 "$pid" 2>/dev/null || down=1; done
    if [ "$down" -eq 1 ]; then
      log "dm inbox watcher gone — restarting the set"
      for pid in $WATCHER_PIDS; do kill "$pid" 2>/dev/null || true; done
      start_watchers || WATCHER_PIDS=""
    fi
  fi
  [ -n "$(bun_pids)" ] || { log "bun process gone — exiting for respawn"; exit 1; }
  port_listening || { log "webhook port $WEBHOOK_PORT gone — exiting for respawn"; exit 1; }
  tmux has-session -t "$SESSION" 2>/dev/null || { log "tmux session lost — exiting for respawn"; exit 1; }
  sleep "$MONITOR_INTERVAL_S"
done
