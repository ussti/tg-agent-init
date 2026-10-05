#!/usr/bin/env bash
# run-tests.sh -- kit test suite. No network, no systemd, no real bot.
#
#   1. leak scan (entities from LEAK_ENTITIES_FILE if set, secrets, vendor tree)
#   2. syntax of every script
#   3. ratewatch unit tests
#   4. installer end-to-end into a throwaway HOME (getMe and bun install skipped)
#      and checks on what it produced
#   5. brain build: upstream public-gbrain-agentos + kit patches (worker tests run
#      when GBRAIN_TEST_PYTHON points at a python with the brain's deps)
#   6. install-fleet end-to-end: two agents, fake brain (token issuer + stateful
#      MCP servers), fake systemctl
#   7. with --with-plugin: build the patched plugin, bun install, typecheck, bun test
set -euo pipefail

KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WITH_PLUGIN=0
[ "${1:-}" = "--with-plugin" ] && WITH_PLUGIN=1

pass=0
fail=0
ok() { pass=$((pass + 1)); echo "  ok   $*"; }
bad() { fail=$((fail + 1)); echo "  FAIL $*"; }
check() { local desc="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi; }

WORK="$(mktemp -d)"
FAKE_BRAIN_PID=""
cleanup() {
  [ -z "$FAKE_BRAIN_PID" ] || kill "$FAKE_BRAIN_PID" 2>/dev/null || true
  # TESTS_KEEP_WORK=1 leaves the throwaway tree in place for debugging.
  if [ "${TESTS_KEEP_WORK:-0}" = 1 ]; then
    echo "work dir kept: $WORK"
  else
    find "$WORK" -mindepth 0 -delete 2>/dev/null || true
  fi
}
trap cleanup EXIT

echo "== 1. leak scan"
check "leak-scan clean" bash "$KIT/scripts/leak-scan.sh"

echo "== 2. syntax"
while IFS= read -r f; do
  check "bash -n ${f#"$KIT"/}" bash -n "$f"
done < <(find "$KIT/server" "$KIT/scripts" "$KIT/core/hooks" "$KIT/core/scripts" "$KIT/core/cron" \
           "$KIT/install-server.sh" "$KIT/install-fleet.sh" -name '*.sh' -type f | sort)
check "python syntax" python3 -m py_compile "$KIT/scripts/render-template.py" \
  "$KIT/server/hooks/silent-reply-check.py" "$KIT/server/fleet/mcp-smoke.py" \
  "$KIT/tests/fake-brain-mcp.py"
find "$KIT" -name __pycache__ -type d -exec find {} -delete \; 2>/dev/null || true

echo "== 3. ratewatch"
check "ratewatch tests" bash "$KIT/server/tests/ratewatch.test.sh"
check "agent-keys unit tests" env PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -s "$KIT/kit/tests" -p 'test_agent_keys.py'
check "agent-login unit tests" env PYTHONDONTWRITEBYTECODE=1 \
  python3 -m unittest discover -s "$KIT/kit/tests" -p 'test_agent_login.py'

echo "== 4. installer end-to-end"
# Fake claude: answers --version, logs every other call with its config dir, no network.
# FAKE_CLAUDE_FAIL=1 makes plugin commands fail (offline install).
mkdir -p "$WORK/claudebin"
cat > "$WORK/claudebin/claude" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "--version" ]; then echo "2.1.0 (Claude Code)"; exit 0; fi
echo "${CLAUDE_CONFIG_DIR:-} $*" >> "${FAKE_CLAUDE_LOG:-/dev/null}"
[ "${FAKE_CLAUDE_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
chmod +x "$WORK/claudebin/claude"
export PATH="$WORK/claudebin:$PATH"
export FAKE_CLAUDE_LOG="$WORK/claude.log"
: > "$FAKE_CLAUDE_LOG"
# Fake upstream tools: log every call, no network. FAKE_TOOLS_FAIL=1 makes them fail
# (offline). A fake `git clone` leaves a checkout with the last30days SKILL.md.
mkdir -p "$WORK/bin"
for tool in npm pipx agent-browser crawl4ai-setup; do
  cat > "$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "\${FAKE_TOOLS_LOG:-/dev/null}"
[ "\${FAKE_TOOLS_FAIL:-0}" = 1 ] && exit 1
exit 0
EOF
  chmod +x "$WORK/bin/$tool"
done
# Fake git: clone leaves a checkout with the last30days SKILL.md; checkout records the
# commit (FAKE_GIT_CHECKOUT_FAIL=1 makes it fail); rev-parse HEAD answers with it
# (FAKE_GIT_HEAD overrides the answer).
cat > "$WORK/bin/git" <<'EOF'
#!/usr/bin/env bash
echo "git $*" >> "${FAKE_TOOLS_LOG:-/dev/null}"
[ "${FAKE_TOOLS_FAIL:-0}" = 1 ] && exit 1
dir=""
if [ "$1" = -C ]; then dir="$2"; shift 2; fi
case "$1" in
  clone)
    d="${@: -1}"; mkdir -p "$d/.git" "$d/skills/last30days"
    printf -- '---\nname: last30days\ndescription: upstream. Use when testing.\n---\n' \
      > "$d/skills/last30days/SKILL.md" ;;
  checkout)
    [ "${FAKE_GIT_CHECKOUT_FAIL:-0}" = 1 ] && exit 1
    echo "$2" > "$dir/.git/PINNED" ;;
  rev-parse) echo "${FAKE_GIT_HEAD:-$(cat "$dir/.git/PINNED" 2>/dev/null || echo 0000000)}" ;;
esac
exit 0
EOF
chmod +x "$WORK/bin/git"
export PATH="$WORK/bin:$PATH"
export FAKE_TOOLS_LOG="$WORK/tools.log"
: > "$FAKE_TOOLS_LOG"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
OWNER=111222333
PORT=18089
DUMMY_TOKEN="987654321:$(printf 'x%.0s' $(seq 1 35))"
if HOME="$FAKE_HOME" TG_AGENT_NONINTERACTIVE=1 TG_AGENT_TEST_SKIP_GETME=1 TG_AGENT_TEST_SKIP_BUN=1 \
   TG_AGENT_BOT_TOKEN="$DUMMY_TOKEN" TG_AGENT_KEY_CAL=cal_test_123 TG_AGENT_GROQ_KEY=gsk_test_1 \
   AGENT_NAME=testbot OWNER_CHAT_ID="$OWNER" \
   OPERATOR_NAME="Test Owner" TIMEZONE=UTC WEBHOOK_PORT="$PORT" BASE_DIR="$FAKE_HOME/agents" \
   bash "$KIT/install-server.sh" --no-systemd --no-cron --no-live-test > "$WORK/install.log" 2>&1; then
  ok "installer exits 0"
