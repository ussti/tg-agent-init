#!/usr/bin/env bash
# install-cron.sh -- install the 4 memory-maintenance jobs into the user's crontab.
# Cross-platform (Linux + macOS both ship `crontab`). Idempotent: re-running replaces
# this agent's block, never duplicates. Pass --dry-run to preview without installing.
#
# Usage:
#   bash install-cron.sh <agent-.claude-dir>          # install
#   bash install-cron.sh <agent-.claude-dir> --dry-run
#
# macOS note: launchd is the native scheduler; a plist template is provided in this
# folder (com.local-agent-kit.memory.plist) if you prefer it. crontab works fine for
# user-level jobs and is used here for one cross-platform path.
set -euo pipefail

AGENT_WS="${1:-}"
DRY_RUN="${2:-}"
if [ -z "$AGENT_WS" ]; then
  echo "usage: bash install-cron.sh <agent-.claude-dir> [--dry-run]" >&2
  exit 1
fi
AGENT_WS="$(cd "$AGENT_WS" && pwd)"   # absolute
SCRIPTS="$AGENT_WS/scripts"
LOG="$AGENT_WS/logs/memory-cron.log"
TAG="# local-agent-kit:$(basename "$(dirname "$AGENT_WS")")"

if [ ! -d "$SCRIPTS" ]; then
  echo "error: $SCRIPTS not found — is this the agent's .claude dir?" >&2
  exit 1
fi
mkdir -p "$(dirname "$LOG")"

BLOCK=$(cat <<EOF
$TAG START
30 4 * * * AGENT_WS="$AGENT_WS" "$SCRIPTS/rotate-warm.sh"   >> "$LOG" 2>&1
0  5 * * * AGENT_WS="$AGENT_WS" "$SCRIPTS/trim-hot.sh"      >> "$LOG" 2>&1
0  6 * * * AGENT_WS="$AGENT_WS" "$SCRIPTS/compress-warm.sh" >> "$LOG" 2>&1
0 21 * * * AGENT_WS="$AGENT_WS" "$SCRIPTS/memory-rotate.sh" >> "$LOG" 2>&1
$TAG END
EOF
)

if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "# would install into crontab:"
  echo "$BLOCK"
  exit 0
fi

# Existing crontab minus any prior block for THIS agent (exact-line awk match — no regex
# delimiter issues; the tag contains '#', which broke a sed-based approach). Never wipes:
# a crontab-read failure just yields an empty prior, and other agents' blocks are preserved.
EXISTING="$(crontab -l 2>/dev/null | awk -v tag="$TAG" '
  $0 == tag " START" { skip = 1; next }
  $0 == tag " END"   { skip = 0; next }
  !skip { print }
')"
{ [ -n "$EXISTING" ] && printf '%s\n' "$EXISTING"; printf '%s\n' "$BLOCK"; } | cat -s | crontab -

echo "installed 4 memory jobs for $(basename "$(dirname "$AGENT_WS")"). Verify: crontab -l"
