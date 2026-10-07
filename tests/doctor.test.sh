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
  check() {
    local desc="$1"
    shift
    if "$@" > /dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
  }
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
KIT_HOME=/opt/agent-doctor/kit
CLONE_CMD="sudo git clone https://github.com/ussti/tg-agent-init $KIT_HOME"
RUN_CMD="sudo bash $KIT_HOME/install-doctor.sh"
PULL_CMD="sudo git -C $KIT_HOME pull"
# install-doctor.sh refuses a kit that is not owned by the user running it or that is
# group/other-writable, so the end-to-end runs use a go-w copy, never the checkout.
copy_kit() {  # copy_kit <dst>: the files install-doctor.sh reads, without group/other write
  mkdir -p "$1/server" "$1/scripts" "$1/kit"
  cp "$KIT/install-doctor.sh" "$1/"
  cp -R "$SD" "$1/server/"
  cp "$KIT/scripts/render-template.py" "$1/scripts/"
  cp "$KIT/kit/versions.env" "$1/kit/"
  chmod -R go-w "$1"
}
chmod 755 "$DOC"
DK="$DOC/kit"
copy_kit "$DK"

# --- templates
render_env() {  # render_env <out>: env.template with every key set
  DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" DOCTOR_BOT_USERNAME=doctor_test_bot \
    DOCTOR_OWNER_ID="$OWNER" DOCTOR_MAX_COST=5 DOCTOR_MAX_COST_USER=50 \
    python3 "$KIT/scripts/render-template.py" "$SD/env.template" "$1"
}
# I2: no dev mode, explicit caps. ENVIRONMENT is not "production": the package overwrites
# the caps with its production preset there (src/config/loader.py:80-101).
env_hardened() {  # env_hardened <env file>
  grep -qx 'ENVIRONMENT=doctor' "$1" && grep -qx 'DEBUG=false' "$1" \
    && grep -qx 'DEVELOPMENT_MODE=false' "$1" && grep -qx 'CLAUDE_MAX_COST_PER_REQUEST=5' "$1" \
    && grep -qx 'CLAUDE_MAX_COST_PER_USER=50' "$1" && grep -qx 'RATE_LIMIT_REQUESTS=100' "$1"
}
env_rendered() {
  render_env "$DOC/env" && ! grep -q '{{' "$DOC/env" && env_hardened "$DOC/env" \
    && grep -qx "ALLOWED_USERS=$OWNER" "$DOC/env" \
    && grep -qx 'SANDBOX_ENABLED=false' "$DOC/env" \
    && grep -qx 'APPROVED_DIRECTORY=/home/doctor' "$DOC/env" \
    && grep -qx 'CLAUDE_CLI_PATH=/home/doctor/.local/bin/claude' "$DOC/env" \
    && grep -qx 'CLAUDE_MAX_COST_PER_REQUEST=5' "$DOC/env" \
    && grep -qx 'AGENTIC_MODE=true' "$DOC/env"
}
check "doctor: env template renders every key" env_rendered
missing_key_refused() {  # every key but the token set; env -u: an exported one cannot leak in
  local out
  rm -f -- "$DOC/env-missing"
  ! out="$(env -u DOCTOR_BOT_TOKEN DOCTOR_BOT_USERNAME=x DOCTOR_OWNER_ID=1 \
    DOCTOR_MAX_COST=5 DOCTOR_MAX_COST_USER=50 \
    python3 "$KIT/scripts/render-template.py" "$SD/env.template" "$DOC/env-missing" 2>&1)" \
    && grep -q 'unset DOCTOR_BOT_TOKEN' <<< "$out" && test ! -e "$DOC/env-missing"
}
check "doctor: env template refuses a missing key, names it, writes nothing" \
  missing_key_refused
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
  check "doctor: unit passes systemd-analyze verify" \
    systemd-analyze verify "$DOC/agent-doctor.service"
