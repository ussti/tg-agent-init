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

# Pinned versions live in kit/versions.env; read as data, never sourced.
pin() {  # pure bash: works with a bare PATH
  local line
  [ -r "$KIT/versions.env" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    if [ "${line%%=*}" = "$1" ] && [ "$line" != "$1" ]; then
      printf '%s\n' "${line#*=}"
      return 0
    fi
  done < "$KIT/versions.env"
}
AGENT_BROWSER_VERSION="$(pin AGENT_BROWSER_VERSION)"
CRAWL4AI_VERSION="$(pin CRAWL4AI_VERSION)"
GWS_CLI_VERSION="$(pin GWS_CLI_VERSION)"
readonly AGENT_BROWSER_VERSION CRAWL4AI_VERSION GWS_CLI_VERSION
[ -r "$KIT/versions.env" ] || warn "no $KIT/versions.env: pinned tools will be skipped"
readonly LOCAL_PREFIX="$HOME/.local"
readonly -a MARKETPLACES=("anthropics/claude-plugins-official")
readonly -a KIT_PLUGINS=(
  "superpowers@claude-plugins-official"
  "vercel@claude-plugins-official"
)

readonly NET_TIMEOUT=600  # seconds; a hung download must not hang the whole install

# Run a command silently with a time limit; stdin closed so nothing can wait for input.
# setsid drops the controlling terminal as well, so a nested sudo fails at once instead of
# asking for a password (playwright's --with-deps calls sudo for apt).
try() {
  local pre=()
  command -v setsid > /dev/null && pre+=(setsid -w)
  command -v timeout > /dev/null && pre+=(timeout "$NET_TIMEOUT")
  "${pre[@]}" "$@" < /dev/null > /dev/null 2>&1
}

# Shared libraries headless Chrome needs and minimal server images lack. Root installs
# them once (prepare-server.sh); the kit only checks, it never calls sudo.
readonly BROWSER_LIBS=(libnss3.so libatk-bridge-2.0.so.0 libgbm.so.1 libxkbcommon.so.0 libasound.so.2)
LDCONFIG="${KIT_LDCONFIG:-$(command -v ldconfig || echo /sbin/ldconfig)}"

# Print the browser libraries missing from the linker cache; empty when all are there
# or when there is no way to tell.
browser_libs_missing() {
  local cache lib missing=()
  cache="$("$LDCONFIG" -p 2> /dev/null)" || return 0
  for lib in "${BROWSER_LIBS[@]}"; do
    grep -qF "$lib (" <<< "$cache" || missing+=("$lib")
  done
  echo "${missing[*]}"
}

# Read the pinned repo/commit of the last30days skill into LAST30_REPO / LAST30_COMMIT.
read_last30_pin() {
  LAST30_REPO="$(pin LAST30DAYS_REPO)"
  LAST30_COMMIT="$(pin LAST30DAYS_COMMIT)"
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
  if [ -z "$AGENT_BROWSER_VERSION" ]; then
    warn "agent-browser: no pinned version in versions.env; skipped"
  elif [ "$(agent-browser --version 2> /dev/null < /dev/null | awk '{print $NF}')" = "$AGENT_BROWSER_VERSION" ]; then
    :  # already there, possibly as the standalone binary npm would refuse to overwrite
  elif command -v npm > /dev/null; then
    try npm install -g --prefix "$LOCAL_PREFIX" "agent-browser@$AGENT_BROWSER_VERSION" \
      || warn "agent-browser not installed; later: npm install -g --prefix ~/.local agent-browser@$AGENT_BROWSER_VERSION"
  else
    warn "npm not found: agent-browser skipped (as root: ./prepare-server.sh $(id -un), then rerun kit/install-kit.sh)"
  fi
  mkdir -p "$HOME/.agent-browser"
  [ -f "$HOME/.agent-browser/config.json" ] \
    || cp "$KIT/config/agent-browser.json" "$HOME/.agent-browser/config.json"

  if command -v pipx > /dev/null; then
    local pkg pkgs=()
    if [ -n "$GWS_CLI_VERSION" ]; then pkgs+=("gws-cli==$GWS_CLI_VERSION")
    else warn "gws-cli: no pinned version in versions.env; skipped"; fi
    if [ -n "$CRAWL4AI_VERSION" ]; then pkgs+=("crawl4ai==$CRAWL4AI_VERSION")
    else warn "crawl4ai: no pinned version in versions.env; skipped"; fi
    pkgs+=(yt-dlp)
    for pkg in "${pkgs[@]}"; do
      try pipx install --force "$pkg" || warn "$pkg not installed; later: pipx install --force '$pkg'"
    done
  else
    warn "pipx not found: gws-cli, crawl4ai, yt-dlp skipped (as root: ./prepare-server.sh $(id -un), then rerun)"
  fi

  # Browsers download into the user's cache, never with --with-deps: system libraries are
  # root's job (prepare-server.sh), and a sudo prompt would stall the install.
  local browsers=0 c4py libs
  if command -v agent-browser > /dev/null; then
    browsers=1
    try agent-browser install || warn "agent-browser: Chrome download failed; later: agent-browser install"
  fi
  if command -v crawl4ai-setup > /dev/null; then
    browsers=1
    try crawl4ai-setup || warn "crawl4ai: setup failed; later: crawl4ai-setup"
    # crawl4ai-setup asks for Chrome with system deps, which fails without root; the
    # bundled Chromium is what crawl4ai launches by default.
    c4py="$(dirname "$(readlink -f "$(command -v crawl4ai-setup)")")/python"
    if [ -x "$c4py" ]; then
      try "$c4py" -m playwright install chromium \
        || warn "crawl4ai: Chromium download failed; later: $c4py -m playwright install chromium"
    fi
  fi
  if [ "$browsers" = 1 ]; then
    libs="$(browser_libs_missing)"
    [ -z "$libs" ] || warn "browsers will not start, system libraries missing: $libs. As root: ./prepare-server.sh $(id -un) (or just: npx -y playwright install-deps chromium)"
  fi

  local dest tmp
  read_last30_pin
  dest="$KIT/vendor/last30days"
  mkdir -p "$KIT/vendor"
  if [ -z "$LAST30_REPO" ] || [ -z "$LAST30_COMMIT" ]; then
    warn "last30days: no pinned repo/commit in versions.env; the skill stays a stub"
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