else
  bad "installer exits 0 (log below)"
  tail -20 "$WORK/install.log"
fi

WS="$FAKE_HOME/agents/testbot/.claude"
SEC="$FAKE_HOME/.config/tg-agent/testbot"
PLUGIN="$WS/dashi-plugin/plugin"

check "no unfilled placeholders outside skills" \
  bash -c "! grep -rl '{{[A-Z_]*}}' '$WS' --exclude-dir=skills --exclude-dir=dashi-plugin"
check "agent.conf sources in bash" \
  bash -c "set -a; . '$WS/agent.conf'; [ \"\$OPERATOR_NAME\" = 'Test Owner' ] && [ \"\$OWNER_CHAT_ID\" = $OWNER ]"
check "secrets dir mode 700" test "$(stat -c %a "$SEC")" = 700
check "channel.conf mode 600" test "$(stat -c %a "$SEC/channel.conf")" = 600
check "keys.env mode 600 in the secrets dir" test "$(stat -c %a "$SEC/keys.env")" = 600
check "key from env stored once" test "$(grep -c '^CAL_API_KEY=' "$SEC/keys.env")" = 1
check "legacy TG_AGENT_GROQ_KEY lands in keys.env" grep -qx 'GROQ_API_KEY="gsk_test_1"' "$SEC/keys.env"
check "keys never in the workspace" bash -c \
  "! grep -rqE 'cal_test_123|gsk_test_1' '$FAKE_HOME/agents'"
check "keys not duplicated into channel.conf" bash -c \
  "! grep -qE 'cal_test_123|gsk_test_1|GROQ_API_KEY' '$SEC/channel.conf'"
check "keys.env sources in bash with the exact values" bash -c \
  "set -eu; . '$SEC/keys.env'; [ \"\$CAL_API_KEY\" = cal_test_123 ] && [ \"\$GROQ_API_KEY\" = gsk_test_1 ]"
check "groq key from env enables voice (config.json)" jq -e '.voice.provider == "groq"' \
  "$WS/state/telegram/config.json"
check "run-agent sources keys.env when present" grep -q 'KEYS_CONF' "$WS/bin/run-agent.sh"
check "lib.sh keys_conf points at keys.env" bash -c \
  "export SECRETS_DIR=/x; . '$WS/bin/lib.sh'; [ \"\$(keys_conf)\" = /x/keys.env ]"
check "bot token only in secrets dir" bash -c "! grep -rqF '$DUMMY_TOKEN' '$FAKE_HOME/agents'"
check "config.json valid, all IDs = owner" jq -e \
  "[.allowed_user_ids[], .allowed_chat_ids[], .owner_chat_ids[], .permission_relay.allowed_user_ids[]] \
   | all(. == $OWNER)" "$WS/state/telegram/config.json"
check "config.json bot_id from token" jq -e '.bot_id == 987654321' "$WS/state/telegram/config.json"
check "config.json webhook on port" jq -e ".webhook.enabled and .webhook.port == $PORT" \
  "$WS/state/telegram/config.json"
check "no upstream canary IDs in agent" bash -c \
  "! grep -rqE '164795011|8507713167' '$WS/state' '$WS/agent.conf' '$PLUGIN/.claude' '$SEC'"
check "plugin settings valid JSON" jq -e '.hooks.Stop' "$PLUGIN/.claude/settings.json"
check "every hook command points at an executable" python3 - "$PLUGIN/.claude/settings.json" <<'PY'
import json, os, sys
d = json.load(open(sys.argv[1]))
for groups in d["hooks"].values():
    for g in groups:
        for h in g["hooks"]:
            parts = [p for p in h["command"].split() if "=" not in p.split("/")[0]]
            runner = os.path.basename(parts[0]) in ("node", "bun")
            target = parts[1] if runner else parts[0]
            assert os.path.isfile(target), target
            assert runner or os.access(target, os.X_OK), target
PY
check "channel.conf access mode is one the plugin accepts" \
  grep -qx 'TELEGRAM_ACCESS_MODE="static"' "$SEC/channel.conf"
check "plugin schema still accepts access mode 'static'" \
  grep -qF ".enum(['static', 'pairing'])" "$KIT/vendor/dashi-plugin/plugin/src/config.ts"
check "eyes hook runs clean on a prompt without channel refs" bash -c \
  "out=\"\$(echo '{\"prompt\":\"hi\"}' | bun '$WS/hooks/eyes-on-turn-start.ts')\" && [ -z \"\$out\" ]"
check "eyes hook on turn start, read receipt on stop" python3 - "$PLUGIN/.claude/settings.json" "$SEC" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
env_file = f"TELEGRAM_CHANNEL_ENV_FILE={sys.argv[2]}/channel.conf"
def cmds(event):
    return [h["command"] for g in d["hooks"][event] for h in g["hooks"]]
eyes = [c for c in cmds("UserPromptSubmit") if "eyes-on-turn-start.ts" in c]
receipt = [c for c in cmds("Stop") if "read-receipt-hook.ts" in c]
assert len(eyes) == 1 and len(receipt) == 1, (eyes, receipt)
assert all(env_file in c for c in eyes + receipt)
PY
check "eyes hook import resolves to the plugin's read-receipt hook" bash -c \
  "cd '$WS/hooks' && test -f \"\$(grep -oE \"'[.][.]/[^']*read-receipt-hook[.]ts'\" \
   eyes-on-turn-start.ts | tr -d \"'\")\""
check "secrets deny rules: Read and Edit, no redundant Write" jq -e --arg s "$SEC" \
  '.permissions.deny | (index("Read(\($s)/**)") != null) and (index("Edit(\($s)/**)") != null)
   and (index("Write(\($s)/**)") == null)' "$PLUGIN/.claude/settings.json"
check "channel rule appended to rules.md" grep -q "## Telegram channel" "$WS/core/rules.md"
check "web-tool routing table in rules.md" bash -c \
  "grep -q '## Which internet tool' '$WS/core/rules.md' && \
   test \$(grep -cE '^\\| .* \\| (WebSearch|WebFetch|crawl4ai|agent-browser|perplexity-research|last30days)' '$WS/core/rules.md') -ge 6"
check "web-tool rule not duplicated on re-run" bash -c \
  "bash '$WS/kit/install-kit.sh' '$WS' '$FAKE_HOME/.claude-agent-testbot' >/dev/null 2>&1 \
   && test \$(grep -c '## Which internet tool' '$WS/core/rules.md') = 1"
check "default writing rules in rules.md" bash -c "grep -qx -- '- No emoji' '$WS/core/rules.md' && \
  grep -q '^- Living syntax: ' '$WS/core/rules.md' && \
  grep -q '^- Numbers and facts only with a source' '$WS/core/rules.md'"