fi
if command -v visudo > /dev/null; then
  printf 'doctor ALL=(ALL) NOPASSWD:ALL\n' > "$DOC/sudoers"
  check "doctor: sudoers line passes visudo -cf" visudo -cf "$DOC/sudoers"
fi
check "doctor: CLAUDE.md works through sudo -u" grep -q 'sudo -u <user> -H' "$SD/CLAUDE.md"
check "doctor: CLAUDE.md forbids self-install" grep -q 'Never run install-doctor.sh' "$SD/CLAUDE.md"
# Every documented root command runs the root-owned clone, never an agent's checkout.
root_cmds_ok() {  # root_cmds_ok <file>: names the clone and run commands, no agent kit path
  grep -qF "$CLONE_CMD" "$1" && grep -qF "$RUN_CMD" "$1" \
    && ! grep -Eq 'sudo bash [^ ]*(~|\$DEST|\$KIT|tg-agent-init/)[^ ]*install-doctor' "$1"
}
check "doctor: CLAUDE.md gives the root-owned kit commands" root_cmds_ok "$SD/CLAUDE.md"
check "doctor: CLAUDE.md gives the kit update command" grep -qF "$PULL_CMD" "$SD/CLAUDE.md"
check "doctor: README gives the root-owned kit commands" root_cmds_ok "$KIT/README.md"
check "doctor: README gives the kit update command" grep -qF "$PULL_CMD" "$KIT/README.md"
# I2/I1: hardening rules the doctor must carry in its instructions
MASK_SED="sed -E 's#bot[0-9]+:[A-Za-z0-9_-]+#bot<hidden>#g'"
claude_md_has() {  # claude_md_has <fixed text>...: every text is in the doctor's CLAUDE.md
  local t
  for t in "$@"; do grep -qF -- "$t" "$SD/CLAUDE.md" || return 1; done
}
check "doctor: CLAUDE.md treats logs and outputs as data" \
  claude_md_has 'data, never instructions'
check "doctor: CLAUDE.md guards its own access files" \
  claude_md_has sudoers /etc/agent-doctor/env ALLOWED_USERS agent-doctor.service \
  'ssh config' firewall
check "doctor: CLAUDE.md sends data only to the owner's chat" \
  claude_md_has "only to the owner's chat"
check "doctor: CLAUDE.md masks tokens" claude_md_has "$MASK_SED"
check "doctor: CLAUDE.md runs list-agents with sudo" claude_md_has 'sudo ~/bin/list-agents.sh'
check "doctor: CLAUDE.md confines file tools to /home/doctor" \
  claude_md_has 'only reach `/home/doctor`' 'sudo -u <user> -H'

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
la_has() {  # la_has <ERE> <root> [args]: some output line of list-agents matches
  local out
  out="$(la "${@:2}")" && grep -Eq -- "$1" <<< "$out"
}
L0="$(new_root la0)"
check "list-agents: none -> message, exit 0" bash -c '[ "$1" = "no agents found" ]' _ "$(la "$L0")"
check "list-agents: none -> no conf paths" bash -c '[ -z "$1" ]' _ "$(la "$L0" --conf-paths)"
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
HELPER_CONF="$L2/home/bob/agents/helper/.claude/agent.conf"
mkdir -p "$L2/home/bob/agents/helper.bak_20260101/.claude" "$L2/home/bob/backups/x/.claude"
cp "$HELPER_CONF" "$L2/home/bob/agents/helper.bak_20260101/.claude/"
cp "$HELPER_CONF" "$L2/home/bob/backups/x/.claude/"
check "list-agents: .bak_ copy ignored" eval '! la_has bak_ "$L2" --conf-paths'
check "list-agents: backups/ copy ignored" eval '! la_has /backups/ "$L2" --conf-paths'
check "list-agents: backup copies leave two agents" la2_ok
printf 'ghost-agent.service loaded active running Ghost\n' > "$L2/.fake/units"
check "list-agents: unit without agent.conf is shown" la_has '^ghost +\? +' "$L2"
touch "$L2/.fake/inactive"
check "list-agents: stopped unit shows its state" la_has '^main +alice +failed' "$L2"
# m8: an unknown argument is a usage error
la_bad_arg() {
  local rc=0
  la "$L2" --bogus > "$DOC/la-bad.out" 2>&1 || rc=$?
  [ "$rc" = 2 ] && grep -q '^usage: ' "$DOC/la-bad.out"
}
check "list-agents: unknown argument -> usage, exit 2" la_bad_arg
# m3: without root an unreadable home hides agents; say so instead of a silent "none"
if [ "$(id -u)" -ne 0 ]; then
  L3="$(new_root la3)"
  make_agent "$L3" carol main "$OWNER" 111111111
  chmod 000 "$L3/home/carol"
  la_note() {
    la "$L3" > "$DOC/la3.out" 2>&1 \
      && grep -q 'cannot read .*/home/carol.*run with sudo to see all agents' "$DOC/la3.out"
  }
  check "list-agents: unreadable home without root -> run-with-sudo note" la_note
  chmod 755 "$L3/home/carol"
