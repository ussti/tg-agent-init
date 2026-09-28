#!/usr/bin/env bash
# install-fleet.sh -- turn the agents made by install-server.sh into one team.
#
# Result: the shared brain (G-Brain: memory, recall, swarm) runs on this server;
# every agent under BASE_DIR gets its own brain token (in its channel.conf,
# mode 600), the three brain MCP servers in its .mcp.json and a team block in
# core/rules.md; the swarm worker learns how to reach each agent's webhook;
# the brain is backed up nightly (pg_dump + vault tar, 14 days).
#
# Run it after all agents are installed, as the same user. Re-running is safe:
# it picks up new agents, keeps existing tokens (--rotate-tokens re-issues
# them) and rewrites the team block in place. Flags:
#   --coordinator NAME     agent that routes cross-domain work (asked if unset)
#   --use-existing-brain   accept a brain this script did not install
#                          (its tokens for the same agent names get rotated)
#   --rotate-tokens        re-issue every agent's brain token
#   --no-restart           do not restart the agents at the end
#                          (refused with rotation: agents would keep dead tokens)
# Unattended: TG_AGENT_NONINTERACTIVE=1 plus TG_FLEET_COORDINATOR / BASE_DIR.
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly KIT_DIR
readonly MIN_RAM_MB=3800
readonly WARN_RAM_MB=7000
readonly BACKUP_HOUR=3
readonly BACKUP_MINUTE=17
readonly BRAIN_SCOPES="10-strategy,10-system,20-daily,20-metrics,30-decisions,40-projects,50-external,50-knowledge,60-tasks,70-runbooks,80-error-patterns,90-inbox,slots"
readonly TEAM_START="<!-- team-layer:start"
readonly TEAM_END="<!-- team-layer:end -->"

# Paths: upstream installer defaults; overridable for tests.
BASE_DIR="${BASE_DIR:-$HOME/agents}"
GBRAIN_DIR="${GBRAIN_DIR:-/opt/gbrain}"
GBRAIN_ETC_DIR="${GBRAIN_ETC_DIR:-/etc/gbrain}"
GBRAIN_USER="${GBRAIN_USER:-gbrain}"
GBRAIN_LOG_DIR="${GBRAIN_LOG_DIR:-/var/log/gbrain}"
SYSTEMD_DIR="${SYSTEMD_DIR:-/etc/systemd/system}"
CRON_DIR="${CRON_DIR:-/etc/cron.d}"
LIB_DIR="${LIB_DIR:-/usr/local/lib/tg-agent}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/gbrain}"
# Upstream unit templates hard-code these ports, so they are not configurable.
readonly MEMORY_PORT=8767
readonly RECALL_PORT=8768
readonly SWARM_PORT=8766
# Tests only: the smoke talks to a fake brain listening on <port + offset>.
SMOKE_PORT_OFFSET="${TG_FLEET_TEST_SMOKE_PORT_OFFSET:-0}"
FLEET_CONF_DIR="$HOME/.config/tg-agent"
FLEET_CONF="$FLEET_CONF_DIR/fleet.conf"
WORKER_UNIT="gbrain-swarm-worker.service"
DROPIN_DIR="$SYSTEMD_DIR/$WORKER_UNIT.d"
DROPIN_FILE="$DROPIN_DIR/tg-agent-fleet.conf"
FLEET_ENV="$GBRAIN_ETC_DIR/fleet.env"
MARKER="$GBRAIN_ETC_DIR/tg-agent-fleet.marker"
BRAIN_PY="$GBRAIN_DIR/.venv/bin/python"
ISSUE_TOKEN="$GBRAIN_DIR/scripts/issue-agent-token.py"

COORDINATOR="${TG_FLEET_COORDINATOR:-}"
ADOPT_BRAIN=0
USE_EXISTING=0
ROTATE=0
DO_RESTART=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --coordinator) [ "$#" -ge 2 ] || { echo "--coordinator needs a name" >&2; exit 2; }
                   COORDINATOR="$2"; shift ;;
    --use-existing-brain) USE_EXISTING=1 ;;
    --rotate-tokens) ROTATE=1 ;;
    --no-restart) DO_RESTART=0 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    *) echo "unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

