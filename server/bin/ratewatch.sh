#!/usr/bin/env bash
# Watchdog for the agent tmux session. Two silent-freeze modes, both of
# which leave the process alive + systemd/cron thinking all is well:
#
#   1. Rate-limit menu ("Stop and wait for limit to reset") — freezes the TUI
#      until dismissed. Handled by sending "1" (= wait-for-reset).
#   2. Stuck composer — an inbound message got typed into the composer but the
#      auto-submit did not land (observed repeatedly after long turns: the
#      dashi-channel single-session delivery types the text, but the trailing
#      submit races the TUI settling, so the message sits un-sent and the chat
#      goes silent). Handled by pressing Enter once the composer has been
#      provably STABLE (same pending text across two polls) with no active turn
#      and no blocking modal — so we never race a mid-arrival paste or an
#      in-flight turn, and never double-submit.
#
# Runs as its own systemd unit next to the agent unit (Restart=always).
#
# Test seam: source with RATEWATCH_TEST_ONLY=1 to load the pure detector
# functions (input_pending / turn_active / blocking_modal) without the loop.

set -uo pipefail

SESSION="${PLUGIN_SESSION_NAME:-agent}"
LOG="${RATEWATCH_LOG:-${LOG_DIR:-$HOME/.local/state/tg-agent}/ratewatch.log}"
AGENT_NAME="${RATEWATCH_AGENT:-${AGENT_NAME:-agent}}"
NOTIFY_SCRIPT="${RATEWATCH_NOTIFY_SCRIPT:-$(dirname "${BASH_SOURCE[0]}")/notify-owner.sh}"
DROPPED="${RATEWATCH_DROPPED:-${LOG_DIR:-$HOME/.local/state/tg-agent}/dropped-messages.tsv}"

# Poll cadence + composer-stability gate. A stuck composer is flushed after it
# stays unchanged across two polls (~2*POLL_INTERVAL of latency), which is well
# under a human's patience but long enough that a message still being delivered
# (or a turn about to start on its own) is never pre-empted.
POLL_INTERVAL="${RATEWATCH_POLL_INTERVAL:-10}"
ENTER_COOLDOWN="${RATEWATCH_ENTER_COOLDOWN:-12}"
RATE_COOLDOWN="${RATEWATCH_RATE_COOLDOWN:-90}"

# Recovery may only start once the SAME text has been sitting in the composer for
# at least this long. Stability across polls is not enough on its own: the
# upstream injector types the text and submits it as two separate steps, so a
# brief unchanged window can simply mean "Enter is about to arrive". 15s is past
# anything the injector does on its own.
MIN_PENDING_AGE_S="${RATEWATCH_MIN_PENDING_AGE:-15}"
# Never re-submit the same text twice inside this window, whoever asked. Belt
# after the lock: a message can be accepted while the pane still shows it.
SUBMIT_COOLDOWN_S="${RATEWATCH_SUBMIT_COOLDOWN:-120}"
LOCK_STALE_S="${RATEWATCH_LOCK_STALE:-60}"
# After a /stop the watchdog keeps off the keyboard for this long. Long enough
# to cover a message the plugin had already queued behind the killed turn, short
# enough that the owner's next real message is still rescued if delivery drops it.
STOP_GRACE_S="${RATEWATCH_STOP_GRACE:-60}"
# Retype escalation (clear the composer and type the text back) is OFF by
# default since 2026-08-02: it cannot tell real pending input from a queued
# message preview, and on the preview it replays an old instruction as a new
# one. Set RATEWATCH_ALLOW_RETYPE=1 only for a supervised experiment.
# Flipped back to 0 on 2026-09-22 (owner decision).
# Retype existed only because Enter alone never submitted — and the reason it
# never submitted is that the text on screen is a queued-message preview over
# an EMPTY composer, which is exactly the case retype turns into a replayed
# instruction. Delivery now goes through the file inbox with a verified Enter
# (dm_delivery.mode=inbox, see run-agent.sh), so the watchdog no longer has
# to rescue messages by typing: it handles modals and rate-limit menus only.
ALLOW_RETYPE="${RATEWATCH_ALLOW_RETYPE:-0}"