fi

# --- install-doctor end to end (fake root, fake system tools, real visudo)
run_doctor() {  # run_doctor <root> <log> [VAR=value...]
  local r="$1" log="$2"
  shift 2
  env PATH="$FAKES:$PATH" TG_DOCTOR_ROOT="$r" TG_DOCTOR_DRY_RUN=1 \
    TG_DOCTOR_NONINTERACTIVE=1 TG_DOCTOR_STABLE_S=1 TG_DOCTOR_START_TIMEOUT_S=3 \
    TG_DOCTOR_OWNER_ID="$OWNER" "$@" \
    bash "${RUN_KIT:-$DK}/install-doctor.sh" < /dev/null > "$log" 2>&1
}
refused() {  # refused <root> <log> <expected text> [VAR=value...]
  local r="$1" log="$2" want="$3"
  shift 3
  ! run_doctor "$r" "$log" "$@" && grep -q -- "$want" "$log"
}
kit_refused() {  # kit_refused <kit> <root> <log>: refused before anything is touched
  local kit="$1" r="$2" log="$3"
  ! RUN_KIT="$kit" run_doctor "$r" "$log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && grep -q 'writable' "$log" && grep -qF "$CLONE_CMD" "$log" && grep -qF "$RUN_CMD" "$log" \
    && test ! -e "$r/etc/sudoers.d/agent-doctor" && test ! -e "$r/.fake/log"
}
tree_hash() {  # content and modes of a fake root, without the fakes' own state
  (cd "$1" && {
    find . -path ./.fake -prune -o -print0 | sort -z | xargs -0 stat -c '%a %n'
    find . -path ./.fake -prune -o -type f -print0 | sort -z | xargs -0 sha256sum
  }) | sha256sum
}
mode_is() { [ "$(stat -c %a "$2")" = "$1" ]; }
TAG="$(sed -n 's/^DOCTOR_BOT_TAG=//p' "$KIT/kit/versions.env" | head -1)"

E="$(new_root e2e)"
make_agent "$E" alice main "$OWNER" 111111111
check "doctor: first install" run_doctor "$E" "$DOC/e1.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
check "doctor: done line" grep -qx '== Doctor is up (@doctor_test_bot)' "$DOC/e1.log"
check "doctor: env file 640" mode_is 640 "$E/etc/agent-doctor/env"
check "doctor: env file has owner and no sandbox" bash -c \
  "grep -qx 'ALLOWED_USERS=$OWNER' '$E/etc/agent-doctor/env' \
   && grep -qx 'SANDBOX_ENABLED=false' '$E/etc/agent-doctor/env'"