check "no Russian typography rule for a non-Russian agent" \
  bash -c "! grep -q 'Russian typography' '$WS/core/rules.md'"
check "onboarding asks five questions: profile, links, goals, overrides, services" \
  python3 - "$WS" <<'PY'
import json, subprocess, sys
out = subprocess.run([sys.executable, f"{sys.argv[1]}/skills/onboard/onboard_slots.py", "list",
                      "--root", sys.argv[1]], capture_output=True, text=True, check=True).stdout
ids = [s["id"] for s in json.loads(out)]
assert ids == ["core/USER.md#profile", "core/USER.md#links", "core/USER.md#goals",
               "core/USER.md#overrides", "tools/TOOLS.md#services"], ids
PY
check "style defaults prefilled in USER.md" bash -c \
  "grep -q '^- One complete solution and the main trade-off' '$WS/core/USER.md' && \
   grep -q '^- Disagree with reasons' '$WS/core/USER.md'"
check "channel line filled by the installer" \
  grep -qx -- '- Telegram, text and voice -- primary' "$WS/core/USER.md"
check "keys folder filled by the installer" grep -qx -- "- Keys folder: $SEC" "$WS/tools/TOOLS.md"
check "kit copied into the workspace" test -f "$WS/kit/manifest.tsv"
check "every manifest skill is a symlink that resolves to SKILL.md" bash -c '
  while IFS=$'"'"'\t'"'"' read -r cat skill kind; do
    case "$cat" in ""|\#*) continue ;; esac
    [ -L "'"$WS"'/skills/$skill" ] || { echo "not a link: $skill"; exit 1; }
    [ "$kind" = upstream ] && continue
    [ -f "'"$WS"'/skills/$skill/SKILL.md" ] || { echo "no SKILL.md: $skill"; exit 1; }
  done < "'"$WS"'/kit/manifest.tsv"'
check "skill links are relative and stay inside the workspace" bash -c \
  "for l in '$WS'/skills/*; do [ -L \"\$l\" ] || continue; t=\$(readlink \"\$l\"); \
   case \"\$t\" in /*) exit 1 ;; esac; \
   case \"\$(readlink -f \"\$l\")\" in '$WS'/*) ;; *) exit 1 ;; esac; done"
check "kit has no template placeholders" bash -c "! grep -rn '{{[A-Z_]*}}' '$KIT/kit'"
check "kit skills carry no fleet paths" bash -c \
  "! grep -rnE 'claude-lab|maimozg|brandmozg|/home/edgelab|edgelab|shared/secrets|\\bKris\\b' '$KIT/kit/skills'"
check "system and dev skills linked" bash -c \
  "for s in skill-finder agent-introspection learnings senior-brainstorm; do \
   test -f '$WS/skills/'\$s/SKILL.md || exit 1; done"
check "learnings ENGINE resolves to the installed engine and its tests" bash -c \
  "AGENT_WS='$WS' bash -c \"\$(grep -m1 '^ENGINE=' '$WS/skills/learnings/SKILL.md'); \
   test -f \\\"\\\$ENGINE\\\" && test -f \\\"\\\${ENGINE%.mjs}.test.mjs\\\"\""
check "agent.conf defines AGENT_WS and run-agent exports it" bash -c \
  "grep -q '^AGENT_WS=' '$KIT/server/templates/agent.conf.template' && \
   grep -qE 'set -a; \. .\\\$TG_AGENT_CONF' '$KIT/server/bin/run-agent.sh'"
check "every kit skill description says when to use it" bash -c '
  for f in '"$KIT"'/kit/skills/*/*/SKILL.md; do
    awk "/^---/{n++} n==1" "$f" | grep -qiE "use (it )?when|use for|когда" || { echo "$f"; exit 1; }
  done'
check "perplexity falls back to WebSearch without a key" \
  grep -q "WebSearch" "$KIT/kit/skills/research/perplexity-research/SKILL.md"
check "cal tool reads CAL_API_KEY from the environment" \
  grep -q "CAL_API_KEY" "$KIT/kit/skills/office/cal/cal"
check "cal tool parses (no bytecode written)" \
  python3 -c 'import ast,sys; ast.parse(open(sys.argv[1]).read())' "$KIT/kit/skills/office/cal/cal"
check "research and office skills linked" bash -c \
  "for s in perplexity-research agent-browser crawl4ai last30days gws cal; do \
   test -f '$WS/skills/'\$s/SKILL.md || exit 1; done"
check "last30days UPSTREAM pins repo and commit" bash -c \
  "grep -qx 'repo=https://github.com/mvanhorn/last30days-skill' '$KIT/kit/skills/research/last30days/UPSTREAM' && \
   grep -qx 'commit=e93c8249d8ba073e8e88c388ed1f0fc403ffd86e' '$KIT/kit/skills/research/last30days/UPSTREAM'"
check "agent-browser config has the exact values" jq -e \
  '(.args | contains("--no-sandbox")) and .contentBoundaries == true
   and .maxOutput == 50000 and .idleTimeout == "15m"' "$KIT/kit/config/agent-browser.json"
check "onboard still a plain folder from core" test -f "$WS/skills/onboard/SKILL.md"
check "deep-research and the old gws wrapper are gone" bash -c \
  "[ ! -e '$WS/skills/deep-research' ] && ! grep -q GOOGLE_ACCESS_TOKEN -R '$WS/skills/' '$WS/kit/' 2>/dev/null"
