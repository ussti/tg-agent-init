#!/usr/bin/env bash
# quick-reminders — local reminder list. No key, no network.
set -euo pipefail

STORE="${REMINDERS_FILE:-${AGENT_WS:-${CLAUDE_PROJECT_DIR:-.}/.claude}/core/reminders.md}"
mkdir -p "$(dirname "$STORE")"
[ -f "$STORE" ] || printf '# Reminders\n\n' > "$STORE"

cmd="${1:-list}"; shift || true
case "$cmd" in
  add)
    [ "$#" -gt 0 ] || { echo "usage: reminders.sh add <text>" >&2; exit 1; }
    printf -- '- [ ] %s (added %s)\n' "$*" "$(date +%Y-%m-%d)" >> "$STORE"
    echo "added: $*"
    ;;
  list)
    grep -nE '^- \[ \] ' "$STORE" || echo "(no open reminders)"
    ;;
  done)
    n="${1:-}"; [ -n "$n" ] || { echo "usage: reminders.sh done <line-number>" >&2; exit 1; }
    sed -i.bak "${n}s/\[ \]/[x]/" "$STORE" && rm -f "$STORE.bak"
    echo "completed line $n"
    ;;
  *)
    echo "usage: reminders.sh {add <text>|list|done <line-number>}" >&2; exit 1
    ;;
esac
