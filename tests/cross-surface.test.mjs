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
const SID_A = 'abcd1234-0000-0000-0000-000000000001';
const SID_B = 'beef5678-0000-0000-0000-000000000002';
const TG_TOKEN = '123456789:' + 'A'.repeat(35);

/** Throwaway agent home: <home>/.claude with agent.conf and core/hot. */
function makeHome() {
  const home = fs.mkdtempSync(path.join(os.tmpdir(), 'xsurf-'));
  const ws = path.join(home, '.claude');
  fs.mkdirSync(path.join(ws, 'core', 'hot'), { recursive: true });
  fs.writeFileSync(path.join(ws, 'agent.conf'), 'AGENT_NAME="zub"\nAGENT_HOME="x"\n');
  return { home, ws, hot: path.join(ws, 'core', 'hot') };
}

/** Run the hook; `now` is "YYYY-MM-DDTHH:MM" local time. */
function run(home, args, stdin, now = '2026-11-27T10:00') {
  const r = spawnSync('node', [HOOK, ...args], {
    input: typeof stdin === 'string' ? stdin : JSON.stringify(stdin),
    env: { ...process.env, CLAUDE_PROJECT_DIR: home, CROSS_SURFACE_NOW: now },
    encoding: 'utf8',
  });
  assert.equal(r.status, 0, r.stderr);
  return r.stdout;
}

function context(out) {
  if (!out) return '';
  const j = JSON.parse(out);
  assert.equal(j.hookSpecificOutput.hookEventName, 'UserPromptSubmit');
  return j.hookSpecificOutput.additionalContext;
}

function tgEntry(hot, ts, user, agent) {
  fs.appendFileSync(path.join(hot, 'recent-plugin.md'),
    `\n### ${ts} [tg]\n**User:** ${user}\n**zub:** ${agent}\n`);
}

function readRecent(hot) {
  return fs.readFileSync(path.join(hot, 'recent.md'), 'utf8');
}

function transcript(home, records) {
  const p = path.join(home, 'transcript.jsonl');
  fs.writeFileSync(p, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  return p;
}

// ---------------------------------------------------------------- stop

test('stop uses last_assistant_message', () => {
  const { home, hot } = makeHome();
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'set up zoom' });
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: 'Zoom is connected.' },
    '2026-11-27T10:05');
  const text = readRecent(hot);
  assert.match(text, /^### 2026-11-27 10:05 \[claude-code\] <!-- s:abcd1234 -->$/m);
  assert.match(text, /^\*\*User:\*\* set up zoom$/m);
  assert.match(text, /^\*\*zub:\*\* Zoom is connected\.$/m);
});

test('stop falls back to transcript', () => {
  const { home, hot } = makeHome();
  const tp = transcript(home, [
    { type: 'user', message: { role: 'user', content: 'old question' } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'old answer' }] } },
    { type: 'user', message: { role: 'user', content: 'plan the flight' } },
    { type: 'user', isMeta: true, message: { role: 'user', content: '<system-reminder>x</system-reminder>' } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'checking' }, { type: 'tool_use', id: 't', name: 'Bash', input: {} }] } },
    { type: 'user', message: { role: 'user', content: [{ type: 'tool_result', tool_use_id: 't', content: 'ok' }] } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'thinking', thinking: 'hm' }] } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'Flight plan\n  is   ready.' }] } },
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
    { type: 'user', message: { role: 'user', content: 'real prompt' } },
    { type: 'user', isCompactSummary: true, message: { role: 'user', content: 'This session is being continued' } },
    { type: 'assistant', message: { role: 'assistant', content: [{ type: 'text', text: 'done' }] } },
  ]);
  run(home, ['stop'], { session_id: SID_A, transcript_path: tp });
  assert.match(readRecent(hot), /^\*\*User:\*\* real prompt$/m);
});

test('stop redacts secrets', () => {
  const { home, hot } = makeHome();
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: `token ${TG_TOKEN} saved` });
  const text = readRecent(hot);
  assert.ok(!text.includes(TG_TOKEN));
  assert.match(text, /\*\*\*REDACTED-TELEGRAM-TOKEN\*\*\*/);
});

test('stop truncates long snippets', () => {
  const { home, hot } = makeHome();
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: 'x'.repeat(5000) });
  const line = readRecent(hot).split('\n').find((l) => l.startsWith('**zub:**'));
  assert.ok(line.length < 700, String(line.length));
});

test('stop self-trims recent.md', () => {
  const { home, hot } = makeHome();
  let big = '# Hot memory\n';
  for (let i = 0; i < 120; i++) {
    big += `\n### 2026-11-26 ${String(i % 24).padStart(2, '0')}:00 [claude-code] <!-- s:00000000 -->\n` +
      `**User:** q${i}\n**zub:** ${'y'.repeat(300)}\n`;
  }
  fs.writeFileSync(path.join(hot, 'recent.md'), big);
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: 'latest' });
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

test('prompt: first call injects the task rule, no news, creates state', () => {
  const { home, hot, ws } = makeHome();
  tgEntry(hot, '2026-11-27 09:00', 'morning', 'seen at start');
  const ctx = context(run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'hi' }));
  assert.match(ctx, /core\/hot\/tasks\.md/);
  assert.doesNotMatch(ctx, /seen at start/);
  assert.ok(fs.existsSync(path.join(ws, 'state', 'cross-surface', `${SID_A}.json`)));
});

