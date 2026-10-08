#!/usr/bin/env bash
# install-doctor.sh -- install the server doctor: a separate Telegram bot (Claude Code
# behind claude-code-telegram) that runs as user "doctor" with passwordless root and
# fixes the agents. Run as root after the first agent is installed. Safe to re-run:
# nothing is duplicated, the package is reinstalled only when DOCTOR_BOT_TAG changed,
# the unit is restarted only when something changed.
# Root runs it only from a root-owned clone (an agent's own checkout is writable by
# the agent, and root must never run agent-writable code):
#   sudo git clone https://github.com/ussti/tg-agent-init /opt/agent-doctor/kit
#   sudo bash /opt/agent-doctor/kit/install-doctor.sh
# Update and re-run: sudo git -C /opt/agent-doctor/kit pull, then the same bash line.
# Tests: TG_DOCTOR_ROOT=<fake root> TG_DOCTOR_DRY_RUN=1 (skip the root check),
#        TG_DOCTOR_NONINTERACTIVE=1 with TG_DOCTOR_BOT_TOKEN / TG_DOCTOR_OWNER_ID.
set -Eeuo pipefail

# physical path: a symlinked component must not hide where the code really lives
KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
readonly KIT_REPO="https://github.com/ussti/tg-agent-init"
readonly KIT_HOME="/opt/agent-doctor/kit"
readonly CLONE_CMD="sudo git clone $KIT_REPO $KIT_HOME"
readonly PULL_CMD="sudo git -C $KIT_HOME pull"
readonly RUN_CMD="sudo bash $KIT_HOME/install-doctor.sh"
R="${TG_DOCTOR_ROOT:-}"          # prefix for paths on disk; paths inside files stay real
readonly DOCTOR_USER="doctor"
readonly DOCTOR_HOME="/home/doctor"
readonly OPT_DIR="/opt/agent-doctor"
readonly ENV_DIR="/etc/agent-doctor"
readonly ENV_FILE="$ENV_DIR/env"
readonly SUDOERS_FILE="/etc/sudoers.d/agent-doctor"
readonly SUDOERS_TMP="/etc/sudoers.d/.agent-doctor.tmp"
readonly USER_MARKER="/opt/agent-doctor/.doctor-user"   # the installer made or adopted it
readonly UNIT_NAME="agent-doctor.service"
readonly UNIT_FILE="/etc/systemd/system/$UNIT_NAME"
readonly CLAUDE_BIN="$DOCTOR_HOME/.local/bin/claude"
readonly PYTHON_VERSION="3.12"
readonly MAX_COST_USD=5
readonly MAX_COST_USER_USD=50
readonly TOKEN_TRIES=3
readonly OWNER_TRIES=3
readonly LOGIN_TRIES=3
readonly JOURNAL_LINES=30
readonly LOGIN_CHECK_TIMEOUT_S=120
readonly HTTP_TIMEOUT_S=20
readonly PACKAGE_REPO="https://github.com/RichardAtCT/claude-code-telegram"
readonly UV_INSTALLER="https://astral.sh/uv/install.sh"
readonly CLAUDE_INSTALLER="https://claude.ai/install.sh"
readonly GREETING="Я doctor, наладчик сервера. Пиши, если агент сломался"
readonly STABLE_S="${TG_DOCTOR_STABLE_S:-20}"
readonly START_TIMEOUT_S="${TG_DOCTOR_START_TIMEOUT_S:-60}"
readonly NONINTERACTIVE="${TG_DOCTOR_NONINTERACTIVE:-0}"
STAMP="$(date +%Y%m%d%H%M%S)"
readonly STAMP
CHANGED=0          # 1 when env, unit or package changed: the unit needs a restart
KEEP_BOT=0
BOT_TOKEN=""
BOT_USERNAME=""
OWNER_ID=""

WORK="$(mktemp -d)"
trap 'rm -rf -- "$WORK"' EXIT

