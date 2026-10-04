#!/usr/bin/env bash
# Unit tests for ratewatch.sh pure detectors (input_pending / turn_active
# / blocking_modal). Sourced via the RATEWATCH_TEST_ONLY seam — no tmux, no loop.
# Run: bash server/tests/ratewatch.test.sh   (exit 0 = all pass)

set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
RATEWATCH_TEST_ONLY=1 source "$HERE/../bin/ratewatch.sh"

pass=0; fail=0
ok()   { if [ "$2" = "$3" ]; then pass=$((pass+1)); else fail=$((fail+1)); printf 'FAIL: %s\n  want=[%s]\n  got =[%s]\n' "$1" "$3" "$2"; fi; }
truthy(){ if "$1" "$2"; then printf 'true'; else printf 'false'; fi; }
# Same, for predicates taking three arguments.
truthy2(){ if "$1" "$2" "$3" "$4"; then printf 'true'; else printf 'false'; fi; }
# Same, for predicates taking four.
truthy3(){ if "$1" "$2" "$3" "$4" "$5"; then printf 'true'; else printf 'false'; fi; }

STATUS='  ⏵⏵ bypass permissions on (shift+tab to cycle) · ← for agents'

# --- input_pending ---
stuck=$(printf '  Baked for 5m\n────\n❯ Да, собери полный список и перепроверь\n────\n%s\n' "$STATUS")
ok "input_pending: real stuck text" "$(input_pending "$stuck")" "Да, собери полный список и перепроверь"

empty=$(printf '────\n❯ \n────\n%s\n' "$STATUS")
ok "input_pending: empty composer" "$(input_pending "$empty")" ""

placeholder=$(printf '────\n❯ Try "how does status-manager.ts work?"\n────\n%s\n' "$STATUS")
ok "input_pending: placeholder = empty" "$(input_pending "$placeholder")" ""

slashdraft=$(printf '────\n❯ /rate-limit-options\n────\n%s\n' "$STATUS")
ok "input_pending: slash draft = empty" "$(input_pending "$slashdraft")" ""

nocomposer=$(printf 'some banner\nno arrow here\n')
ok "input_pending: no composer line" "$(input_pending "$nocomposer")" ""

# Live composers pad with U+00A0 (NBSP, \xc2\xa0) after the arrow — must read empty.
nbsp=$(printf '\342\235\257\302\240                              \n%s\n' "$STATUS")
ok "input_pending: NBSP-padded empty composer" "$(input_pending "$nbsp")" ""
nbsptext=$(printf '\342\235\257\302\240 да, собери список\n%s\n' "$STATUS")
ok "input_pending: NBSP + real text" "$(input_pending "$nbsptext")" "да, собери список"

# --- composer_ghost (Claude Code prompt suggestion = dim SGR 2 text) ---
# Live capture 2026-10-04: `capture-pane -e` composer line for a suggestion.
ghost=$(printf '\033[39m\342\235\257\302\240\033[2mЗакрой остальные черновики\033[0m\n%s\n' "$STATUS")
ok "composer_ghost: dim suggestion = ghost" "$(truthy composer_ghost "$ghost")" "true"
typed=$(printf '\033[39m\342\235\257\302\240Да, ок\n%s\n' "$STATUS")
ok "composer_ghost: default-colour typed text = real" "$(truthy composer_ghost "$typed")" "false"
ok "composer_ghost: empty composer = not ghost" "$(truthy composer_ghost "$empty")" "false"
ok "composer_ghost: plain capture without escapes = not ghost" "$(truthy composer_ghost "$stuck")" "false"
dimarrow=$(printf '\033[38;5;246m\342\235\257\302\240\033[39mделай 1\n%s\n' "$STATUS")
ok "composer_ghost: dim ARROW but default text = real" "$(truthy composer_ghost "$dimarrow")" "false"