STATE_DIR="${RATEWATCH_STATE_DIR:-$(dirname "${RATEWATCH_LOG:-${LOG_DIR:-$HOME/.local/state/tg-agent}/ratewatch.log}")}"
LOCK_DIR="$STATE_DIR/submit-${PLUGIN_SESSION_NAME:-agent}.lock"
HISTORY_FILE="$STATE_DIR/submit-${PLUGIN_SESSION_NAME:-agent}.history"

# Stop file: while it exists the watchdog touches no keys at all. Killing the
# process is NOT a pause — cron ensure revives it within two minutes, and on
# 2026-09-22 the revived watchdog retyped an unverified composer line into the
# peer agent session while a human was busy restarting it. Touch this file to
# stand the watchdog down, remove it to resume. It expires by itself after
# PAUSE_MAX_S so a forgotten pause never leaves the fleet unguarded; set
# RATEWATCH_PAUSE_MAX=0 to disable the expiry.
PAUSE_FILE="${RATEWATCH_PAUSE_FILE:-$STATE_DIR/ratewatch.paused}"
PAUSE_MAX_S="${RATEWATCH_PAUSE_MAX:-3600}"

RATE_LIMIT_MARKER="Stop and wait for limit to reset"

log() { printf '[%s] [ratewatch] %s\n' "$(date -Is)" "$*" >>"$LOG" 2>&1; }

# ───── Pure detectors (unit-tested; take pane text as $1) ─────

# Text pending in the composer, or empty string if the composer is idle/empty.
# The composer is the LAST line carrying the prompt arrow. An empty composer
# renders either bare or as greyed placeholder ("Try \"...\"" / "Ask ...") —
# both must read as empty so we never "submit" a placeholder.
input_pending() {
  local line text
  line=$(printf '%s\n' "$1" | grep '❯' | tail -1)
  [ -n "$line" ] || { printf ''; return; }
  # Strip everything up to and including the arrow, then trim surrounding space.
  text=${line#*❯}
  # The composer pads with a NO-BREAK SPACE (U+00A0) right after the arrow, which
  # the C-locale [:space:] class does NOT match — normalize it (and any other
  # NBSP) to a plain space first, else an empty composer trims to a lone " ".
  text=${text//$'\xc2\xa0'/ }
  text="${text#"${text%%[![:space:]]*}"}"   # ltrim
  text="${text%"${text##*[![:space:]]}"}"   # rtrim
  case "$text" in
    '' | 'Try "'* | 'Ask '* | '/'* ) printf '' ;;   # empty, placeholder, or a slash-cmd draft
    'Press up to edit'* | 'paste again to expand'* ) printf '' ;;  # TUI hints, not user text
    ?) printf '' ;;                                 # single char — too short to be a real message
    *) printf '%s' "$text" ;;
  esac
}

# Is the composer text a Claude Code prompt suggestion rather than typed input?
# $1 = pane captured WITH escapes (`capture-pane -e`). After a turn the TUI
# predicts the next prompt and draws it in the composer as dim (SGR 2) ghost
# text; plain `capture-pane -p` strips the styling, so input_pending() reads it
# as a stuck message. Enter does not submit a suggestion (Tab accepts it), so
# every one got spooled and reported to the owner as «their» lost message
# (a peer fleet, 2026-10-02..04). Real typed text renders in the default colour.
# Only the styling of the TEXT counts: the arrow itself is sometimes drawn grey.
composer_ghost() {
  local line text
  line=$(printf '%s\n' "$1" | grep '❯' | tail -1)
  [ -n "$line" ] || return 1
  text=${line#*❯}
  text=${text//$'\xc2\xa0'/ }
  text="${text#"${text%%[! ]*}"}"   # ltrim plain spaces only; ESC must survive
  case "$text" in
    $'\e[2m'* | $'\e[2;'* ) return 0 ;;
  esac
  return 1
}

# Is the pending text SAFE to retype? Retyping is the only action that actually
# submits in this TUI (plain Enter had 0/12 success on 2026-07-31), but it
# replaces the composer with what we read from the PANE — so it must never run
# when the pane text is not the literal message:
#   * "[Pasted text #7 +1 lines]" — a placeholder; the real payload lives in the
#     TUI's paste buffer and retyping would send the placeholder string instead.
#   * "… +N lines" / multi-line drafts — we only read the last ❯ line, so
#     retyping would silently truncate the message.
#   * text ending in "…" or "⋯" — the pane truncated it to the pane width.
#   * any control character — capture-pane should not emit them, but a stray
#     tab / CR / BEL would be typed literally into the composer.
retype_safe() {
  local text="$1"
  [ -n "$text" ] || return 1
  case "$text" in
    *'[Pasted text'* | *'+'[0-9]*' lines]'* ) return 1 ;;
    *'…' | *'⋯' | *'...' ) return 1 ;;
    *[[:cntrl:]]* ) return 1 ;;
  esac
  # A retyped line must fit comfortably inside the pane, else what we read is
  # probably already clipped by the renderer.
  [ "${#text}" -le 400 ] || return 1
  return 0
}

