#!/usr/bin/env bash
# install-cron.sh -- install the tg-agent server jobs into the user's crontab.
# Idempotent: re-running replaces this agent's block, never duplicates, and never
# touches other blocks (the core memory jobs have their own tag). --dry-run previews.
#
# Usage:
#   bash install-cron.sh <agent-.claude-dir> [--dry-run]
set -euo pipefail

AGENT_WS="${1:-}"
DRY_RUN="${2:-}"
if [ -z "$AGENT_WS" ]; then
  echo "usage: bash install-cron.sh <agent-.claude-dir> [--dry-run]" >&2
  exit 1
fi
AGENT_WS="$(cd "$AGENT_WS" && pwd)"
BIN="$AGENT_WS/bin"
LOG="$AGENT_WS/logs/server-cron.log"
TAG="# tg-agent:$(basename "$(dirname "$AGENT_WS")")"

for script in auth-monitor.sh snapshot.sh cleanup-media.sh learnings-lint.sh; do
  if [ ! -x "$BIN/$script" ]; then
    echo "error: $BIN/$script missing or not executable — run install-server.sh first" >&2
    exit 1
  fi
done
mkdir -p "$(dirname "$LOG")"

# auth every 6h, snapshot hourly, media cleanup Sunday 03:30, learnings review Sunday 11:00
BLOCK=$(cat <<EOF
$TAG START
0  */6 * * * "$BIN/auth-monitor.sh"   >> "$LOG" 2>&1
17 *   * * * "$BIN/snapshot.sh"       >> "$LOG" 2>&1
30 3   * * 0 "$BIN/cleanup-media.sh"  >> "$LOG" 2>&1
0  11  * * 0 "$BIN/learnings-lint.sh" >> "$LOG" 2>&1
$TAG END
EOF
)

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "# would install into crontab:"
  echo "$BLOCK"
  exit 0
fi

# Exact-line awk match: the tag contains '#', which breaks sed-based removal.
EXISTING="$({ crontab -l 2>/dev/null || true; } | awk -v tag="$TAG" '
  $0 == tag " START" { skip = 1; next }
  $0 == tag " END"   { skip = 0; next }
  !skip { print }
')"
{ [ -n "$EXISTING" ] && printf '%s\n' "$EXISTING"; printf '%s\n' "$BLOCK"; } | cat -s | crontab -

echo "installed tg-agent server jobs for $(basename "$(dirname "$AGENT_WS")"). Verify: crontab -l"
