#!/usr/bin/env bash
# Hook: PreToolUse Bash — blocks dangerous patterns
# Source: HOOKS.md canon (verbatim)
set -euo pipefail
cmd=$(jq -r ".tool_input.command // \"\"")

dangerous_patterns=(
  "rm -rf"
  "git reset --hard"
  "git push.*--force"
  "DROP TABLE"
  "DROP DATABASE"
  "(curl|wget)\b.*[|].*\b(ba)?sh\b"
  # Outbound / destructive Google Workspace ops — hard-stop under bypassPermissions.
  # Reads/writes (search, read, append, calendar create) stay free; these escalate.
  "gws gmail send"
  "gws drive (delete|trash|rm)\b"
  "gws calendar delete"
)

for pattern in "${dangerous_patterns[@]}"; do
  if echo "$cmd" | grep -qiE "$pattern"; then
    echo "BLOCKED: '$cmd' matches dangerous pattern '$pattern'. Suggest a safer alternative." >&2
    exit 2
  fi
done
exit 0