say() { echo "[fleet] $*"; }
warn() { echo "[fleet] WARN: $*" >&2; }
die() { echo "[fleet] ERROR: $*" >&2; exit 1; }
NONINTERACTIVE="${TG_AGENT_NONINTERACTIVE:-0}"

# TG_FLEET_NO_SUDO=1 (tests only): run privileged steps as the current user.
as_root() {
  if [ "${TG_FLEET_NO_SUDO:-0}" = "1" ]; then "$@"; else sudo "$@"; fi
}
as_brain_user() {
  if [ "${TG_FLEET_NO_SUDO:-0}" = "1" ]; then "$@"; else sudo -u "$GBRAIN_USER" "$@"; fi
}

# read_conf FILE KEY: value of KEY="..." without sourcing; bash builtins only,
# so a secret value never reaches a child process argv.
read_conf() {
  local file="$1" key="$2" line val=""
  [ -r "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" == "$key="* ]]; then
      val="${line#*=}"
      val="${val%\"}"; val="${val#\"}"
      break
    fi
  done < "$file"
  printf '%s' "$val"
}

# set_conf_line FILE KEY VALUE: replace or append KEY="VALUE", keep mode 600.
# Builtins only (printf, read): the value is a secret.
set_conf_line() {
  local file="$1" key="$2" val="$3" tmp line found=0
  tmp="$(mktemp "$(dirname "$file")/.conf.XXXXXX")"
  chmod 600 "$tmp"
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      if [[ "$line" == "$key="* ]]; then
        printf '%s="%s"\n' "$key" "$val" >> "$tmp"
        found=1
      else
        printf '%s\n' "$line" >> "$tmp"
      fi
    done < "$file"
  fi
  [ "$found" = "1" ] || printf '%s="%s"\n' "$key" "$val" >> "$tmp"
  mv "$tmp" "$file"
}

# ---------------------------------------------------------------- preflight
say "preflight"
missing=()
for cmd in python3 patch systemctl; do
  command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
done
[ "${TG_FLEET_NO_SUDO:-0}" = "1" ] || command -v sudo >/dev/null 2>&1 || missing+=(sudo)
[ "${#missing[@]}" -eq 0 ] || die "missing commands: ${missing[*]}"
[ "$(uname -s)" = "Linux" ] || die "Linux only"
[[ "$SMOKE_PORT_OFFSET" =~ ^[0-9]+$ ]] || die "TG_FLEET_TEST_SMOKE_PORT_OFFSET must be a number"
if [ "$DO_RESTART" = "0" ] && { [ "$ROTATE" = "1" ] || [ "$USE_EXISTING" = "1" ]; }; then
  die "--no-restart cannot be combined with token rotation: running agents would keep revoked tokens"
fi

