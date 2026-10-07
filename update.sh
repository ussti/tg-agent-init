#!/usr/bin/env bash
# update.sh -- bring an installed agent up to the current version of this repo.
#
# Run as the agent user (not root), from the repo copy in its home:
#   cd ~/tg-agent-init && ./update.sh
#
# Pulls the repo, rebuilds the Telegram plugin, refreshes the server scripts, hooks
# and the skill kit, then restarts the agent and checks that it comes back. If it does
# not, the previous version is put back. Memory, the profile from /onboard, rules,
# keys, logins, logs and the library are never touched.
#
# Flags: --no-pull (use the repo as it is), --no-restart, --ws <agent workspace>
# (needed only when this user has more than one agent).
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KIT_DIR
readonly HEALTH_WAIT_S="${TG_AGENT_UPDATE_HEALTH_WAIT_S:-120}"
readonly HEALTH_STABLE_S="${TG_AGENT_UPDATE_STABLE_S:-20}"
readonly KEEP_BACKUPS=3

say() { echo "[update] $*"; }
die() { echo "[update] ERROR: $*" >&2; exit 1; }

DO_PULL=1
DO_RESTART=1
WS=""
ARGS=("$@")
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-pull) DO_PULL=0 ;;
    --no-restart) DO_RESTART=0 ;;
    --ws) [ "$#" -ge 2 ] || die "--ws needs a path"; WS="$2"; shift ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) die "unknown flag: $1" ;;
  esac
  shift
done

[ "$(id -u)" != "0" ] || die "run as the agent user, not root (su - <user> first)"

# ---------------------------------------------------------------- repo
if [ "$DO_PULL" = "1" ]; then
  [ -d "$KIT_DIR/.git" ] || die "$KIT_DIR is not a git checkout; use --no-pull"
  say "pulling the new version"
  git -C "$KIT_DIR" pull --ff-only \
    || die "git pull failed (local edits in $KIT_DIR?); nothing was changed"
  # The new update.sh may differ from the one running now: hand over to it.
  exec bash "$KIT_DIR/update.sh" --no-pull "${ARGS[@]}"
fi

# ---------------------------------------------------------------- agent
if [ -z "$WS" ]; then
  mapfile -t confs < <(find "$HOME" -mindepth 4 -maxdepth 4 -path '*/.claude/agent.conf' \
    -not -path '*.bak_*' 2>/dev/null | sort)
  [ "${#confs[@]}" -gt 0 ] || die "no agent found under $HOME (run install-server.sh first)"
  if [ "${#confs[@]}" -gt 1 ]; then
    printf '  %s\n' "${confs[@]%/agent.conf}" >&2
    die "several agents found; pick one with --ws <path>"
  fi
  WS="${confs[0]%/agent.conf}"
fi
[ -f "$WS/agent.conf" ] || die "no agent.conf in $WS"
set -a
# shellcheck disable=SC1091
. "$WS/agent.conf"
set +a
: "${AGENT_NAME:?}" "${AGENT_HOME:?}" "${AGENT_WS:?}" "${SECRETS_DIR:?}" "${CLAUDE_CONFIG_DIR:?}"
[ "$AGENT_WS" = "$WS" ] || [ "$(cd "$AGENT_WS" 2>/dev/null && pwd)" = "$(cd "$WS" && pwd)" ] \
  || die "agent.conf in $WS points at another workspace: $AGENT_WS"

# Updating from inside the agent would kill the session running the update.
if [ -n "${TMUX:-}" ] && [ "$(tmux display-message -p '#S' 2>/dev/null)" = "${PLUGIN_SESSION_NAME:-}" ]; then
  die "run this in your own terminal, not through the agent"
fi

for cmd in bun patch python3; do
  command -v "$cmd" > /dev/null || die "missing command: $cmd"
done
BUN_BIN="$(command -v bun)"
export AGENT_HOME AGENT_WS SECRETS_DIR BUN_BIN CLAUDE_BIN

