#!/usr/bin/env node
// cross-surface.mjs -- shared memory between the Telegram bot and Claude Code sessions
// (Claude Desktop over SSH, terminal, Claude Code on the phone) of one agent.
//
// The Telegram plugin writes its turns to core/hot/recent-plugin.md. This hook:
//   stop                      Stop hook of Claude Code sessions in the agent folder (workspace
//                             settings.json only; the bot never loads it). Appends the turn to
//                             core/hot/recent.md in the plugin's entry format, so write-handoff.sh
//                             merges both channels in time order.
//   prompt --self tg|claude-code
//                             UserPromptSubmit hook of both surfaces. Injects the turns the other
//                             surface wrote since this session last looked, and the shared task
//                             list core/hot/tasks.md when it changed.
//
// Input: hook JSON on stdin. Output (prompt mode): hookSpecificOutput.additionalContext or
// nothing. Never blocks a turn: any error exits 0 without output. Stdlib only.
// The plugin's own files are only read, never written.

import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const TAG_CLAUDE_CODE = 'claude-code';
const SELVES = new Set(['tg', TAG_CLAUDE_CODE]);
const USER_SNIPPET_MAX = 300;
const AGENT_SNIPPET_MAX = 600;
const NEWS_MAX_ENTRIES = 8;
const NEWS_MAX_CHARS = 3500;
const TASKS_MAX_CHARS = 2500;
const RECENT_TRIM_BYTES = 24 * 1024;
const RECENT_KEEP_ENTRIES = 40;
const STATE_TTL_MS = 7 * 24 * 3600 * 1000;
const SID_SHORT = 8;
const KEY_LEN = 12;
const RECENT_HEADER =
  '# Hot memory -- Claude Code sessions\n\n' +
  '_Turns from Claude Code sessions in the agent folder (desktop app, terminal, phone)._\n' +
  '_Written by hooks/cross-surface.mjs. Telegram turns are in recent-plugin.md._\n';
const TASK_RULE =
  'Shared task list: core/hot/tasks.md -- the same list is seen from Telegram and from Claude ' +
  'Code sessions. When you start, advance, pause or finish a multi-step task, update its line: ' +
  'task, current step, next step, where it is being done (tg / claude-code). Remove finished ' +
  'tasks. One task is driven from one place at a time.';

// Same patterns as write-handoff.sh.
const REDACTIONS = [
  [/[0-9]{8,12}:[A-Za-z0-9_-]{30,}/g, '***REDACTED-TELEGRAM-TOKEN***'],
  [/AKIA[0-9A-Z]{16}/g, '***REDACTED-AWS-KEY***'],
  [/sk-ant-[A-Za-z0-9_-]{40,}/g, '***REDACTED-ANTHROPIC-KEY***'],
  [/sk-[A-Za-z0-9]{32,}/g, '***REDACTED-OPENAI-KEY***'],
  [/ghp_[A-Za-z0-9]{36}/g, '***REDACTED-GITHUB-PAT***'],
  [/gho_[A-Za-z0-9]{36}/g, '***REDACTED-GITHUB-OAUTH***'],
  [/xox[bpars]-[A-Za-z0-9-]{20,}/g, '***REDACTED-SLACK-TOKEN***'],
  [/(apify_api_)[A-Za-z0-9]{30,}/g, '$1***REDACTED***'],
  [/(BEGIN [A-Z ]*PRIVATE KEY)[^-]*/g, '$1***REDACTED-PRIVATE-KEY***'],
];

const HEADER_RE = /^### (\d{4}-\d{2}-\d{2} \d{2}:\d{2}) \[([^\]\n]+)\](.*)$/;
const SID_RE = /<!-- s:([A-Za-z0-9_-]+) -->/;

// ---------------------------------------------------------------- helpers

function workspaceDir() {
  return process.env.CLAUDE_PROJECT_DIR
    ? path.join(process.env.CLAUDE_PROJECT_DIR, '.claude')
    : path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');
}