# --- turn_active ---
active=$(printf '✻ Envisioning… (3s · ↓ 69 tokens)\n%s · esc to interrupt · ←\n' "$STATUS")
ok "turn_active: generating" "$(truthy turn_active "$active")" "true"
ok "turn_active: idle stuck" "$(truthy turn_active "$stuck")" "false"

# --- blocking_modal ---
spend=$(printf "You've hit your monthly spend limit.\n❯ Да\n  Adjust monthly spend limit: \$24.06\n")
ok "blocking_modal: spend" "$(truthy blocking_modal "$spend")" "true"

fable=$(printf 'Fable 5 now uses usage credits — you have \$51.22\n❯ да\n')
ok "blocking_modal: fable" "$(truthy blocking_modal "$fable")" "true"

survey=$(printf 'How is Claude doing this session? (optional)\n  1: Bad  2: Fine\n❯ ок\n')
ok "blocking_modal: feedback survey" "$(truthy blocking_modal "$survey")" "true"

ratemenu=$(printf 'Stop and wait for limit to reset\n❯ x\n')
ok "blocking_modal: rate menu" "$(truthy blocking_modal "$ratemenu")" "true"

ok "blocking_modal: clean stuck pane" "$(truthy blocking_modal "$stuck")" "false"

# AskUserQuestion select-list: highlighted option carries the SAME ❯ arrow as the
# composer. Must read as a modal so the watchdog never toggles the owner's choice.
selmenu=$(printf 'HTML и PDF — каких резюме?\n❯ 1. [✔] Менеджер проектов — MAX\n  2. [ ] Менеджер продукта — Каналы\n  5. Chat about this\nEnter to select · ↑/↓ to navigate · Esc to cancel\n')
ok "blocking_modal: select menu" "$(truthy blocking_modal "$selmenu")" "true"
# And the full loop condition must NOT fire on the select menu (the real 15:39 bug).
if [ -n "$(input_pending "$selmenu")" ] && ! turn_active "$selmenu" && ! blocking_modal "$selmenu"; then
  ok "loop-condition: select menu suppressed" "fires" "suppressed"
else
  ok "loop-condition: select menu suppressed" "suppressed" "suppressed"
fi

# --- integration: the exact condition the loop acts on ---
# stuck pane: pending non-empty AND not turn_active AND not blocking_modal
if [ -n "$(input_pending "$stuck")" ] && ! turn_active "$stuck" && ! blocking_modal "$stuck"; then
  ok "loop-condition: stuck fires" "yes" "yes"
else
  ok "loop-condition: stuck fires" "no" "yes"
fi
# active turn with pending text (queued) must NOT fire
activepending=$(printf '❯ да\n✻ Working\n%s · esc to interrupt\n' "$STATUS")
if [ -n "$(input_pending "$activepending")" ] && ! turn_active "$activepending" && ! blocking_modal "$activepending"; then
  ok "loop-condition: active turn suppressed" "fires" "suppressed"
else
  ok "loop-condition: active turn suppressed" "suppressed" "suppressed"
fi

# ───── Regressions from the live 2026-07-28 incidents ─────

# Feedback survey renders as a bare option row and EATS Enter (a peer agent sat silent).
survey_row=$(printf '  1: Bad    2: Fine   3: Good   0: Dismiss\n❯ покажи граф связей\n%s\n' "$STATUS")
ok "blocking_modal: bare survey option row" "$(truthy blocking_modal "$survey_row")" "true"

# Login flow screens must never be typed into.
login_paste=$(printf '  Login\n  Paste code here if prompted >\n  Esc to cancel\n')
ok "blocking_modal: login paste prompt" "$(truthy blocking_modal "$login_paste")" "true"
login_ok=$(printf '  Logged in as owner@example.com\n  Login successful. Press Enter to continue…\n')
ok "blocking_modal: login success screen" "$(truthy blocking_modal "$login_ok")" "true"