check "re-running install-kit replaces a plain skill dir by a link and keeps the old one" bash -c "
  rm '$WS/skills/quick-reminders' && mkdir '$WS/skills/quick-reminders' \
  && bash '$WS/kit/install-kit.sh' '$WS' '$FAKE_HOME/.claude-agent-testbot' >/dev/null 2>&1 \
  && [ -L '$WS/skills/quick-reminders' ] && [ -f '$WS/skills/quick-reminders/SKILL.md' ] \
  && [ -n \"\$(ls -d '$WS'/skills-replaced/quick-reminders.* 2>/dev/null)\" ]"
check "agent-browser from npm, pinned, no root" \
  grep -q "npm install -g --prefix $FAKE_HOME/.local agent-browser@0.38.2" "$FAKE_TOOLS_LOG"
check "python tools from pipx, pinned" bash -c "grep -q 'pipx install --force gws-cli==1.5.0' '$FAKE_TOOLS_LOG' && \
  grep -q 'pipx install --force crawl4ai==0.9.4' '$FAKE_TOOLS_LOG' && grep -q 'pipx install --force yt-dlp' '$FAKE_TOOLS_LOG'"
check "last30days cloned at the pinned commit and linked" bash -c \
  "grep -q 'git clone https://github.com/mvanhorn/last30days-skill' '$FAKE_TOOLS_LOG' && \
   grep -q 'checkout e93c8249d8ba073e8e88c388ed1f0fc403ffd86e' '$FAKE_TOOLS_LOG' && \
   grep -q 'description: upstream' '$WS/skills/last30days/SKILL.md'"
check "browser setup steps run after install" bash -c \
  "grep -qx 'agent-browser install' '$FAKE_TOOLS_LOG' && grep -qx 'crawl4ai-setup ' '$FAKE_TOOLS_LOG'"
check "agent-browser safety config installed" \
  jq -e '.contentBoundaries == true and .maxOutput == 50000' "$FAKE_HOME/.agent-browser/config.json"
check "kit plugins installed into the agent's config dir" bash -c \
  "for p in superpowers@claude-plugins-official document-skills@anthropic-agent-skills \
   vercel@claude-plugins-official; do grep -q \"plugin install \$p\" '$FAKE_CLAUDE_LOG' || exit 1; done; \
   grep -q 'marketplace add anthropics/skills' '$FAKE_CLAUDE_LOG'"
check "rerun on the same workspace keeps last30days upstream, no second clone" bash -c "
  n=\$(grep -c 'git clone' '$FAKE_TOOLS_LOG') \
  && bash '$WS/kit/install-kit.sh' '$WS' '$FAKE_HOME/.claude-agent-testbot' >/dev/null 2>&1 \
  && [ \"\$(grep -c 'git clone' '$FAKE_TOOLS_LOG')\" = \"\$n\" ] \
  && grep -q ' fetch' '$FAKE_TOOLS_LOG' \
  && grep -q 'description: upstream' '$WS/skills/last30days/SKILL.md'"
check "existing agent-browser config is preserved on rerun" bash -c "
  echo '{\"marker\":1}' > '$FAKE_HOME/.agent-browser/config.json' \
  && bash '$WS/kit/install-kit.sh' '$WS' '$FAKE_HOME/.claude-agent-testbot' >/dev/null 2>&1 \
  && jq -e '.marker == 1 and (has(\"maxOutput\") | not)' '$FAKE_HOME/.agent-browser/config.json'"
check "unpinned last30days is never linked; a failed attempt does not block the rerun" bash -c "
  W='$WORK/pin'; mkdir -p \"\$W/ws\" \
  && FAKE_GIT_CHECKOUT_FAIL=1 HOME='$WORK/pin-home' bash '$KIT/kit/install-kit.sh' \"\$W/ws\" \"\$W/cfg\" >/dev/null 2>&1 \
  && grep -q 'Not installed yet' \"\$W/ws/skills/last30days/SKILL.md\" \
  && [ ! -e \"\$W/ws/kit/vendor/last30days\" ] \
  && HOME='$WORK/pin-home' bash '$KIT/kit/install-kit.sh' \"\$W/ws\" \"\$W/cfg\" >/dev/null 2>&1 \
  && grep -q 'description: upstream' \"\$W/ws/skills/last30days/SKILL.md\""
check "failed clone leaves no temp dir behind" bash -c "
  ! ls -d \"$WORK/pin/ws/kit/vendor\"/.last30days.* >/dev/null 2>&1"
check "checkout ok but HEAD is not the pin: stub stays, nothing linked to vendor" bash -c "
  W='$WORK/pin2'; mkdir -p \"\$W/ws\" \
  && FAKE_GIT_HEAD=deadbeef HOME='$WORK/pin2-home' bash '$KIT/kit/install-kit.sh' \"\$W/ws\" \"\$W/cfg\" >/dev/null 2>&1 \
  && grep -q 'Not installed yet' \"\$W/ws/skills/last30days/SKILL.md\" \
  && [ ! -e \"\$W/ws/kit/vendor/last30days\" ] \
  && ! ls -d \"\$W/ws/kit/vendor\"/.last30days.* >/dev/null 2>&1"
check "rerun over a vendor checkout that moved off the pin: link falls back to the stub" bash -c "
  W='$WORK/pin3'; mkdir -p \"\$W/ws\" \
  && HOME='$WORK/pin3-home' bash '$KIT/kit/install-kit.sh' \"\$W/ws\" \"\$W/cfg\" >/dev/null 2>&1 \
  && grep -q 'description: upstream' \"\$W/ws/skills/last30days/SKILL.md\" \
  && FAKE_GIT_HEAD=deadbeef HOME='$WORK/pin3-home' bash '$KIT/kit/install-kit.sh' \"\$W/ws\" \"\$W/cfg\" >\"\$W/log\" 2>&1 \
  && grep -q 'Not installed yet' \"\$W/ws/skills/last30days/SKILL.md\" \
  && grep -q 'WARN: last30days' \"\$W/log\""
check "superpowers installed into the agent's config dir" bash -c \
  "grep -qx '$FAKE_HOME/.claude-agent-testbot plugin marketplace add anthropics/claude-plugins-official' \
     '$FAKE_CLAUDE_LOG' && \
   grep -qx '$FAKE_HOME/.claude-agent-testbot plugin install superpowers@claude-plugins-official' \
     '$FAKE_CLAUDE_LOG'"
check "plugin sees workspace skills" test -f "$PLUGIN/.claude/skills/onboard/SKILL.md"
check "language rules installed" test -f "$FAKE_HOME/.claude-agent-testbot/rules/python.md"
check "plugin CLAUDE.md has raw HTML rule" grep -q "RAW HTML" "$PLUGIN/CLAUDE.md"
check "claude config: bypass prompt skipped" jq -e '.skipDangerousModePermissionPrompt' \
  "$FAKE_HOME/.claude-agent-testbot/settings.json"
check "claude config: plugin dir trusted" jq -e \
  --arg p "$PLUGIN" '.projects[$p].hasTrustDialogAccepted' "$FAKE_HOME/.claude-agent-testbot/.claude.json"
check "claude config: external CLAUDE.md imports pre-approved" jq -e --arg p "$PLUGIN" \
  '.projects[$p] | .hasClaudeMdExternalIncludesApproved and .hasClaudeMdExternalIncludesWarningShown' \
  "$FAKE_HOME/.claude-agent-testbot/.claude.json"
# snapshot.sh turns the agent home into a git repo within the first hour; Claude Code
# then keys trust on the repo root, so it must be pre-approved too.
check "claude config: agent home (snapshot repo root) trusted" jq -e --arg p "$(dirname "$WS")" \
  '.projects[$p] | .hasTrustDialogAccepted and .hasClaudeMdExternalIncludesApproved
     and .hasClaudeMdExternalIncludesWarningShown' \
  "$FAKE_HOME/.claude-agent-testbot/.claude.json"
check "server cron dry-run" bash "$KIT/server/cron/install-cron.sh" "$WS" --dry-run
check "core cron dry-run" bash "$KIT/core/cron/install-cron.sh" "$WS" --dry-run

# Fake crontab: `-l` fails like the real one for a user who has no crontab yet.
FAKE_BIN="$WORK/fakebin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/crontab" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -l) [ -f "$FAKE_CRONTAB_FILE" ] || { echo "no crontab for $(id -un)" >&2; exit 1; }
      cat "$FAKE_CRONTAB_FILE" ;;
  -) cat > "$FAKE_CRONTAB_FILE" ;;
