# Cross-surface memory Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a student works with one agent from Telegram (phone) and from Claude Code sessions in the
agent folder (Claude Desktop over SSH, terminal, Claude Code on the phone) and each surface sees what
the other did and can pick up the same task.

**Architecture:** the Telegram plugin already writes its turns to `core/hot/recent-plugin.md`; the kit
reserves `core/hot/recent.md` for a second channel and `write-handoff.sh` already merges both, but
nothing writes `recent.md`. One Node hook, `core/hooks/cross-surface.mjs`, fills the gap: in `stop`
mode (workspace settings only, so the bot never runs it) it appends the Claude Code turn to
`recent.md`; in `prompt` mode (both settings files) it injects the other surface's turns since the
session last looked, plus the shared task list `core/hot/tasks.md` when it changed. `update.sh`
migrates the owner's workspace `settings.json` in place; `CLAUDE.md` is never touched.

**Tech Stack:** Node 22 (stdlib only, like `local-recall.mjs`), bash, python3 for the settings
migration, `node --test` for unit tests, `tests/run-tests.sh` for install/update end-to-end.

**Spec:** this conversation (Kris, 2026-11-27): «Telegram и мак одновременно видят, что у каждого
творится, подхватывают задачи друг друга»; constraints verified in the kit code (see Global
Constraints).

## Global Constraints

- Verified: Claude Code reads project `settings.json` only from the session cwd (no walk-up, git root
  ignored). Bot cwd = `$PLUGIN_DIR` (plugin settings), Claude Code sessions in the agent folder use
  `$AGENT_WS/settings.json`. The `stop` writer goes ONLY into the workspace settings.
- The plugin's files (`recent-plugin.md`, `logs/verbose-*.jsonl`) are read-only for the new hook.
- Hot entry format = the plugin's: `\n### YYYY-MM-DD HH:MM [tag]\n**User:** …\n**<AGENT_NAME>:** …\n`,
  local time, minute precision (so `write-handoff.sh` sorts both files together).
- Claude Code entries: tag `claude-code`, header suffix ` <!-- s:<first 8 chars of session_id> -->`.
- Hook stdin/stdout: stdin JSON; prompt mode prints
  `{"hookSpecificOutput":{"hookEventName":"UserPromptSubmit","additionalContext":…}}` or nothing.
  Any error → exit 0, no output: memory must never break a turn.
- Stop hooks in one group run in parallel: the workspace Stop command is the chain
  `node $CLAUDE_PROJECT_DIR/.claude/hooks/cross-surface.mjs stop; $CLAUDE_PROJECT_DIR/.claude/hooks/write-handoff.sh`.
- Secret redaction = the patterns of `write-handoff.sh`, applied before writing `recent.md`.
- Caps: user snippet 300 chars, agent snippet 600, news ≤ 8 entries and ≤ 3500 chars,
  tasks ≤ 2500 chars, `recent.md` self-trim above 24 KiB to the last 40 entries, state files
  older than 7 days removed.
- `update.sh` never rewrites owner data: settings migration only adds/rewrites the two kit hook
  commands, keeps every other key, is idempotent, is backed up and restored on rollback.

## Review Focus

1. A Claude Code session open since morning must still get the afternoon's Telegram turns —
   test `prompt: tg turns written after the session started are injected once`.
2. Two Claude Code sessions (mac + phone) see each other but never themselves — test
   `prompt claude-code: other claude-code sessions are news, own entries are not`.
3. Several turns inside one minute — none lost, none repeated — test `same-minute entries`.
4. Stop fires before the final text reaches the transcript — `last_assistant_message` is preferred,
   transcript only as fallback — tests `stop uses last_assistant_message` and `stop falls back to transcript`.
5. An owner who edited `settings.json` by hand keeps her edits — test `migrate keeps custom keys`.

---

### Task 1: `cross-surface.mjs stop` — write Claude Code turns to `recent.md`

**Files:**
- Create: `core/hooks/cross-surface.mjs`
- Test: `tests/cross-surface.test.mjs`

**Interfaces:**
- Produces: CLI `node cross-surface.mjs stop` (stdin: `{session_id, transcript_path, last_assistant_message?}`);
  CLI `node cross-surface.mjs prompt --self tg|claude-code` (Task 2). Workspace root =
  `$CLAUDE_PROJECT_DIR/.claude`, else the script's parent dir. State:
  `<ws>/state/cross-surface/<sid>.json` = `{cursorTs, seen: string[], tasksHash, pendingPrompt}`.