check "doctor: env file has no dev mode and explicit caps" env_hardened "$E/etc/agent-doctor/env"
check "doctor: sudoers 440 with the exact line" bash -c \
  "[ \"\$(stat -c %a '$E/etc/sudoers.d/agent-doctor')\" = 440 ] \
   && [ \"\$(cat '$E/etc/sudoers.d/agent-doctor')\" = 'doctor ALL=(ALL) NOPASSWD:ALL' ]"
check "doctor: unit installed as is" cmp "$SD/agent-doctor.service.template" \
  "$E/etc/systemd/system/agent-doctor.service"
check "doctor: unit enabled" test -e "$E/.fake/enabled-agent-doctor.service"
check "doctor: CLAUDE.md and list-agents in place" bash -c \
  "cmp '$SD/CLAUDE.md' '$E/home/doctor/CLAUDE.md' \
   && [ \"\$(stat -c %a '$E/home/doctor/bin/list-agents.sh')\" = 755 ]"
check "doctor: pinned package installed" grep -qx \
  "git+https://github.com/RichardAtCT/claude-code-telegram@$TAG" "$E/.fake/uv-installs"
check "doctor: opt tree readable by others" bash -c \
  "[ -z \"\$(find '$E/opt/agent-doctor' ! -perm -o+r)\" ]"
check "doctor: claude installed for doctor" test -x "$E/home/doctor/.local/bin/claude"
check "doctor: greeting sent to the owner" grep -qx \
  'Я doctor, наладчик сервера. Пиши, если агент сломался' "$E/.fake/sent.txt"
token_only_in_env() {
  [ "$(grep -rlF "$DOCTOR_TOKEN" "$E" | grep -v '/.fake/')" = "$E/etc/agent-doctor/env" ] \
    && ! grep -qF "$DOCTOR_TOKEN" "$DOC/e1.log" "$E/.fake/log"
}
check "doctor: token only in the env file, never printed" token_only_in_env

H1="$(tree_hash "$E")"
check "doctor: second run keeps the bot without a token" run_doctor "$E" "$DOC/e2.log"
same_tree() { [ "$(tree_hash "$E")" = "$H1" ]; }
check "doctor: second run changes no file" same_tree
second_quiet() {
  [ "$(wc -l < "$E/.fake/uv-installs")" = 1 ] \
    && [ "$(grep -c 'systemctl restart' "$E/.fake/log")" = 1 ] \
    && [ "$(wc -l < "$E/.fake/sent.txt")" = 1 ]
}
check "doctor: second run: no reinstall, no restart, no second greeting" second_quiet
echo v0.0.1 > "$E/opt/agent-doctor/.installed-tag"
new_tag() {
  run_doctor "$E" "$DOC/e3.log" && [ "$(wc -l < "$E/.fake/uv-installs")" = 2 ] \
    && [ "$(grep -c 'systemctl restart' "$E/.fake/log")" = 2 ]
}
check "doctor: changed tag reinstalls and restarts" new_tag
# I5: caps the owner edited survive a re-run; an invalid cap falls back to the default
sed -i -e 's/^CLAUDE_MAX_COST_PER_REQUEST=.*/CLAUDE_MAX_COST_PER_REQUEST=7.5/' \
  -e 's/^CLAUDE_MAX_COST_PER_USER=.*/CLAUDE_MAX_COST_PER_USER=80/' "$E/etc/agent-doctor/env"
caps_kept() {
  run_doctor "$E" "$DOC/e4.log" \
    && grep -qx 'CLAUDE_MAX_COST_PER_REQUEST=7.5' "$E/etc/agent-doctor/env" \
    && grep -qx 'CLAUDE_MAX_COST_PER_USER=80' "$E/etc/agent-doctor/env" \
    && [ "$(grep -c 'systemctl restart' "$E/.fake/log")" = 2 ]
}
check "doctor: edited caps kept on re-run, no restart" caps_kept
sed -i -e 's/^CLAUDE_MAX_COST_PER_REQUEST=.*/CLAUDE_MAX_COST_PER_REQUEST=0/' \
  -e 's/^CLAUDE_MAX_COST_PER_USER=.*/CLAUDE_MAX_COST_PER_USER=lots/' "$E/etc/agent-doctor/env"
