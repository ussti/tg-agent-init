#!/usr/bin/env bash
# doctor.test.sh -- offline tests of the server doctor: templates, list-agents,
# install-doctor end to end on fakes, doctor-hint. Sourced by run-tests.sh (uses its
# KIT, WORK, ok/bad/check); also runs alone: bash tests/doctor.test.sh
if ! declare -F check > /dev/null; then
  set -euo pipefail
  KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  WORK="$(mktemp -d)"
  trap 'rm -rf -- "$WORK"' EXIT
  pass=0
  fail=0
  ok() { pass=$((pass + 1)); echo "  ok   $*"; }
  bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
  check() { local desc="$1"; shift; if "$@" > /dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }
  DOCTOR_STANDALONE=1
fi

DOC="$WORK/doctor"
FAKES="$KIT/tests/fakes/doctor"
SD="$KIT/server/doctor"
mkdir -p "$DOC"
for f in "$FAKES"/*; do check "doctor: syntax $(basename "$f")" bash -n "$f"; done
# Bot-token shaped test values, built at run time (no literal token in the repo).
DUMMY_TAIL="$(printf 'x%.0s' $(seq 1 35))"
DOCTOR_TOKEN="222222222:$DUMMY_TAIL"
OWNER=123456789
export PATH="$PATH:/usr/sbin:/sbin"   # visudo, useradd live here; not on a user's PATH

# --- templates
render_env() {  # render_env <out>: env.template with every key set
  DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" DOCTOR_BOT_USERNAME=doctor_test_bot \
    DOCTOR_OWNER_ID="$OWNER" DOCTOR_MAX_COST=5 \
    python3 "$KIT/scripts/render-template.py" "$SD/env.template" "$1"
}
env_rendered() {
  render_env "$DOC/env" && ! grep -q '{{' "$DOC/env" \
    && grep -qx "ALLOWED_USERS=$OWNER" "$DOC/env" \
    && grep -qx 'SANDBOX_ENABLED=false' "$DOC/env" \
    && grep -qx 'APPROVED_DIRECTORY=/home/doctor' "$DOC/env" \
    && grep -qx 'CLAUDE_CLI_PATH=/home/doctor/.local/bin/claude' "$DOC/env" \
    && grep -qx 'CLAUDE_MAX_COST_PER_REQUEST=5' "$DOC/env" \
    && grep -qx 'AGENTIC_MODE=true' "$DOC/env"
}
check "doctor: env template renders every key" env_rendered
check "doctor: env template refuses a missing key" bash -c \
  "! DOCTOR_BOT_USERNAME=x DOCTOR_OWNER_ID=1 DOCTOR_MAX_COST=5 \
   python3 '$KIT/scripts/render-template.py' '$SD/env.template' '$DOC/env-missing'"
unit_ok() {
  grep -qx 'User=doctor' "$SD/agent-doctor.service.template" \
    && grep -qx 'Restart=always' "$SD/agent-doctor.service.template" \
    && grep -qx 'EnvironmentFile=/etc/agent-doctor/env' "$SD/agent-doctor.service.template" \
    && ! grep -q '{{' "$SD/agent-doctor.service.template"
}
check "doctor: unit has user, restart, env file" unit_ok
if command -v systemd-analyze > /dev/null; then
  # the real ExecStart does not exist here; verify a copy that points at /bin/true
  sed 's#^ExecStart=.*#ExecStart=/bin/true#' "$SD/agent-doctor.service.template" \
    > "$DOC/agent-doctor.service"
  check "doctor: unit passes systemd-analyze verify" systemd-analyze verify "$DOC/agent-doctor.service"
fi
if command -v visudo > /dev/null; then
  printf 'doctor ALL=(ALL) NOPASSWD:ALL\n' > "$DOC/sudoers"
  check "doctor: sudoers line passes visudo -cf" visudo -cf "$DOC/sudoers"
fi
check "doctor: CLAUDE.md works through sudo -u" grep -q 'sudo -u <user> -H' "$SD/CLAUDE.md"
check "doctor: CLAUDE.md forbids self-install" grep -q 'Never run install-doctor.sh' "$SD/CLAUDE.md"

# --- fixtures
new_root() {  # new_root <name>: fresh fake server root, prints its path
  local r="$DOC/$1"
  rm -rf -- "$r"
  mkdir -p "$r/etc" "$r/.fake"
  printf 'ID=ubuntu\nID_LIKE=debian\n' > "$r/etc/os-release"
  echo "$r"
}
make_agent() {  # make_agent <root> <user> <name> <owner> <bot_id>
  local r="$1" u="$2" n="$3" own="$4" id="$5"
  local ws="/home/$u/agents/$n/.claude" sec="/home/$u/.config/tg-agent/$n"
  mkdir -p "$r$ws" "$r$sec"
  cat > "$r$ws/agent.conf" <<EOF
AGENT_NAME="$n"
AGENT_HOME="/home/$u/agents/$n"
AGENT_WS="$ws"
SECRETS_DIR="$sec"
OWNER_CHAT_ID="$own"
LOG_DIR="$ws/logs"
EOF
  printf 'TELEGRAM_BOT_TOKEN="%s:%s"\n' "$id" "$DUMMY_TAIL" > "$r$sec/channel.conf"
}
la() {  # la <root> [args]: list-agents.sh against a fake root, fake systemctl first
  TG_DOCTOR_ROOT="$1" PATH="$FAKES:$PATH" bash "$SD/list-agents.sh" "${@:2}"
}

# --- list-agents
L0="$(new_root la0)"
check "list-agents: none -> message, exit 0" bash -c \
  "[ \"\$(TG_DOCTOR_ROOT='$L0' PATH='$FAKES:$PATH' bash '$SD/list-agents.sh')\" = 'no agents found' ]"
check "list-agents: none -> no conf paths" bash -c \
  "[ -z \"\$(TG_DOCTOR_ROOT='$L0' PATH='$FAKES:$PATH' bash '$SD/list-agents.sh' --conf-paths)\" ]"
L1="$(new_root la1)"
make_agent "$L1" alice main "$OWNER" 111111111
la1_ok() {
  local out
  out="$(la "$L1")"
  grep -Eq '^main +alice +active +active +/home/alice/agents/main/.claude$' <<< "$out"
}
check "list-agents: one agent with user, units, workspace" la1_ok
L2="$(new_root la2)"
make_agent "$L2" alice main "$OWNER" 111111111
make_agent "$L2" bob helper 555 333333333
la2_ok() {
  [ "$(la "$L2" --conf-paths | wc -l)" = 2 ] \
    && la "$L2" --conf-paths | grep -qx "$L2/home/bob/agents/helper/.claude/agent.conf" \
    && la "$L2" | grep -Eq '^helper +bob '
}
check "list-agents: two users" la2_ok
# Backup copies that the include pattern */.claude/agent.conf WOULD match; each must be skipped.
mkdir -p "$L2/home/bob/agents/helper.bak_20260101/.claude" "$L2/home/bob/backups/x/.claude"
cp "$L2/home/bob/agents/helper/.claude/agent.conf" "$L2/home/bob/agents/helper.bak_20260101/.claude/"
cp "$L2/home/bob/agents/helper/.claude/agent.conf" "$L2/home/bob/backups/x/.claude/"
check "list-agents: .bak_ copy ignored" bash -c \
  "! TG_DOCTOR_ROOT='$L2' PATH='$FAKES:$PATH' bash '$SD/list-agents.sh' --conf-paths | grep -q 'bak_'"
check "list-agents: backups/ copy ignored" bash -c \
  "! TG_DOCTOR_ROOT='$L2' PATH='$FAKES:$PATH' bash '$SD/list-agents.sh' --conf-paths | grep -q '/backups/'"
check "list-agents: backup copies leave two agents" la2_ok
printf 'ghost-agent.service loaded active running Ghost\n' > "$L2/.fake/units"
check "list-agents: unit without agent.conf is shown" bash -c \
  "TG_DOCTOR_ROOT='$L2' PATH='$FAKES:$PATH' bash '$SD/list-agents.sh' \
   | grep -Eq '^ghost +\\? +'"
touch "$L2/.fake/inactive"
check "list-agents: stopped unit shows its state" bash -c \
  "TG_DOCTOR_ROOT='$L2' PATH='$FAKES:$PATH' bash '$SD/list-agents.sh' | grep -Eq '^main +alice +failed'"

if [ "${DOCTOR_STANDALONE:-0}" = 1 ]; then
  echo
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
fi
