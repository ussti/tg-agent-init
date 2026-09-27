#!/usr/bin/env bash
# Hook: PostToolUse Bash — append every command to log
# Source: HOOKS.md canon (verbatim)
set -euo pipefail
cmd=$(jq -r ".tool_input.command // \"\"")
LOG="$CLAUDE_PROJECT_DIR/.claude/logs/activity/command-log.txt"
mkdir -p "$(dirname "$LOG")"
printf "%s %s\n" "$(date -Is)" "$cmd" >> "$LOG"
exit 0