caps_reset() {
  run_doctor "$E" "$DOC/e5.log" && env_hardened "$E/etc/agent-doctor/env"
}
check "doctor: invalid caps reset to the defaults" caps_reset

Z="$(new_root none)"
check "doctor: no agents -> stop, points at install-server" \
  refused "$Z" "$DOC/z.log" "install-server.sh" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
D="$(new_root dup)"
make_agent "$D" alice main "$OWNER" 222222222
check "doctor: agent's token refused" \
  refused "$D" "$DOC/d.log" "agent's bot" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
check "doctor: refused token leaves no env file" test ! -e "$D/etc/agent-doctor/env"
G="$(new_root getme)"
make_agent "$G" alice main "$OWNER" 111111111
touch "$G/.fake/getme-fail"
check "doctor: token Telegram rejects -> stop" \
  refused "$G" "$DOC/g.log" "did not accept" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
check "doctor: malformed token -> stop" \
  refused "$G" "$DOC/g2.log" "does not look like" TG_DOCTOR_BOT_TOKEN="123:short"
M="$(new_root owners)"
make_agent "$M" alice main 111 111111111
make_agent "$M" bob helper 222 333333333
check "doctor: no TG_DOCTOR_OWNER_ID -> stop, agent.conf is not trusted" \
  refused "$M" "$DOC/m.log" "TG_DOCTOR_OWNER_ID" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
  TG_DOCTOR_OWNER_ID=
check "doctor: single agent owner is not a fallback either" \
  refused "$E" "$DOC/m1.log" "TG_DOCTOR_OWNER_ID" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
  TG_DOCTOR_OWNER_ID=
two_owners_ok() {
  run_doctor "$M" "$DOC/m2.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" TG_DOCTOR_OWNER_ID=222 \
    && grep -qx 'ALLOWED_USERS=222' "$M/etc/agent-doctor/env"
}
check "doctor: two owners with TG_DOCTOR_OWNER_ID" two_owners_ok
N="$(new_root login)"
make_agent "$N" alice main "$OWNER" 111111111
touch "$N/.fake/login-fail"
check "doctor: claude not logged in -> stop with the login command" \
  refused "$N" "$DOC/n.log" "su - doctor -c claude" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
# the unit is enabled only when the install finished, so doctor-hint keeps reminding
check "doctor: login not done -> unit not enabled" \
  test ! -e "$N/.fake/enabled-agent-doctor.service"
U="$(new_root unit)"
make_agent "$U" alice main "$OWNER" 111111111
touch "$U/.fake/inactive"
check "doctor: unit not up -> journal printed, stop" \
  refused "$U" "$DOC/u.log" "fake journal line" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