say() { echo "[doctor] $*"; }
die() {
  echo "[doctor] ERROR: $*" >&2
  echo "[doctor] fix it, then run again: $RUN_CMD" >&2
  exit 1
}
# Any command that fails outside an if/||/&& condition stops the run with the retry hint.
trap 'die "step failed at line $LINENO"' ERR
fetch() { curl -fsSL --retry 3 -o "$2" "$1" || die "download failed: $1"; }
# Value of KEY="value" (quotes and CR optional); conf files are never sourced as root.
conf_get() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\r\{0,1\}$/\1/p" "$1" | head -1; }
# Put SRC at DST with MODE when the content differs; status 0 only when DST changed.
place() {
  local src="$1" dst="$2" mode="$3"
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    chmod "$mode" "$dst"
    return 1
  fi
  install -m "$mode" "$src" "$dst"
}
as_doctor() { runuser -u "$DOCTOR_USER" -- env HOME="$R$DOCTOR_HOME" "$@"; }

# --- 1. checks
if [ "${TG_DOCTOR_DRY_RUN:-0}" != 1 ] && [ "$(id -u)" -ne 0 ]; then
  die "run as root: $RUN_CMD"
fi
# The kit must be writable by nobody but the user running it (root on a server): every
# file under it, the kit dir and each parent dir. A root-owned sticky parent (/tmp) is
# fine, since others cannot move entries they do not own out of it.
untrusted_path() {  # prints the first path someone else could change; status 0 if one
  local uid dir owner mode hit
  uid="$(id -u)"
  hit="$(find "$KIT" \( ! -user "$uid" -o -perm /022 \) -print -quit 2>&1)" \
    || { echo "$KIT"; return 0; }
  [ -z "$hit" ] || { echo "$hit"; return 0; }
  dir="$KIT"
  while [ "$dir" != / ]; do
    dir="$(dirname "$dir")"
    owner="$(stat -c %u "$dir")"
    mode="$((8#$(stat -c %a "$dir")))"
    if [ "$owner" != 0 ] && [ "$owner" != "$uid" ]; then echo "$dir"; return 0; fi
    if [ $((mode & 8#022)) -ne 0 ] && ! { [ "$owner" = 0 ] && [ $((mode & 8#1000)) -ne 0 ]; }
    then
      echo "$dir"
      return 0
    fi
  done
  return 1
}
if bad_path="$(untrusted_path)"; then
  {
    echo "[doctor] ERROR: the kit is not owned by $(id -un) or is writable by others: $bad_path"
    echo "[doctor] root runs the doctor kit only from a root-owned clone:"
    echo "  $CLONE_CMD"
    echo "  $RUN_CMD"
    echo "[doctor] already cloned there? update it: $PULL_CMD"
  } >&2
  exit 1
fi
# Never pick up config from the caller's directory (an agent could plant uv.toml there)
cd /
export UV_NO_CONFIG=1
grep -Eqs '^(ID|ID_LIKE)=.*(ubuntu|debian)' "$R/etc/os-release" \
  || die "the doctor installs on Ubuntu or Debian only"
for tool in curl jq python3 visudo git; do
  command -v "$tool" > /dev/null || die "$tool is missing (apt install $tool)"
done
mapfile -t CONFS < <(bash "$KIT/server/doctor/list-agents.sh" --conf-paths)
[ "${#CONFS[@]}" -gt 0 ] \
  || die "no agent on this server yet; install one first: ./install-server.sh"
say "agents found: ${#CONFS[@]}"

# --- 2. user (an existing one the installer did not make gets root only after a yes)
adopt_user() {
  local ans
  say "WARN: user $DOCTOR_USER exists and was not created by this installer;"
  say "it gets passwordless root (sudo) and runs the doctor bot"
  if [ "$NONINTERACTIVE" = 1 ]; then
    [ "${TG_DOCTOR_ADOPT_USER:-0}" = 1 ] \
      || die "user $DOCTOR_USER already exists; to use it anyway set TG_DOCTOR_ADOPT_USER=1"
    return 0
  fi
  read -r -p "[doctor] use the existing user $DOCTOR_USER for the doctor? [y/N] " ans
  case "$ans" in
    y | Y | yes | Yes) ;;
    *) die "user $DOCTOR_USER kept as is; remove or rename it, or answer y" ;;
  esac
}
if ! getent passwd "$DOCTOR_USER" > /dev/null; then
  say "creating user $DOCTOR_USER"
  useradd -m -s /bin/bash "$DOCTOR_USER"
elif [ ! -e "$R$USER_MARKER" ]; then
  adopt_user
fi
mkdir -p "$R$OPT_DIR"
[ -e "$R$USER_MARKER" ] || echo "$DOCTOR_USER" > "$R$USER_MARKER"

# --- 3. sudo (validated before it is moved into place)
printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$DOCTOR_USER" > "$WORK/sudoers"
visudo -cf "$WORK/sudoers" > /dev/null || die "sudoers line failed visudo -cf; nothing installed"
mkdir -p "$R/etc/sudoers.d"
if [ -f "$R$SUDOERS_FILE" ] && cmp -s "$WORK/sudoers" "$R$SUDOERS_FILE"; then
  chmod 440 "$R$SUDOERS_FILE"
else
  # a dotted name is skipped by sudo, so a half-written file is never read
  had_sudoers=0
  if [ -f "$R$SUDOERS_FILE" ]; then
    cp -p "$R$SUDOERS_FILE" "$WORK/sudoers.prev"
    had_sudoers=1
  fi
  install -m 440 "$WORK/sudoers" "$R$SUDOERS_TMP"
  chown root:root "$R$SUDOERS_TMP"
  mv -f "$R$SUDOERS_TMP" "$R$SUDOERS_FILE"
  # the whole sudo config must still parse; otherwise put the previous state back
  if ! visudo -c > /dev/null; then
    if [ "$had_sudoers" = 1 ]; then
      install -m 440 "$WORK/sudoers.prev" "$R$SUDOERS_TMP"
      mv -f "$R$SUDOERS_TMP" "$R$SUDOERS_FILE"
    else
      rm -f -- "$R$SUDOERS_FILE"
    fi
    die "sudo config failed visudo -c after adding $SUDOERS_FILE; previous state restored"
  fi
  say "sudo granted to $DOCTOR_USER"
fi

# --- 4. uv
UV="$R/usr/local/bin/uv"
if [ ! -x "$UV" ]; then
  say "installing uv"
  fetch "$UV_INSTALLER" "$WORK/uv.sh"
  UV_INSTALL_DIR="$R/usr/local/bin" UV_NO_MODIFY_PATH=1 sh "$WORK/uv.sh" > /dev/null \
    || die "uv install failed"
fi

# --- 5-6. the bot package at the pinned tag, in a venv with a managed Python under /opt
TAG="$(sed -n 's/^DOCTOR_BOT_TAG=//p' "$KIT/kit/versions.env" | tr -d '\r' | head -1)"
[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "no DOCTOR_BOT_TAG=vX.Y.Z in kit/versions.env"
BOT_BIN="$R$OPT_DIR/venv/bin/claude-telegram-bot"
if [ -x "$BOT_BIN" ] && [ "$(cat "$R$OPT_DIR/.installed-tag" 2> /dev/null)" = "$TAG" ]; then
  say "claude-code-telegram $TAG already installed"
else
  say "installing claude-code-telegram $TAG"
  mkdir -p "$R$OPT_DIR"
  UV_PYTHON_INSTALL_DIR="$R$OPT_DIR/python" "$UV" venv --clear --python "$PYTHON_VERSION" \
    --python-preference only-managed "$R$OPT_DIR/venv" > /dev/null || die "venv failed"
  UV_PYTHON_INSTALL_DIR="$R$OPT_DIR/python" "$UV" pip install \
    --python "$R$OPT_DIR/venv/bin/python" "git+$PACKAGE_REPO@$TAG" > /dev/null \
    || die "package install failed: $PACKAGE_REPO@$TAG"
  echo "$TAG" > "$R$OPT_DIR/.installed-tag"
  CHANGED=1
fi
chmod -R a+rX "$R$OPT_DIR"   # the managed Python must be readable by the doctor user

# --- 7. Claude Code for the doctor user
if [ ! -x "$R$CLAUDE_BIN" ]; then
  say "installing Claude Code for $DOCTOR_USER"
  mkdir -p "$WORK/pub"
  chmod 711 "$WORK"
  chmod 755 "$WORK/pub"
  fetch "$CLAUDE_INSTALLER" "$WORK/pub/claude.sh"
  chmod 644 "$WORK/pub/claude.sh"
  # shellcheck disable=SC2016  # $HOME expands in the doctor's shell
  as_doctor bash -c 'cd "$HOME" && bash "$1"' _ "$WORK/pub/claude.sh" > /dev/null \
    || die "Claude Code install failed for $DOCTOR_USER"
fi

# --- 8. bot token
token_is_agents() {  # token_is_agents <token>: the bot id belongs to an agent
  local conf sec agent name
  for conf in "${CONFS[@]}"; do
    name="$(conf_get "$conf" AGENT_NAME)"
    sec="$(conf_get "$conf" SECRETS_DIR)"
    agent=""
    if [ -n "$sec" ] && [ -r "$R$sec/channel.conf" ]; then
      agent="$(conf_get "$R$sec/channel.conf" TELEGRAM_BOT_TOKEN)"
    fi
    if [ -z "$agent" ]; then
      say "WARN: could not read the bot token of agent ${name:-?} ($conf);" \
        "make sure the doctor's bot is not that agent's bot"
      continue
    fi
    [ "${agent%%:*}" = "${1%%:*}" ] && return 0
  done
  return 1
}
get_me() {  # get_me <token>: prints the bot username when Telegram accepts the token
  local resp name
  resp="$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$1" \
    | curl -sS -m "$HTTP_TIMEOUT_S" -K - 2> /dev/null)" || return 1
  [ "$(jq -r '.ok' <<< "$resp")" = true ] || return 1
  [ "$(jq -r '.result.id' <<< "$resp")" = "${1%%:*}" ] || return 1
  name="$(jq -r '.result.username' <<< "$resp")"
  [[ "$name" =~ ^[A-Za-z0-9_]{5,}$ ]] || return 1
  echo "$name"
}
choose_token() {
  local existing="" existing_name="" ans token username tries=0
  if [ -r "$R$ENV_FILE" ]; then existing="$(conf_get "$R$ENV_FILE" TELEGRAM_BOT_TOKEN)"; fi
  existing_name="$(conf_get "$R$ENV_FILE" TELEGRAM_BOT_USERNAME 2> /dev/null || true)"
  # an env file without a bot username is not trusted: ask for a token again
  if [ -n "$existing" ] && [ -n "$existing_name" ]; then
    if [ "$NONINTERACTIVE" = 1 ]; then
      [ -z "${TG_DOCTOR_BOT_TOKEN:-}" ] && KEEP_BOT=1
    else
      read -r -p "[doctor] keep the current doctor bot? [Y/n] " ans
      case "$ans" in n | N | no | No) ;; *) KEEP_BOT=1 ;; esac
    fi
  fi
  if [ "$KEEP_BOT" = 1 ]; then
    if username="$(get_me "$existing")"; then
      BOT_TOKEN="$existing"
      BOT_USERNAME="$username"
      return 0
    fi
    say "Telegram no longer accepts the current doctor bot token; a new token is needed"
    KEEP_BOT=0
  fi
  [ "$NONINTERACTIVE" = 1 ] \
    || say "create a NEW bot in @BotFather for the doctor (not an agent's bot)"
  while [ "$tries" -lt "$TOKEN_TRIES" ]; do
    tries=$((tries + 1))
    if [ "$NONINTERACTIVE" = 1 ]; then
      token="${TG_DOCTOR_BOT_TOKEN:-}"
      [ -n "$token" ] || die "TG_DOCTOR_BOT_TOKEN is not set"
    else
      read -rs -p "[doctor] doctor bot token (input hidden): " token
      echo
    fi
    if ! [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]]; then
      say "this does not look like a bot token"
    elif token_is_agents "$token"; then
      say "this is an agent's bot; the doctor needs its own bot from @BotFather"
    elif username="$(get_me "$token")"; then
      BOT_TOKEN="$token"
      BOT_USERNAME="$username"
      say "bot @$BOT_USERNAME accepted"
      return 0
    else
      say "Telegram did not accept the token"
    fi
    [ "$NONINTERACTIVE" = 1 ] && break
  done
  die "no valid doctor bot token"
}
choose_token
if [ "$KEEP_BOT" = 0 ] && [ "$NONINTERACTIVE" != 1 ]; then
  say "now open https://t.me/$BOT_USERNAME and press Start, then press Enter here"
  read -r _