# Number of non-empty continuation lines below the composer's arrow line, i.e.
# how much of a multi-line draft we CANNOT see in `input_pending` (which only
# reads the arrow line). Retyping a multi-line draft would submit just its last
# line and silently drop the rest, and C-u only kills the current line — so a
# non-zero count must block the retype path entirely.
composer_extra_lines() {
  local -a lines=()
  local l i last=-1 n=0
  mapfile -t lines <<<"$1"
  for i in "${!lines[@]}"; do
    case "${lines[$i]}" in *❯*) last=$i ;; esac
  done
  [ "$last" -ge 0 ] || { printf '0'; return; }
  for (( i = last + 1; i < ${#lines[@]}; i++ )); do
    l=${lines[$i]}
    case "$l" in *───*) break ;; esac          # bottom border of the box
    l=${l//$'\xc2\xa0'/ }
    l=${l//[[:space:]]/}
    [ -n "$l" ] && n=$(( n + 1 ))
  done
  printf '%s' "$n"
}

# ───── Anti-double-submit (cross-review, 2026-07-31) ─────
# Tonight a human and this watchdog retyped the same pending message within
# seconds of each other and it was submitted TWICE. Two independent guards:
#   * a lock, so only one actor drives the keyboard at a time;
#   * a digest history, so the same text is never submitted twice in a window —
#     which also covers "the message was accepted but the pane has not repainted".

text_digest() {
  printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

# Was this exact text submitted within SUBMIT_COOLDOWN_S? Pure: takes the
# history file content on stdin-like arg so it can be unit-tested.
# $1 = digest, $2 = now (epoch), $3 = history text ("digest ts" per line)
submit_recently_done() {
  local digest="$1" now="$2" history="$3" d ts
  while read -r d ts; do
    [ "$d" = "$digest" ] || continue
    [ -n "$ts" ] || continue
    (( now - ts <= SUBMIT_COOLDOWN_S )) && return 0
  done <<<"$history"
  return 1
}

# Is a lock left behind by a dead or ancient process? $1 = pid, $2 = lock mtime
# (epoch), $3 = now (epoch).
lock_stale() {
  local pid="$1" mtime="$2" now="$3"
  [ -n "$pid" ] || return 0
  kill -0 "$pid" 2>/dev/null || return 0          # owner is gone
  (( now - mtime > LOCK_STALE_S )) && return 0    # owner is wedged
  return 1
}

# Did the text we tried to submit actually leave the composer?
#   $1 = pane captured after the key action, $2 = the text we submitted.
#
# Success is: a turn started, or the composer no longer holds THAT text. The
# second clause matters — on 2026-07-31 12:25 a peer agent's message was submitted
# correctly, the owner's NEXT message landed in the composer within the same second,
# and a plain "composer must be empty" check read that as a failure, so the
# watchdog disarmed itself for the hour and her next messages sat unsent.
#
# Guard against Enter merely reflowing the draft: if what sits there now still
# starts with what we submitted, nothing was sent.
submit_confirmed() {
  local pane="$1" expected="${2:-}" now_pending
  turn_active "$pane" && return 0
  now_pending="$(input_pending "$pane")"
  [ -z "$now_pending" ] && return 0
  [ -z "$expected" ] && return 1
  [ "$now_pending" = "$expected" ] && return 1
  case "$now_pending" in "$expected"*) return 1 ;; esac   # reflow / partial edit
  return 0                                                # a different message — ours went through
}

# Last N lines of the pane — the live status area. Detectors below MUST look only
# here: on 2026-07-31 an agent sat unrecovered because the words "1 shell" were still
# in its SCROLLBACK from an earlier turn, and a whole-pane grep read that as
# "the session is busy" forever.
pane_tail() {
  printf '%s\n' "$1" | grep -v '^[[:space:]]*$' | tail -n "${2:-3}"
}

# A background shell / MCP task holds the session: Claude Code treats it as busy
# and Enter does NOT submit (observed all through 2026-07-28). Pressing keys here
# achieves nothing and only risks landing them somewhere unintended — stand down
# and let the operator or the task itself resolve it.
session_held() {
  pane_tail "$1" 3 | grep -qE '[0-9]+ (shell|MCP task)|↓ to manage'
}

# A turn is generating (do not touch the composer).
turn_active() {
  pane_tail "$1" 3 | grep -qE 'esc to interrupt'
}

# the owner pressed /stop. The plugin's stop path sends a bare Escape into the pane:
# generation dies, but anything already sitting in the composer stays there, and
# the composer handler below reads that leftover as a stuck message and submits
# it — the agent resumes the very work she just stopped. Her words on
# 2026-08-01: «после стоп продолжают работу». The TUI marks the interrupt with
# one unmistakable line, so the watchdog can see it without any plugin change.
interrupted() {
  pane_tail "$1" 12 | grep -qF 'Interrupted ·'
}

# Must the composer handler stand down because of a /stop? Pure decision so the
# policy is unit-tested rather than inferred from the loop.
#   $1 = digest of the pending text
#   $2 = digest of what sat in the composer when the interrupt landed ("" if it
#        was empty)
#   $3 = interrupt epoch ("" when no interrupt is in effect)
#   $4 = now (epoch)
# Two rules. The text that was pending at the interrupt is dead for good — that
# is exactly the work she stopped. Anything else waits out a short grace window,
# which covers a message the plugin had already queued behind the dying turn.
stop_blocks_submit() {
  local digest="$1" poisoned="$2" at="$3" now="$4"
  [ -n "$poisoned" ] && [ "$digest" = "$poisoned" ] && return 0
  [ -n "$at" ] && (( now - at < STOP_GRACE_S )) && return 0
  return 1
}

# A modal / interactive picker owns the keyboard (spend limit / fable-credits /
# rate menu / session feedback survey / an AskUserQuestion select-list). Enter
# here means something OTHER than "submit composer" — e.g. it selects a menu
# option — so the stuck-composer handler must stand down. The select-list also
# renders its highlighted option with the same `❯` arrow the composer uses, so
# without this guard input_pending() mistakes the option text for pending input
# and the watchdog toggles the owner's choice every cycle. Its footer is unambiguous:
# "Enter to select · ↑/↓ to navigate · Esc to cancel".
# The session-feedback survey is especially dangerous: it renders as a bare
# numbered row ("1: Bad  2: Fine  3: Good  0: Dismiss") without its question
# text once scrolled, and it EATS Enter — that is how a peer agent sat silent on
# 2026-07-28. Match the option row itself, not just the question.
blocking_modal() {
  pane_tail "$1" 12 | grep -qiE \
    'monthly spend limit|Adjust monthly spend|rate-limit-options|Fable 5 now uses|How is Claude doing this session|Stop and wait for limit to reset|Enter to select|to navigate|Esc to cancel|0: Dismiss|1: Bad|Press Enter to continue|Paste code here|Login successful|Select login method'
}

# The session-feedback survey is the ONE modal the watchdog may clear by itself,
# because it is the only one whose dismissal is not a decision: "0: Dismiss"
# answers nothing. It has to be cleared, because while it is up Enter never
# reaches the composer and every inbound message queues behind it — on
# 2026-08-01 a peer agent held three of the owner's messages for eleven hours that way,
# with blocking_modal() correctly standing down and nothing else ever acting.
# Matched narrowly: the rating options must be present, so a spend-limit modal,
# a rate menu or an AskUserQuestion list can never be answered by accident. Read
# only the status area — a row left in the scrollback would otherwise make the
# watchdog append a stray "0" to whatever the owner is composing.
feedback_survey() {
  local tail
  tail=$(pane_tail "$1" 6)
  printf '%s\n' "$tail" | grep -qF '0: Dismiss' || return 1
  printf '%s\n' "$tail" | grep -qE '1: Bad|2: Fine|3: Good'
}

# ───── Give-up reporting: spool + owner alert ─────
# Every give-up path must leave a trace a human can find. Enabling retype
# (2026-09-22) shrank the give-up surface but did not remove it: retype itself
# can fail, and a pasted / multiline / truncated composer is never retyped.
# Until now only the retype-disabled branch spooled anything, so with retype on
# the remaining losses were completely silent — which is how six of the owner's
# messages died between 20 and 22.09 with nothing but a log line.
#
# spool_dropped: append the text once. Returns 1 when it was already spooled —
# the composer can still hold a line that was recorded (or answered) earlier,
# and re-spooling makes an old sentence resurface as if the owner had just written
# it (2026-09-09, «оплата пока вручную»).
spool_dropped() {
  local text="$1" spool="${2:-${DROPPED:-}}"
  [ -n "$text" ] || return 0
  [ -n "$spool" ] || return 0
  mkdir -p "$(dirname "$spool")" 2>/dev/null || true
  if grep -qxF "$text" \
       <(cut -f2- "$spool" 2>/dev/null; cut -f2- "${spool%.tsv}.seen.tsv" 2>/dev/null); then
    return 1
  fi
  printf '%s\t%s\n' "$(date -Is)" "$text" >> "$spool"
}

# report_dropped: spool, then alert the owner over the Bot API so a human hears
# about it. The alert script owns its own throttle and refuses to type into a
# busy session; a failure there is never fatal to the watchdog.
report_dropped() {
  local text="$1"
  if spool_dropped "$text"; then
    log "SPOOLED: ${text:0:60}"
  else
    log "SKIP-SPOOL: already spooled, not re-adding: ${text:0:40}"
  fi
  [ -x "$NOTIFY_SCRIPT" ] || return 0
  "$NOTIFY_SCRIPT" "$AGENT_NAME" "$text" >/dev/null 2>&1 || true
}

# pause_state: off | active | expired. Pure — takes the file, the max age and
# "now", so the expiry is testable without waiting an hour.
pause_state() {
  local file="$1" max="$2" now="$3" mtime
  [ -e "$file" ] || { printf 'off'; return 0; }
  mtime=$(stat -c %Y "$file" 2>/dev/null || printf '0')
  if [ "$max" -gt 0 ] && (( now - mtime >= max )); then
    printf 'expired'
  else
    printf 'active'
  fi
}

# ───── Test seam ─────
if [ "${RATEWATCH_TEST_ONLY:-}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

log "started; watching $SESSION every ${POLL_INTERVAL}s (rate-limit menu + stuck composer)"

# Safety budget: never press Enter more than MAX_PRESSES_PER_HOUR times. A
# runaway detector is far worse than a missed submit, so the watchdog disarms
# the composer handler for the rest of the hour once the budget is spent.
# Two independent valves. The generous one caps total key actions so a runaway
# detector cannot hammer the pane; the strict one counts only FAILED recoveries,
# because that is what "the watchdog is malfunctioning" actually looks like. The
# old single budget of 6 actions/h meant three rescued messages per hour, and on
# 2026-07-31 a live conversation exhausted it in minutes while the owner's later
# messages sat unsent.
MAX_PRESSES_PER_HOUR="${RATEWATCH_MAX_PRESSES:-24}"
MAX_FAILED_PER_HOUR="${RATEWATCH_MAX_FAILED:-3}"
STABLE_POLLS="${RATEWATCH_STABLE_POLLS:-2}"
# The survey either clears on the first "0" or something else is wrong.
MAX_SURVEY_FAILS="${RATEWATCH_MAX_SURVEY_FAILS:-2}"

presses=0
failures=0
window_start=$SECONDS
last_pending=""
last_ghost=""        # last prompt suggestion logged, so each one is logged once
stable_count=0
first_seen=0        # epoch when the current pending text was first observed
giveup_digest=""    # text we already failed to submit; skip it, keep serving others
survey_fails=0      # failed survey dismissals this hour
interrupt_at=""     # epoch of the /stop currently in effect ("" = none)
paused=0            # 1 while the stop file holds the watchdog down
interrupt_digest="" # text that sat in the composer when that /stop landed

# Exclusive keyboard ownership for this session. `mkdir` is atomic; the pid and
# the directory mtime let another actor decide whether a leftover lock is stale.
# Released on every exit path, including a crash inside the recovery block.
acquire_lock() {
  local now pid mtime
  now=$(date +%s)
  if mkdir "$LOCK_DIR" 2>/dev/null; then
    printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
    return 0
  fi
  pid=$(cat "$LOCK_DIR/pid" 2>/dev/null || printf '')
  mtime=$(stat -c %Y "$LOCK_DIR" 2>/dev/null || printf '0')
  if lock_stale "$pid" "$mtime" "$now"; then
    log "breaking stale submit lock (pid='${pid:-none}', age $(( now - mtime ))s)"
    rm -rf "$LOCK_DIR" 2>/dev/null || true
    if mkdir "$LOCK_DIR" 2>/dev/null; then
      printf '%s\n' "$$" >"$LOCK_DIR/pid" 2>/dev/null || true
      return 0
    fi
  fi
  return 1
}

release_lock() { rm -rf "$LOCK_DIR" 2>/dev/null || true; }
# A handler for INT/TERM must EXIT explicitly: a bare `trap cleanup TERM` runs the
# cleanup and then resumes the loop, which made SIGTERM a no-op and left old
# watchdogs alive across a redeploy (2026-07-31).
trap release_lock EXIT
trap 'release_lock; exit 143' INT TERM

record_submit() {
  printf '%s %s\n' "$1" "$(date +%s)" >>"$HISTORY_FILE" 2>/dev/null || true
  # Keep the history small; only the cooldown window matters.
  tail -50 "$HISTORY_FILE" >"$HISTORY_FILE.tmp" 2>/dev/null \
    && mv "$HISTORY_FILE.tmp" "$HISTORY_FILE" 2>/dev/null || true
}

while true; do
  # Roll the safety window every hour.
  if (( SECONDS - window_start >= 3600 )); then
    (( presses > 0 )) && log "hourly window rolled (actions: $presses, failures: $failures)"
    presses=0
    failures=0
    survey_fails=0
    window_start=$SECONDS
  fi

  # A pause outranks everything below: no Enter, no retype, no survey tap.
  case "$(pause_state "$PAUSE_FILE" "$PAUSE_MAX_S" "$(date +%s)")" in
    active)
      if [ "$paused" != "1" ]; then
        reason="$(head -c 120 "$PAUSE_FILE" 2>/dev/null | tr '\n' ' ')"
        log "PAUSED: $PAUSE_FILE present — standing down${reason:+ (${reason})}"
        paused=1
      fi
      last_pending=""; stable_count=0
      sleep "$POLL_INTERVAL"
      continue
      ;;
    expired)
      log "pause expired (older than ${PAUSE_MAX_S}s) — removing $PAUSE_FILE and resuming"
      rm -f "$PAUSE_FILE" 2>/dev/null || true
      paused=0
      ;;
    *)
      if [ "$paused" = "1" ]; then
        log "RESUMED: $PAUSE_FILE removed"
        paused=0
      fi
      ;;
  esac

  if tmux has-session -t "$SESSION" 2>/dev/null; then
    PANE=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null || true)

    if printf '%s' "$PANE" | grep -qF "$RATE_LIMIT_MARKER"; then
      log "rate-limit menu detected — sending '1' to dismiss"
      tmux send-keys -t "$SESSION" "1" Enter
      last_pending=""; stable_count=0
      sleep "$RATE_COOLDOWN"
      continue
    fi

    # Clear the feedback survey before looking at the composer: while it is up
    # nothing can be submitted, so an untouched survey silently freezes the agent.
    if feedback_survey "$PANE" && ! turn_active "$PANE" && ! session_held "$PANE"; then
      if (( survey_fails >= MAX_SURVEY_FAILS )); then
        : # tried and failed this hour — a human has to look; do not tap "0" forever
      elif (( presses + 1 > MAX_PRESSES_PER_HOUR )); then
        log "SAFETY: action budget spent ($presses/h) — leaving the feedback survey up"
      elif acquire_lock; then
        log "feedback survey blocking the composer — sending '0' to dismiss"
        tmux send-keys -t "$SESSION" "0"
        presses=$(( presses + 1 ))
        sleep "$ENTER_COOLDOWN"
        AFTER=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null || true)
        if feedback_survey "$AFTER"; then
          survey_fails=$(( survey_fails + 1 ))
          log "WARN: survey still up after '0' (${survey_fails}/${MAX_SURVEY_FAILS}) — human needed"
        else
          log "OK: feedback survey dismissed"
        fi
        # A "0" that lands after the widget already closed becomes literal text in
        # the composer. Never leave our own keystroke there: the stuck-composer
        # rule would otherwise submit it as if the owner had typed it (a peer agent,
        # 2026-09-22 04:05 — two dismissal taps merged into a "00" user message).
        residue="$(input_pending "$AFTER")"
        if [ -n "$residue" ] && printf '%s' "$residue" | grep -qE '^[01]{1,3}$'; then
          log "cleared own keystroke residue from composer: ${residue}"
          tmux send-keys -t "$SESSION" C-u
        fi
        release_lock
        last_pending=""; stable_count=0
        continue
      fi
    fi

    # Track /stop before touching the composer. The marker sits in the status
    # area until the next turn scrolls it away, so entering the state is
    # edge-triggered: the text pending at that first sighting is the one the owner
    # stopped, and it must never be typed back in.
    if interrupted "$PANE"; then
      if [ -z "$interrupt_at" ]; then
        interrupt_at=$(date +%s)
        interrupt_pending="$(input_pending "$PANE")"
        if [ -n "$interrupt_pending" ]; then
          interrupt_digest="$(text_digest "$interrupt_pending")"
          log "/stop detected — standing down ${STOP_GRACE_S}s; will never resubmit: ${interrupt_pending:0:50}"
        else
          interrupt_digest=""
          log "/stop detected — standing down ${STOP_GRACE_S}s (composer empty)"
        fi
      fi
    else
      interrupt_at=""; interrupt_digest=""
    fi

    pending="$(input_pending "$PANE")"
    if [ -n "$pending" ] \
      && composer_ghost "$(tmux capture-pane -t "$SESSION" -p -J -e 2>/dev/null || true)"; then
      # A prompt suggestion, not a message: never press Enter, never spool it.
      if [ "$pending" != "$last_ghost" ]; then
        log "SKIP: prompt suggestion (dim ghost text), not input: ${pending:0:40}"
        last_ghost="$pending"
      fi
      pending=""
    fi
    if [ -n "$pending" ] && ! turn_active "$PANE" && ! blocking_modal "$PANE" && ! session_held "$PANE"; then
      if [ "$pending" = "$last_pending" ]; then
        stable_count=$(( stable_count + 1 ))
      else
        last_pending="$pending"; stable_count=1; first_seen=$(date +%s)
      fi

      now_s=$(date +%s)
      pending_age=$(( now_s - first_seen ))

      if (( stable_count >= STABLE_POLLS && pending_age >= MIN_PENDING_AGE_S )); then
        # A recovery can spend TWO key actions (Enter, then the retype). Require
        # both slots up front so the escalation can never overrun the budget.
        if (( failures >= MAX_FAILED_PER_HOUR )); then
          log "SAFETY: $failures failed recoveries this hour — standing down, pending: ${pending:0:40}"
          last_pending=""; stable_count=0
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        if (( presses + 2 > MAX_PRESSES_PER_HOUR )); then
          log "SAFETY: action budget spent ($presses/h) — standing down, pending: ${pending:0:40}"
          last_pending=""; stable_count=0
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        # Same text already submitted moments ago? Then the pane is simply behind
        # reality — never send it twice.
        digest="$(text_digest "$pending")"
        if stop_blocks_submit "$digest" "$interrupt_digest" "$interrupt_at" "$now_s"; then
          log "SKIP: /stop in effect — not submitting: ${pending:0:40}"
          last_pending=""; stable_count=0
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        if [ -n "$giveup_digest" ] && [ "$digest" = "$giveup_digest" ]; then
          # Already failed on this exact text; a human has to look. Other
          # messages are still served.
          last_pending=""; stable_count=0
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        if submit_recently_done "$digest" "$now_s" "$(cat "$HISTORY_FILE" 2>/dev/null || printf '')"; then
          log "SKIP: this exact text was submitted <${SUBMIT_COOLDOWN_S}s ago: ${pending:0:40}"
          last_pending=""; stable_count=0
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        # Digits-only pending text is almost always our own menu keystroke ("0"
        # for the feedback survey, "1" for the rate menu) that missed its widget.
        # Clear it instead of submitting it as a user message; on the rare chance
        # it really was typed by a human, the log line below shows what was
        # dropped and the message can simply be sent again.
        if printf '%s' "$pending" | grep -qE '^[01]{1,3}$'; then
          log "SKIP: digits-only pending is our own keystroke — clearing: ${pending}"
          tmux send-keys -t "$SESSION" C-u
          last_pending=""; stable_count=0
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        # One actor at a time on this keyboard.
        if ! acquire_lock; then
          log "SKIP: submit lock held by another actor — standing down this pass"
          sleep "$ENTER_COOLDOWN"
          continue
        fi
        record_submit "$digest"
        log "stuck composer stable ${stable_count}x, age ${pending_age}s — pressing Enter: ${pending:0:50}"
        tmux send-keys -t "$SESSION" Enter
        presses=$(( presses + 1 ))
        sleep "$ENTER_COOLDOWN"

        # Verify a submit actually happened (empty composer or a started turn) —
        # not merely that the text changed.
        AFTER=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null || true)
        if submit_confirmed "$AFTER" "$pending"; then
          log "OK: submitted after Enter"
        else
          # Plain Enter does not reach the submit path in this TUI (0/12 on
          # 2026-07-31). What does work — verified by hand ~6/6 the same night —
          # is clearing the composer and retyping the text before Enter. Only
          # safe when the pane text IS the whole literal message.
          extra=$(composer_extra_lines "$AFTER")
          if [ "$ALLOW_RETYPE" != "1" ]; then
            # DISABLED 2026-08-02 after the replay incident. When Enter does not
            # submit, the thing on the composer line is very often NOT pending
            # input at all — it is a queued-message preview that Claude Code
            # renders with the same arrow. Retyping it resurrects an old message
            # of the owner's as a brand-new instruction, and the agent goes off and
            # does work she never asked for (a peer agent cycled «напиши еще три
            # поста» / «в драфты» / «запиши в handoff» for hours). Detection and
            # logging stay on; the keyboard does not.
            log "SKIP: Enter did not submit and retype is disabled — leaving it: ${pending:0:40}"
            report_dropped "$pending"
            failures=$(( failures + 1 ))
            giveup_digest="$digest"
          elif retype_safe "$pending" && [ "$extra" = "0" ]; then
            log "Enter did not submit — retyping: ${pending:0:50}"
            tmux send-keys -t "$SESSION" C-u
            # `--` stops tmux option parsing: a message starting with a dash
            # must never be read as a flag.
            tmux send-keys -t "$SESSION" -l -- "$pending"
            tmux send-keys -t "$SESSION" Enter
            presses=$(( presses + 1 ))
            sleep "$ENTER_COOLDOWN"
            AFTER=$(tmux capture-pane -t "$SESSION" -p -J 2>/dev/null || true)
            if submit_confirmed "$AFTER" "$pending"; then
              log "OK: submitted after retype"
            else
              log "WARN: retype did not submit either — human needed: ${pending:0:40}"
              report_dropped "$pending"
              failures=$(( failures + 1 ))
              # Give up on THIS text (the digest history already holds it, so it
              # will be skipped for SUBMIT_COOLDOWN_S) but stay armed for other
              # messages: a global disarm left the owner's later messages unsent.
              giveup_digest="$digest"
            fi
          else
            log "WARN: Enter did not submit; unsafe to retype (paste/multiline/truncated/extra=${extra}) — human needed: ${pending:0:40}"
            report_dropped "$pending"
            failures=$(( failures + 1 ))
            giveup_digest="$digest"
          fi
        fi
        release_lock
        last_pending=""; stable_count=0
        continue
      fi
    else
      last_pending=""; stable_count=0
    fi
  fi
  sleep "$POLL_INTERVAL"
done
