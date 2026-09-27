#!/usr/bin/env bash
# UserPromptSubmit hook: detects an operator-correction in the prompt and injects
# a reminder to capture the lesson into core/LEARNINGS.md. Implements the
# self-learning feedback loop (correction in chat -> Learnings). Manual-fix mode:
# the agent appends the lesson itself; no auto-rewrite of rules/skills.
set -uo pipefail

BODY=$(cat)
PROMPT=$(printf '%s' "$BODY" | jq -r '.prompt // ""' 2>/dev/null)
[ -z "$PROMPT" ] && exit 0

# Russian-first, voice-tolerant correction signals.
PATTERN='неправильно|не ?верно|не так|ты ошиб|ошибся|ошибка|я же сказал|я (уже )?сказал|не туда|перепутал|это не то|опять|сколько раз|запомни|запиши урок|исправь|почему ты|не надо было|так нельзя|wrong|that'"'"'s not'

printf '%s' "$PROMPT" | grep -qiE "$PATTERN" || exit 0

cat <<'EOF'
[correction-detector] the operator appears to be correcting you. Before anything else, capture the lesson:
append a new row to core/LEARNINGS.md "Log" table — Date | Type | Context (what you did) | Error (what was wrong) | Rule (how to prevent the repeat) | Repeats 0 | Applied to. Then fix the issue she raised. Per CLAUDE.md self-improvement: a correction becomes a systemic change, not just a verbal "ok".
EOF
exit 0