STAMP="$(date +%Y%m%d_%H%M%S)"
BAK="$AGENT_WS/backups/update_$STAMP"
PLUGIN_ROOT="$AGENT_WS/dashi-plugin"
mkdir -p "$BAK"
say "agent $AGENT_NAME, workspace $AGENT_WS"

# ---------------------------------------------------------------- build (nothing live changes yet)
NEW="$BAK/plugin-new"
say "building the Telegram plugin"
bash "$KIT_DIR/scripts/build-plugin.sh" "$NEW" \
  || die "plugin build failed; the agent keeps running the old version"
if [ "${TG_AGENT_TEST_SKIP_BUN:-0}" != "1" ]; then
  (cd "$NEW/plugin" && bun install --frozen-lockfile) \
    || die "bun install failed; the agent keeps running the old version"
fi
mkdir -p "$NEW/plugin/.claude"
ln -sfn ../../../skills "$NEW/plugin/.claude/skills"
python3 "$KIT_DIR/scripts/render-template.py" \
  "$KIT_DIR/server/templates/plugin-settings.json.template" "$NEW/plugin/.claude/settings.json" \
  || die "plugin settings render failed; the agent keeps running the old version"
# Local files a user may have added to the old plugin dir.
for f in .env .claude/settings.local.json; do
  [ ! -f "$PLUGIN_ROOT/plugin/$f" ] || cp -p "$PLUGIN_ROOT/plugin/$f" "$NEW/plugin/$f"
done

# ---------------------------------------------------------------- backup
say "backup: $BAK"
CODE_DIRS=(bin hooks scripts skills/onboard)
for d in "${CODE_DIRS[@]}"; do
  [ ! -e "$AGENT_WS/$d" ] || { mkdir -p "$BAK/ws/$(dirname "$d")"; cp -a "$AGENT_WS/$d" "$BAK/ws/$d"; }
done
# The kit minus its downloaded upstream checkouts, which install-kit.sh reuses.
[ ! -d "$AGENT_WS/kit" ] || tar -C "$AGENT_WS" --exclude=kit/vendor -cf "$BAK/kit.tar" kit

# put_file SRC DST: replace through a new inode. A running bash script (run-agent.sh,
# ratewatch.sh) keeps reading its old copy instead of a half-written file.
put_file() {
  cp -p "$1" "$2.update-tmp"
  mv -f "$2.update-tmp" "$2"
}
put_dir_files() {  # put_dir_files DST SRC...
  local dst="$1" f
  shift
  mkdir -p "$dst"
  for f in "$@"; do [ ! -f "$f" ] || put_file "$f" "$dst/$(basename "$f")"; done
}