# I1: the package logs every Bot API URL (token inside) at INFO; the dump must mask it
journal_masked() {
  grep -qF 'api.telegram.org/bot<hidden>/getUpdates' "$DOC/u.log" \
    && ! grep -qF "$DOCTOR_TOKEN" "$DOC/u.log" && ! grep -qF "${DOCTOR_TOKEN#*:}" "$DOC/u.log"
}
check "doctor: journal dump masks the bot token" journal_masked
W="$(new_root greet)"
make_agent "$W" alice main "$OWNER" 111111111
touch "$W/.fake/send-fail"
greet_warns() {
  run_doctor "$W" "$DOC/w.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && grep -q 'press Start' "$DOC/w.log" && test ! -e "$W/opt/agent-doctor/.greeted"
}
check "doctor: greeting failure is only a warning" greet_warns
# fix round 1: start job failure, ERR trap, bad username, env without username
S="$(new_root startfail)"
make_agent "$S" alice main "$OWNER" 111111111
touch "$S/.fake/fail-start" "$S/.fake/inactive"
start_fail_reports() {
  refused "$S" "$DOC/s.log" "fake journal line" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && grep -q 'sudo bash .*install-doctor.sh' "$DOC/s.log"
}
check "doctor: failed start job -> journal and retry command" start_fail_reports
X="$(new_root unexpected)"
make_agent "$X" alice main "$OWNER" 111111111
touch "$X/.fake/useradd-fail"
unexpected_reports() {
  refused "$X" "$DOC/x.log" "ERROR: step failed at line" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && grep -q 'sudo bash .*install-doctor.sh' "$DOC/x.log"
}
check "doctor: unexpected failure -> ERROR line and retry command" unexpected_reports
B="$(new_root badname)"
make_agent "$B" alice main "$OWNER" 111111111
touch "$B/.fake/bad-username"
check "doctor: bad bot username -> token treated as invalid" \
  refused "$B" "$DOC/b.log" "did not accept" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
V="$(new_root nousername)"
make_agent "$V" alice main "$OWNER" 111111111
run_doctor "$V" "$DOC/v0.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" || true
grep -v '^TELEGRAM_BOT_USERNAME=' "$V/etc/agent-doctor/env" > "$DOC/v.env"
cp "$DOC/v.env" "$V/etc/agent-doctor/env"
check "doctor: env without bot username is not kept -> asks for a token" \
  refused "$V" "$DOC/v.log" "TG_DOCTOR_BOT_TOKEN"
sudoers_moved() {  # m13: written to the dotted temp name, then moved; never written in place
  test ! -e "$E/etc/sudoers.d/.agent-doctor.tmp" \
    && grep -qxF "mv -f $E/etc/sudoers.d/.agent-doctor.tmp $E/etc/sudoers.d/agent-doctor" \
      "$E/.fake/log"
}
check "doctor: sudoers moved into place from the temp file, temp file gone" sudoers_moved
# m12: a sudoers line visudo -cf rejects stops the install before anything is installed
VF="$(new_root visudo-cf)"
make_agent "$VF" alice main "$OWNER" 111111111
touch "$VF/.fake/visudo-cf-fail"
visudo_cf_stops() {
  refused "$VF" "$DOC/vf.log" "visudo -cf" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && test ! -e "$VF/etc/sudoers.d/agent-doctor" \
    && test ! -e "$VF/etc/sudoers.d/.agent-doctor.tmp" \
    && test ! -e "$VF/etc/agent-doctor/env"
}
check "doctor: visudo -cf fails -> sudoers not installed, install stops" visudo_cf_stops
run_io() {  # run_io <root> <log> <stdin line>...: interactive install, answers on stdin
  local r="$1" log="$2"
  shift 2
  printf '%s\n' "$@" \
    | env PATH="$FAKES:$PATH" TG_DOCTOR_ROOT="$r" TG_DOCTOR_DRY_RUN=1 \
      TG_DOCTOR_STABLE_S=1 TG_DOCTOR_START_TIMEOUT_S=3 bash "$DK/install-doctor.sh" \
      > "$log" 2>&1
}
# R5: the owner ID is typed twice; the two must match
IO="$(new_root interactive)"
make_agent "$IO" alice main "$OWNER" 111111111
interactive_owner_refused() {  # token, Start, then: empty, two mismatched pairs
  ! run_io "$IO" "$DOC/io.log" "$DOCTOR_TOKEN" '' '' 111 222 333 444 \
    && grep -q 'must be digits' "$DOC/io.log" && grep -q 'differ' "$DOC/io.log" \
    && grep -q 'no valid owner ID' "$DOC/io.log" && test ! -e "$IO/etc/agent-doctor/env"
}
check "doctor: interactive owner: empty and mismatched answers are refused" \
  interactive_owner_refused
