#!/usr/bin/env bash
# install-fleet.sh -- turn the agents made by install-server.sh into one team.
#
# Result: the shared brain (G-Brain: memory, recall, swarm) runs on this server;
# every agent under BASE_DIR gets its own brain token (in its channel.conf,
# mode 600), the three brain MCP servers in its .mcp.json and a team block in
# core/rules.md; the swarm worker learns how to reach each agent's webhook;
# the brain is backed up nightly (pg_dump + vault tar, 14 days).
#
# An agent whose .mcp.json points its brain entries at another server (a shared
# brain elsewhere) keeps that wiring and its key: no local token, no rewrite.
# If every agent is like that, no local brain is installed at all. Wiring the
# kit cannot place (a ${VAR} host, a stdio entry without a URL, local and remote
# entries together, a remote wiring with a gap) stops the run; so does a local
# agent that still carries signs of a remote brain an earlier run rewired
# (GBRAIN_TOKEN in channel.conf, a .mcp.json backup pointing elsewhere).
# Every check runs before the first write: a refusal changes nothing.
#
# Team roster: the agents on this server, plus the lines of the roster file
# (~/.config/tg-agent/fleet-roster, one "name: one-line role" per line, # for
# comments) for teammates on other servers. A role ending in "(coordinator)"
# names the coordinator. With an agent on a remote brain the roster file is
# required and the coordinator must be named (flag or roster) and listed there.
#
# Run it after all agents are installed, as the same user. Re-running is safe:
# it picks up new agents, keeps existing tokens (--rotate-tokens re-issues
# them) and rewrites the team block in place. Flags:
#   --coordinator NAME     agent that routes cross-domain work (asked if unset)
#   --roster FILE          roster file instead of ~/.config/tg-agent/fleet-roster
#   --use-existing-brain   accept a brain this script did not install
#                          (its tokens for the same agent names get rotated)
#   --replace-remote-brain move agents wired to a remote shared brain (or with
#                          wiring the kit cannot place) onto the local one; they
#                          lose access to the shared memory. Recorded in fleet.conf
#   --rotate-tokens        re-issue every local-brain agent's token
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

ROSTER_FILE="$FLEET_CONF_DIR/fleet-roster"
ROSTER_EXPLICIT=0
COORDINATOR="${TG_FLEET_COORDINATOR:-}"
ADOPT_BRAIN=0
USE_EXISTING=0
REPLACE_REMOTE=0
ROTATE=0
DO_RESTART=1
while [ "$#" -gt 0 ]; do
  case "$1" in
    --coordinator) [ "$#" -ge 2 ] || { echo "--coordinator needs a name" >&2; exit 2; }
                   COORDINATOR="$2"; shift ;;
    --roster) [ "$#" -ge 2 ] || { echo "--roster needs a file" >&2; exit 2; }
              ROSTER_FILE="$2"; ROSTER_EXPLICIT=1; shift ;;
    --use-existing-brain) USE_EXISTING=1 ;;
    --replace-remote-brain) REPLACE_REMOTE=1 ;;
    --rotate-tokens) ROTATE=1 ;;
    --no-restart) DO_RESTART=0 ;;
    -h|--help) sed -n '2,38p' "$0"; exit 0 ;;
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

# ================================================================ plan
# Nothing until the "apply" mark writes a file, issues a token or restarts a
# service: every refusal leaves the server exactly as it was.

# brain_wiring FILE: the verdict of server/fleet/brain-wiring.py (see there).
brain_wiring() { python3 "$KIT_DIR/server/fleet/brain-wiring.py" "$1"; }