fi

# --- 9. owner (agent.conf is writable by the agent, so it is never trusted on its own)
choose_owner() {
  local owners ans again tries=0 conf
  if [ "$KEEP_BOT" = 1 ]; then
    OWNER_ID="$(conf_get "$R$ENV_FILE" ALLOWED_USERS)"
    [[ "$OWNER_ID" =~ ^[0-9]+$ ]] && return 0
  fi
  if [ "$NONINTERACTIVE" = 1 ]; then
    [ -n "${TG_DOCTOR_OWNER_ID:-}" ] || die "set TG_DOCTOR_OWNER_ID (the owner's Telegram ID)"
    OWNER_ID="$TG_DOCTOR_OWNER_ID"
  else
    owners="$(for conf in "${CONFS[@]}"; do conf_get "$conf" OWNER_CHAT_ID; done \
      | grep -E '^[0-9]+$' | sort -u | tr '\n' ' ' || true)"
    say "owner IDs found in the agents: ${owners:-none}"
    while [ "$tries" -lt "$OWNER_TRIES" ]; do
      tries=$((tries + 1))
      read -r -p "[doctor] type the owner Telegram ID: " ans
      if ! [[ "$ans" =~ ^[0-9]+$ ]]; then
        say "the owner ID must be digits"
        continue
      fi
      read -r -p "[doctor] type it once more: " again
      if [ "$again" != "$ans" ]; then
        say "the two IDs differ; type again"
        continue
      fi
      [[ " $owners" == *" $ans "* ]] \
        || say "WARN: ID $ans matches no agent's owner; using it as typed"
      OWNER_ID="$ans"
      break
    done
  fi
  [[ "$OWNER_ID" =~ ^[0-9]+$ ]] || die "no valid owner ID"
}
choose_owner