# Background shell / MCP task holds the session — Enter does not submit there.
held_shell=$(printf '❯ закоммить изменения вики\n%s · 1 shell · ← for agents · ↓ to manage\n' "$STATUS")
ok "session_held: background shell" "$(truthy session_held "$held_shell")" "true"
held_mcp=$(printf '❯ дождись доставки\n%s · 1 MCP task · ← for agents\n' "$STATUS")
ok "session_held: background MCP task" "$(truthy session_held "$held_mcp")" "true"
ok "session_held: clean pane" "$(truthy session_held "$stuck")" "false"

# TUI hints that appear on the composer line are not user text.
hint_up=$(printf '❯ Press up to edit queued messages\n%s\n' "$STATUS")
ok "input_pending: queued-messages hint" "$(input_pending "$hint_up")" ""
hint_paste=$(printf '❯ paste again to expand\n%s\n' "$STATUS")
ok "input_pending: paste-again hint" "$(input_pending "$hint_paste")" ""
one_char=$(printf '❯ x\n%s\n' "$STATUS")
ok "input_pending: single char too short" "$(input_pending "$one_char")" ""

# Full loop condition must stand down on every one of these.
for name in survey_row login_paste held_shell held_mcp hint_up one_char; do
  eval "pane=\$$name"
  if [ -n "$(input_pending "$pane")" ] && ! turn_active "$pane" \
     && ! blocking_modal "$pane" && ! session_held "$pane"; then
    ok "loop-condition: $name suppressed" "fires" "suppressed"
  else
    ok "loop-condition: $name suppressed" "suppressed" "suppressed"
  fi
done

# ───── retype_safe (2026-07-31: Enter alone never submits; retype does) ─────
ok "retype_safe: plain russian text" "$(truthy retype_safe 'добавь тезисам темы, чтобы фильтр работал')" "true"
ok "retype_safe: short command"      "$(truthy retype_safe 'открой PR')" "true"
# Paste placeholders must NEVER be retyped — the real payload is in the TUI's
# paste buffer, retyping would send the placeholder text itself.
ok "retype_safe: paste placeholder"  "$(truthy retype_safe '[Pasted text #7 +1 lines]')" "false"
ok "retype_safe: multi-line marker"  "$(truthy retype_safe 'сделай отчёт +3 lines]')" "false"
# Renderer-truncated text would be retyped incomplete.
ok "retype_safe: ellipsis unicode"   "$(truthy retype_safe 'собери длинный список и…')" "false"
ok "retype_safe: ellipsis ascii"     "$(truthy retype_safe 'собери длинный список и...')" "false"
ok "retype_safe: empty"              "$(truthy retype_safe '')" "false"
long=$(printf 'a%.0s' $(seq 1 401))
ok "retype_safe: over 400 chars"     "$(truthy retype_safe "$long")" "false"
ok "retype_safe: exactly 400 chars"  "$(truthy retype_safe "${long:0:400}")" "true"

# Guards added after cross-review (codex, 2026-07-31).
ok "retype_safe: leading dash allowed (tmux -- terminates options)" "$(truthy retype_safe '-R перезапусти')" "true"
ok "retype_safe: paste placeholder mid-string" "$(truthy retype_safe 'вот файл [Pasted text #3 +2 lines]')" "false"
ok "retype_safe: tab inside text" "$(truthy retype_safe "$(printf 'текст\tс табом')")" "false"
ok "retype_safe: CR inside text"  "$(truthy retype_safe "$(printf 'текст\rвозврат')")" "false"