/** Current time; CROSS_SURFACE_NOW ("YYYY-MM-DDTHH:MM", local) pins it in tests. */
function now() {
  const pinned = process.env.CROSS_SURFACE_NOW;
  const d = pinned ? new Date(pinned) : new Date();
  return Number.isNaN(d.getTime()) ? new Date() : d;
}

/** 'YYYY-MM-DD HH:MM' in local time -- the plugin's hot-entry format. */
function formatTs(d) {
  const p = (n) => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())} ` +
    `${p(d.getHours())}:${p(d.getMinutes())}`;
}

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch { return ''; }
}

function writeAtomic(file, text) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.tmp.${process.pid}`);
  try {
    fs.writeFileSync(tmp, text, 'utf8');
    fs.renameSync(tmp, file);
  } finally {
    try { fs.unlinkSync(tmp); } catch { /* renamed or never written */ }
  }
}

function redact(s) {
  return REDACTIONS.reduce((acc, [re, rep]) => acc.replace(re, rep), s);
}

function snippet(s, max) {
  const flat = redact(String(s)).replace(/\s+/g, ' ').trim();
  return flat.length > max ? `${flat.slice(0, max)} …` : flat;
}

function validSid(sid) {
  return typeof sid === 'string' && /^[A-Za-z0-9_-]{1,128}$/.test(sid) ? sid : null;
}

function agentLabel(ws) {
  const m = readText(path.join(ws, 'agent.conf')).match(/^AGENT_NAME=["']?([^"'\n]+)["']?\s*$/m);
  return m ? m[1].trim() : 'Agent';
}

function hash(s) {
  return crypto.createHash('sha1').update(s).digest('hex').slice(0, KEY_LEN);
}

/**
 * Split a hot-memory file into entries.
 * @param {string} text file content
 * @param {string} channel 'tg' for recent-plugin.md, 'claude-code' for recent.md
 * @returns {{ts: string, tag: string, sid: string|null, key: string, channel: string, text: string}[]}
 */
export function parseEntries(text, channel) {
  const out = [];
  let cur = null;
  const flush = () => {
    if (!cur) return;
    const body = cur.lines.join('\n').trim();
    out.push({ ...cur.meta, channel, key: hash(`${channel}\n${cur.header}\n${body}`), text: body });
  };
  for (const line of text.split('\n')) {
    const m = line.match(HEADER_RE);
    if (m) {
      flush();
      const sid = (m[3].match(SID_RE) || [])[1] || null;
      cur = { header: line, meta: { ts: m[1], tag: m[2], sid }, lines: [] };
    } else if (cur) {
      cur.lines.push(line);
    }
  }
  flush();
  return out;
}

function statePath(ws, sid) {
  return path.join(ws, 'state', 'cross-surface', `${sid}.json`);
}

function loadState(ws, sid) {
  try { return JSON.parse(fs.readFileSync(statePath(ws, sid), 'utf8')); } catch { return null; }
}

function saveState(ws, sid, state) {
  writeAtomic(statePath(ws, sid), JSON.stringify(state));
}

function cleanupStates(ws, keepSid) {
  const dir = path.join(ws, 'state', 'cross-surface');
  let names = [];
  try { names = fs.readdirSync(dir); } catch { return; }
  const cutoff = Date.now() - STATE_TTL_MS;
  for (const n of names) {
    if (!n.endsWith('.json') || n === `${keepSid}.json`) continue;
    const f = path.join(dir, n);
    try { if (fs.statSync(f).mtimeMs < cutoff) fs.unlinkSync(f); } catch { /* raced */ }
  }
}

// ---------------------------------------------------------------- transcript fallback