# Agents a past --replace-remote-brain put on the local brain on purpose.
ACKED=" $(read_conf "$FLEET_CONF" FLEET_LOCAL_BRAIN) "
LOCAL_AGENTS=()
REMOTE_AGENTS=()
MOVED=()
declare -A REMOTE_WIRING=()
for a in "${AGENTS[@]}"; do
  mcp="$(agent_val "$a" PLUGIN_DIR)/.mcp.json"
  wiring="$(brain_wiring "$mcp")" || die "agent '$a': cannot read $mcp"
  IFS=$'\t' read -r status detail _ _ _ _ _ _ extras <<<"$wiring"
  case "$status" in
    local)
      LOCAL_AGENTS+=("$a")
      [ "$extras" = "-" ] \
        || warn "$a: brain entries outside the kit's names ($extras) stay in .mcp.json as they are"
      ;;
    remote)
      if [ "$REPLACE_REMOTE" = "1" ]; then
        warn "$a: replacing the remote shared brain ($detail) with the local one (--replace-remote-brain)"
        [ "$extras" = "-" ] \
          || warn "$a: entries $extras still point at the remote brain; remove them from .mcp.json by hand"
        LOCAL_AGENTS+=("$a")
        MOVED+=("$a")
      else
        say "$a: stays on the remote shared brain ($detail); its brain wiring and key are left as they are"
        REMOTE_AGENTS+=("$a")
        REMOTE_WIRING[$a]="$wiring"
      fi
      ;;
    unknown|mixed)
      if [ "$REPLACE_REMOTE" = "1" ]; then
        warn "$a: $status brain wiring ($detail); --replace-remote-brain puts gbrain-memory,"
        warn "  gbrain-recall and gbrain-swarm on the local brain; other brain entries stay as they are"
        LOCAL_AGENTS+=("$a")
        MOVED+=("$a")
      else
        die "agent '$a': $status brain wiring in $mcp: $detail.
  The kit will not guess which brain this agent belongs to. Fix .mcp.json by hand
  (memory, recall and swarm on one server, each key as 'Bearer \${VAR}' with VAR set in
  channel.conf) and re-run, or move the agent onto this server's brain with
  --replace-remote-brain (it loses the shared memory)."
      fi
      ;;
    *) die "agent '$a': cannot classify the brain wiring in $mcp" ;;
  esac
done

# Signs of a remote brain an earlier run of this script rewired to 127.0.0.1:
# the remote key is still in channel.conf, or a .mcp.json backup points away.
for a in "${LOCAL_AGENTS[@]}"; do
  [[ "$ACKED" == *" $a "* ]] && continue
  plugin_dir="$(agent_val "$a" PLUGIN_DIR)"
  signs=""
  if [ -n "$(read_conf "$(agent_val "$a" SECRETS_DIR)/channel.conf" GBRAIN_TOKEN)" ] \
     && ! grep -qF '${GBRAIN_TOKEN}' "$plugin_dir/.mcp.json"; then
    signs+=$'\n'"    GBRAIN_TOKEN is set in its channel.conf, but .mcp.json does not use it"
  fi
  for backup in "$plugin_dir"/.mcp.json?*; do
    [ -f "$backup" ] || continue
    case "$(brain_wiring "$backup" 2>/dev/null | cut -f1)" in
      remote|mixed) signs+=$'\n'"    $backup points at a remote brain" ;;
    esac
  done
  [ -n "$signs" ] || continue
  if [ "$REPLACE_REMOTE" = "1" ]; then
    warn "$a: signs of a remote brain, kept on the local one (--replace-remote-brain):$signs"
    MOVED+=("$a")
    continue
  fi
  die "agent '$a' looks like it was on a remote shared brain that an earlier run rewired:$signs
  Nothing was changed. To put it back on the remote brain, copy the gbrain-* entries
  from that backup into $plugin_dir/.mcp.json (keys as 'Bearer \${GBRAIN_TOKEN}'),
  then re-run. If it belongs on this server's brain, re-run with --replace-remote-brain."
done

# A remote agent with a GBRAIN_BEARER its wiring does not use: a dead local key.
for a in "${REMOTE_AGENTS[@]}"; do
  IFS=$'\t' read -r _ _ _ mem_var _ rec_var _ sw_var _ <<<"${REMOTE_WIRING[$a]}"
  channel="$(agent_val "$a" SECRETS_DIR)/channel.conf"
  if [ -n "$(read_conf "$channel" GBRAIN_BEARER)" ] \
     && [[ " $mem_var $rec_var $sw_var " != *" GBRAIN_BEARER "* ]]; then
    warn "$a: stale GBRAIN_BEARER in $channel (a local brain key its remote wiring does not use)."
    warn "  Kept. To drop it: back up channel.conf, then delete that one line by hand."
  fi
done