IU="$(new_root unknown-owner)"
make_agent "$IU" alice main "$OWNER" 111111111
unknown_owner_accepted() {  # an ID no agent knows: a warning, then accepted
  run_io "$IU" "$DOC/iu.log" "$DOCTOR_TOKEN" '' 999 999 \
    && grep -q 'WARN: .*999.*matches no agent' "$DOC/iu.log" \
    && grep -qx 'ALLOWED_USERS=999' "$IU/etc/agent-doctor/env"
}
check "doctor: interactive owner: unknown ID warns and is accepted" unknown_owner_accepted
# KEEP_BOT: the kept token is checked again with getMe
KB="$(new_root keepbot)"
make_agent "$KB" alice main "$OWNER" 111111111
run_doctor "$KB" "$DOC/kb0.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" || true
touch "$KB/.fake/getme-fail"
check "doctor: kept token Telegram rejects -> asks for a new token" \
  refused "$KB" "$DOC/kb.log" "no longer" TG_DOCTOR_BOT_TOKEN=
# m12: interactive "n" to keeping the bot -> a new token, Start, owner typed twice
KN="$(new_root keep-no)"
make_agent "$KN" alice main "$OWNER" 111111111
run_doctor "$KN" "$DOC/kn0.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" || true
keep_no_replaces() {
  run_io "$KN" "$DOC/kn.log" n "444444444:$DUMMY_TAIL" '' "$OWNER" "$OWNER" \
    && grep -q '^TELEGRAM_BOT_TOKEN=444444444:' "$KN/etc/agent-doctor/env" \
    && grep -qx "ALLOWED_USERS=$OWNER" "$KN/etc/agent-doctor/env"
}
check "doctor: interactive keep=n -> new token and owner written" keep_no_replaces
check "doctor: git is a required tool" \
  grep -Eq '^for tool in .*\bgit\b.*; do' "$DK/install-doctor.sh"
# a doctor user the installer did not create is used only after an explicit yes
AU="$(new_root adopt)"
make_agent "$AU" alice main "$OWNER" 111111111
touch "$AU/.fake/user-doctor"
mkdir -p "$AU/home/doctor"
adopt_refused() {
  refused "$AU" "$DOC/au.log" "TG_DOCTOR_ADOPT_USER=1" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && test ! -e "$AU/etc/sudoers.d/agent-doctor"
}
check "doctor: foreign doctor user, non-interactive -> stop without sudo" adopt_refused
adopt_ok() {
  run_doctor "$AU" "$DOC/au2.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" TG_DOCTOR_ADOPT_USER=1 \
    && test -e "$AU/opt/agent-doctor/.doctor-user" && ! grep -q useradd "$AU/.fake/log"
}
check "doctor: foreign doctor user adopted with TG_DOCTOR_ADOPT_USER=1" adopt_ok
check "doctor: adopted user needs no flag next time" \
  run_doctor "$AU" "$DOC/au3.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