- Exported for tests (`export function`): `parseEntries(text, channel) -> {ts, tag, sid, key, text}[]`.

- [ ] Tests (temp workspace with `agent.conf` `AGENT_NAME="zub"`):
  `stop uses last_assistant_message` (header regex
  `^### \d{4}-\d{2}-\d{2} \d{2}:\d{2} \[claude-code\] <!-- s:abcd1234 -->$`, `**User:** <pendingPrompt>`,
  `**zub:** <text>`); `stop falls back to transcript` (skips isMeta, isCompactSummary, tool_result-only
  user records; takes the last assistant text after the last real prompt);
  `stop redacts secrets` (a `123456789:` + 35-char Telegram token becomes `***REDACTED-TELEGRAM-TOKEN***`);
  `stop self-trims recent.md` (file > 24 KiB → header + 40 entries); `stop on garbage stdin exits 0, writes nothing`.
- [ ] Run `node --test tests/cross-surface.test.mjs` → FAIL (module missing).
- [ ] Implement stop mode.
- [ ] Run → PASS. Commit.

### Task 2: `cross-surface.mjs prompt` — inject the other surface's news and the task list

**Files:** Modify `core/hooks/cross-surface.mjs`; Create `core/templates/core/hot/tasks.md.template`;
Test `tests/cross-surface.test.mjs`.

- [ ] Tests: `prompt: first call injects the task rule, no news, creates state`;
  `prompt: tg turns written after the session started are injected once`;
  `prompt claude-code: other claude-code sessions are news, own entries are not`;
  `prompt tg: only recent.md entries are news`; `same-minute entries`;
  `tasks injected when changed, silent when unchanged`; `news capped at 8 entries with a "more" note`;
  `prompt claude-code saves pendingPrompt` (consumed by stop); `missing files → no output, exit 0`.
- [ ] Run → FAIL. Implement. Run → PASS. Commit.

Cursor rule: on each prompt, news = other-surface entries with `ts > cursorTs` or
(`ts == cursorTs` and `key ∉ seen`); then `cursorTs = max ts of all entries`, `seen = keys at cursorTs`.
First prompt of a session (no state): no news (handoff.md is already in its context), cursor set.
Task rule text (English, injected on the first prompt and whenever tasks are shown): the shared list
is `core/hot/tasks.md`; when starting, advancing, finishing or pausing a multi-step task, update its
line (task, where it is, next step, which surface holds it).

### Task 3: wire it in — templates, install, update migration

**Files:**
- Modify: `core/templates/settings.json.template` (Stop chain, UserPromptSubmit `prompt --self claude-code`)
- Modify: `server/templates/plugin-settings.json.template` (UserPromptSubmit
  `CLAUDE_PROJECT_DIR={{AGENT_HOME}} node {{AGENT_WS}}/hooks/cross-surface.mjs prompt --self tg`)
- Create: `scripts/migrate-ws-settings.py <settings.json>` → prints `changed`/`unchanged`, exit 1 on bad JSON (file untouched)
- Modify: `install-server.sh` (copy `tasks.md` template), `update.sh` (backup `settings.json` into
  `$BAK/ws/`, migrate after the hooks swap, create `tasks.md` if missing, restore on rollback;
  bad JSON → warning, update continues)
- Modify: `tests/run-tests.sh` (node unit tests; migration cases; install + update e2e; py_compile)
- Modify: `ARCHITECTURE.md` (memory section), `README.md` (one paragraph for students)

- [ ] Tests: `migrate: old template gets both hooks`; `migrate: second run unchanged`;
  `migrate: current template unchanged`; `migrate keeps custom keys` (extra hook + env + permissions
  survive); `migrate: settings without write-handoff get a new Stop group`; `migrate: bad JSON exit 1,
  file untouched`; e2e `install: tasks.md + cross-surface hooks in both settings`;
  `update: old workspace settings migrated, backup has ws/settings.json`;
  `handoff merges a claude-code entry with a tg entry in time order`.
- [ ] Run `bash tests/run-tests.sh` → new checks FAIL. Implement. Full suite PASS. Commit.

### Task 4: live check on a throwaway agent folder

- [ ] Real `claude` session (fresh config, owner's token NOT copied) in a temp agent layout:
  two turns from the "workspace" cwd, one fake tg entry appended → next prompt shows it;
  `recent.md` and `handoff.md` contain the Claude Code turns.
- [ ] Code review (fresh reviewer, whole branch). PR to main.