# composer_extra_lines: a multi-line draft must block the retype path.
single=$(printf '────\n❯ одна строка\n────\n%s\n' "$STATUS")
ok "composer_extra_lines: single line" "$(composer_extra_lines "$single")" "0"
multi=$(printf '────\n❯ первая строка черновика\n  вторая строка черновика\n  третья\n────\n%s\n' "$STATUS")
ok "composer_extra_lines: multi-line draft" "$(composer_extra_lines "$multi")" "2"
padded=$(printf '────\n\342\235\257\302\240 текст\n\302\240        \n────\n%s\n' "$STATUS")
ok "composer_extra_lines: NBSP padding is not a line" "$(composer_extra_lines "$padded")" "0"
ok "composer_extra_lines: no composer at all" "$(composer_extra_lines 'ничего')" "0"

# submit_confirmed: only an empty composer or a started turn counts.
SENT='всё ещё текст'
after_empty=$(printf '────\n❯ \n────\n%s\n' "$STATUS")
ok "submit_confirmed: empty composer" "$(truthy2 submit_confirmed "$after_empty" "$SENT" '')" "true"
after_turn=$(printf '✻ Working…\n────\n❯ всё ещё текст\n────\n%s · esc to interrupt\n' "$STATUS")
ok "submit_confirmed: turn started" "$(truthy2 submit_confirmed "$after_turn" "$SENT" '')" "true"
after_same=$(printf '────\n❯ всё ещё текст\n────\n%s\n' "$STATUS")
ok "submit_confirmed: same text still sitting" "$(truthy2 submit_confirmed "$after_same" "$SENT" '')" "false"
# Enter that only reflowed / extended the draft must NOT count as success.
after_reflow=$(printf '────\n❯ всё ещё текст и ещё\n────\n%s\n' "$STATUS")
ok "submit_confirmed: reflow is not a submit" "$(truthy2 submit_confirmed "$after_reflow" "$SENT" '')" "false"
# The 12:25 false negative: our message went through and the owner's NEXT message is
# already in the composer. That IS a success.
after_next=$(printf '────\n❯ скинула, читай\n────\n%s\n' "$STATUS")
ok "submit_confirmed: next message arrived" "$(truthy2 submit_confirmed "$after_next" "$SENT" '')" "true"
ok "submit_confirmed: no expected text falls back to strict" "$(truthy2 submit_confirmed "$after_next" '' '')" "false"

# ───── Detectors must read the STATUS AREA, not the scrollback ─────
# Regression: an agent sat unrecovered for minutes because "1 shell" from an earlier
# turn was still visible in its scrollback, so a whole-pane grep read the session
# as permanently busy.
scroll_shell=$(printf '● Bash(git push)\n  ⎿ 1 shell still running\n  готово\n────\n❯ попробуй запушить ещё раз\n────\n%s\n' "$STATUS")
ok "session_held: stale 'shell' in scrollback ignored" "$(truthy session_held "$scroll_shell")" "false"
status_shell=$(printf '❯ попробуй ещё\n%s · 1 shell · ← for agents\n' "$STATUS")
ok "session_held: shell in the status line still caught" "$(truthy session_held "$status_shell")" "true"

scroll_esc=$(printf '  раньше тут было esc to interrupt\n  и текст\n────\n❯ давай ещё раз\n────\n%s\n' "$STATUS")
ok "turn_active: stale 'esc to interrupt' ignored" "$(truthy turn_active "$scroll_esc")" "false"

scroll_menu=$(printf '  когда-то был Enter to select\n  много\n  строк\n  вывода\n  ещё\n  ещё\n  ещё\n  ещё\n  ещё\n  ещё\n  ещё\n  ещё\n  ещё\n────\n❯ обычное сообщение\n────\n%s\n' "$STATUS")
ok "blocking_modal: menu far above is ignored" "$(truthy blocking_modal "$scroll_menu")" "false"

# And the full loop condition must now FIRE on the agent pane that was stuck.
if [ -n "$(input_pending "$scroll_shell")" ] && ! turn_active "$scroll_shell" \
   && ! blocking_modal "$scroll_shell" && ! session_held "$scroll_shell"; then
  ok "loop-condition: an agent's stale-shell pane recovers" "fires" "fires"