check "doctor: user created by the installer is marked" test -e "$E/opt/agent-doctor/.doctor-user"
AI="$(new_root adopt-io)"
make_agent "$AI" alice main "$OWNER" 111111111
touch "$AI/.fake/user-doctor"
adopt_io_no() {
  ! run_io "$AI" "$DOC/ai.log" n && grep -q 'not created by this installer' "$DOC/ai.log" \
    && test ! -e "$AI/etc/sudoers.d/agent-doctor"
}
check "doctor: foreign doctor user, interactive no -> stop" adopt_io_no
# full visudo -c after the move; a failure puts the previous state back
VC="$(new_root visudo-c)"
make_agent "$VC" alice main "$OWNER" 111111111
touch "$VC/.fake/visudo-c-fail"
visudo_c_new() {
  refused "$VC" "$DOC/vc.log" "visudo -c" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && test ! -e "$VC/etc/sudoers.d/agent-doctor"
}
check "doctor: visudo -c fails, no previous file -> new file removed" visudo_c_new
mkdir -p "$VC/etc/sudoers.d"
rm -f -- "$VC/etc/sudoers.d/agent-doctor"
printf '# previous\n' > "$VC/etc/sudoers.d/agent-doctor"
visudo_c_restored() {
  refused "$VC" "$DOC/vc2.log" "visudo -c" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && [ "$(cat "$VC/etc/sudoers.d/agent-doctor")" = '# previous' ]
}
check "doctor: visudo -c fails -> previous sudoers restored" visudo_c_restored
# m9: an agent whose token cannot be read is named, not skipped silently
T9="$(new_root token-unchecked)"
make_agent "$T9" alice main "$OWNER" 111111111
make_agent "$T9" bob helper "$OWNER" 333333333
rm -f -- "$T9/home/bob/.config/tg-agent/helper/channel.conf"
token_unchecked_warns() {
  run_doctor "$T9" "$DOC/t9.log" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN" \
    && grep -q "WARN: .*agent helper" "$DOC/t9.log"
}
check "doctor: agent token not checkable -> warning names the agent" token_unchecked_warns
O="$(new_root os)"
make_agent "$O" alice main "$OWNER" 111111111
printf 'ID=fedora\n' > "$O/etc/os-release"
check "doctor: not Ubuntu/Debian -> stop" \
  refused "$O" "$DOC/o.log" "Ubuntu or Debian" TG_DOCTOR_BOT_TOKEN="$DOCTOR_TOKEN"
if [ "$(id -u)" -ne 0 ]; then
  check "doctor: not root -> stop" refused "$O" "$DOC/root.log" "run as root" TG_DOCTOR_DRY_RUN=0
fi
# C1: root never runs a kit someone else can write (owner = the user running it)
KG="$(new_root kitgw)"
make_agent "$KG" alice main "$OWNER" 111111111
copy_kit "$DOC/kit-gw"
chmod g+w "$DOC/kit-gw/server/doctor/list-agents.sh"
check "doctor: group-writable file in the kit -> refused, clone command shown" \
  kit_refused "$DOC/kit-gw" "$KG" "$DOC/kgw.log"
copy_kit "$DOC/kit-ow"
chmod o+w "$DOC/kit-ow/scripts"
check "doctor: other-writable dir in the kit -> refused" \
  kit_refused "$DOC/kit-ow" "$KG" "$DOC/kow.log"
mkdir -p "$DOC/anc"
copy_kit "$DOC/anc/kit"
chmod 775 "$DOC/anc"
check "doctor: group-writable parent of the kit -> refused" \
  kit_refused "$DOC/anc/kit" "$KG" "$DOC/kanc.log"

# --- doctor-hint (end of install-server.sh)
HN="$(new_root hint)"
hint() {  # hint [args]: doctor-hint.sh output against the fake systemctl
  TG_DOCTOR_ROOT="$HN" PATH="$FAKES:$PATH" bash "$SD/doctor-hint.sh" "$@"
}
hint_has() {  # hint_has <exact line> [args]: the hint prints this line
  grep -qxF -- "$1" <<< "$(hint "${@:2}")"
}
hint_shown() {
  hint_has '== Agent is up. One step left: the doctor' \
    && hint_has "  $CLONE_CMD" && hint_has "  $RUN_CMD" \
    && ! grep -q '/srv/kit' <<< "$(hint /srv/kit)"
}
check "doctor-hint: no doctor -> clone and install from the root-owned kit" hint_shown
touch "$HN/.fake/enabled-agent-doctor.service"
check "doctor-hint: doctor enabled -> silent" bash -c '[ -z "$1" ]' _ "$(hint)"

if [ "${DOCTOR_STANDALONE:-0}" = 1 ]; then
  echo
  echo "$pass passed, $fail failed"
  [ "$fail" -eq 0 ]
fi
