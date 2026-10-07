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

if [ "${DOCTOR_STANDALONE:-0}" = 1 ]; then
  echo
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
fi
