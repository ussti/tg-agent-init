#!/usr/bin/env bash
# list-agents.sh -- the agents on this server: name, Linux user, unit states, workspace.
# Read-only. Agents are found at run time (every agent.conf under /home), never from a
# list written at install, so an agent added later is seen too.
# Usage: list-agents.sh [--conf-paths]   (--conf-paths: only the agent.conf paths)
set -euo pipefail

R="${TG_DOCTOR_ROOT:-}"          # test root prefix; empty on a server
readonly MAX_DEPTH=6             # /home/<user>/agents/<name>/.claude/agent.conf is 5

# Value of KEY="value" (quotes and CR optional) from a conf file; never sourced.
conf_get() { sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\r\{0,1\}$/\1/p" "$1" | head -1; }

unit_state() {
  command -v systemctl > /dev/null || { echo "?"; return 0; }
  systemctl is-active "$1" 2> /dev/null || true
}

find_confs() {
  [ -d "$R/home" ] || return 0
  find "$R/home" -mindepth 3 -maxdepth "$MAX_DEPTH" -path '*/.claude/agent.conf' \
    -not -path '*.bak_*' -not -path '*/backups/*' 2> /dev/null | sort
}

mapfile -t confs < <(find_confs)

if [ "${1:-}" = "--conf-paths" ]; then
  [ "${#confs[@]}" -eq 0 ] || printf '%s\n' "${confs[@]}"
  exit 0
fi

rows=()
seen=" "
for c in "${confs[@]}"; do
  rel="${c#"$R"/home/}"
  user="${rel%%/*}"
  name="$(conf_get "$c" AGENT_NAME)"
  ws="$(conf_get "$c" AGENT_WS)"
  seen+="$name "
  rows+=("$(printf '%-16s %-12s %-10s %-10s %s' "$name" "$user" \
    "$(unit_state "$name-agent.service")" "$(unit_state "$name-ratewatch.service")" "$ws")")
done

if command -v systemctl > /dev/null; then
  while read -r unit _; do
    name="${unit%-agent.service}"
    case "$seen" in *" $name "*) continue ;; esac
    rows+=("$(printf '%-16s %-12s %-10s %-10s %s' "$name" "?" \
      "$(unit_state "$unit")" "$(unit_state "$name-ratewatch.service")" "(no agent.conf)")")
  done < <(systemctl list-units '*-agent.service' --all --no-legend --plain 2> /dev/null || true)
fi

if [ "${#rows[@]}" -eq 0 ]; then
  echo "no agents found"
  exit 0
fi
printf '%-16s %-12s %-10s %-10s %s\n' NAME USER AGENT RATEWATCH WORKSPACE
printf '%s\n' "${rows[@]}"
