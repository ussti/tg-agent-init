# shellcheck shell=bash
# Shared helpers for the tg-agent server scripts. Source, do not execute.
#
# Every script finds the agent through one non-secret file, agent.conf,
# written by install-server.sh into the agent workspace (<AGENT_HOME>/.claude).
# Scripts are installed into <AGENT_HOME>/.claude/bin, so the default is the
# parent of this directory; TG_AGENT_CONF overrides it (tests, cron, systemd).
# Secrets never live in agent.conf — only in files under $SECRETS_DIR.

TG_AGENT_BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# load_agent_conf: export every key of agent.conf into the environment.
load_agent_conf() {
  local conf="${TG_AGENT_CONF:-$TG_AGENT_BIN/../agent.conf}"
  if [ ! -f "$conf" ]; then
    echo "[tg-agent] FATAL: agent.conf not found at $conf" >&2
    return 1
  fi
  set -a
  # shellcheck disable=SC1090
  . "$conf"
  set +a
  export TG_AGENT_CONF="$conf"
}

# conf_value FILE KEY: print the value of KEY=... from a KEY=VALUE file without
# sourcing it (secrets files are read, never executed). Strips one layer of
# surrounding quotes. Prints nothing when the file or key is missing.
conf_value() {
  local file="$1" key="$2" line
  [ -r "$file" ] || return 0
  line="$(grep -m1 -E "^${key}=" "$file" 2>/dev/null || true)"
  line="${line#*=}"
  line="${line%\"}"; line="${line#\"}"
  line="${line%\'}"; line="${line#\'}"
  printf '%s' "$line"
}

# channel_conf / auth_conf: paths of the two secret files for this agent.
channel_conf() { printf '%s/channel.conf' "${SECRETS_DIR:?SECRETS_DIR unset}"; }
auth_conf()    { printf '%s/claude-auth.conf' "${SECRETS_DIR:?SECRETS_DIR unset}"; }
# keys_conf: optional skill keys written by agent-keys (may not exist).
keys_conf()    { printf '%s/keys.env' "${SECRETS_DIR:?SECRETS_DIR unset}"; }