# Roster: the roster file's teammates (other servers included) in file order,
# then local agents it does not list. A role from the file wins; otherwise a
# local agent's role comes from the first line of its CLAUDE.md.
TEAM=()
declare -A ROLE=()
declare -A IN_ROSTER=()
ROSTER_COORD=""
coord_re='^(.*[^[:space:]])?[[:space:]]*[(]coordinator[)]$'
if [ -f "$ROSTER_FILE" ]; then
  n=0
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(#.*)?$ ]] && continue
    [[ "$line" =~ ^[[:space:]]*([a-z][a-z0-9-]{1,30})[[:space:]]*(:[[:space:]]*(.*))?$ ]] \
      || die "bad fleet-roster line $n in $ROSTER_FILE (expected 'name: one-line role')"
    name="${BASH_REMATCH[1]}" role="${BASH_REMATCH[3]}"
    role="${role%"${role##*[![:space:]]}"}"
    if [[ "$role" =~ $coord_re ]]; then
      [ -z "$ROSTER_COORD" ] \
        || die "more than one coordinator in $ROSTER_FILE ($ROSTER_COORD, $name): mark one line"
      ROSTER_COORD="$name"
      role="${BASH_REMATCH[1]}"
    fi
    [ -z "${ROLE[$name]+x}" ] || die "agent '$name' listed twice in $ROSTER_FILE"
    TEAM+=("$name")
    ROLE[$name]="$role"
    IN_ROSTER[$name]=1
  done < "$ROSTER_FILE"
  say "roster file: $ROSTER_FILE"
elif [ "$ROSTER_EXPLICIT" = "1" ]; then
  die "roster file $ROSTER_FILE not found"
elif [ "${#REMOTE_AGENTS[@]}" -gt 0 ]; then
  die "no team roster ($ROSTER_FILE), but ${REMOTE_AGENTS[*]} is on a remote shared brain.
  The team lives on that brain; this server only knows its own agents. Create the file
  with one line per teammate on other servers, 'name: one-line role', and end the
  coordinator's line with (coordinator), for example:
    lead: Code and infrastructure (coordinator)
  Then re-run (or pass another file with --roster FILE)."
fi
for a in "${AGENTS[@]}"; do
  if [ -z "${ROLE[$a]+x}" ]; then
    TEAM+=("$a")
    ROLE[$a]=""
  fi
  if [ -z "${ROLE[$a]}" ]; then
    first="$(head -n1 "$BASE_DIR/$a/.claude/CLAUDE.md" 2>/dev/null || true)"
    case "$first" in "# $a — "*) ROLE[$a]="${first#"# $a — "}" ;; esac
  fi
done
[ "${#TEAM[@]}" -ge 2 ] || warn "the team is just ${TEAM[0]}: the swarm has nobody to talk to;
  teammates on other servers go into $ROSTER_FILE"

# Coordinator: flag/env, then the roster's (coordinator) line. Without a remote
# brain in play, then fleet.conf, then ask (default: first agent). With one, a
# coordinator remembered from another team layout is not trusted: name it.
prev_coord="$(read_conf "$FLEET_CONF" FLEET_COORDINATOR)"
if [ -n "$COORDINATOR" ] && [ -n "$ROSTER_COORD" ] && [ "$COORDINATOR" != "$ROSTER_COORD" ]; then
  warn "coordinator '$COORDINATOR' (flag) overrides '$ROSTER_COORD' marked in $ROSTER_FILE"
fi
COORDINATOR="${COORDINATOR:-$ROSTER_COORD}"
if [ -z "$COORDINATOR" ] && [ "${#REMOTE_AGENTS[@]}" -gt 0 ]; then
  if [ "$NONINTERACTIVE" != "1" ]; then
    read -r -p "Coordinator (a teammate listed in $ROSTER_FILE): " COORDINATOR || true
  fi
  [ -n "$COORDINATOR" ] || die "name the coordinator: ${REMOTE_AGENTS[*]} is on a remote shared brain,
  so the one remembered in fleet.conf is not used. Pass --coordinator NAME, or end the
  coordinator's line in $ROSTER_FILE with (coordinator)."
elif [ -z "$COORDINATOR" ]; then
  def="${prev_coord:-${AGENTS[0]}}"
  if [ "$NONINTERACTIVE" != "1" ]; then
    read -r -p "Coordinator agent (${TEAM[*]}) [$def]: " COORDINATOR || true
  fi
  COORDINATOR="${COORDINATOR:-$def}"
fi
if [ "${#REMOTE_AGENTS[@]}" -gt 0 ]; then
  [ -n "${IN_ROSTER[$COORDINATOR]+x}" ] || die "coordinator '$COORDINATOR' is not in the roster $ROSTER_FILE.
  With an agent on a remote shared brain the coordinator is a teammate listed there,
  the one that coordinates on that brain. Add its line or name one that is listed."
else
  [ -n "${ROLE[$COORDINATOR]+x}" ] || die "coordinator '$COORDINATOR' is not one of: ${TEAM[*]}
  (a teammate on another server goes into $ROSTER_FILE as 'name: role')"
fi
coord_local=0
for a in "${LOCAL_AGENTS[@]}"; do [ "$a" = "$COORDINATOR" ] && coord_local=1; done
if [ "${#LOCAL_AGENTS[@]}" -gt 0 ] && [ "$coord_local" = "0" ]; then
  warn "coordinator '$COORDINATOR' is not on this server's brain: the local swarm"
  warn "cannot deliver escalations from ${LOCAL_AGENTS[*]} to it"
fi

# Every refusal happens before the first token is issued: issuing revokes the
# agent's previous brain token.
if [ "${#LOCAL_AGENTS[@]}" -gt 0 ] && as_root test -d "$DROPIN_DIR"; then
  foreign="$(as_root find "$DROPIN_DIR" -maxdepth 1 -type f ! -name "$(basename "$DROPIN_FILE")" -printf '%f ')"
  [ -z "$foreign" ] || die "$DROPIN_DIR has drop-ins this kit did not write ($foreign).
  They may set AGENT_GATEWAYS too; merge them by hand or move them away, then re-run."
fi

# The local brain: keep, adopt, install, or none at all.
brain_present() { as_brain_user test -x "$BRAIN_PY" && as_brain_user test -f "$ISSUE_TOKEN"; }

BRAIN_ACTION=none
if [ "${#LOCAL_AGENTS[@]}" -eq 0 ]; then
  BRAIN_ACTION=none
elif brain_present; then
  if as_root test -f "$MARKER"; then
    BRAIN_ACTION=keep
  elif [ "$USE_EXISTING" = "1" ]; then
    BRAIN_ACTION=adopt
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
  BRAIN_ACTION=install
fi

# ================================================================ apply
# ---------------------------------------------------------------- brain
case "$BRAIN_ACTION" in
  none)
    say "every agent is on a remote shared brain: skipping the local brain, tokens, swarm worker and backup"
    # Pieces of a local brain an earlier run set up: reported, never deleted.
    leftovers=()
    for f in "$CRON_DIR/tg-agent-gbrain-backup" "$FLEET_ENV" "$DROPIN_FILE"; do
      as_root test -e "$f" && leftovers+=("$f")
    done
    if [ "${#leftovers[@]}" -gt 0 ]; then
      warn "left over from a local brain on this server, unused now that every agent is remote:"
      for f in "${leftovers[@]}"; do warn "  $f"; done
      warn "The kit does not delete them. To clean up, back them up first, then remove each by hand:"
      warn "  sudo mkdir -p /root/tg-agent-leftovers"
      warn "  sudo cp -a FILE /root/tg-agent-leftovers/ && sudo rm FILE"
      warn "  then: sudo systemctl daemon-reload (the local brain in $GBRAIN_DIR, if any, keeps running)"
    fi
    ;;
  keep) say "brain already installed by this kit at $GBRAIN_DIR" ;;
  adopt)
    warn "using a brain this kit did not install ($GBRAIN_DIR);"
    warn "tokens for agents named ${LOCAL_AGENTS[*]} will be re-issued there"
    ROTATE=1
    ADOPT_BRAIN=1
    ;;
  install)
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
    ;;
