#!/usr/bin/env bash
# install-server.sh -- stand up one Telegram agent on a Linux server.
#
# Result: <BASE_DIR>/<name>/.claude holds the agent (identity + 4-layer memory
# from core/, the server scripts, the patched dashi plugin); secrets go to
# ~/.config/tg-agent/<name>/ (mode 600, outside the workspace); two systemd
# units keep the agent and its rate-limit watchdog alive; cron runs memory
# maintenance, auth checks, snapshots, media cleanup and a weekly review.
# Ends with a live test: the agent must send the owner a message.
#
# Interactive by default. For unattended runs set TG_AGENT_NONINTERACTIVE=1 and
# pass every answer as an env var (names in the prompts below; the bot token as
# TG_AGENT_BOT_TOKEN). Flags: --no-systemd, --no-cron, --no-live-test.
# Re-running with an existing agent name moves the old workspace and secrets
# aside (*.bak_<timestamp>); nothing is deleted.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KIT_DIR
readonly LIVE_TEST_TIMEOUT_S=240
readonly PORT_WAIT_S=90

DO_SYSTEMD=1
DO_CRON=1
DO_LIVE_TEST=1
for arg in "$@"; do
  case "$arg" in
    --no-systemd) DO_SYSTEMD=0 ;;
    --no-cron) DO_CRON=0 ;;
    --no-live-test) DO_LIVE_TEST=0 ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown flag: $arg" >&2; exit 2 ;;
  esac
done

say() { echo "[install] $*"; }
die() { echo "[install] ERROR: $*" >&2; exit 1; }
NONINTERACTIVE="${TG_AGENT_NONINTERACTIVE:-0}"

# ask VAR "prompt" "default": env var wins, then the prompt, then the default.
ask() {
  local var="$1" prompt="$2" def="$3" val="${!1:-}"
  if [ -z "$val" ] && [ "$NONINTERACTIVE" != "1" ]; then
    read -r -p "$prompt [$def]: " val || true
  fi
  printf -v "$var" '%s' "${val:-$def}"
}

# Values go into KEY="value" files read by bash and systemd: no expansion chars.
check_plain() {
  local name="$1" val="$2"
  case "$val" in
    *'"'*|*'$'*|*'`'*|*'\'*) die "$name must not contain \" \$ \` or \\" ;;
  esac
}

# ---------------------------------------------------------------- preflight
say "preflight"
missing=()
for cmd in bun tmux jq claude patch python3 ss curl node git crontab openssl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
[ "${#missing[@]}" -eq 0 ] || die "missing commands: ${missing[*]} (see README: server prerequisites)"
[ "$(uname -s)" = "Linux" ] || die "Linux only (systemd + ss)"