esac
SH
chmod +x "$FAKE_BIN/crontab"
install_both_crons() {
  PATH="$FAKE_BIN:$PATH" FAKE_CRONTAB_FILE="$WORK/crontab.txt" \
    bash "$KIT/core/cron/install-cron.sh" "$WS" &&
  PATH="$FAKE_BIN:$PATH" FAKE_CRONTAB_FILE="$WORK/crontab.txt" \
    bash "$KIT/server/cron/install-cron.sh" "$WS"
}
check "cron installs into an empty crontab" install_both_crons
check "crontab got both blocks" test "$(grep -c ' START$' "$WORK/crontab.txt" 2>/dev/null)" = 2
cp "$WORK/crontab.txt" "$WORK/crontab.once" 2>/dev/null || true
check "cron re-install keeps one copy of each block" install_both_crons
check "crontab unchanged by re-install" diff -q "$WORK/crontab.once" "$WORK/crontab.txt"

for unit in agent ratewatch; do
  out="$WORK/$unit.service"
  if (set -a; . "$WS/agent.conf"; RUN_USER=u RUN_GROUP=g USER_HOME="$FAKE_HOME" \
      python3 "$KIT/scripts/render-template.py" "$KIT/server/systemd/$unit.service.template" "$out"); then
    check "$unit unit renders without placeholders" bash -c "! grep -q '{{' '$out'"
  else
    bad "$unit unit renders"
  fi
done
# The watchdog must come back on a plain start of the agent after a manual stop:
# Requires= alone leaves it dead, WantedBy=<agent>.service pulls it in again.
WATCH_UNIT="$WORK/ratewatch.service"
AGENT_UNIT_NAME="$(set -a; . "$WS/agent.conf"; echo "$AGENT_NAME-agent.service")"
check "ratewatch is wanted by the agent unit" grep -qx "WantedBy=$AGENT_UNIT_NAME" "$WATCH_UNIT"
check "ratewatch is not tied to multi-user.target" bash -c "! grep -q 'multi-user.target' '$WATCH_UNIT'"
check "ratewatch SIGTERM exit counts as success" grep -qx "SuccessExitStatus=143" "$WATCH_UNIT"
check "installer re-enables ratewatch (drops the old wants link)" \
  grep -qF 'systemctl reenable "$UNIT_WATCH"' "$KIT/install-server.sh"

# Interactive run with systemd on and no passwordless sudo: the installer must not
# stop at a sudo password prompt; it leaves the units on disk and prints the commands.
# Skipped as root: there the installer would really install the units.
if [ "$(id -u)" = "0" ]; then
  echo "  skip sudo fallback (running as root)"
else
  SUDO_HOME="$WORK/home-sudo"
  mkdir -p "$SUDO_HOME" "$WORK/sudobin"
  printf '%s\n' '#!/usr/bin/env bash' 'echo "$*" >> "$FAKE_SUDO_LOG"' 'exit 1' \
    > "$WORK/sudobin/sudo"
  chmod +x "$WORK/sudobin/sudo"
  : > "$WORK/sudo.log"
  if HOME="$SUDO_HOME" PATH="$WORK/sudobin:$PATH" FAKE_SUDO_LOG="$WORK/sudo.log" \
     TG_AGENT_TEST_SKIP_GETME=1 TG_AGENT_TEST_SKIP_BUN=1 TG_AGENT_BOT_TOKEN="$DUMMY_TOKEN" \
     AGENT_NAME=sudobot OWNER_CHAT_ID="$OWNER" TIMEZONE=UTC WEBHOOK_PORT=$((PORT + 2)) \
     BASE_DIR="$SUDO_HOME/agents" timeout 120 bash "$KIT/install-server.sh" --no-cron --no-live-test \
     < /dev/null > "$WORK/install-sudo.log" 2>&1; then
    ok "installer without passwordless sudo exits 0"
  else
    bad "installer without passwordless sudo exits 0 (log below)"
    tail -20 "$WORK/install-sudo.log"
  fi
  SUDO_UNITS="$SUDO_HOME/agents/sudobot/.claude/systemd"
  check "sudo only probed non-interactively" bash -c \
    "test -s '$WORK/sudo.log' && ! grep -qv '^-n ' '$WORK/sudo.log'"
  check "units kept in the workspace" test -f "$SUDO_UNITS/sudobot-agent.service" -a \
    -f "$SUDO_UNITS/sudobot-ratewatch.service"
  check "printed install command points at the kept units" \
    grep -qF "$SUDO_UNITS/sudobot-agent.service" "$WORK/install-sudo.log"
fi

echo "== 4c. keys: re-install, invalid and empty values"
# keys_install HOME LOG [VAR=value ...]: installer run into HOME with the extra env.
keys_install() {
  local home="$1" log="$2"; shift 2
  mkdir -p "$home"
  env "$@" HOME="$home" TG_AGENT_NONINTERACTIVE=1 TG_AGENT_TEST_SKIP_GETME=1 \
    TG_AGENT_TEST_SKIP_BUN=1 TG_AGENT_BOT_TOKEN="$DUMMY_TOKEN" AGENT_NAME=keysbot \
    OWNER_CHAT_ID="$OWNER" OPERATOR_NAME="Test Owner" TIMEZONE=UTC WEBHOOK_PORT=18091 \
    BASE_DIR="$home/agents" \
    bash "$KIT/install-server.sh" --no-systemd --no-cron --no-live-test > "$log" 2>&1
}
KH="$WORK/keyshome"
check "keys install: first run" keys_install "$KH" "$WORK/keys1.log" \
  TG_AGENT_KEY_CAL=cal_test_123 TG_AGENT_KEY_BRAVE=brave_test_1
check "keys install: re-run with a new brave value and an empty jina" keys_install "$KH" \
  "$WORK/keys2.log" TG_AGENT_KEY_BRAVE=brave_new_2 TG_AGENT_KEY_JINA=
KSEC="$KH/.config/tg-agent/keysbot"
check "re-install keeps the earlier key, one line per name" bash -c \
  "[ \"\$(grep -c '^CAL_API_KEY=' '$KSEC/keys.env')\" = 1 ] && grep -qx 'CAL_API_KEY=\"cal_test_123\"' '$KSEC/keys.env'"