function isRealPrompt(rec) {
  if (rec.type !== 'user' || rec.isMeta || rec.isCompactSummary || rec.isSidechain) return false;
  const c = rec.message && rec.message.content;
  if (typeof c === 'string') return c.trim() !== '';
  if (!Array.isArray(c) || c.some((b) => b && b.type === 'tool_result')) return false;
  return c.some((b) => b && b.type === 'text' && String(b.text || '').trim());
}

function textOf(content) {
  if (typeof content === 'string') return content;
  if (!Array.isArray(content)) return '';
  return content.filter((b) => b && b.type === 'text').map((b) => b.text || '').join('\n');
}

/** Last real prompt and the last assistant text after it. */
function fromTranscript(file) {
  const recs = [];
  for (const line of readText(file).split('\n')) {
    if (!line.trim()) continue;
    try { recs.push(JSON.parse(line)); } catch { /* partial line */ }
  }
  let start = -1;
  for (let i = recs.length - 1; i >= 0; i--) if (isRealPrompt(recs[i])) { start = i; break; }
  if (start < 0) return { prompt: '', text: '' };
  let text = '';
  for (let i = recs.length - 1; i > start; i--) {
    const r = recs[i];
    if (r.type !== 'assistant' || r.isSidechain) continue;
    const t = textOf(r.message && r.message.content).trim();
    if (t) { text = t; break; }
  }
  return { prompt: textOf(recs[start].message.content).trim(), text };
}

// ---------------------------------------------------------------- stop