test('prompt: tg turns written after the session started are injected once', () => {
  const { home, hot } = makeHome();
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'hi' }, '2026-11-27T09:00');
  tgEntry(hot, '2026-11-27 15:10', 'reminder for 19:00?', 'Set for 19:00 Bali.');
  const ctx = context(run(home, ['prompt', '--self', 'claude-code'],
    { session_id: SID_A, prompt: 'what happened' }, '2026-11-27T16:00'));
  assert.match(ctx, /Set for 19:00 Bali\./);
  assert.match(ctx, /\[tg 2026-11-27 15:10\]/);
  const again = context(run(home, ['prompt', '--self', 'claude-code'],
    { session_id: SID_A, prompt: 'and now' }, '2026-11-27T16:01'));
  assert.doesNotMatch(again, /Set for 19:00 Bali\./);
});

test('prompt claude-code: other claude-code sessions are news, own entries are not', () => {
  const { home } = makeHome();
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'a1' }, '2026-11-27T09:00');
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_B, prompt: 'b1' }, '2026-11-27T09:00');
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: 'from mac' }, '2026-11-27T09:01');
  run(home, ['stop'], { session_id: SID_B, last_assistant_message: 'from phone' }, '2026-11-27T09:02');
  const ctxA = context(run(home, ['prompt', '--self', 'claude-code'],
    { session_id: SID_A, prompt: 'a2' }, '2026-11-27T09:03'));
  assert.match(ctxA, /from phone/);
  assert.doesNotMatch(ctxA, /from mac/);
});

test('prompt tg: only recent.md entries are news', () => {
  const { home, hot } = makeHome();
  run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'x' }, '2026-11-27T09:00');
  tgEntry(hot, '2026-11-27 09:05', 'tg q', 'tg own answer');
  run(home, ['stop'], { session_id: SID_A, last_assistant_message: 'mac work' }, '2026-11-27T09:06');
  const ctx = context(run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'y' },
    '2026-11-27T09:07'));
  assert.match(ctx, /mac work/);
  assert.doesNotMatch(ctx, /tg own answer/);
});

test('same-minute entries', () => {
  const { home, hot } = makeHome();
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'x' }, '2026-11-27T09:00');
  tgEntry(hot, '2026-11-27 09:05', 'q1', 'first in minute');
  const c1 = context(run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'y' },
    '2026-11-27T09:05'));
  assert.match(c1, /first in minute/);
  tgEntry(hot, '2026-11-27 09:05', 'q2', 'second in minute');
  const c2 = context(run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'z' },
    '2026-11-27T09:05'));
  assert.match(c2, /second in minute/);
  assert.doesNotMatch(c2, /first in minute/);
});

test('tasks injected when changed, silent when unchanged', () => {
  const { home, hot } = makeHome();
  const tasks = path.join(hot, 'tasks.md');
  fs.writeFileSync(tasks, '# Tasks\n\n- Zoom for Dmitry -- mac -- next: test link\n');
  const c1 = context(run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'x' }));
  assert.match(c1, /Zoom for Dmitry/);
  const c2 = context(run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'y' }));
  assert.doesNotMatch(c2, /Zoom for Dmitry/);
  fs.appendFileSync(tasks, '- Flight plan -- tg -- next: send to managers\n');
  const c3 = context(run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'z' }));
  assert.match(c3, /Flight plan/);
});

test('news capped at 8 entries with a "more" note', () => {
  const { home, hot } = makeHome();
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'x' }, '2026-11-27T08:00');
  for (let i = 0; i < 20; i++) {
    tgEntry(hot, `2026-11-27 09:${String(i).padStart(2, '0')}`, `q${i}`, `answer-${i}-end`);
  }
  const ctx = context(run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'y' },
    '2026-11-27T10:00'));
  assert.equal((ctx.match(/answer-\d+-end/g) || []).length, 8);
  assert.match(ctx, /answer-19-end/);
  assert.doesNotMatch(ctx, /answer-11-end/);
  assert.match(ctx, /12 earlier/);
  assert.ok(ctx.length < 5000, String(ctx.length));
});

test('template-only tasks.md counts as empty', () => {
  const { home, hot } = makeHome();
  const tpl = path.join(HERE, '..', 'core', 'templates', 'core', 'hot', 'tasks.md.template');
  fs.copyFileSync(tpl, path.join(hot, 'tasks.md'));
  const ctx = context(run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'x' }));
  assert.doesNotMatch(ctx, /Shared task list \(core/);
  assert.doesNotMatch(ctx, /Zoom for the client/);
});

test('long news entries keep the block under the size cap', () => {
  const { home, hot } = makeHome();
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'x' }, '2026-11-27T08:00');
  for (let i = 0; i < 8; i++) {
    tgEntry(hot, `2026-11-27 09:0${i}`, `q${i}`, `${'z'.repeat(900)} big-${i}`);
  }
  const ctx = context(run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'y' },
    '2026-11-27T10:00'));
  assert.ok(ctx.length < 5000, String(ctx.length));
  assert.match(ctx, /big-7/);
  assert.match(ctx, /earlier not shown/);
});

test('prompt tg does not save a pending prompt', () => {
  const { home, ws } = makeHome();
  run(home, ['prompt', '--self', 'tg'], { session_id: SID_B, prompt: 'secret-ish' });
  const st = JSON.parse(fs.readFileSync(path.join(ws, 'state', 'cross-surface', `${SID_B}.json`), 'utf8'));
  assert.equal(st.pendingPrompt ?? null, null);
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
  const past = new Date(Date.now() - 8 * 24 * 3600 * 1000);
  fs.utimesSync(old, past, past);
  run(home, ['prompt', '--self', 'claude-code'], { session_id: SID_A, prompt: 'x' });
  assert.ok(!fs.existsSync(old));
});