else
  ok "loop-condition: an agent's stale-shell pane recovers" "suppressed" "fires"
fi

# ───── Anti-double-submit guards (cross-review 2026-07-31) ─────
SUBMIT_COOLDOWN_S=120
LOCK_STALE_S=60

d1=$(text_digest 'открой PR')
d2=$(text_digest 'закоммить и запушь')
ok "text_digest: stable"      "$(text_digest 'открой PR')" "$d1"
ok "text_digest: distinct"    "$([ "$d1" != "$d2" ] && echo differ)" "differ"

hist=$(printf '%s 1000\n%s 900\n' "$d1" "$d2")
ok "submit_recently_done: inside window"  "$(truthy2 submit_recently_done "$d1" 1050 "$hist")" "true"
ok "submit_recently_done: outside window" "$(truthy2 submit_recently_done "$d1" 1200 "$hist")" "false"
ok "submit_recently_done: unknown digest" "$(truthy2 submit_recently_done "$(text_digest 'нечто')" 1050 "$hist")" "false"
ok "submit_recently_done: empty history"  "$(truthy2 submit_recently_done "$d1" 1050 '')" "false"

# lock_stale: dead owner, wedged owner, healthy owner.
ok "lock_stale: pid missing"      "$(truthy2 lock_stale '' 1000 1010)" "true"
ok "lock_stale: dead pid"         "$(truthy2 lock_stale 999999 1000 1010)" "true"
ok "lock_stale: live but wedged"  "$(truthy2 lock_stale $$ 1000 1100)" "true"
ok "lock_stale: live and fresh"   "$(truthy2 lock_stale $$ 1000 1010)" "false"

# --- feedback_survey: the one modal the watchdog is allowed to clear itself ---
# 2026-08-01: a peer agent sat 11h with three of the owner's messages queued behind this
# survey. blocking_modal() rightly stood down; nothing else ever dismissed it.
srv_q=$(printf '● How is Claude doing this session? (optional)\n  1: Bad    2: Fine   3: Good   0: Dismiss\n❯ подними число новостей\n%s\n' "$STATUS")
ok "feedback_survey: question + options" "$(truthy feedback_survey "$srv_q")" "true"

srv_bare=$(printf '  1: Bad    2: Fine   3: Good   0: Dismiss\n❯ подними число новостей\n%s\n' "$STATUS")
ok "feedback_survey: bare option row" "$(truthy feedback_survey "$srv_bare")" "true"

ok "feedback_survey: clean stuck pane" "$(truthy feedback_survey "$stuck")" "false"
ok "feedback_survey: spend modal is not ours" "$(truthy feedback_survey "$spend")" "false"
ok "feedback_survey: rate menu is not ours" "$(truthy feedback_survey "$ratemenu")" "false"
ok "feedback_survey: select list is not ours" "$(truthy feedback_survey "$selmenu")" "false"

# "0" must never be typed on the strength of a row left in the SCROLLBACK: that
# would append a stray digit to whatever the owner is composing.
srv_stale=$(printf '  1: Bad    2: Fine   3: Good   0: Dismiss\n')$(printf '\nfiller %s' 1 2 3 4 5 6 7 8)$(printf '\n❯ текст\n%s\n' "$STATUS")
ok "feedback_survey: stale row far above ignored" "$(truthy feedback_survey "$srv_stale")" "false"

# A lone Dismiss without ratings is some other prompt — stay out of it.
srv_lone=$(printf '  0: Dismiss\n❯ текст\n%s\n' "$STATUS")
ok "feedback_survey: lone dismiss ignored" "$(truthy feedback_survey "$srv_lone")" "false"

# The survey still counts as a blocking modal: the composer handler must not
# press Enter while it is up (it eats Enter), the survey branch clears it first.
ok "feedback_survey: also a blocking_modal" "$(truthy blocking_modal "$srv_bare")" "true"