function trimRecent(file) {
  const content = readText(file);
  if (Buffer.byteLength(content, 'utf8') <= RECENT_TRIM_BYTES) return;
  const starts = [...content.matchAll(/^### /gm)].map((m) => m.index);
  if (starts.length <= RECENT_KEEP_ENTRIES) return;
  const head = content.slice(0, starts[0]).trimEnd();
  const kept = content.slice(starts[starts.length - RECENT_KEEP_ENTRIES]);
  writeAtomic(file, `${head || RECENT_HEADER.trimEnd()}\n\n${kept}`);
}

function stop(input) {
  const ws = workspaceDir();
  const sid = validSid(input.session_id);
  const state = sid ? loadState(ws, sid) : null;
  let prompt = (state && typeof state.pendingPrompt === 'string') ? state.pendingPrompt : '';
  let text = typeof input.last_assistant_message === 'string' ? input.last_assistant_message : '';
  if ((!prompt || !text.trim()) && typeof input.transcript_path === 'string') {
    const t = fromTranscript(input.transcript_path);
    prompt = prompt || t.prompt;
    text = text.trim() ? text : t.text;
  }
  if (!prompt.trim() && !text.trim()) return;

  const file = path.join(ws, 'core', 'hot', 'recent.md');
  if (!fs.existsSync(file)) writeAtomic(file, RECENT_HEADER);
  const sidTag = sid ? sid.slice(0, SID_SHORT) : 'unknown';
  const entry =
    `\n### ${formatTs(now())} [${TAG_CLAUDE_CODE}] <!-- s:${sidTag} -->\n` +
    `**User:** ${snippet(prompt || '(no prompt)', USER_SNIPPET_MAX)}\n` +
    `**${agentLabel(ws)}:** ${snippet(text || '(no text)', AGENT_SNIPPET_MAX)}\n`;
  fs.appendFileSync(file, entry, 'utf8');
  trimRecent(file);
  if (sid && state && state.pendingPrompt) saveState(ws, sid, { ...state, pendingPrompt: null });
}

// ---------------------------------------------------------------- prompt

function renderEntry(e) {
  const body = e.text.replace(/\n+/g, ' | ');
  return `[${e.tag} ${e.ts}] ${body}`;
}

function newsBlock(news) {
  let shown = news.slice(-NEWS_MAX_ENTRIES);
  let lines = shown.map(renderEntry);
  while (lines.length > 1 && lines.join('\n').length > NEWS_MAX_CHARS) {
    shown = shown.slice(1);
    lines = lines.slice(1);
  }
  const earlier = news.length - shown.length;
  const more = earlier > 0
    ? ` ${earlier} earlier not shown: see core/hot/recent-plugin.md and core/hot/recent.md.`
    : '';
  return `New on the other surface since your last message (oldest first).${more}\n` +
    lines.join('\n');
}

/** Task lines only: comments, headers and italic note lines of the template are dropped. */
function taskLines(text) {
  return text
    .replace(/<!--[\s\S]*?-->/g, '')
    .split('\n')
    .filter((l) => {
      const t = l.trim();
      return t && !t.startsWith('#') && !/^_.*_$/.test(t);
    })
    .join('\n')
    .trim();
}

function prompt(input, self) {
  const ws = workspaceDir();
  const sid = validSid(input.session_id);
  if (!sid) return;
  cleanupStates(ws, sid);
  const hot = path.join(ws, 'core', 'hot');
  const entries = [
    ...parseEntries(readText(path.join(hot, 'recent-plugin.md')), 'tg'),
    ...parseEntries(readText(path.join(hot, 'recent.md')), TAG_CLAUDE_CODE),
  ];
  const own = sid.slice(0, SID_SHORT);
  const isOther = (e) => (self === 'tg'
    ? e.channel === TAG_CLAUDE_CODE
    : e.channel === 'tg' || e.sid !== own);

  const prev = loadState(ws, sid);
  const first = !prev;
  let news = [];
  if (!first) {
    const seen = new Set(prev.seen || []);
    const cursor = prev.cursorTs || '';
    news = entries
      .filter(isOther)
      .filter((e) => e.ts > cursor || (e.ts === cursor && !seen.has(e.key)))
      .sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));
  }
  const cursorTs = entries.reduce((m, e) => (e.ts > m ? e.ts : m), (prev && prev.cursorTs) || '');
  const seenNow = entries.filter((e) => e.ts === cursorTs).map((e) => e.key);

  const tasksBody = taskLines(readText(path.join(hot, 'tasks.md')));
  const tasksHash = tasksBody ? hash(tasksBody) : '';
  const tasksChanged = tasksHash !== ((prev && prev.tasksHash) || '');
  const showTasks = Boolean(tasksBody) && (first || tasksChanged);

  const pendingPrompt = self === TAG_CLAUDE_CODE && typeof input.prompt === 'string'
    ? input.prompt : null;
  saveState(ws, sid, { cursorTs, seen: seenNow, tasksHash, pendingPrompt });

  const parts = [];
  if (news.length) parts.push(newsBlock(news));
  if (showTasks) {
    const t = tasksBody.length > TASKS_MAX_CHARS ? `${tasksBody.slice(0, TASKS_MAX_CHARS)} …` : tasksBody;
    parts.push(`Shared task list (core/hot/tasks.md)${first ? '' : ', changed'}:\n${t}`);
  }
  if (first || showTasks) parts.push(TASK_RULE);
  if (!parts.length) return;
  const where = self === 'tg' ? 'Telegram' : 'a Claude Code session';
  const context =
    `<cross-surface-memory>\nYou are answering in ${where}. The same agent also works on the ` +
    `other surface; this is what it shares.\n\n${parts.join('\n\n')}\n</cross-surface-memory>`;
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: context },
  }));
}

// ---------------------------------------------------------------- main

function main() {
  const [mode, flag, self] = process.argv.slice(2);
  let input;
  try { input = JSON.parse(fs.readFileSync(0, 'utf8')); } catch { return; }
  if (!input || typeof input !== 'object') return;
  if (mode === 'stop') stop(input);
  else if (mode === 'prompt' && flag === '--self' && SELVES.has(self)) prompt(input, self);
}

if (process.argv[1] && path.resolve(process.argv[1]) === path.resolve(new URL(import.meta.url).pathname)) {
  try { main(); } catch { /* memory must never break a turn */ }
}