esac

# ---------------------------------------------------------------- tokens
# Only agents on this server's brain: a remote agent keeps its own key.
for a in "${LOCAL_AGENTS[@]}"; do
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
STAMP="$(date +%Y%m%d_%H%M%S)"
roster=""
for a in "${TEAM[@]}"; do
  line="- **$a** — ${ROLE[$a]:-agent}"
  [ "$a" = "$COORDINATOR" ] && line+=" (coordinator)"
  roster+="$line"$'\n'
done
roster="${roster%$'\n'}"

for a in "${AGENTS[@]}"; do
  plugin_dir="$(agent_val "$a" PLUGIN_DIR)"
  ws="$(agent_val "$a" AGENT_WS)"
  what="core/rules.md"
  if [ -z "${REMOTE_WIRING[$a]+x}" ]; then
  what=".mcp.json, settings.local.json, core/rules.md"
  mkdir -p "$plugin_dir/.claude"
  python3 - "$plugin_dir" "$MEMORY_PORT" "$RECALL_PORT" "$SWARM_PORT" "$STAMP" <<'PY'
import json
import pathlib
import shutil
import sys

plugin_dir = pathlib.Path(sys.argv[1])
ports = {"gbrain-memory": sys.argv[2], "gbrain-recall": sys.argv[3], "gbrain-swarm": sys.argv[4]}
stamp = sys.argv[5]

