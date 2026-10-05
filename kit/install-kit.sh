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

# Web-tool routing rule: appended once, the heading is the idempotency guard.
append_web_rule() {
  local rules="$AGENT_WS/core/rules.md"
  [ -f "$rules" ] || { warn "no $rules: web-tool rule skipped"; return 0; }
  if grep -q '^## Which internet tool' "$rules"; then
    say "web-tool rule already in rules.md"
  else
    say "adding the web-tool rule to rules.md"
    cat "$KIT/rules/web-tools.md" >> "$rules"
  fi
}
append_web_rule

# Tool map: the kit table is appended to tools/TOOLS.md once (core/templates is overwritten
# by sync-core, so the table cannot live there); the heading is the idempotency guard.
append_tools_map() {
  local tools="$AGENT_WS/tools/TOOLS.md"
  [ -f "$tools" ] || { warn "no $tools: kit tool map skipped"; return 0; }
  if grep -q '^## Default kit' "$tools"; then
    say "kit tool map already in TOOLS.md"
  else
    say "adding the kit tool map to TOOLS.md"
    cat "$KIT/TOOLS-kit.md" >> "$tools"
  fi
  # deep-research was removed from the kit; drop its stale row from the base table (idempotent)
  sed -i '/^| deep-research |/d' "$tools"
}
append_tools_map

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

readonly NET_TIMEOUT=600  # seconds; a hung download must not hang the whole install

# Run a command silently with a time limit; stdin closed so nothing can wait for input.
try() {
  if command -v timeout > /dev/null; then
    timeout "$NET_TIMEOUT" "$@" < /dev/null > /dev/null 2>&1
  else
    "$@" < /dev/null > /dev/null 2>&1
  fi
}

# Read the pinned repo/commit of the last30days skill into LAST30_REPO / LAST30_COMMIT.
read_last30_pin() {
  local file="$KIT/skills/research/last30days/UPSTREAM"
  LAST30_REPO="" LAST30_COMMIT=""
  if [ -r "$file" ]; then
    LAST30_REPO="$(sed -n 's/^repo=//p' "$file" || true)"
    LAST30_COMMIT="$(sed -n 's/^commit=//p' "$file" || true)"
  else
    warn "last30days: $file missing; the skill stays a stub"
  fi
}

# True when dir is a checkout whose HEAD is exactly the pinned commit.
is_pinned_checkout() {
  local dir="$1" head
  head="$(git -C "$dir" rev-parse HEAD 2> /dev/null < /dev/null || true)"
  [ -n "$LAST30_COMMIT" ] && [ "$head" = "$LAST30_COMMIT" ] \
    && [ -f "$dir/skills/last30days/SKILL.md" ]
}

# Point skills/last30days at the downloaded upstream copy, only if it sits on the pin.
relink_last30days() {
  read_last30_pin
  if is_pinned_checkout "$KIT/vendor/last30days"; then
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
      try pipx install --force "$pkg" || warn "$pkg not installed; later: pipx install --force '$pkg'"
    done
  else
    warn "pipx not found: gws-cli, crawl4ai, yt-dlp skipped (sudo apt install pipx, then rerun)"
  fi

  if command -v agent-browser > /dev/null; then
    try agent-browser install || warn "agent-browser: Chrome download failed; later: agent-browser install (if Chrome lacks system libraries: sudo $LOCAL_PREFIX/bin/agent-browser install --with-deps)"
  fi
  if command -v crawl4ai-setup > /dev/null; then
    try crawl4ai-setup || warn "crawl4ai: browser setup failed; later: crawl4ai-setup"
  fi

  local dest tmp
  read_last30_pin
  dest="$KIT/vendor/last30days"
  mkdir -p "$KIT/vendor"
  if [ -z "$LAST30_REPO" ] || [ -z "$LAST30_COMMIT" ]; then
    warn "last30days: no pinned repo/commit in UPSTREAM; skipped"
  elif [ -d "$dest/.git" ]; then  # rerun: update the existing checkout instead of cloning
    try git -C "$dest" fetch || warn "last30days: fetch failed (offline?); keeping the current checkout"
    try git -C "$dest" checkout "$LAST30_COMMIT" \
      || warn "last30days: checkout of $LAST30_COMMIT failed; later: git -C $dest checkout $LAST30_COMMIT"
  elif [ -e "$dest" ]; then
    warn "last30days: $dest exists but is not a git checkout; move it aside (mv '$dest' '$dest.old'), then rerun kit/install-kit.sh"
  else
    tmp="$(mktemp -d "$KIT/vendor/.last30days.XXXXXX")" \
      || { warn "last30days: cannot create a temp dir; later: rerun kit/install-kit.sh"; return 0; }
    if try git clone "$LAST30_REPO" "$tmp/src" && try git -C "$tmp/src" checkout "$LAST30_COMMIT" \
       && is_pinned_checkout "$tmp/src"; then
      mv "$tmp/src" "$dest" || warn "last30days: could not move the checkout into place"
    fi
    # the installer owns this temp dir: drop whatever is left of the attempt
    case "$tmp" in "$KIT/vendor/.last30days."*) rm -rf -- "$tmp" ;; esac
  fi
  if is_pinned_checkout "$dest"; then
    relink_last30days
  else
    warn "last30days not installed at the pinned commit; the skill tells the agent how to fix it"
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
