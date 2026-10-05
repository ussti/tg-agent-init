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
if [ "$SRC_KIT" != "$KIT" ]; then  # re-run from the installed copy: nothing to copy
  cp -R "$SRC_KIT"/. "$KIT/"
fi
rm -rf "$KIT/tests"
find "$KIT/skills" "$KIT/bin" -name '*.sh' -exec chmod +x {} +
chmod +x "$KIT"/bin/* 2>/dev/null || true

link_skills() {
  local cat skill kind
  while IFS=$'\t' read -r cat skill kind; do
    case "$cat" in ''|\#*) continue ;; esac
    local dest="$AGENT_WS/skills/$skill"
    if [ -e "$dest" ] && [ ! -L "$dest" ]; then
      # a real folder from an older install: keep it outside skills/ (no duplicates for Claude)
      local backup="$AGENT_WS/skills-replaced/$skill.$(date +%Y%m%d%H%M%S)"
      mkdir -p "$AGENT_WS/skills-replaced"
      say "moving existing $dest to $backup"
      mv "$dest" "$backup"
    fi
    ln -sfn "../kit/skills/$cat/$skill" "$dest"
  done < "$KIT/manifest.tsv"
}
say "linking skills"
mkdir -p "$AGENT_WS/skills"
link_skills

readonly AGENT_BROWSER_VERSION="0.38.2"
readonly CRAWL4AI_VERSION="0.9.4"
readonly GWS_CLI_VERSION="1.5.0"
readonly LOCAL_PREFIX="$HOME/.local"
readonly -a MARKETPLACES=("anthropics/claude-plugins-official" "anthropics/skills")
readonly -a KIT_PLUGINS=(
  "superpowers@claude-plugins-official"
  "vercel@claude-plugins-official"
  "document-skills@anthropic-agent-skills"
)

# Run a command silently; stdin closed so nothing can wait for input.
try() { "$@" < /dev/null > /dev/null 2>&1; }

# Point skills/last30days at the downloaded upstream copy, if there is one.
relink_last30days() {
  if [ -f "$KIT/vendor/last30days/skills/last30days/SKILL.md" ]; then
    ln -sfn "../kit/vendor/last30days/skills/last30days" "$AGENT_WS/skills/last30days"
  fi
}
relink_last30days  # link_skills just reset it to the stub; a downloaded copy wins

install_deps() {
  mkdir -p "$LOCAL_PREFIX/bin"
  export PATH="$LOCAL_PREFIX/bin:$PATH"  # tools installed below must be found right away
  if command -v npm > /dev/null; then
    try npm install -g --prefix "$LOCAL_PREFIX" "agent-browser@$AGENT_BROWSER_VERSION" \
      || warn "agent-browser not installed; later: npm install -g --prefix ~/.local agent-browser@$AGENT_BROWSER_VERSION"
  else
    warn "npm not found: agent-browser skipped (install Node.js, then rerun kit/install-kit.sh)"
  fi
  mkdir -p "$HOME/.agent-browser"
  [ -f "$HOME/.agent-browser/config.json" ] \
    || cp "$KIT/config/agent-browser.json" "$HOME/.agent-browser/config.json"

  if command -v pipx > /dev/null; then
    local pkg
    for pkg in "gws-cli==$GWS_CLI_VERSION" "crawl4ai==$CRAWL4AI_VERSION" yt-dlp; do
      try pipx install "$pkg" || warn "$pkg not installed; later: pipx install '$pkg'"
    done
  else
    warn "pipx not found: gws-cli, crawl4ai, yt-dlp skipped (sudo apt install pipx, then rerun)"
  fi

  if command -v agent-browser > /dev/null; then
    try agent-browser install || warn "agent-browser: Chrome download failed; later: agent-browser install"
  fi
  if command -v crawl4ai-setup > /dev/null; then
    try crawl4ai-setup || warn "crawl4ai: browser setup failed; later: crawl4ai-setup"
  fi

  local repo commit dest
  repo="$(sed -n 's/^repo=//p' "$KIT/skills/research/last30days/UPSTREAM")"
  commit="$(sed -n 's/^commit=//p' "$KIT/skills/research/last30days/UPSTREAM")"
  dest="$KIT/vendor/last30days"
  if [ -d "$dest/.git" ]; then  # rerun: update the existing checkout instead of cloning
    try git -C "$dest" fetch || true
    try git -C "$dest" checkout "$commit" || true
  else
    try git clone "$repo" "$dest" && try git -C "$dest" checkout "$commit" || true
  fi
  if [ -f "$dest/skills/last30days/SKILL.md" ]; then
    relink_last30days
  else
    warn "last30days not downloaded; the skill tells the agent how to fix it"
  fi
}

install_plugins() {
  local m p claude_bin="${CLAUDE_BIN:-$(command -v claude || true)}"
  [ -n "$claude_bin" ] || { warn "claude not found: plugins skipped"; return 0; }
  for m in "${MARKETPLACES[@]}"; do
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" try "$claude_bin" plugin marketplace add "$m" \
      || warn "marketplace $m unreachable"
  done
  for p in "${KIT_PLUGINS[@]}"; do
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" try "$claude_bin" plugin install "$p" \
      || warn "could not install $p; later: CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\" claude plugin install $p"
  done
}

if [ "${KIT_SKIP_DEPS:-0}" != 1 ]; then
  install_deps
  install_plugins
fi
say "done"
