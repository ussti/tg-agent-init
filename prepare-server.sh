#!/usr/bin/env bash
# prepare-server.sh -- get a fresh Ubuntu/Debian server ready for install-server.sh.
#
# Run as root on a new server, from a clone of this repo:
#   git clone https://github.com/ussti/tg-agent-init.git && cd tg-agent-init && ./prepare-server.sh
#
# It installs what install-server.sh needs (system packages, Node.js, bun, Claude Code),
# creates a separate Unix user for the agent (Claude Code does not run without
# confirmations as root) and copies this repo into that user's home. Safe to re-run:
# anything already in place is kept.
#
# Usage: prepare-server.sh [user]     (default user: agent)
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KIT_DIR
readonly NODE_MAJOR_MIN=24
readonly NODESOURCE_URL="https://deb.nodesource.com/setup_${NODE_MAJOR_MIN}.x"
readonly BUN_URL="https://bun.sh/install"
readonly CLAUDE_URL="https://claude.ai/install.sh"
readonly APT_PACKAGES=(
  ca-certificates curl git jq tmux patch cron iproute2 openssl unzip
  python3 python3-venv pipx
)

say() { echo "[prepare] $*"; }
die() { echo "[prepare] ERROR: $*" >&2; exit 1; }

case "${1:-}" in
  -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
esac
AGENT_USER="${1:-agent}"

[ "$(id -u)" = "0" ] || die "run as root (on a fresh server you log in as root)"
command -v apt-get > /dev/null || die "apt-get not found: Ubuntu 22.04+ or Debian 12+ expected"
[[ "$AGENT_USER" =~ ^[a-z][a-z0-9_-]{0,30}$ ]] || die "bad user name: $AGENT_USER"
[ "$AGENT_USER" != "root" ] || die "the agent user must not be root"

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

# fetch URL FILE: download an installer to a file first, so a cut connection
# never runs half a script.
fetch() { curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"; }

export DEBIAN_FRONTEND=noninteractive

say "system packages"
apt-get update -q > /dev/null
apt-get install -y -q "${APT_PACKAGES[@]}" > /dev/null
systemctl enable --now cron > /dev/null 2>&1 || true

node_major() { node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0; }
if [ "$(node_major)" -lt "$NODE_MAJOR_MIN" ]; then
  say "Node.js $NODE_MAJOR_MIN"
  fetch "$NODESOURCE_URL" "$WORK/nodesource.sh"
  bash "$WORK/nodesource.sh" > /dev/null
  apt-get install -y -q nodejs > /dev/null
fi
[ "$(node_major)" -ge "$NODE_MAJOR_MIN" ] || die "Node.js $NODE_MAJOR_MIN+ not installed"
say "node $(node --version)"

if [ ! -x /usr/local/bin/bun ]; then
  say "bun"
  fetch "$BUN_URL" "$WORK/bun.sh"
  BUN_INSTALL=/usr/local bash "$WORK/bun.sh" > /dev/null
fi
say "bun $(/usr/local/bin/bun --version)"

if id "$AGENT_USER" > /dev/null 2>&1; then
  say "user $AGENT_USER exists"
else
  say "creating user $AGENT_USER"
  useradd -m -s /bin/bash "$AGENT_USER"
fi
USER_HOME="$(getent passwd "$AGENT_USER" | cut -d: -f6)"
as_user() { runuser -u "$AGENT_USER" -- env HOME="$USER_HOME" "$@"; }

# ~/.local/bin must exist before the first login: Ubuntu's ~/.profile adds it to PATH only then.
as_user mkdir -p "$USER_HOME/.local/bin"

if [ ! -x "$USER_HOME/.local/bin/claude" ]; then
  say "Claude Code for $AGENT_USER"
  fetch "$CLAUDE_URL" "$WORK/claude.sh"
  chmod 644 "$WORK/claude.sh"
  chmod 755 "$WORK"
  as_user bash -c "cd '$USER_HOME' && bash '$WORK/claude.sh'" > /dev/null
fi
[ -x "$USER_HOME/.local/bin/claude" ] || die "Claude Code not installed for $AGENT_USER"
say "claude $(as_user "$USER_HOME/.local/bin/claude" --version 2>/dev/null | head -1)"

DEST="$USER_HOME/tg-agent-init"
if [ -d "$DEST" ]; then
  say "$DEST exists, kept as is"
else
  say "copying the repo to $DEST"
  cp -a "$KIT_DIR" "$DEST"
  chown -R "$AGENT_USER:$AGENT_USER" "$DEST"
fi

cat <<EOF

[prepare] done. Next, one command at a time:

  su - $AGENT_USER
  cd tg-agent-init && ./install-server.sh

At the end the installer prints two commands for root: type exit, then paste them.
EOF