check "re-install: env value wins per name, once" bash -c \
  "[ \"\$(grep -c '^BRAVE_API_KEY=' '$KSEC/keys.env')\" = 1 ] && grep -qx 'BRAVE_API_KEY=\"brave_new_2\"' '$KSEC/keys.env'"
check "re-install: keys.env mode 600" test "$(stat -c %a "$KSEC/keys.env")" = 600
check "empty TG_AGENT_KEY_* is skipped" bash -c "! grep -q '^JINA_API_KEY' '$KSEC/keys.env'"
BAD_VALUE='bad$value'
keys_install_fails() { ! keys_install "$@"; }
check "invalid TG_AGENT_KEY_* fails the installer" keys_install_fails "$WORK/badhome" \
  "$WORK/keysbad.log" "TG_AGENT_KEY_CAL=$BAD_VALUE"
check "invalid key value never printed" bash -c "! grep -qF 'bad\$value' '$WORK/keysbad.log' && \
  grep -q 'TG_AGENT_KEY_CAL' '$WORK/keysbad.log'"

echo "== 5. brain build"
GB_BUILD="$WORK/gbrain-build"
if bash "$KIT/scripts/build-gbrain.sh" "$GB_BUILD" > "$WORK/gbrain-build.log" 2>&1; then
  ok "build-gbrain applies every patch"
else
  bad "build-gbrain (log below)"
  tail -5 "$WORK/gbrain-build.log"
fi
check "worker no longer sends agentId" \
  bash -c "! grep -q '\"agentId\": to_agent' '$GB_BUILD/services/swarm_mcp/worker.py'"
check "no .orig/.rej left in the build" \
  bash -c "[ -z \"\$(find '$GB_BUILD' -name '*.orig' -o -name '*.rej')\" ]"
if [ -n "${GBRAIN_TEST_PYTHON:-}" ]; then
  (cd "$GB_BUILD" && PYTHONDONTWRITEBYTECODE=1 "$GBRAIN_TEST_PYTHON" -m pytest -q -p no:cacheprovider \
     tests/test_swarm_worker_hmac.py > "$WORK/gbrain-pytest.log" 2>&1) \
    && ok "upstream worker tests ($(grep -oE '[0-9]+ passed' "$WORK/gbrain-pytest.log"))" \
    || { bad "upstream worker tests"; tail -5 "$WORK/gbrain-pytest.log"; }
else
  echo "  skip upstream worker tests (set GBRAIN_TEST_PYTHON)"
fi

echo "== 6. install-fleet end-to-end"
# Second agent next to testbot from section 4.
if HOME="$FAKE_HOME" TG_AGENT_NONINTERACTIVE=1 TG_AGENT_TEST_SKIP_GETME=1 TG_AGENT_TEST_SKIP_BUN=1 FAKE_TOOLS_FAIL=1 \
   TG_AGENT_BOT_TOKEN="$DUMMY_TOKEN" AGENT_NAME=helper-two AGENT_ROLE="Research helper" \
   OWNER_CHAT_ID="$OWNER" OPERATOR_NAME="Test Owner" TIMEZONE=UTC WEBHOOK_PORT=18090 LANGUAGE=Russian \
   BASE_DIR="$FAKE_HOME/agents" FAKE_CLAUDE_FAIL=1 \
   bash "$KIT/install-server.sh" --no-systemd --no-cron --no-live-test > "$WORK/install2.log" 2>&1; then
  ok "second agent installed (npm, pipx, git and plugin installs all fail; the install still finishes)"
else
  bad "second agent installed"; tail -10 "$WORK/install2.log"
fi
check "offline: install still finishes, kit skills linked" \
  test -L "$FAKE_HOME/agents/helper-two/.claude/skills/gws"
check "offline: last30days keeps the stub" grep -q "Not installed yet" \
  "$FAKE_HOME/agents/helper-two/.claude/skills/last30days/SKILL.md"
# No npm/pipx at all: the rest of the kit must still install.
NT="$WORK/notools"; mkdir -p "$NT/bin" "$NT/ws"
for t in bash env sed cp rm find chmod mkdir ln mv date dirname ls cat mktemp rmdir; do
  ln -sf "$(command -v "$t")" "$NT/bin/$t"
done
check "no npm/pipx: other kit items still installed" bash -c \
  "HOME='$NT/home' PATH='$NT/bin' CLAUDE_BIN='$WORK/claudebin/claude' \
     bash '$KIT/kit/install-kit.sh' '$NT/ws' '$NT/cfg' >/dev/null 2>&1 \
   && test -f '$NT/ws/skills/gws/SKILL.md' && grep -q '$NT/cfg plugin install superpowers' '$FAKE_CLAUDE_LOG'"
check "offline plugin install only warns" grep -q "WARN: marketplace .* unreachable" "$WORK/install2.log"
check "Russian agent gets the typography rule inside Response format" python3 - \
  "$FAKE_HOME/agents/helper-two/.claude/core/rules.md" <<'PY'
import sys
text = open(sys.argv[1], encoding="utf-8").read()
section = text.split("## Response format", 1)[1].split("\n## ", 1)[0]
assert section.count("- Russian typography: ") == 1, section
PY
# A reinstall leftover must be ignored by agent discovery.
cp -a "$FAKE_HOME/agents/testbot" "$FAKE_HOME/agents/testbot.bak_20000101_000000"

FL="$WORK/fleet"
GB="$FL/gbrain"
FAKEBIN="$FL/bin"
mkdir -p "$GB/.venv/bin" "$GB/scripts" "$GB/services/swarm_mcp" "$FL/etc" "$FL/systemd" \
         "$FL/cron" "$FL/lib" "$FAKEBIN"
