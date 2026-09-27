#!/usr/bin/env bash
# run-tests.sh -- kit test suite. No network, no systemd, no real bot.
#
#   1. leak scan (entities from LEAK_ENTITIES_FILE if set, secrets, vendor tree)
#   2. syntax of every script
#   3. ratewatch unit tests
#   4. installer end-to-end into a throwaway HOME (getMe and bun install skipped)
#      and checks on what it produced
#   5. with --with-plugin: build the patched plugin, bun install, typecheck, bun test
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
trap 'find "$WORK" -mindepth 0 -delete 2>/dev/null || true' EXIT

echo "== 1. leak scan"
check "leak-scan clean" bash "$KIT/scripts/leak-scan.sh"

echo "== 2. syntax"
while IFS= read -r f; do
  check "bash -n ${f#"$KIT"/}" bash -n "$f"
done < <(find "$KIT/server" "$KIT/scripts" "$KIT/core/hooks" "$KIT/core/scripts" "$KIT/core/cron" \
           "$KIT/install-server.sh" -name '*.sh' -type f | sort)
check "python syntax" python3 -m py_compile "$KIT/scripts/render-template.py" \
  "$KIT/server/hooks/silent-reply-check.py"
find "$KIT" -name __pycache__ -type d -exec find {} -delete \; 2>/dev/null || true

echo "== 3. ratewatch"
check "ratewatch tests" bash "$KIT/server/tests/ratewatch.test.sh"

echo "== 4. installer end-to-end"
FAKE_HOME="$WORK/home"
mkdir -p "$FAKE_HOME"
OWNER=111222333
PORT=18089
DUMMY_TOKEN="987654321:$(printf 'x%.0s' $(seq 1 35))"
if HOME="$FAKE_HOME" TG_AGENT_NONINTERACTIVE=1 TG_AGENT_TEST_SKIP_GETME=1 TG_AGENT_TEST_SKIP_BUN=1 \
   TG_AGENT_BOT_TOKEN="$DUMMY_TOKEN" AGENT_NAME=testbot OWNER_CHAT_ID="$OWNER" \
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
            target = parts[1] if parts[0] == "node" else parts[0]
            assert os.path.isfile(target), target
            assert parts[0] == "node" or os.access(target, os.X_OK), target
PY
check "channel rule appended to rules.md" grep -q "## Telegram channel" "$WS/core/rules.md"
check "plugin CLAUDE.md has raw HTML rule" grep -q "RAW HTML" "$PLUGIN/CLAUDE.md"
check "claude config: bypass prompt skipped" jq -e '.skipDangerousModePermissionPrompt' \
  "$FAKE_HOME/.claude-agent-testbot/settings.json"
check "claude config: plugin dir trusted" jq -e \
  --arg p "$PLUGIN" '.projects[$p].hasTrustDialogAccepted' "$FAKE_HOME/.claude-agent-testbot/.claude.json"
check "server cron dry-run" bash "$KIT/server/cron/install-cron.sh" "$WS" --dry-run
check "core cron dry-run" bash "$KIT/core/cron/install-cron.sh" "$WS" --dry-run

for unit in agent ratewatch; do
  out="$WORK/$unit.service"
  if (set -a; . "$WS/agent.conf"; RUN_USER=u RUN_GROUP=g USER_HOME="$FAKE_HOME" \
      python3 "$KIT/scripts/render-template.py" "$KIT/server/systemd/$unit.service.template" "$out"); then
    check "$unit unit renders without placeholders" bash -c "! grep -q '{{' '$out'"
  else
    bad "$unit unit renders"
  fi
done

if [ "$WITH_PLUGIN" = "1" ]; then
  echo "== 5. plugin build + tests"
  bash "$KIT/scripts/build-plugin.sh" "$WORK/plugin-build" > "$WORK/build.log" 2>&1 \
    && ok "build-plugin" || bad "build-plugin"
  (cd "$WORK/plugin-build/plugin" && bun install --frozen-lockfile > "$WORK/bun.log" 2>&1) \
    && ok "bun install" || bad "bun install"
  (cd "$WORK/plugin-build/plugin" && bunx tsc --noEmit > "$WORK/tsc.log" 2>&1) \
    && ok "typecheck" || bad "typecheck"
  (cd "$WORK/plugin-build/plugin" && bun test > "$WORK/test.log" 2>&1) \
    && ok "bun test ($(grep -oE '[0-9]+ pass' "$WORK/test.log" | tail -1))" \
    || { bad "bun test"; grep -E ' fail|✗' "$WORK/test.log" | head -10; }
fi

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