# While a turn is generating, keys land in the composer — the survey branch waits.
srv_active=$(printf '  1: Bad    2: Fine   3: Good   0: Dismiss\n✻ Working… (3s)\n%s · esc to interrupt\n' "$STATUS")
if feedback_survey "$srv_active" && ! turn_active "$srv_active"; then r=dismiss; else r=wait; fi
ok "feedback_survey: gated by turn_active" "$r" "wait"

# --- /stop handling ---
# The real rendering, captured from an agent's pane after the owner pressed /stop on
# 2026-08-01: "  ⎿  Interrupted · What should Claude do instead?"
stopped=$(printf '● Читаю логи…\n  \342\216\277  Interrupted \302\267 What should Claude do instead?\n\342\235\257 собери каталог по всем материалам\n%s\n' "$STATUS")
ok "interrupted: real /stop pane" "$(truthy interrupted "$stopped")" "true"
ok "interrupted: ordinary stuck pane" "$(truthy interrupted "$stuck")" "false"
ok "interrupted: generating pane" "$(truthy interrupted "$srv_active")" "false"

# Once the next turn has scrolled the marker out of the status area, the state
# clears on its own — the watchdog must not be muted forever by one /stop.
stop_scrolled=$(printf '  \342\216\277  Interrupted \302\267 What should Claude do instead?\n')$(printf '\nline %s' 1 2 3 4 5 6 7 8 9 10 11 12)$(printf '\n\342\235\257 новое сообщение\n%s\n' "$STATUS")
ok "interrupted: marker scrolled away" "$(truthy interrupted "$stop_scrolled")" "false"

killed=$(text_digest "собери каталог по всем материалам")
other=$(text_digest "а теперь посчитай расходы")
now=1785570000

# The text she stopped is dead for good — even long after the grace window.
ok "stop_blocks_submit: stopped text, fresh" \
   "$(truthy3 stop_blocks_submit "$killed" "$killed" $(( now - 5 )) "$now")" "true"
ok "stop_blocks_submit: stopped text, hours later" \
   "$(truthy3 stop_blocks_submit "$killed" "$killed" $(( now - 7200 )) "$now")" "true"

# Anything else waits out the grace window, then gets served normally.
ok "stop_blocks_submit: other text inside grace" \
   "$(truthy3 stop_blocks_submit "$other" "$killed" $(( now - 5 )) "$now")" "true"
ok "stop_blocks_submit: other text after grace" \
   "$(truthy3 stop_blocks_submit "$other" "$killed" $(( now - STOP_GRACE_S - 1 )) "$now")" "false"

# No interrupt in effect: the guard is transparent.
ok "stop_blocks_submit: no interrupt" \
   "$(truthy3 stop_blocks_submit "$other" "" "" "$now")" "false"

# /stop with an empty composer poisons nothing, only the grace window applies.
ok "stop_blocks_submit: empty composer at stop, inside grace" \
   "$(truthy3 stop_blocks_submit "$other" "" $(( now - 5 )) "$now")" "true"
ok "stop_blocks_submit: empty composer at stop, after grace" \
   "$(truthy3 stop_blocks_submit "$other" "" $(( now - STOP_GRACE_S - 1 )) "$now")" "false"

# --- spool_dropped / report_dropped ---
# Every give-up path must record the lost text exactly once, and the recording
# must never resurrect a line that was already spooled or already answered.
TMPD=$(mktemp -d)
SPOOL="$TMPD/dropped.tsv"

spool_dropped "первое сообщение" "$SPOOL"; ok "spool_dropped: first write rc" "$?" "0"
ok "spool_dropped: text stored" "$(cut -f2- "$SPOOL")" "первое сообщение"
ok "spool_dropped: timestamped" "$(cut -f1 "$SPOOL" | grep -cE '^[0-9]{4}-[0-9]{2}-[0-9]{2}T')" "1"

