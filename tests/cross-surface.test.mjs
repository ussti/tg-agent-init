// cross-surface.test.mjs -- unit tests for core/hooks/cross-surface.mjs.
// Run: node --test tests/cross-surface.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = path.dirname(fileURLToPath(import.meta.url));
const HOOK = path.join(HERE, '..', 'core', 'hooks', 'cross-surface.mjs');
const TASKS_TPL = path.join(HERE, '..', 'core', 'templates', 'core', 'hot', 'tasks.md.template');
const SID_A = 'abcd1234-0000-0000-0000-000000000001';
const SID_B = 'beef5678-0000-0000-0000-000000000002';
const TG_TOKEN = '123456789:' + 'A'.repeat(35);
const DAY_MS = 24 * 3600 * 1000;

/** Throwaway agent home: <home>/.claude with agent.conf and core/hot. */
function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'xsurf-'));
  const ws = path.join(home, '.claude');
  fs.mkdirSync(path.join(ws, 'core', 'hot'), { recursive: true });
  fs.writeFileSync(path.join(ws, 'agent.conf'), 'AGENT_NAME="zub"\nAGENT_HOME="x"\n');
  return { home, ws, hot: path.join(ws, 'core', 'hot') };
}

/** Run the hook; `now` is "YYYY-MM-DDTHH:MM" local time, null for the real clock. */
function run(home, args, stdin, now = '2026-11-27T10:00', extraEnv = {}) {
  const env = { ...process.env, CLAUDE_PROJECT_DIR: home, ...extraEnv };
  if (now) env.CROSS_SURFACE_NOW = now; else delete env.CROSS_SURFACE_NOW;
  const r = spawnSync('node', [HOOK, ...args], {
    input: typeof stdin === 'string' ? stdin : JSON.stringify(stdin),
    env,
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

/** UserPromptSubmit as `self`; returns the injected context or ''. */
function ask(home, self, sid, prompt, now) {
  const out = run(home, ['prompt', '--self', self], { session_id: sid, prompt }, now);
  if (!out) return '';
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
  return j.hookSpecificOutput.additionalContext;
}

function reply(home, sid, text, now) {
  run(home, ['stop'], { session_id: sid, last_assistant_message: text }, now);
}

function tgEntry(hot, ts, user, agent) {
  fs.appendFileSync(path.join(hot, 'recent-plugin.md'),
    `\n### ${ts} [tg]\n**User:** ${user}\n**zub:** ${agent}\n`);
}

function readRecent(hot) {
  return fs.readFileSync(path.join(hot, 'recent.md'), 'utf8');
}

// Transcript records in Claude Code's JSONL shape.
const userRec = (content, extra = {}) =>
  ({ type: 'user', ...extra, message: { role: 'user', content } });
const botRec = (...blocks) =>
  ({ type: 'assistant', message: { role: 'assistant', content: blocks } });
const txt = (text) => ({ type: 'text', text });

function transcript(home, records) {
  const p = path.join(home, 'transcript.jsonl');
  fs.writeFileSync(p, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  return p;
}

// ---------------------------------------------------------------- stop

test('stop uses last_assistant_message', () => {
  const { home, hot } = makeHome();
  ask(home, 'claude-code', SID_A, 'set up zoom');
  reply(home, SID_A, 'Zoom is connected.', '2026-11-27T10:05');
  const text = readRecent(hot);
  assert.match(text, /^### 2026-11-27 10:05 \[claude-code\] <!-- s:abcd1234 -->$/m);
  assert.match(text, /^\*\*User:\*\* set up zoom$/m);
  assert.match(text, /^\*\*zub:\*\* Zoom is connected\.$/m);
});

test('stop falls back to transcript', () => {
  const { home, hot } = makeHome();
  const tp = transcript(home, [
    userRec('old question'),
    botRec(txt('old answer')),
    userRec('plan the flight'),
    userRec('<system-reminder>x</system-reminder>', { isMeta: true }),
    botRec(txt('checking'), { type: 'tool_use', id: 't', name: 'Bash', input: {} }),
    userRec([{ type: 'tool_result', tool_use_id: 't', content: 'ok' }]),
    botRec({ type: 'thinking', thinking: 'hm' }),
    botRec(txt('Flight plan\n  is   ready.')),
  ]);
  run(home, ['stop'], { session_id: SID_A, transcript_path: tp });
  const text = readRecent(hot);
  assert.match(text, /^\*\*User:\*\* plan the flight$/m);
  assert.match(text, /^\*\*zub:\*\* Flight plan is ready\.$/m);
  assert.doesNotMatch(text, /old answer|checking/);
});

test('stop skips a compaction summary as the prompt', () => {
  const { home, hot } = makeHome();
  const tp = transcript(home, [
    userRec('real prompt'),
    userRec('This session is being continued', { isCompactSummary: true }),
    botRec(txt('done')),
  ]);
  run(home, ['stop'], { session_id: SID_A, transcript_path: tp });
  assert.match(readRecent(hot), /^\*\*User:\*\* real prompt$/m);
});

test('stop redacts secrets', () => {
  const { home, hot } = makeHome();
  reply(home, SID_A, `token ${TG_TOKEN} saved`);
  const text = readRecent(hot);
  assert.ok(!text.includes(TG_TOKEN));
  assert.match(text, /\*\*\*REDACTED-TELEGRAM-TOKEN\*\*\*/);
});

test('stop truncates long snippets', () => {
  const { home, hot } = makeHome();
  reply(home, SID_A, 'x'.repeat(5000));
  const line = readRecent(hot).split('\n').find((l) => l.startsWith('**zub:**'));
  assert.ok(line.length < 700, String(line.length));
});

test('stop self-trims recent.md', () => {
  const { home, hot } = makeHome();
  let big = '# Hot memory\n';
  for (let i = 0; i < 120; i++) {
    const hh = String(i % 24).padStart(2, '0');
    big += `\n### 2026-11-26 ${hh}:00 [claude-code] <!-- s:00000000 -->\n` +
      `**User:** q${i}\n**zub:** ${'y'.repeat(300)}\n`;
  }
  fs.writeFileSync(path.join(hot, 'recent.md'), big);
  reply(home, SID_A, 'latest');
  const text = readRecent(hot);
  assert.ok(text.startsWith('# Hot memory'));
  assert.equal((text.match(/^### /gm) || []).length, 40);
  assert.match(text, /latest/);
});

test('stop with neither prompt nor text writes nothing', () => {
  const { home, hot } = makeHome();
  run(home, ['stop'], { session_id: SID_A });
  assert.ok(!fs.existsSync(path.join(hot, 'recent.md')));
});

test('stop on garbage stdin exits 0, writes nothing', () => {
  const { home, hot } = makeHome();
  run(home, ['stop'], 'not json');
  assert.ok(!fs.existsSync(path.join(hot, 'recent.md')));
});

// ---------------------------------------------------------------- prompt

test('prompt: first call injects the task rule, no news already in handoff', () => {
  const { home, hot, ws } = makeHome();
  tgEntry(hot, '2026-11-27 09:00', 'morning', 'seen at start');
  fs.copyFileSync(path.join(hot, 'recent-plugin.md'), path.join(hot, 'handoff.md'));
  const ctx = ask(home, 'claude-code', SID_A, 'hi');
  assert.ok(ctx.includes(`Shared task list: ${path.join(hot, 'tasks.md')}`), ctx);
  assert.doesNotMatch(ctx, /seen at start/);
  const stateFile = path.join(ws, 'state', 'cross-surface', `${SID_A}.json`);
  assert.equal(fs.statSync(stateFile).mode & 0o777, 0o600);
  assert.equal(fs.statSync(path.dirname(stateFile)).mode & 0o777, 0o700);
});

test('prompt: first call gets other-surface turns newer than the handoff', () => {
  const { home, hot } = makeHome();
  tgEntry(hot, '2026-11-27 09:00', 'morning', 'in handoff');
  fs.copyFileSync(path.join(hot, 'recent-plugin.md'), path.join(hot, 'handoff.md'));
  tgEntry(hot, '2026-11-27 09:00', 'same minute', 'same-minute-not-in-handoff');
  tgEntry(hot, '2026-11-27 09:30', 'later', 'newer than handoff');
  const ctx = ask(home, 'claude-code', SID_A, 'continue on the mac', '2026-11-27T09:31');
  assert.match(ctx, /newer than handoff/);
  assert.match(ctx, /same-minute-not-in-handoff/);
  assert.doesNotMatch(ctx, /in handoff\b/);
});

test('entries use the agent timezone from agent.conf', () => {
  const { home, ws, hot } = makeHome();
  fs.appendFileSync(path.join(ws, 'agent.conf'), 'TZ="Asia/Makassar"\n');
  const fmt = () => new Intl.DateTimeFormat('sv-SE', {
    timeZone: 'Asia/Makassar', year: 'numeric', month: '2-digit', day: '2-digit',
    hour: '2-digit', minute: '2-digit', hourCycle: 'h23',
  }).format(new Date()).replace('T', ' ');
  const before = fmt();
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: 'tz' }, null, { TZ: 'UTC' });
  const after = fmt();
  const ts = readRecent(hot).match(/^### (\S+ \S+) \[claude-code\]/m)[1];
  assert.ok(ts === before || ts === after, `${ts} vs ${before}/${after}`);
});

test('pending prompt is stored redacted and cut', () => {
  const { home, ws } = makeHome();
  ask(home, 'claude-code', SID_A, `my token ${TG_TOKEN} ${'w'.repeat(2000)}`);
  const raw = fs.readFileSync(path.join(ws, 'state', 'cross-surface', `${SID_A}.json`), 'utf8');
  assert.ok(!raw.includes(TG_TOKEN));
  assert.ok(raw.length < 800, String(raw.length));
});

test("a session's own tasks.md edit is not re-injected to it", () => {
  const { home, hot } = makeHome();
  ask(home, 'claude-code', SID_A, 'start');
  fs.writeFileSync(path.join(hot, 'tasks.md'), '- Zoom -- link -- next: send -- claude-code\n');
  reply(home, SID_A, 'added the task');
  assert.doesNotMatch(ask(home, 'claude-code', SID_A, 'next'), /Zoom -- link/);
  assert.match(ask(home, 'tg', SID_B, 'from the phone'), /Zoom -- link/);
});

test('task lines starting with # and a number are kept', () => {
  const { home, hot } = makeHome();
  fs.writeFileSync(path.join(hot, 'tasks.md'), '# Tasks\n\n#1 Flight plan -- tg\n');
  assert.match(ask(home, 'tg', SID_B, 'x'), /#1 Flight plan/);
});

test('a stale lock does not block the writer', () => {
  const { home, hot } = makeHome();
  const lock = path.join(hot, 'recent.md.lock');
  fs.writeFileSync(lock, '');
  const past = new Date(Date.now() - 60 * 1000);
  fs.utimesSync(lock, past, past);
  reply(home, SID_A, 'after stale lock');
  assert.match(readRecent(hot), /after stale lock/);
  assert.ok(!fs.existsSync(lock));
});

test('a held lock delays the writer but never drops the turn', () => {
  const { home, hot } = makeHome();
  fs.writeFileSync(path.join(hot, 'recent.md.lock'), '');
  reply(home, SID_A, 'despite fresh lock');
  assert.match(readRecent(hot), /despite fresh lock/);
});

test('prompt: tg turns written after the session started are injected once', () => {
  const { home, hot } = makeHome();
  ask(home, 'claude-code', SID_A, 'hi', '2026-11-27T09:00');
  tgEntry(hot, '2026-11-27 15:10', 'reminder for 19:00?', 'Set for 19:00 Bali.');
  const ctx = ask(home, 'claude-code', SID_A, 'what happened', '2026-11-27T16:00');
  assert.match(ctx, /Set for 19:00 Bali\./);
  assert.match(ctx, /\[tg 2026-11-27 15:10\]/);
  const again = ask(home, 'claude-code', SID_A, 'and now', '2026-11-27T16:01');
  assert.doesNotMatch(again, /Set for 19:00 Bali\./);
});

test('prompt claude-code: other claude-code sessions are news, own entries are not', () => {
  const { home } = makeHome();
  ask(home, 'claude-code', SID_A, 'a1', '2026-11-27T09:00');
  ask(home, 'claude-code', SID_B, 'b1', '2026-11-27T09:00');
  reply(home, SID_A, 'from mac', '2026-11-27T09:01');
  reply(home, SID_B, 'from phone', '2026-11-27T09:02');
  const ctxA = ask(home, 'claude-code', SID_A, 'a2', '2026-11-27T09:03');
  assert.match(ctxA, /from phone/);
  assert.doesNotMatch(ctxA, /from mac/);
});

test('prompt tg: only recent.md entries are news', () => {
  const { home, hot } = makeHome();
  ask(home, 'tg', SID_B, 'x', '2026-11-27T09:00');
  tgEntry(hot, '2026-11-27 09:05', 'tg q', 'tg own answer');
  reply(home, SID_A, 'mac work', '2026-11-27T09:06');
  const ctx = ask(home, 'tg', SID_B, 'y', '2026-11-27T09:07');
  assert.match(ctx, /mac work/);
  assert.doesNotMatch(ctx, /tg own answer/);
});

test('same-minute entries', () => {
  const { home, hot } = makeHome();
  ask(home, 'claude-code', SID_A, 'x', '2026-11-27T09:00');
  tgEntry(hot, '2026-11-27 09:05', 'q1', 'first in minute');
  const c1 = ask(home, 'claude-code', SID_A, 'y', '2026-11-27T09:05');
  assert.match(c1, /first in minute/);
  tgEntry(hot, '2026-11-27 09:05', 'q2', 'second in minute');
  const c2 = ask(home, 'claude-code', SID_A, 'z', '2026-11-27T09:05');
  assert.match(c2, /second in minute/);
  assert.doesNotMatch(c2, /first in minute/);
});

test('tasks injected when changed, silent when unchanged', () => {
  const { home, hot } = makeHome();
  const tasks = path.join(hot, 'tasks.md');
  fs.writeFileSync(tasks, '# Tasks\n\n- Zoom for Dmitry -- mac -- next: test link\n');
  assert.match(ask(home, 'tg', SID_B, 'x'), /Zoom for Dmitry/);
  assert.doesNotMatch(ask(home, 'tg', SID_B, 'y'), /Zoom for Dmitry/);
  fs.appendFileSync(tasks, '- Flight plan -- tg -- next: send to managers\n');
  assert.match(ask(home, 'tg', SID_B, 'z'), /Flight plan/);
});

test('news capped at 8 entries with a "more" note', () => {
  const { home, hot } = makeHome();
  ask(home, 'claude-code', SID_A, 'x', '2026-11-27T08:00');
  for (let i = 0; i < 20; i++) {
    tgEntry(hot, `2026-11-27 09:${String(i).padStart(2, '0')}`, `q${i}`, `answer-${i}-end`);
  }
  const ctx = ask(home, 'claude-code', SID_A, 'y', '2026-11-27T10:00');
  assert.equal((ctx.match(/answer-\d+-end/g) || []).length, 8);
  assert.match(ctx, /answer-19-end/);
  assert.doesNotMatch(ctx, /answer-11-end/);
  assert.match(ctx, /12 earlier/);
  assert.ok(ctx.length < 5000, String(ctx.length));
});

test('template-only tasks.md counts as empty', () => {
  const { home, hot } = makeHome();
  fs.copyFileSync(TASKS_TPL, path.join(hot, 'tasks.md'));
  const ctx = ask(home, 'tg', SID_B, 'x');
  assert.doesNotMatch(ctx, /Shared task list \(core/);
  assert.doesNotMatch(ctx, /Zoom for the client/);
});

test('long news entries keep the block under the size cap', () => {
  const { home, hot } = makeHome();
  ask(home, 'claude-code', SID_A, 'x', '2026-11-27T08:00');
  for (let i = 0; i < 8; i++) {
    tgEntry(hot, `2026-11-27 09:0${i}`, `q${i}`, `${'z'.repeat(900)} big-${i}`);
  }
  const ctx = ask(home, 'claude-code', SID_A, 'y', '2026-11-27T10:00');
  assert.ok(ctx.length < 5000, String(ctx.length));
  assert.match(ctx, /big-7/);
  assert.match(ctx, /earlier not shown/);
});

test('prompt tg does not save a pending prompt', () => {
  const { home, ws } = makeHome();
  ask(home, 'tg', SID_B, 'secret-ish');
  const stateFile = path.join(ws, 'state', 'cross-surface', `${SID_B}.json`);
  assert.equal(JSON.parse(fs.readFileSync(stateFile, 'utf8')).pendingPrompt ?? null, null);
});

test('missing files and bad input give no output', () => {
  const { home } = makeHome();
  assert.equal(run(home, ['prompt', '--self', 'claude-code'], 'garbage'), '');
  assert.equal(run(home, ['prompt'], { session_id: SID_A, prompt: 'x' }), '');
  assert.equal(run(home, ['bogus'], { session_id: SID_A }), '');
});

test('old state files are cleaned up', () => {
  const { home, ws } = makeHome();
  const dir = path.join(ws, 'state', 'cross-surface');
  fs.mkdirSync(dir, { recursive: true });
  const old = path.join(dir, 'old-session.json');
  fs.writeFileSync(old, '{}');
  const past = new Date(Date.now() - 8 * DAY_MS);
  fs.utimesSync(old, past, past);
  ask(home, 'claude-code', SID_A, 'x');
  assert.ok(!fs.existsSync(old));
});