: > "$GB/scripts/issue-agent-token.py"
cp "$GB_BUILD/services/swarm_mcp/worker.py" "$GB/services/swarm_mcp/worker.py"
# Fake token issuer: one deterministic token per agent, every call logged.
cat > "$GB/.venv/bin/python" <<EOF
#!/usr/bin/env bash
name=""
while [ "\$#" -gt 0 ]; do [ "\$1" = "--agent" ] && name="\$2"; shift; done
echo "\$name" >> "$FL/issued.log"
echo "# issued agent=\$name sha=abc" >&2
token="\$(printf 'FLEETTESTTOKEN%sXXXXXXXXXXXXXXXXXXXXXXXXXXXX' "\${name//-/_}")"
echo "\$token" >> "$FL/valid-tokens"
echo "\$token"
EOF
cat > "$FAKEBIN/systemctl" <<EOF
#!/usr/bin/env bash
echo "\$*" >> "$FL/systemctl.log"
EOF
chmod +x "$GB/.venv/bin/python" "$FAKEBIN/systemctl"
# Fake brain MCP servers on 8766-8768 + offset; the smoke is pointed there.
SMOKE_OFFSET=$((20000 + RANDOM % 20000))
mkfifo "$FL/brain.ready"
python3 "$KIT/tests/fake-brain-mcp.py" "$FL/valid-tokens" $((8767 + SMOKE_OFFSET)) \
  $((8768 + SMOKE_OFFSET)) $((8766 + SMOKE_OFFSET)) > "$FL/brain.ready" 2> "$FL/brain.log" &
FAKE_BRAIN_PID=$!
read -r -t 10 _ < "$FL/brain.ready" || bad "fake brain started"
touch "$FL/systemd/testbot-agent.service"

# run_fleet LOG [flags]: install-fleet against the fakes; env extras via FLEET_ENV_EXTRA.
run_fleet() {
  local log="$1"; shift
  env HOME="$FAKE_HOME" PATH="$FAKEBIN:$PATH" TG_AGENT_NONINTERACTIVE=1 TG_FLEET_NO_SUDO=1 \
    BASE_DIR="$FAKE_HOME/agents" GBRAIN_DIR="$GB" GBRAIN_ETC_DIR="$FL/etc" \
    GBRAIN_LOG_DIR="$FL/log" SYSTEMD_DIR="$FL/systemd" CRON_DIR="$FL/cron" LIB_DIR="$FL/lib" \
    BACKUP_DIR="$FL/backups" TG_FLEET_TEST_SMOKE_PORT_OFFSET="$SMOKE_OFFSET" ${FLEET_ENV_EXTRA:-} \
    bash "$KIT/install-fleet.sh" "$@" > "$log" 2>&1
}
issued() { [ -f "$FL/issued.log" ] && wc -l < "$FL/issued.log" || echo 0; }
# refused LOG PATTERN [flags]: install-fleet must fail, and say why.
refused() { local log="$1" why="$2"; shift 2; ! run_fleet "$log" "$@" && grep -q "$why" "$log"; }

check "refuses a brain it did not install" refused "$FL/nomarker.log" "not installed by this kit" --coordinator testbot
check "nothing issued on refusal" test "$(issued)" = 0
echo "installed by test" > "$FL/etc/tg-agent-fleet.marker"

if run_fleet "$FL/run1.log" --coordinator testbot; then
  ok "install-fleet exits 0"
else
  bad "install-fleet exits 0 (log below)"; tail -15 "$FL/run1.log"
fi
SEC1="$FAKE_HOME/.config/tg-agent/testbot"
SEC2="$FAKE_HOME/.config/tg-agent/helper-two"
WS2="$FAKE_HOME/agents/helper-two/.claude"
PLUGIN2="$WS2/dashi-plugin/plugin"
check "backup copy not treated as an agent" bash -c "! grep -q 'bak_' '$FL/issued.log'"
check "one token per agent" test "$(issued)" = 2
check "token stored in channel.conf" grep -q '^GBRAIN_BEARER="FLEETTESTTOKENtestbot' "$SEC1/channel.conf"
check "token stored for dashed name" grep -q '^GBRAIN_BEARER="FLEETTESTTOKENhelper_two' "$SEC2/channel.conf"
check "channel.conf still mode 600" test "$(stat -c %a "$SEC1/channel.conf")" = 600
check "channel.conf still sources in bash" bash -c \
  "set -a; . '$SEC1/channel.conf'; [ -n \"\$TELEGRAM_BOT_TOKEN\" ] && [ -n \"\$GBRAIN_BEARER\" ]"
check "brain tokens never printed" bash -c "! grep -q FLEETTESTTOKEN '$FL/run1.log'"
check "brain tokens only in secrets dirs" bash -c \
  "! grep -rq FLEETTESTTOKEN '$FAKE_HOME/agents' '$FL/etc' '$FL/systemd' '$FL/cron'"
check ".mcp.json keeps dashi-channel, adds 3 brain servers" jq -e \
  '.mcpServers as $s | $s["dashi-channel"] and ([$s["gbrain-memory"], $s["gbrain-recall"],
    $s["gbrain-swarm"]] | map(.headers.Authorization) | all(. == "Bearer ${GBRAIN_BEARER}"))' \
  "$PLUGIN2/.mcp.json"
check ".mcp.json brain ports" jq -e \
  '.mcpServers["gbrain-memory"].url == "http://127.0.0.1:8767/mcp"
   and .mcpServers["gbrain-swarm"].url == "http://127.0.0.1:8766/mcp"' "$PLUGIN2/.mcp.json"
check "settings.local.json enables all four" jq -e \
  '.enabledMcpjsonServers | contains(["dashi-channel","gbrain-memory","gbrain-recall","gbrain-swarm"])' \
  "$PLUGIN2/.claude/settings.local.json"
check "team block in rules.md" grep -q 'team-layer:start' "$WS2/core/rules.md"
check "team block names both agents" bash -c \
  "grep -q '^- \*\*testbot\*\* — .* (coordinator)$' '$WS2/core/rules.md' \
   && grep -q '^- \*\*helper-two\*\* — Research helper$' '$WS2/core/rules.md'"
check "team block has no placeholders" bash -c "! grep -q '{{' '$WS2/core/rules.md'"
check "channel rule kept above team block" grep -q "## Telegram channel" "$WS2/core/rules.md"
check "fleet.conf records team" bash -c \
  "set -a; . '$FAKE_HOME/.config/tg-agent/fleet.conf'; [ \"\$FLEET_AGENTS\" = 'helper-two testbot' ] \
   && [ \"\$FLEET_COORDINATOR\" = testbot ]"
check "fleet.env mode 600" test "$(stat -c %a "$FL/etc/fleet.env")" = 600
# fleet_env_ok: the worker's env file maps every agent to its port and webhook secret.
fleet_env_ok() (
  set -a
  . "$FL/etc/fleet.env"
  set +a
  python3 - "$SEC1/channel.conf" "$SEC2/channel.conf" "$OWNER" <<'PY'
import json, os, sys
gw = json.loads(os.environ["AGENT_GATEWAYS"])
auth = json.loads(os.environ["AGENT_GATEWAY_AUTH"])
assert gw == {"helper-two": "http://127.0.0.1:18090/hooks/agent",
              "testbot": "http://127.0.0.1:18089/hooks/agent"}, gw
for agent, conf in zip(["testbot", "helper-two"], sys.argv[1:3]):
    var = auth[agent].split(":", 2)[2]
    want = [l.split("=", 1)[1].strip().strip('"') for l in open(conf)
            if l.startswith("TELEGRAM_WEBHOOK_TOKEN=")][0]
    assert want and os.environ[var] == want, agent
assert os.environ["COORDINATOR_AGENT"] == "testbot"
assert os.environ["OWNER_CHAT_ID"] == sys.argv[3]
PY
)
check "fleet.env: gateways + auth resolve to webhook tokens" fleet_env_ok
check "worker drop-in loads fleet.env" grep -qx "EnvironmentFile=$FL/etc/fleet.env" \
  "$FL/systemd/gbrain-swarm-worker.service.d/tg-agent-fleet.conf"