spool_dropped "первое сообщение" "$SPOOL"; ok "spool_dropped: duplicate rc" "$?" "1"
ok "spool_dropped: duplicate not appended" "$(wc -l < "$SPOOL")" "1"

# Already surfaced once (moved to .seen.tsv) — still must not come back.
printf '%s\t%s\n' "$(date -Is)" "уже показанное" > "${SPOOL%.tsv}.seen.tsv"
spool_dropped "уже показанное" "$SPOOL"; ok "spool_dropped: seen text rc" "$?" "1"
ok "spool_dropped: seen text not re-added" "$(wc -l < "$SPOOL")" "1"

spool_dropped "второе сообщение" "$SPOOL"
ok "spool_dropped: new text appended" "$(wc -l < "$SPOOL")" "2"

spool_dropped "" "$SPOOL"; ok "spool_dropped: empty text is a no-op" "$(wc -l < "$SPOOL")" "2"

# report_dropped wires the spool to the owner alert: the alert gets the
# agent name and the full text, and a broken alert never breaks the watchdog.
STUB="$TMPD/notify.sh"
printf '#!/usr/bin/env bash\nprintf "%%s|%%s\\n" "$1" "$2" >> "%s/calls"\n' "$TMPD" > "$STUB"
chmod +x "$STUB"
( DROPPED="$SPOOL" NOTIFY_SCRIPT="$STUB" AGENT_NAME="testagent" LOG="$TMPD/log" \
  report_dropped "третье сообщение" )
ok "report_dropped: spooled" "$(cut -f2- "$SPOOL" | tail -1)" "третье сообщение"
ok "report_dropped: alert called" "$(cat "$TMPD/calls" 2>/dev/null)" "testagent|третье сообщение"

printf '#!/usr/bin/env bash\nexit 3\n' > "$STUB"
( DROPPED="$SPOOL" NOTIFY_SCRIPT="$STUB" AGENT_NAME="testagent" LOG="$TMPD/log" \
  report_dropped "четвёртое сообщение" )
ok "report_dropped: survives a failing alert" "$?" "0"

( DROPPED="$SPOOL" NOTIFY_SCRIPT="$TMPD/nope.sh" AGENT_NAME="testagent" LOG="$TMPD/log" \
  report_dropped "пятое сообщение" )
ok "report_dropped: survives a missing alert script" "$?" "0"
ok "report_dropped: still spooled without alert" "$(cut -f2- "$SPOOL" | tail -1)" "пятое сообщение"

# --- pause_state: the stop-file that suspends every keystroke ---
# Owner, 2026-09-22: stopping the watchdog by hand does not hold — cron ensure
# revives it within two minutes and it replayed an unverified composer line into
# the session. The stop file is the only durable pause.
PAUSED="$TMPD/ratewatch.paused"
ok "pause_state: no file = off" "$(pause_state "$PAUSED" 3600 1000)" "off"
: > "$PAUSED"
touch -d @900 "$PAUSED"
ok "pause_state: fresh file = active" "$(pause_state "$PAUSED" 3600 1000)" "active"
ok "pause_state: within max age = active" "$(pause_state "$PAUSED" 3600 4400)" "active"
ok "pause_state: past max age = expired" "$(pause_state "$PAUSED" 3600 4500)" "expired"
ok "pause_state: max 0 disables expiry" "$(pause_state "$PAUSED" 0 999999)" "active"
ok "pause_state: empty reason still pauses" "$(pause_state "$PAUSED" 3600 1000)" "active"
printf 'чужая строка в композере\n' > "$PAUSED"
touch -d @900 "$PAUSED"
ok "pause_state: file with reason = active" "$(pause_state "$PAUSED" 3600 1000)" "active"
rm -f "$PAUSED"
ok "pause_state: removed file = off" "$(pause_state "$PAUSED" 3600 1000)" "off"

rm -r "$TMPD" 2>/dev/null || true

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