# --- 10. env file (values through the environment, never argv)
keep_cap() {  # keep_cap <KEY> <default>: the env file's value when it is a positive number
  local v=""
  [ -r "$R$ENV_FILE" ] && v="$(conf_get "$R$ENV_FILE" "$1")"
  if [[ "$v" =~ ^[0-9]+(\.[0-9]+)?$ ]] && [[ "$v" =~ [1-9] ]]; then
    echo "$v"
  else
    echo "$2"
  fi
}
COST_REQUEST="$(keep_cap CLAUDE_MAX_COST_PER_REQUEST "$MAX_COST_USD")"
COST_USER="$(keep_cap CLAUDE_MAX_COST_PER_USER "$MAX_COST_USER_USD")"
mkdir -p "$R$ENV_DIR"
chmod 750 "$R$ENV_DIR"
chown "root:$DOCTOR_USER" "$R$ENV_DIR"
(
  umask 077
  DOCTOR_BOT_TOKEN="$BOT_TOKEN" DOCTOR_BOT_USERNAME="$BOT_USERNAME" \
    DOCTOR_OWNER_ID="$OWNER_ID" DOCTOR_MAX_COST="$COST_REQUEST" \
    DOCTOR_MAX_COST_USER="$COST_USER" \
    python3 "$KIT/scripts/render-template.py" "$KIT/server/doctor/env.template" "$WORK/env"
) || die "env file render failed"
if place "$WORK/env" "$R$ENV_FILE" 640; then
  CHANGED=1
  say "env file written: $ENV_FILE"
