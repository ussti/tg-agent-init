#!/usr/bin/env bash
# install-kit.sh -- put the default kit into an agent workspace.
# Copies kit/ to $AGENT_WS/kit, links every manifest skill into $AGENT_WS/skills
# (Claude Code finds skills one level deep only), then installs upstream tools and
# plugins. Optional items never fail the install: they warn and print the later command.
# Usage: kit/install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>
set -euo pipefail

SRC_KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_WS="${1:?usage: install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>}"
CLAUDE_CONFIG_DIR="${2:?usage: install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>}"
[ -d "$AGENT_WS" ] || { echo "[kit] no workspace at $AGENT_WS" >&2; exit 1; }
KIT="$AGENT_WS/kit"

say() { echo "[kit] $*"; }
warn() { echo "[kit] WARN: $*" >&2; }

say "copying kit into $KIT"
mkdir -p "$KIT"
cp -R "$SRC_KIT"/. "$KIT/"
rm -rf "$KIT/tests"
find "$KIT/skills" "$KIT/bin" -name '*.sh' -exec chmod +x {} +
chmod +x "$KIT"/bin/* 2>/dev/null || true

link_skills() {
  local cat skill kind
  while IFS=$'\t' read -r cat skill kind; do
    case "$cat" in ''|\#*) continue ;; esac
    ln -sfn "../kit/skills/$cat/$skill" "$AGENT_WS/skills/$skill"
  done < "$KIT/manifest.tsv"
}
say "linking skills"
mkdir -p "$AGENT_WS/skills"
link_skills