mcp_path = plugin_dir / ".mcp.json"
old = mcp_path.read_text()
mcp = json.loads(old)
servers = mcp.setdefault("mcpServers", {})
for name, port in ports.items():
    # ${GBRAIN_BEARER} is expanded by Claude Code from the pane env (channel.conf).
    servers[name] = {
        "type": "http",
        "url": f"http://127.0.0.1:{port}/mcp",
        "headers": {"Authorization": "Bearer ${GBRAIN_BEARER}"},
    }
new = json.dumps(mcp, indent=2) + "\n"
if new != old:
    # The old wiring stays recoverable (and tells a later run what it was).
    backup = plugin_dir / f".mcp.json.bak_fleet_{stamp}"
    n = 1
    while backup.exists():
        backup = plugin_dir / f".mcp.json.bak_fleet_{stamp}_{n}"
        n += 1
    shutil.copy2(mcp_path, backup)
    mcp_path.write_text(new)

local_path = plugin_dir / ".claude" / "settings.local.json"
local = json.loads(local_path.read_text()) if local_path.exists() else {}
enabled = local.setdefault("enabledMcpjsonServers", [])
for name in ["dashi-channel", *ports]:
    if name not in enabled:
        enabled.append(name)
local_path.write_text(json.dumps(local, indent=2) + "\n")
PY
  fi

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
  say "$a: $what updated"
done

# ---------------------------------------------------------------- fleet.conf
mkdir -p "$FLEET_CONF_DIR"
chmod 700 "$FLEET_CONF_DIR"
[ -f "$FLEET_CONF" ] || { : > "$FLEET_CONF"; chmod 600 "$FLEET_CONF"; }
set_conf_line "$FLEET_CONF" FLEET_AGENTS "${AGENTS[*]}"
set_conf_line "$FLEET_CONF" FLEET_COORDINATOR "$COORDINATOR"
if [ "${#MOVED[@]}" -gt 0 ]; then
  # Agents put on the local brain on purpose: later runs skip the remote-sign check.
  acked_now=""
  for a in "${AGENTS[@]}"; do
    in_moved=0
    for m in "${MOVED[@]}"; do [ "$m" = "$a" ] && in_moved=1; done
    if [ "$in_moved" = "1" ] || [[ "$ACKED" == *" $a "* ]]; then
      acked_now+="${acked_now:+ }$a"
    fi
  done
  set_conf_line "$FLEET_CONF" FLEET_LOCAL_BRAIN "$acked_now"
fi

# The swarm worker and the backup belong to the local brain.
if [ "${#LOCAL_AGENTS[@]}" -gt 0 ]; then
# ---------------------------------------------------------------- swarm worker
say "pointing the swarm worker at the agents' webhooks"

env_tmp="$(mktemp "$FLEET_CONF_DIR/.fleet-env.XXXXXX")"
chmod 600 "$env_tmp"
gateways="{" auth="{" sep=""
for a in "${LOCAL_AGENTS[@]}"; do
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
  for a in "${LOCAL_AGENTS[@]}"; do
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
fi

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
say "smoke: each agent's key against memory, recall, swarm"
# Only the core tool set is served (GBRAIN_TOOLS=core) and none of these calls
# writes a note: supersede_decision checks the key and the write scope before it
# finds that the old decision is missing, so that error counts as a pass.
SMOKE_TOOLS=(supersede_decision recent ack)
SMOKE_ARGS=(
  '{"old_path":"30-decisions/tg-agent-fleet-smoke-missing.md","new_title":"smoke","new_body":"smoke","reason":"smoke"}'
  '{"scope":"30-decisions","limit":1}'
  '{"task_id":"tg-agent-fleet-smoke-noop"}'
)
# A key without write scope on 30-decisions fails the scope check first: still
# proof that the brain knows the key, reported as such.
SMOKE_EXPECT=("Original decision not found|cannot write to 30-decisions" "" "")

