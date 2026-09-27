#!/usr/bin/env bash
# Weekly learnings review. The plugin has no scheduler, so cron wakes the agent
# by typing a prompt into its tmux pane. Before that, the scored LEARNINGS.md is
# regenerated deterministically, so the file stays current even when the agent
# is down or skips the turn.
#
# Never types into a busy pane: a prompt sent over a running turn gets queued
# or glued to other input. Waits up to WAIT_LIMIT_MIN, then gives up. Exit 0.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf

SESSION="${PLUGIN_SESSION_NAME:?PLUGIN_SESSION_NAME unset}"
ENGINE="$AGENT_WS/scripts/learnings-engine.mjs"
LOG="$LOG_DIR/learnings-lint.log"
WAIT_LIMIT_MIN="${LEARNINGS_WAIT_LIMIT_MIN:-40}"
OPERATOR="${OPERATOR_NAME:-the owner}"
mkdir -p "$LOG_DIR"
log() { printf '[%s] %s\n' "$(date -Is)" "$*" >> "$LOG"; }

LEARN="node $ENGINE"
PROMPT="Run the weekly learnings review. Step 1: run \`${LEARN} lint\` and \`${LEARN} score\` and build a digest by bucket: PROMOTE (score>0.8, candidates for standing canon), HOT (freq>=3, the rule is not working, change the system), STALE (score<0.15, propose archiving). If every bucket is empty, say so plainly. Step 2: for each PROMOTE candidate ask ${OPERATOR} for a short OK; on yes run \`${LEARN} promote <ID>\`. Step 3: look through core/learnings/episodes.jsonl and recent work and propose 1-2 recurring workflows worth a skill (name, trigger, what it automates, one line why), or say there are none. Deliver to ${OPERATOR} in Telegram via mcp__dashi-channel__reply to chat_id ${OWNER_CHAT_ID}, format html, compact."

if [ -f "$ENGINE" ]; then
  node "$ENGINE" report --write >> "$LOG" 2>&1 && log "OK: report --write" \
    || log "WARN: report --write failed"
fi

if ! tmux has-session -t "$SESSION" 2>/dev/null; then
  log "SKIP: tmux session '$SESSION' not found (agent down?)"
  exit 0
fi

pane_busy() {
  tmux capture-pane -t "$SESSION" -p -S -5 2>/dev/null | grep -qE 'esc to interrupt'
}

waited=0
while pane_busy; do
  if [ "$waited" -ge "$WAIT_LIMIT_MIN" ]; then
    log "SKIP: session busy for ${WAIT_LIMIT_MIN}m — prompt not injected"
    exit 0
  fi
  sleep 60
  waited=$((waited + 1))
done
[ "$waited" -gt 0 ] && log "WAIT: session was busy ${waited}m before injection"

tmux send-keys -t "$SESSION" C-u
sleep 0.3
tmux send-keys -t "$SESSION" -- "$PROMPT"
sleep 0.3
tmux send-keys -t "$SESSION" Enter
log "OK: learnings prompt injected into '$SESSION'"