restore() {
  say "rolling back to the previous version"
  if [ -d "$BAK/plugin-old" ]; then
    rm -rf "$BAK/plugin-failed"
    [ ! -e "$PLUGIN_ROOT" ] || mv "$PLUGIN_ROOT" "$BAK/plugin-failed"
    mv "$BAK/plugin-old" "$PLUGIN_ROOT"
  fi
  local d
  for d in "${CODE_DIRS[@]}"; do
    [ -e "$BAK/ws/$d" ] || continue
    if [ -d "$BAK/ws/$d" ] && [ "$d" = skills/onboard ]; then
      rm -rf "$AGENT_WS/$d"
      cp -a "$BAK/ws/$d" "$AGENT_WS/$d"
    else
      put_dir_files "$AGENT_WS/$d" "$BAK/ws/$d"/*
    fi
  done
  [ ! -f "$BAK/kit.tar" ] || tar -C "$AGENT_WS" -xf "$BAK/kit.tar"
}

# ---------------------------------------------------------------- swap
say "installing the new plugin, scripts and hooks"
[ ! -e "$PLUGIN_ROOT" ] || mv "$PLUGIN_ROOT" "$BAK/plugin-old"
mv "$NEW" "$PLUGIN_ROOT"
# Same order as install-server.sh: the server layer wins over the core.
put_dir_files "$AGENT_WS/bin" "$KIT_DIR"/server/bin/*
put_dir_files "$AGENT_WS/hooks" "$KIT_DIR"/core/hooks/*
put_dir_files "$AGENT_WS/hooks" "$KIT_DIR"/server/hooks/*
put_dir_files "$AGENT_WS/scripts" "$KIT_DIR"/core/scripts/*.sh "$KIT_DIR"/core/scripts/*.mjs
rm -rf "$AGENT_WS/skills/onboard"
cp -R "$KIT_DIR/core/skills/onboard" "$AGENT_WS/skills/"
chmod +x "$AGENT_WS"/bin/*.sh "$AGENT_WS"/hooks/*.sh "$AGENT_WS"/hooks/*.py "$AGENT_WS"/scripts/*.sh

say "updating the skill kit"
if ! KIT_SKIP_DEPS="${KIT_SKIP_DEPS:-0}" bash "$KIT_DIR/kit/install-kit.sh" "$AGENT_WS" "$CLAUDE_CONFIG_DIR"; then
  restore
  die "skill kit update failed; the previous version is back"
fi
find -L "$AGENT_WS/skills" -name '*.sh' -exec chmod +x {} + 2>/dev/null || true

VERSION="$(git -C "$KIT_DIR" rev-parse --short HEAD 2>/dev/null || echo unknown)"
mkdir -p "$AGENT_WS/state"
printf '%s\n' "$VERSION" > "$AGENT_WS/state/kit-version"

# ---------------------------------------------------------------- restart + health
UNIT="$AGENT_NAME-agent.service"
UNIT_WATCH="$AGENT_NAME-ratewatch.service"
main_pid() { systemctl show -p MainPID --value "$1" 2>/dev/null || echo 0; }
port_up() { ss -ltnH "sport = :${TELEGRAM_WEBHOOK_PORT:?}" 2>/dev/null | grep -q .; }

# restart_unit UNIT: the units run as this user with Restart=always, so stopping the
# main process is a restart that needs no root.
restart_unit() {
  local pid
  pid="$(main_pid "$1")"
  [ -n "$pid" ] && [ "$pid" != 0 ] || return 1
  kill "$pid" 2>/dev/null || return 1
  printf '%s' "$pid"
}

# healthy OLD_PID: a new main process holds the webhook port for HEALTH_STABLE_S in a row.
healthy() {
  local old="$1" waited=0 stable=0 pid
  while [ "$waited" -lt "$HEALTH_WAIT_S" ]; do
    pid="$(main_pid "$UNIT")"
    if [ -n "$pid" ] && [ "$pid" != 0 ] && [ "$pid" != "$old" ] && port_up; then
      stable=$((stable + 3))
      [ "$stable" -lt "$HEALTH_STABLE_S" ] || return 0
    else
      stable=0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

prune_backups() {
  local old
  find "$AGENT_WS/backups" -mindepth 1 -maxdepth 1 -type d -name 'update_*' | sort -r \
    | tail -n +"$((KEEP_BACKUPS + 1))" | while IFS= read -r old; do rm -rf -- "$old"; done
}

if [ "$DO_RESTART" = "1" ]; then
  if old_pid="$(restart_unit "$UNIT")"; then
    restart_unit "$UNIT_WATCH" > /dev/null || true
    say "restarting the agent, checking that it comes back (up to ${HEALTH_WAIT_S}s)"
    if healthy "$old_pid"; then
      say "the agent is back up"
    else
      restore
      old_pid="$(restart_unit "$UNIT" || echo 0)"
      restart_unit "$UNIT_WATCH" > /dev/null || true
      if healthy "$old_pid"; then
        die "the new version did not start; the previous version is back and running. Logs: $AGENT_WS/logs/"
      fi
      die "the agent does not start even on the previous version. Logs: $AGENT_WS/logs/"
    fi
  else
    say "the agent service is not running; start it as root: systemctl restart $UNIT $UNIT_WATCH"
  fi
fi

prune_backups
echo
echo "== Updated '$AGENT_NAME' to $VERSION. Memory, profile, keys and logins are as they were."
echo "   previous version kept in $BAK"