# Prints "host:port" as wired and the URL to dial; tests reroute the host and
# shift the port onto a fake brain.
smoke_target() {
  python3 - "$1" "$SMOKE_PORT_OFFSET" "${TG_FLEET_TEST_SMOKE_HOST:-}" <<'PY'
import sys
from urllib.parse import urlsplit, urlunsplit

url, offset, host = urlsplit(sys.argv[1]), int(sys.argv[2]), sys.argv[3]
port = url.port or (443 if url.scheme == "https" else 80)
netloc = f"{host or url.hostname}:{port + offset}"
print(f"{url.hostname}:{port}", urlunsplit(url._replace(netloc=netloc)))
PY
}

failed=0
for a in "${AGENTS[@]}"; do
  channel="$(agent_val "$a" SECRETS_DIR)/channel.conf"
  if [ -n "${REMOTE_WIRING[$a]+x}" ]; then
    IFS=$'\t' read -r _ _ mem_url mem_var rec_url rec_var sw_url sw_var _ <<<"${REMOTE_WIRING[$a]}"
    urls=("$mem_url" "$rec_url" "$sw_url")
    vars=("$mem_var" "$rec_var" "$sw_var")
  else
    urls=("http://127.0.0.1:$MEMORY_PORT/mcp" "http://127.0.0.1:$RECALL_PORT/mcp"
          "http://127.0.0.1:$SWARM_PORT/mcp")
    vars=(GBRAIN_BEARER GBRAIN_BEARER GBRAIN_BEARER)
  fi
  passed=0
  for i in 0 1 2; do
    tool="${SMOKE_TOOLS[$i]}" url="${urls[$i]}" var="${vars[$i]}"
    case "$var" in
      -) warn "  $a: no 'Bearer \${VAR}' key for $tool in .mcp.json (the brain would refuse the agent)"
         failed=1; continue ;;
      !) warn "  $a: literal key for $tool in .mcp.json; put it in channel.conf and write 'Bearer \${VAR}'"
         failed=1; continue ;;
    esac
    token="$(read_conf "$channel" "$var")"
    if [ -z "$token" ]; then
      warn "  $a: $var is not set in channel.conf"
      failed=1
      continue
    fi
    if ! wired="$(smoke_target "$url" 2>/dev/null)" || [ -z "$wired" ]; then
      warn "  $a: cannot read the brain URL for $tool in .mcp.json"
      failed=1
      unset token
      continue
    fi
    read -r shown target <<<"$wired"
    # Token on stdin, never in argv.
    if why="$(printf '%s\n' "$token" | python3 "$KIT_DIR/server/fleet/mcp-smoke.py" \
        "$target" "$tool" "${SMOKE_ARGS[$i]}" "${SMOKE_EXPECT[$i]}")"; then
      case "$why" in
        *"cannot write to 30-decisions"*)
          say "  $a -> $shown $tool ok (key accepted; no write scope on 30-decisions)" ;;
        *) say "  $a -> $shown $tool ok" ;;
      esac
      passed=$((passed + 1))
    else
      warn "  $a -> $shown $tool FAILED: ${why:-no reply}"
      failed=1
    fi
    unset token
  done
  if [ "$passed" = "0" ]; then
    warn "  $a: not one brain check passed"
    failed=1
  fi
done
[ "$failed" = "0" ] || die "smoke failed. Local brain: journalctl -u 'gbrain-*' -n 50
  (\"unknown bearer token\" after the brain was reinstalled: re-run with --rotate-tokens).
  Remote shared brain: check that server and the agent's key in channel.conf."

echo
echo "== Done. Team: ${TEAM[*]} (coordinator: $COORDINATOR)"
if [ "${#LOCAL_AGENTS[@]}" -gt 0 ]; then
  echo "  brain:    $GBRAIN_DIR for ${LOCAL_AGENTS[*]} (services: systemctl status 'gbrain-*')"
  echo "  backups:  $BACKUP_DIR, nightly at $(printf '%02d:%02d' "$BACKUP_HOUR" "$BACKUP_MINUTE")"
fi
[ "${#REMOTE_AGENTS[@]}" -eq 0 ] || echo "  remote shared brain: ${REMOTE_AGENTS[*]} (left as wired)"
echo "  try it:   ask ${TEAM[0]} in Telegram to pass a small task to ${TEAM[1]:-another agent} over the swarm"