fi
chown "root:$DOCTOR_USER" "$R$ENV_FILE"

# --- 11. instructions and helper
mkdir -p "$R$DOCTOR_HOME/bin"
if [ -f "$R$DOCTOR_HOME/CLAUDE.md" ] \
   && ! cmp -s "$KIT/server/doctor/CLAUDE.md" "$R$DOCTOR_HOME/CLAUDE.md"; then
  cp -p "$R$DOCTOR_HOME/CLAUDE.md" "$R$DOCTOR_HOME/CLAUDE.md.bak_$STAMP"
fi
place "$KIT/server/doctor/CLAUDE.md" "$R$DOCTOR_HOME/CLAUDE.md" 644 || true
place "$KIT/server/doctor/list-agents.sh" "$R$DOCTOR_HOME/bin/list-agents.sh" 755 || true
chown -R "$DOCTOR_USER:$DOCTOR_USER" "$R$DOCTOR_HOME/bin" "$R$DOCTOR_HOME/CLAUDE.md"

# --- 12. unit
mkdir -p "$(dirname "$R$UNIT_FILE")"
if place "$KIT/server/doctor/agent-doctor.service.template" "$R$UNIT_FILE" 644; then
  CHANGED=1
  systemctl daemon-reload
fi

# --- 13. Claude login of the doctor user
claude_ok() {
  as_doctor bash -c 'cd "$HOME" && timeout "$1" "$2" -p ping' _ \
    "$LOGIN_CHECK_TIMEOUT_S" "$R$CLAUDE_BIN" < /dev/null > /dev/null 2>&1
}
if ! claude_ok; then
  [ "$NONINTERACTIVE" = 1 ] \
    && die "Claude is not logged in for $DOCTOR_USER; run: su - doctor -c claude, then /login"
  for try in $(seq 1 "$LOGIN_TRIES"); do
    say "log Claude in for the doctor: press Enter, Claude opens; type /login, finish it"
    say "in the browser, then type /exit. (By hand: su - doctor -c claude)"
    read -r _
    as_doctor bash -c 'cd "$HOME" && "$1"' _ "$R$CLAUDE_BIN" || true
    claude_ok && break
    [ "$try" = "$LOGIN_TRIES" ] && die "Claude login for $DOCTOR_USER not confirmed"
  done