# ---------------------------------------------------------------- answers
echo "== tg-agent installer =="
ask AGENT_NAME "Agent name (lowercase, used for folders and units)" "assistant"
[[ "$AGENT_NAME" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || die "agent name: lowercase letters, digits, dash; 2-31 chars"
ask AGENT_ROLE "Agent role (short)" "Personal assistant"
ask ROLE_DESCRIPTION "Role description" "Personal assistant, strategist and coach."
ask CHARACTER "Character / tone" "Direct, concrete, no flattery."
ask OPERATOR_NAME "Your name" "Owner"
ask OPERATOR_ADDRESS "How should the agent address you" "$OPERATOR_NAME"
ask OWNER_CHAT_ID "Your Telegram numeric user ID (ask @userinfobot)" ""
[[ "$OWNER_CHAT_ID" =~ ^[1-9][0-9]{4,14}$ ]] || die "owner ID must be a positive number"
ask TIMEZONE "Timezone (IANA, e.g. Europe/Berlin)" "UTC"
[ -f "/usr/share/zoneinfo/$TIMEZONE" ] || die "unknown timezone: $TIMEZONE"
ask LANGUAGE "Language the agent speaks to you" "English"
ask VOICE_LANG "Voice transcription language code" "en"
ask AGENT_MODEL "Claude model for the agent" "opus"
ask PRIMARY_MODEL "Model name for the identity docs" "Claude Opus"
ask BASE_DIR "Where to create the agent" "$HOME/agents"
ask WEBHOOK_PORT "Local webhook port (free, 1024-65535)" "8089"
[[ "$WEBHOOK_PORT" =~ ^[0-9]+$ ]] && [ "$WEBHOOK_PORT" -ge 1024 ] && [ "$WEBHOOK_PORT" -le 65535 ] \
  || die "port must be 1024-65535"
if ss -ltnH "sport = :$WEBHOOK_PORT" | grep -q .; then
  die "port $WEBHOOK_PORT is already in use"
fi
for v in AGENT_ROLE ROLE_DESCRIPTION CHARACTER OPERATOR_NAME OPERATOR_ADDRESS LANGUAGE \
         VOICE_LANG AGENT_MODEL PRIMARY_MODEL BASE_DIR; do
  check_plain "$v" "${!v}"
done

BOT_TOKEN="${TG_AGENT_BOT_TOKEN:-}"
if [ -z "$BOT_TOKEN" ] && [ "$NONINTERACTIVE" != "1" ]; then
  read -r -s -p "Bot token from @BotFather (hidden): " BOT_TOKEN || true
  echo
fi
[[ "$BOT_TOKEN" =~ ^[0-9]+:[A-Za-z0-9_-]{30,}$ ]] || die "bot token format is wrong"

GROQ_KEY="${TG_AGENT_GROQ_KEY:-}"
if [ -z "$GROQ_KEY" ] && [ "$NONINTERACTIVE" != "1" ]; then
  read -r -s -p "Groq key for voice messages (optional, enter to skip): " GROQ_KEY || true
  echo
fi
OAUTH="${TG_AGENT_CLAUDE_OAUTH:-}"
if [ -z "$OAUTH" ] && [ "$NONINTERACTIVE" != "1" ]; then
  read -r -s -p "Claude long-lived token from 'claude setup-token' (optional, enter to skip): " OAUTH || true
  echo
fi
for v in BOT_TOKEN GROQ_KEY OAUTH; do check_plain "$v" "${!v}"; done

# ---------------------------------------------------------------- bot check
if [ "${TG_AGENT_TEST_SKIP_GETME:-0}" = "1" ]; then
  # test-only: no network; trust the id in the token
  GETME="$(jq -n --arg id "${BOT_TOKEN%%:*}" '{ok:true,result:{id:($id|tonumber),username:"test_bot"}}')"
else
  say "checking the bot token with Telegram (getMe)"
  GETME="$(printf 'url = "https://api.telegram.org/bot%s/getMe"\n' "$BOT_TOKEN" | curl -sS -m 20 -K - || true)"
  [ "$(jq -r '.ok // false' <<<"$GETME" 2>/dev/null)" = "true" ] || die "Telegram rejected the token"
fi
BOT_ID="$(jq -r '.result.id' <<<"$GETME")"
BOT_USERNAME="$(jq -r '.result.username' <<<"$GETME")"
[ "$BOT_ID" = "${BOT_TOKEN%%:*}" ] || die "getMe id does not match the token"
say "bot: @$BOT_USERNAME"

# ---------------------------------------------------------------- layout
AGENT_HOME="$BASE_DIR/$AGENT_NAME"
AGENT_WS="$AGENT_HOME/.claude"
SECRETS_DIR="$HOME/.config/tg-agent/$AGENT_NAME"
CLAUDE_CONFIG_DIR="$HOME/.claude-agent-$AGENT_NAME"
CLAUDE_BIN="$(command -v claude)"
BUN_BIN="$(command -v bun)"
PLUGIN_DIR="$AGENT_WS/dashi-plugin/plugin"
RUN_USER="$(id -un)"
RUN_GROUP="$(id -gn)"
USER_HOME="$HOME"
WEBHOOK_TOKEN="$(openssl rand -hex 24)"
VOICE_PROVIDER="none"
[ -n "$GROQ_KEY" ] && VOICE_PROVIDER="groq"
STAMP="$(date +%Y%m%d_%H%M%S)"

for d in "$AGENT_HOME" "$SECRETS_DIR"; do
  if [ -e "$d" ]; then
    say "'$d' exists -> moving to $d.bak_$STAMP"
    mv "$d" "$d.bak_$STAMP"
  fi
done

export AGENT_NAME AGENT_ROLE ROLE_DESCRIPTION CHARACTER OPERATOR_NAME OPERATOR_ADDRESS \
  TIMEZONE LANGUAGE PRIMARY_MODEL OWNER_CHAT_ID AGENT_HOME AGENT_WS SECRETS_DIR \
  CLAUDE_CONFIG_DIR CLAUDE_BIN BUN_BIN AGENT_MODEL WEBHOOK_PORT BOT_ID RUN_USER RUN_GROUP USER_HOME \
  VOICE_PROVIDER
export LANGUAGE_CODE="$VOICE_LANG"

# render SRC DST: fill {{KEY}} from the environment; unknown placeholders fail.
render() {
  python3 "$KIT_DIR/scripts/render-template.py" "$1" "$2"
}

# ---------------------------------------------------------------- core
say "scaffolding the agent core in $AGENT_WS"
C="$KIT_DIR/core"
T="$C/templates"
mkdir -p "$AGENT_WS"/core/warm "$AGENT_WS"/core/hot "$AGENT_WS"/core/learnings \
         "$AGENT_WS"/core/archive "$AGENT_WS"/tools "$AGENT_WS"/hooks "$AGENT_WS"/scripts \
         "$AGENT_WS"/skills "$AGENT_WS"/agents "$AGENT_WS"/logs/activity "$AGENT_WS"/backups \
         "$AGENT_WS"/bin "$AGENT_WS"/state/telegram "$AGENT_WS"/state/dm-inbox \
         "$AGENT_HOME"/library
cp "$T/CLAUDE.md.template"              "$AGENT_WS/CLAUDE.md"
cp "$T/settings.json.template"          "$AGENT_WS/settings.json"
cp "$T/core/USER.md.template"           "$AGENT_WS/core/USER.md"
cp "$T/core/rules.md.template"          "$AGENT_WS/core/rules.md"
cp "$T/core/MEMORY.md.template"         "$AGENT_WS/core/MEMORY.md"
cp "$T/core/LEARNINGS.md.template"      "$AGENT_WS/core/LEARNINGS.md"
cp "$T/core/warm/decisions.md.template" "$AGENT_WS/core/warm/decisions.md"
cp "$T/core/hot/recent.md.template"     "$AGENT_WS/core/hot/recent.md"
cp "$T/core/hot/handoff.md.template"    "$AGENT_WS/core/hot/handoff.md"
cp "$T/tools/TOOLS.md.template"         "$AGENT_WS/tools/TOOLS.md"
: > "$AGENT_WS/core/learnings/episodes.jsonl"
cp "$C"/hooks/* "$AGENT_WS/hooks/"
cp "$C"/scripts/*.sh "$C"/scripts/*.mjs "$AGENT_WS/scripts/"
cp -R "$C"/skills/. "$AGENT_WS/skills/"
python3 "$KIT_DIR/scripts/render-template.py" --tree "$AGENT_WS"

# Russian-speaking agent: typography rule goes into Response format, after the defaults.
case "$LANGUAGE" in
  Russian*|russian*|Русск*|русск*|ru|RU)
    python3 - "$AGENT_WS/core/rules.md" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
anchor = "- Summary after each task\n"
rule = "- Russian typography: long dash «—», quotes «ёлочки», е instead of ё\n"
text = path.read_text(encoding="utf-8")
if anchor not in text:
    raise SystemExit("install-server: Response format anchor missing in core/rules.md")
path.write_text(text.replace(anchor, anchor + rule, 1), encoding="utf-8")
PY
    ;;
esac

# Channel rule on top of the core identity: the owner only reads Telegram.
cat "$KIT_DIR/server/templates/channel-rules.md" >> "$AGENT_WS/core/rules.md"

# ---------------------------------------------------------------- server layer
say "installing server scripts and hooks"
cp "$KIT_DIR"/server/bin/* "$AGENT_WS/bin/"
cp "$KIT_DIR"/server/hooks/* "$AGENT_WS/hooks/"
chmod +x "$AGENT_WS"/bin/*.sh "$AGENT_WS"/hooks/*.sh "$AGENT_WS"/hooks/*.py "$AGENT_WS"/scripts/*.sh
find "$AGENT_WS/skills" -name '*.sh' -exec chmod +x {} +
render "$KIT_DIR/server/templates/agent.conf.template" "$AGENT_WS/agent.conf"

say "writing secrets to $SECRETS_DIR (mode 600)"
(
  umask 077
  mkdir -p "$SECRETS_DIR"
  export BOT_TOKEN WEBHOOK_TOKEN
  render "$KIT_DIR/server/templates/channel.conf.template" "$SECRETS_DIR/channel.conf"
  if [ -n "$GROQ_KEY" ]; then
    printf 'GROQ_API_KEY="%s"\n' "$GROQ_KEY" >> "$SECRETS_DIR/channel.conf"
  fi
  if [ -n "$OAUTH" ]; then
    printf 'CLAUDE_CODE_OAUTH_TOKEN="%s"\n' "$OAUTH" > "$SECRETS_DIR/claude-auth.conf"
  fi
)
chmod 700 "$SECRETS_DIR"
chmod 600 "$SECRETS_DIR"/*.conf

# ---------------------------------------------------------------- plugin
say "building the Telegram plugin (upstream + patches)"
bash "$KIT_DIR/scripts/build-plugin.sh" "$AGENT_WS/dashi-plugin"
if [ "${TG_AGENT_TEST_SKIP_BUN:-0}" != "1" ]; then
  (cd "$PLUGIN_DIR" && bun install --frozen-lockfile)
fi
mkdir -p "$PLUGIN_DIR/.claude"
# the agent runs in the plugin dir: point its project skills at the workspace skills
ln -sfn ../../../skills "$PLUGIN_DIR/.claude/skills"
render "$KIT_DIR/server/templates/plugin-settings.json.template" "$PLUGIN_DIR/.claude/settings.json"
(umask 077; render "$KIT_DIR/server/templates/config.json.template" "$AGENT_WS/state/telegram/config.json")

# ---------------------------------------------------------------- claude config
say "preparing Claude Code config dir $CLAUDE_CONFIG_DIR"
mkdir -p "$CLAUDE_CONFIG_DIR"
python3 - "$CLAUDE_CONFIG_DIR" "$PLUGIN_DIR" "$("$CLAUDE_BIN" --version | awk '{print $1}')" <<'PY'
import json
import pathlib
import sys

cfg_dir, plugin_dir, version = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]


def merge(path: pathlib.Path, patch: dict) -> None:
    data = json.loads(path.read_text()) if path.exists() else {}
    for key, val in patch.items():
        if isinstance(val, dict):
            data.setdefault(key, {})
            for k2, v2 in val.items():
                data[key].setdefault(k2, {}).update(v2)
        else:
            data[key] = val
    path.write_text(json.dumps(data, indent=2) + "\n")


merge(cfg_dir / "settings.json", {"skipDangerousModePermissionPrompt": True, "theme": "dark"})
merge(cfg_dir / ".claude.json", {
    "hasCompletedOnboarding": True,
    "lastOnboardingVersion": version,
    # The workspace CLAUDE.md @-imports files outside the plugin dir; pre-approve them
    # so the first start does not stop at the external-imports prompt.
    "projects": {plugin_dir: {
        "hasTrustDialogAccepted": True,
        "hasClaudeMdExternalIncludesApproved": True,
        "hasClaudeMdExternalIncludesWarningShown": True,
    }},
})
PY
if [ ! -f "$CLAUDE_CONFIG_DIR/CLAUDE.md" ]; then
  render "$T/global-CLAUDE.md.template" "$CLAUDE_CONFIG_DIR/CLAUDE.md"
fi
mkdir -p "$CLAUDE_CONFIG_DIR/rules"
for f in bash python typescript; do
  [ -f "$CLAUDE_CONFIG_DIR/rules/$f.md" ] || cp "$T/global-rules/$f.md" "$CLAUDE_CONFIG_DIR/rules/"
done

if [ -z "$OAUTH" ] && [ ! -f "$CLAUDE_CONFIG_DIR/.credentials.json" ]; then
  echo
  echo "Claude Code is not logged in for this agent. In another terminal run:"
  echo "    CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\" claude"
  echo "then type /login, finish the login, exit with /exit."
  if [ "$NONINTERACTIVE" != "1" ]; then
    read -r -p "Press Enter when done (or Ctrl-C to stop here) " _ || true
  fi
  [ -f "$CLAUDE_CONFIG_DIR/.credentials.json" ] || say "WARN: still no credentials; the agent will not answer until you log in"
fi

# ---------------------------------------------------------------- systemd
UNIT_AGENT="$AGENT_NAME-agent.service"
UNIT_WATCH="$AGENT_NAME-ratewatch.service"
if [ "$DO_SYSTEMD" = "1" ]; then
  say "installing systemd units $UNIT_AGENT, $UNIT_WATCH"
  # Rendered units stay in the workspace so a manual install can point at them.
  UNIT_DIR="$AGENT_WS/systemd"
  mkdir -p "$UNIT_DIR"
  render "$KIT_DIR/server/systemd/agent.service.template" "$UNIT_DIR/$UNIT_AGENT"
  render "$KIT_DIR/server/systemd/ratewatch.service.template" "$UNIT_DIR/$UNIT_WATCH"
  # Root or passwordless sudo only: a password prompt would stall the install.
  CAN_ROOT=1
  if [ "$(id -u)" = "0" ]; then
    as_root() { "$@"; }
  elif sudo -n true 2>/dev/null; then
    as_root() { sudo -n "$@"; }
  else
    CAN_ROOT=0
  fi
  if [ "$CAN_ROOT" = "1" ]; then
    as_root install -m 644 "$UNIT_DIR/$UNIT_AGENT" "$UNIT_DIR/$UNIT_WATCH" /etc/systemd/system/
    as_root systemctl daemon-reload
    as_root systemctl enable --now "$UNIT_AGENT" "$UNIT_WATCH"
  else
    say "no passwordless sudo; install the units yourself (as root or with sudo):"
    echo "    sudo install -m 644 $UNIT_DIR/$UNIT_AGENT $UNIT_DIR/$UNIT_WATCH /etc/systemd/system/"
    echo "    sudo systemctl daemon-reload && sudo systemctl enable --now $UNIT_AGENT $UNIT_WATCH"
    DO_LIVE_TEST=0
  fi
fi

# ---------------------------------------------------------------- cron
if [ "$DO_CRON" = "1" ]; then
  say "installing cron jobs"
  bash "$C/cron/install-cron.sh" "$AGENT_WS"
  bash "$KIT_DIR/server/cron/install-cron.sh" "$AGENT_WS"
fi

# ---------------------------------------------------------------- live test
if [ "$DO_LIVE_TEST" = "1" ] && [ "$DO_SYSTEMD" = "1" ]; then
  say "live test: waiting for the plugin to listen on 127.0.0.1:$WEBHOOK_PORT"
  waited=0
  until ss -ltnH "sport = :$WEBHOOK_PORT" | grep -q .; do
    [ "$waited" -lt "$PORT_WAIT_S" ] || die "plugin did not come up; see $AGENT_WS/logs/"
    sleep 3
    waited=$((waited + 3))
  done
  HOT="$AGENT_WS/core/hot/recent-plugin.md"
  before="$(stat -c %Y "$HOT" 2>/dev/null || echo 0)"
  SESSION="$AGENT_NAME-agent"
  sleep 10
  tmux send-keys -t "$SESSION" C-u
  tmux send-keys -t "$SESSION" -l -- "Installation self-test: send the owner one short line via mcp__dashi-channel__reply to chat_id $OWNER_CHAT_ID saying that you are online and ready."
  sleep 0.5
  tmux send-keys -t "$SESSION" Enter
  say "live test: waiting up to ${LIVE_TEST_TIMEOUT_S}s for the reply"
  waited=0
  while [ "$(stat -c %Y "$HOT" 2>/dev/null || echo 0)" = "$before" ]; do
    if [ "$waited" -ge "$LIVE_TEST_TIMEOUT_S" ]; then
      die "no reply recorded; check 'tmux attach -t $SESSION' (login? prompt?)"
    fi
    sleep 5
    waited=$((waited + 5))
  done
  say "live test passed: the agent replied (check Telegram)"
fi

echo
echo "== Done. Agent '$AGENT_NAME' (@$BOT_USERNAME)"
echo "  workspace:  $AGENT_HOME"
echo "  watch it:   tmux attach -t $AGENT_NAME-agent   (detach: Ctrl-b d)"
echo "  services:   systemctl status $UNIT_AGENT $UNIT_WATCH"
echo "  next:       write /onboard to the bot -- it asks about you and fills the profile"
