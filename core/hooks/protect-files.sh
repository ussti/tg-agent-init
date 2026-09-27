#!/usr/bin/env bash
# Hook: PreToolUse Edit|Write — protects sensitive files
# Source: HOOKS.md canon (verbatim)
set -euo pipefail
file=$(jq -r ".tool_input.file_path // .tool_input.path // \"\"")

protected=(
  ".env*"
  ".git/*"
  "package-lock.json"
  "yarn.lock"
  "*.pem"
  "*.key"
  "secrets/*"
)

for pattern in "${protected[@]}"; do
  if echo "$file" | grep -qiE "^${pattern//\*/.*}$"; then
    echo "BLOCKED: '$file' is a protected file. Explain why this edit is needed." >&2
    exit 2
  fi
done
exit 0