fi

# --- 14. start; restart only when something changed (a restart from the doctor's own
# session would cut it off)
if [ "$CHANGED" = 1 ]; then
  systemctl restart "$UNIT_NAME" || true   # wait_stable below reports and dumps the journal
else
  systemctl start "$UNIT_NAME" || true
fi
wait_stable() {
  local stable=0 waited=0
  while [ "$waited" -lt "$START_TIMEOUT_S" ]; do
    if systemctl is-active --quiet "$UNIT_NAME"; then
      stable=$((stable + 1))
      [ "$stable" -ge "$STABLE_S" ] && return 0
    else
      stable=0
    fi
    sleep 1
    waited=$((waited + 1))
  done
  return 1
}
if ! wait_stable; then
  # the package logs each Bot API URL at INFO, token included: mask it in the dump
  journalctl -u "$UNIT_NAME" -n "$JOURNAL_LINES" --no-pager 2>&1 \
    | sed -E 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<hidden>#g' >&2 || true
  die "$UNIT_NAME did not stay up for ${STABLE_S}s"
fi
# enabled only now: until the install really finished, doctor-hint keeps reminding
systemctl is-enabled --quiet "$UNIT_NAME" 2> /dev/null || systemctl enable --quiet "$UNIT_NAME"

# --- 15. greeting, once per bot
BOT_ID="${BOT_TOKEN%%:*}"
if [ "$(cat "$R$OPT_DIR/.greeted" 2> /dev/null)" != "$BOT_ID" ]; then
  if printf 'url = "https://api.telegram.org/bot%s/sendMessage"\n' "$BOT_TOKEN" \
     | curl -fsS -m "$HTTP_TIMEOUT_S" -K - --data-urlencode "chat_id=$OWNER_ID" \
       --data-urlencode "text=$GREETING" -o /dev/null 2> /dev/null; then
    echo "$BOT_ID" > "$R$OPT_DIR/.greeted"
  else
    say "WARN: could not write to you; open https://t.me/$BOT_USERNAME, press Start and write hi"
  fi
fi

echo "== Doctor is up (@$BOT_USERNAME)"