# Agents: <BASE_DIR>/<name>/.claude/agent.conf whose AGENT_NAME equals the
# folder name. That skips the *.bak_<stamp> copies a reinstall leaves behind.
AGENTS=()
for conf in "$BASE_DIR"/*/.claude/agent.conf; do
  [ -f "$conf" ] || continue
  dir_name="$(basename "$(dirname "$(dirname "$conf")")")"
  name="$(read_conf "$conf" AGENT_NAME)"
  [ "$name" = "$dir_name" ] || continue
  [[ "$name" =~ ^[a-z][a-z0-9-]{1,30}$ ]] || { warn "skipping '$name': bad agent name"; continue; }
  AGENTS+=("$name")
done
[ "${#AGENTS[@]}" -ge 1 ] || die "no agents under $BASE_DIR (run install-server.sh first)"
[ "${#AGENTS[@]}" -ge 2 ] || warn "only one agent (${AGENTS[0]}): the brain works, the swarm has nobody to talk to"
say "agents: ${AGENTS[*]}"

agent_conf() { printf '%s/%s/.claude/agent.conf' "$BASE_DIR" "$1"; }
agent_val() { read_conf "$(agent_conf "$1")" "$2"; }

OWNER_CHAT_ID="$(agent_val "${AGENTS[0]}" OWNER_CHAT_ID)"
OPERATOR_NAME="$(agent_val "${AGENTS[0]}" OPERATOR_NAME)"
declare -A SEEN_PORT=()
for a in "${AGENTS[@]}"; do
  [ "$(agent_val "$a" OWNER_CHAT_ID)" = "$OWNER_CHAT_ID" ] \
    || die "agent '$a' has another owner: one team serves one owner"
  port="$(agent_val "$a" TELEGRAM_WEBHOOK_PORT)"
  [[ "$port" =~ ^[0-9]+$ ]] || die "agent '$a': no TELEGRAM_WEBHOOK_PORT in agent.conf"
  [ -z "${SEEN_PORT[$port]:-}" ] || die "agents '${SEEN_PORT[$port]}' and '$a' share port $port"
  SEEN_PORT[$port]="$a"
  channel="$(agent_val "$a" SECRETS_DIR)/channel.conf"
  [ -f "$channel" ] || die "agent '$a': missing $channel"
  [ -n "$(read_conf "$channel" TELEGRAM_WEBHOOK_TOKEN)" ] || die "agent '$a': no webhook token"
  [ -f "$(agent_val "$a" PLUGIN_DIR)/.mcp.json" ] || die "agent '$a': missing plugin .mcp.json"
  [ -f "$(agent_val "$a" AGENT_WS)/core/rules.md" ] || die "agent '$a': missing core/rules.md"
done

# Coordinator: flag/env, then fleet.conf, then ask (default: first agent).
prev_coord="$(read_conf "$FLEET_CONF" FLEET_COORDINATOR)"
if [ -z "$COORDINATOR" ]; then
  def="${prev_coord:-${AGENTS[0]}}"
  if [ "$NONINTERACTIVE" != "1" ]; then
    read -r -p "Coordinator agent (${AGENTS[*]}) [$def]: " COORDINATOR || true
  fi
  COORDINATOR="${COORDINATOR:-$def}"
fi
in_fleet=0
for a in "${AGENTS[@]}"; do [ "$a" = "$COORDINATOR" ] && in_fleet=1; done
[ "$in_fleet" = "1" ] || die "coordinator '$COORDINATOR' is not one of: ${AGENTS[*]}"

# Every refusal happens before the first token is issued: issuing revokes the
# agent's previous brain token.
if as_root test -d "$DROPIN_DIR"; then
  foreign="$(as_root find "$DROPIN_DIR" -maxdepth 1 -type f ! -name "$(basename "$DROPIN_FILE")" -printf '%f ')"
  [ -z "$foreign" ] || die "$DROPIN_DIR has drop-ins this kit did not write ($foreign).
  They may set AGENT_GATEWAYS too; merge them by hand or move them away, then re-run."
fi

# ---------------------------------------------------------------- brain
brain_present() { as_brain_user test -x "$BRAIN_PY" && as_brain_user test -f "$ISSUE_TOKEN"; }

if brain_present; then
  if as_root test -f "$MARKER"; then
    say "brain already installed by this kit at $GBRAIN_DIR"
  elif [ "$USE_EXISTING" = "1" ]; then
    warn "using a brain this kit did not install ($GBRAIN_DIR);"
    warn "tokens for agents named ${AGENTS[*]} will be re-issued there"
    ROTATE=1
    ADOPT_BRAIN=1
  else
    die "a brain already exists at $GBRAIN_DIR but was not installed by this kit.
  If it is yours and you want these agents in it, re-run with --use-existing-brain
  (tokens of agents with the same names in that brain get rotated)."
  fi
  # The swarm worker must not send agentId: the dashi webhook answers 404 to it.
  if as_brain_user grep -q '"agentId": to_agent' "$GBRAIN_DIR/services/swarm_mcp/worker.py"; then
    die "the brain at $GBRAIN_DIR lacks patch 0001 (worker sends agentId, agents would 404).
  Apply it: sudo patch -d $GBRAIN_DIR -p1 < $KIT_DIR/patches/public-gbrain-agentos/0001-swarm-worker-drop-agentid.patch"
  fi
else
  # A half-present brain is not a fresh server: upstream's installer would
  # rsync --delete over it (vault included) and reset the database password.
  if as_root test -e "$GBRAIN_DIR"; then
    die "$GBRAIN_DIR exists but $BRAIN_PY or $ISSUE_TOKEN is missing: repair or move it away first"
  fi
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  mem_mb=$((mem_kb / 1024))
  [ "$mem_mb" -ge "$MIN_RAM_MB" ] || die "brain needs at least 4 GB RAM (found ${mem_mb} MB)"
  [ "$mem_mb" -ge "$WARN_RAM_MB" ] || warn "${mem_mb} MB RAM: brain + agents fit, but tight; 8 GB is comfortable"
  say "installing the brain (upstream public-gbrain-agentos + kit patches) into $GBRAIN_DIR"
  build_root="$(mktemp -d)"
  # The upstream installer runs as root and may leave root-owned files here.
  trap 'as_root rm -rf "$build_root"' EXIT
  bash "$KIT_DIR/scripts/build-gbrain.sh" "$build_root/gbrain"
  as_root bash "$build_root/gbrain/scripts/install.sh"
  brain_present || die "brain install finished but $BRAIN_PY or $ISSUE_TOKEN is missing"
  printf 'installed by tg-agent-init install-fleet.sh on %s\n' "$(date -Is)" \
    | as_root tee "$MARKER" >/dev/null
  as_root rm -rf "$build_root"
  trap - EXIT
fi

# ---------------------------------------------------------------- tokens
for a in "${AGENTS[@]}"; do
  channel="$(agent_val "$a" SECRETS_DIR)/channel.conf"
  if [ -n "$(read_conf "$channel" GBRAIN_BEARER)" ] && [ "$ROTATE" = "0" ]; then
    say "$a: brain token already set"
    continue
  fi
  say "$a: issuing brain token"
  token="$(as_brain_user "$BRAIN_PY" "$ISSUE_TOKEN" --agent "$a" --scopes "$BRAIN_SCOPES" 2>/dev/null)" \
    || die "$a: token issue failed (run it by hand to see why: sudo -u $GBRAIN_USER $BRAIN_PY $ISSUE_TOKEN --agent $a --scopes ...)"
  token="${token##*$'\n'}"
  [[ "$token" =~ ^[A-Za-z0-9_-]{32,}$ ]] || die "$a: token issuer printed something unexpected"
  set_conf_line "$channel" GBRAIN_BEARER "$token"
  unset token
done
if [ "$ADOPT_BRAIN" = "1" ]; then
  # From now on the brain counts as the kit's: re-runs keep tokens.
  printf 'adopted by tg-agent-init install-fleet.sh on %s\n' "$(date -Is)" \
    | as_root tee "$MARKER" >/dev/null
fi

# ---------------------------------------------------------------- agent config
say "wiring brain MCP servers and the team block into each agent"
roster=""
for a in "${AGENTS[@]}"; do
  role=""
  first="$(head -n1 "$BASE_DIR/$a/.claude/CLAUDE.md" 2>/dev/null || true)"
  case "$first" in "# $a — "*) role="${first#"# $a — "}" ;; esac
  line="- **$a** — ${role:-agent}"
  [ "$a" = "$COORDINATOR" ] && line+=" (coordinator)"
  roster+="$line"$'\n'
done
roster="${roster%$'\n'}"

for a in "${AGENTS[@]}"; do
  plugin_dir="$(agent_val "$a" PLUGIN_DIR)"
  ws="$(agent_val "$a" AGENT_WS)"
  mkdir -p "$plugin_dir/.claude"
  python3 - "$plugin_dir" "$MEMORY_PORT" "$RECALL_PORT" "$SWARM_PORT" <<'PY'
import json
import pathlib
import sys

plugin_dir = pathlib.Path(sys.argv[1])
ports = {"gbrain-memory": sys.argv[2], "gbrain-recall": sys.argv[3], "gbrain-swarm": sys.argv[4]}

mcp_path = plugin_dir / ".mcp.json"
mcp = json.loads(mcp_path.read_text())
servers = mcp.setdefault("mcpServers", {})
for name, port in ports.items():
    # ${GBRAIN_BEARER} is expanded by Claude Code from the pane env (channel.conf).
    servers[name] = {
        "type": "http",
        "url": f"http://127.0.0.1:{port}/mcp",
        "headers": {"Authorization": "Bearer ${GBRAIN_BEARER}"},
    }
mcp_path.write_text(json.dumps(mcp, indent=2) + "\n")

local_path = plugin_dir / ".claude" / "settings.local.json"
local = json.loads(local_path.read_text()) if local_path.exists() else {}
enabled = local.setdefault("enabledMcpjsonServers", [])
for name in ["dashi-channel", *ports]:
    if name not in enabled:
        enabled.append(name)
local_path.write_text(json.dumps(local, indent=2) + "\n")
PY

  rules="$ws/core/rules.md"
  block="$(mktemp)"
  AGENT_NAME="$a" OPERATOR_NAME="$OPERATOR_NAME" FLEET_ROSTER="$roster" \
    FLEET_COORDINATOR="$COORDINATOR" \
    python3 "$KIT_DIR/scripts/render-template.py" "$KIT_DIR/server/templates/team-rules.md" "$block"
  python3 - "$rules" "$block" "$TEAM_START" "$TEAM_END" <<'PY'
import pathlib
import re
import sys

rules, block, start, end = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3], sys.argv[4]
text = rules.read_text()
new = block.read_text().strip("\n")
pattern = re.compile(re.escape(start) + r".*?" + re.escape(end), re.S)
if pattern.search(text):
    text = pattern.sub(lambda _m: new, text, count=1)
else:
    text = text.rstrip("\n") + "\n\n" + new + "\n"
rules.write_text(text)
PY
  rm -f "$block"
  say "$a: .mcp.json, settings.local.json, core/rules.md updated"
done

# ---------------------------------------------------------------- fleet.conf
mkdir -p "$FLEET_CONF_DIR"
chmod 700 "$FLEET_CONF_DIR"
[ -f "$FLEET_CONF" ] || { : > "$FLEET_CONF"; chmod 600 "$FLEET_CONF"; }
set_conf_line "$FLEET_CONF" FLEET_AGENTS "${AGENTS[*]}"
set_conf_line "$FLEET_CONF" FLEET_COORDINATOR "$COORDINATOR"

# ---------------------------------------------------------------- swarm worker
say "pointing the swarm worker at the agents' webhooks"

env_tmp="$(mktemp "$FLEET_CONF_DIR/.fleet-env.XXXXXX")"
chmod 600 "$env_tmp"
gateways="{" auth="{" sep=""
for a in "${AGENTS[@]}"; do
  var="FLEET_$(printf '%s' "$a" | tr 'a-z-' 'A-Z_')_WEBHOOK_TOKEN"
  gateways+="$sep\"$a\":\"http://127.0.0.1:$(agent_val "$a" TELEGRAM_WEBHOOK_PORT)/hooks/agent\""
  auth+="$sep\"$a\":\"bearer:env:$var\""
  sep=","
done
gateways+="}" auth+="}"
{
  printf '# Written by tg-agent-init install-fleet.sh; re-running it rewrites this file.\n'
  printf "AGENT_GATEWAYS='%s'\n" "$gateways"
  printf "AGENT_GATEWAY_AUTH='%s'\n" "$auth"
  printf 'OWNER_CHAT_ID="%s"\n' "$OWNER_CHAT_ID"
  printf 'COORDINATOR_AGENT="%s"\n' "$COORDINATOR"
  for a in "${AGENTS[@]}"; do
    var="FLEET_$(printf '%s' "$a" | tr 'a-z-' 'A-Z_')_WEBHOOK_TOKEN"
    printf '%s="%s"\n' "$var" "$(read_conf "$(agent_val "$a" SECRETS_DIR)/channel.conf" TELEGRAM_WEBHOOK_TOKEN)"
  done
} >> "$env_tmp"
as_root install -m 600 "$env_tmp" "$FLEET_ENV"
[ "${TG_FLEET_NO_SUDO:-0}" = "1" ] || as_root chown root:root "$FLEET_ENV"
rm -f "$env_tmp"

dropin_tmp="$(mktemp)"
printf '# Written by tg-agent-init install-fleet.sh: agent gateways for the swarm worker.\n[Service]\nEnvironmentFile=%s\n' \
  "$FLEET_ENV" > "$dropin_tmp"
as_root mkdir -p "$DROPIN_DIR"
as_root install -m 644 "$dropin_tmp" "$DROPIN_FILE"
rm -f "$dropin_tmp"
as_root systemctl daemon-reload
as_root systemctl restart "$WORKER_UNIT"

# ---------------------------------------------------------------- backup
say "installing nightly brain backup ($BACKUP_DIR, 14 days)"
as_root mkdir -p "$LIB_DIR"
as_root install -m 755 "$KIT_DIR/server/fleet/gbrain-backup.sh" "$LIB_DIR/gbrain-backup.sh"
cron_tmp="$(mktemp)"
{
  printf '# tg-agent-init: nightly G-Brain backup (pg_dump + vault tar).\n'
  printf 'GBRAIN_DIR=%s\nBACKUP_DIR=%s\n' "$GBRAIN_DIR" "$BACKUP_DIR"
  printf '%s %s * * * root %s/gbrain-backup.sh >> %s/backup.log 2>&1\n' \
    "$BACKUP_MINUTE" "$BACKUP_HOUR" "$LIB_DIR" "$GBRAIN_LOG_DIR"
} > "$cron_tmp"
as_root install -m 644 "$cron_tmp" "$CRON_DIR/tg-agent-gbrain-backup"
rm -f "$cron_tmp"

# ---------------------------------------------------------------- restart
if [ "$DO_RESTART" = "1" ]; then
  for a in "${AGENTS[@]}"; do
    if [ -f "$SYSTEMD_DIR/$a-agent.service" ]; then
      say "$a: restarting to load the brain"
      as_root systemctl restart "$a-agent.service"
    else
      warn "$a: no $a-agent.service; restart the agent yourself"
    fi
  done
fi

# ---------------------------------------------------------------- smoke
say "smoke: each agent's token against memory, recall, swarm"
# port:tool:args -- read-only tools that authenticate the caller.
SMOKE_CALLS=(
  "$MEMORY_PORT:slot_list:{\"limit\":1}"
  "$RECALL_PORT:recent:{\"scope\":\"30-decisions\",\"limit\":1}"
  "$SWARM_PORT:stats:{}"
)
failed=0
for a in "${AGENTS[@]}"; do
  token="$(read_conf "$(agent_val "$a" SECRETS_DIR)/channel.conf" GBRAIN_BEARER)"
  for call in "${SMOKE_CALLS[@]}"; do
    port="${call%%:*}" rest="${call#*:}"
    port=$((port + SMOKE_PORT_OFFSET))
    tool="${rest%%:*}" args="${rest#*:}"
    # Token on stdin, never in argv.
    if why="$(printf '%s\n' "$token" \
        | python3 "$KIT_DIR/server/fleet/mcp-smoke.py" "http://127.0.0.1:$port/mcp" "$tool" "$args")"; then
      say "  $a -> :$port $tool ok"
    else
      warn "  $a -> :$port $tool FAILED: ${why:-no reply}"
      failed=1
    fi
  done
  unset token
done
[ "$failed" = "0" ] || die "smoke failed; see: journalctl -u 'gbrain-*' -n 50
  (\"unknown bearer token\" after the brain was reinstalled: re-run with --rotate-tokens)"

echo
echo "== Done. Team: ${AGENTS[*]} (coordinator: $COORDINATOR)"
echo "  brain:    $GBRAIN_DIR (services: systemctl status 'gbrain-*')"
echo "  backups:  $BACKUP_DIR, nightly at $(printf '%02d:%02d' "$BACKUP_HOUR" "$BACKUP_MINUTE")"
echo "  try it:   ask ${AGENTS[0]} in Telegram to pass a small task to ${AGENTS[1]:-another agent} over the swarm"