check "worker restarted" grep -qx 'restart gbrain-swarm-worker.service' "$FL/systemctl.log"
check "agent with a unit restarted" grep -qx 'restart testbot-agent.service' "$FL/systemctl.log"
check "backup script + cron installed" bash -c \
  "[ -x '$FL/lib/gbrain-backup.sh' ] && grep -q '^17 3 \* \* \* root $FL/lib/gbrain-backup.sh' \
   '$FL/cron/tg-agent-gbrain-backup'"
check "smoke covered 2 agents x 3 servers" test "$(grep -c ' ok$' "$FL/run1.log")" = 6
# smoke_rejects TOKEN: mcp-smoke.py must fail and name the reason, never echo the token.
smoke_rejects() {
  local out
  ! out="$(printf '%s\n' "$1" | python3 "$KIT/server/fleet/mcp-smoke.py" \
      "http://127.0.0.1:$((8767 + SMOKE_OFFSET))/mcp" slot_list '{"limit":1}')" \
    && grep -q "unknown bearer token" <<<"$out" && ! grep -q "$1" <<<"$out"
}
check "smoke rejects an unknown token" smoke_rejects BOGUSTOKENBOGUSTOKENBOGUSTOKEN0000000
# Without the session handshake the fake answers 400, like the live brain.
no_session_400() {
  python3 - "http://127.0.0.1:$((8766 + SMOKE_OFFSET))/mcp" <<'PY'
import json, sys, urllib.error, urllib.request
req = urllib.request.Request(sys.argv[1], method="POST", data=json.dumps(
    {"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode(),
    headers={"Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=5)
except urllib.error.HTTPError as exc:
    sys.exit(0 if exc.code == 400 else 1)
sys.exit(1)
PY
}
check "fake brain is stateful (400 without session)" no_session_400

cp "$WS2/core/rules.md" "$FL/rules.first"
cp "$FL/etc/fleet.env" "$FL/fleet.env.first"
if run_fleet "$FL/run2.log"; then ok "re-run exits 0 (coordinator from fleet.conf)"; else
  bad "re-run exits 0"; tail -10 "$FL/run2.log"; fi
check "re-run issues no new tokens" test "$(issued)" = 2
check "re-run leaves rules.md unchanged" cmp -s "$FL/rules.first" "$WS2/core/rules.md"
check "re-run leaves fleet.env unchanged" cmp -s "$FL/fleet.env.first" "$FL/etc/fleet.env"
check "exactly one team block" test "$(grep -c 'team-layer:start' "$WS2/core/rules.md")" = 1
rotated() { run_fleet "$FL/run3.log" --rotate-tokens && [ "$(issued)" = 4 ]; }
check "--rotate-tokens re-issues both" rotated
check "unknown coordinator refused" refused "$FL/run4.log" "is not one of" --coordinator nobody
echo "EnvironmentFile=/etc/other.env" > "$FL/systemd/gbrain-swarm-worker.service.d/webhook.conf"
check "foreign worker drop-in refused" refused "$FL/run5.log" "did not write" --rotate-tokens
rm -f "$FL/systemd/gbrain-swarm-worker.service.d/webhook.conf"
check "foreign drop-in: nothing rotated" test "$(issued)" = 4
check "rotation refused under --no-restart" refused "$FL/run7.log" "cannot be combined" \
  --rotate-tokens --no-restart
mv "$WS2/core/rules.md" "$FL/rules.moved"
check "missing rules.md refused" refused "$FL/run8.log" "missing core/rules.md" --rotate-tokens
mv "$FL/rules.moved" "$WS2/core/rules.md"
check "refusals issued no tokens" test "$(issued)" = 4
# A dead token (brain reinstalled, database reset) must fail the smoke.
cp "$FL/valid-tokens" "$FL/valid-tokens.keep"
: > "$FL/valid-tokens"
check "smoke fails on dead tokens" refused "$FL/run9.log" "unknown bearer token"
cp "$FL/valid-tokens.keep" "$FL/valid-tokens"
# --use-existing-brain adopts the brain: marker written, tokens rotated once.
mv "$FL/etc/tg-agent-fleet.marker" "$FL/marker.first"
adopted() {
  run_fleet "$FL/run10.log" --use-existing-brain && [ "$(issued)" = 6 ] \
    && grep -q '^adopted by' "$FL/etc/tg-agent-fleet.marker" \
    && run_fleet "$FL/run11.log" && [ "$(issued)" = 6 ]
}
check "--use-existing-brain adopts, re-run keeps tokens" adopted
# A half-present brain dir is not a fresh server: never install over it.
mv "$GB/.venv/bin/python" "$FL/python.moved"
check "half-present brain refused" refused "$FL/run12.log" "exists but"
mv "$FL/python.moved" "$GB/.venv/bin/python"
sed -i 's/^    body = {$/    body = {\n        "agentId": to_agent,/' "$GB/services/swarm_mcp/worker.py"
check "unpatched brain refused" refused "$FL/run6.log" "lacks patch 0001"

if [ "$WITH_PLUGIN" = "1" ]; then
  echo "== 7. plugin build + tests"
  bash "$KIT/scripts/build-plugin.sh" "$WORK/plugin-build" > "$WORK/build.log" 2>&1 \
    && ok "build-plugin" || bad "build-plugin"
  (cd "$WORK/plugin-build/plugin" && bun install --frozen-lockfile > "$WORK/bun.log" 2>&1) \
    && ok "bun install" || bad "bun install"
  (cd "$WORK/plugin-build/plugin" && bunx tsc --noEmit > "$WORK/tsc.log" 2>&1) \
    && ok "typecheck" || bad "typecheck"
  # The plugin must accept the env the installer wrote (clean env: no host TELEGRAM_*).
  check "installer channel.conf passes the plugin's RuntimeEnvSchema" \
    env -i PATH="$PATH" HOME="$FAKE_HOME" bash -c "set -a; . '$SEC/channel.conf'; set +a; \
      cd '$WORK/plugin-build/plugin' && bun -e \
      \"const { RuntimeEnvSchema } = await import('./src/config.ts'); RuntimeEnvSchema.parse(process.env)\""
  (cd "$WORK/plugin-build/plugin" && bun test > "$WORK/test.log" 2>&1) \
    && ok "bun test ($(grep -oE '[0-9]+ pass' "$WORK/test.log" | tail -1))" \
    || { bad "bun test"; grep -E ' fail|✗' "$WORK/test.log" | head -10; }
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
