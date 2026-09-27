#!/usr/bin/env node
// learnings-engine.mjs -- Learnings System v2 engine.
//
// Three layers (see skills/learnings/SKILL.md):
//   Layer 1  Episodes   core/learnings/episodes.jsonl  (append-only, source of truth)
//   Layer 2  Learnings  core/LEARNINGS.md              (scored view, regenerated)
//   Layer 3  Rules      promoted canon                 (GREEN-zone, surfaced in-context)
//
// Layer 2->3 closure (the whole point of the loop): `promote` marks a learning
// status=promoted. Promoted learnings are the approved standing canon -- they are
// EXEMPT from decay and surfaced into every session by the `promoted` command (which
// the SessionStart inject hook prints to context). Promotion NEVER auto-edits the RED
// files rules.md / CLAUDE.md; the canon lives in the GREEN learnings tier instead, so
// the loop closes without a human pasting into a RED file. The operator still approves each
// promotion (weekly lint surfaces PROMOTE candidates); she just no longer has to hand-
// edit a protected file for the lesson to become permanent.
//
// Commands:
//   capture          read one episode JSON from stdin, append with id/ts/freq/status
//   score            print ACTIVE episodes sorted by composite score
//   lint             list HOT (freq>=3) / STALE (score<0.15) / PROMOTE (score>0.8)
//   drafts           list open auto-capture drafts whose rule is still a placeholder
//   resolve <id>     close a draft: read the real rule from stdin, drop draft tags
//   bump <id>        increment freq (repeat violation)
//   promote <id>     mark status=promoted -> becomes standing canon (decay-exempt)
//   promoted         list promoted canon (decay-exempt; consumed by the inject hook)
//   archive <id>     mark status=archived
//   report           print a scored markdown table to stdout
//   report --write   back up LEARNINGS.md and regenerate its scored section
//
// Pure scoring helpers are exported for unit tests; CLI runs only when invoked directly.
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

// --- Constants (no magic numbers) -------------------------------------------
export const DECAY_DAYS = 30; // recency decays to 0 over this many days
const FREQ_SATURATION = 3; // repeats at which frequency score maxes out
const W_RECENCY = 0.4;
const W_FREQUENCY = 0.3;
const W_IMPACT = 0.3;
const PROMOTE_THRESHOLD = 0.8;
const STALE_THRESHOLD = 0.15;
const HOT_FREQ = 3;
const DAY_MS = 86_400_000;
// Auto-merge: a fresh capture whose rule is this similar to an existing active
// episode bumps that episode's freq (a repeat) instead of appending a duplicate.
// This is what makes freq>=2 reachable without a manual `bump`, which unjams the
// Layer 2->3 promotion gate (freq=1 tops out at score 0.80, threshold is >0.8).
const MERGE_THRESHOLD = 0.6;

export const IMPACT_WEIGHTS = Object.freeze({
  critical: 1.0,
  high: 0.7,
  medium: 0.4,
  low: 0.1,
});

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const WORKSPACE = path.resolve(__dirname, '..'); // .claude/
const EPISODES_PATH =
  process.env.LEARNINGS_EPISODES || path.join(WORKSPACE, 'core', 'learnings', 'episodes.jsonl');
const LEARNINGS_PATH =
  process.env.LEARNINGS_FILE || path.join(WORKSPACE, 'core', 'LEARNINGS.md');

const SCORED_MARKER_START = '<!-- scored:start -->';
const SCORED_MARKER_END = '<!-- scored:end -->';

// --- Pure scoring helpers (unit-tested) -------------------------------------

// Recency: 1.0 fresh, linear decay to 0 at DECAY_DAYS, never negative.
export function computeRecency(ageDays) {
  return Math.max(0, 1 - ageDays / DECAY_DAYS);
}

// Frequency: saturates at FREQ_SATURATION repeats.
export function computeFrequency(freq) {
  return Math.min(1, freq / FREQ_SATURATION);
}

// Impact: fixed weight per level, unknown -> low.
export function computeImpact(impact) {
  return IMPACT_WEIGHTS[impact] ?? IMPACT_WEIGHTS.low;
}

// Composite score in [0, 1].
export function computeScore(ep, nowMs) {
  const ageDays = (nowMs - Date.parse(ep.ts)) / DAY_MS;
  return (
    W_RECENCY * computeRecency(ageDays) +
    W_FREQUENCY * computeFrequency(ep.freq ?? 1) +
    W_IMPACT * computeImpact(ep.impact)
  );
}

// Classify an episode into zero or more action tags.
export function classify(ep, nowMs) {
  const tags = [];
  const score = computeScore(ep, nowMs);
  if ((ep.freq ?? 1) >= HOT_FREQ) tags.push('HOT');
  if (score > PROMOTE_THRESHOLD) tags.push('PROMOTE');
  if (score < STALE_THRESHOLD) tags.push('STALE');
  return tags;
}

// Next sequential id for a given YYYYMMDD date, given the existing ids.
export function nextId(existingIds, dateStr) {
  const prefix = `EP-${dateStr}-`;
  const max = existingIds
    .filter((id) => id.startsWith(prefix))
    .map((id) => parseInt(id.slice(prefix.length), 10))
    .filter((n) => Number.isFinite(n))
    .reduce((a, b) => Math.max(a, b), 0);
  return `${prefix}${String(max + 1).padStart(3, '0')}`;
}

// --- Similarity for auto-merge (unit-tested) --------------------------------

// Normalize free text for comparison: lowercase, keep letters/digits (Unicode,
// so Cyrillic survives), collapse everything else to single spaces.
export function normalizeText(s) {
  return String(s ?? '')
    .toLowerCase()
    .replace(/[^\p{L}\p{N}]+/gu, ' ')
    .trim();
}

// Token set of a normalized string, dropping 1-char noise tokens.
export function tokenSet(s) {
  return new Set(normalizeText(s).split(' ').filter((t) => t.length >= 2));
}

// Jaccard overlap of two token sets in [0, 1]; two empties are treated as 0.
export function jaccard(a, b) {
  if (!a.size && !b.size) return 0;
  let inter = 0;
  for (const t of a) if (b.has(t)) inter += 1;
  return inter / (a.size + b.size - inter);
}

// Rule similarity: identical after normalization -> 1, else token Jaccard.
export function ruleSimilarity(a, b) {
  if (normalizeText(a) === normalizeText(b)) return 1;
  return jaccard(tokenSet(a), tokenSet(b));
}

// Best active episode whose rule is >= threshold similar to `rule`, or null.
// Episodes files are per-agent, so callers pass this agent's episodes only.
// Drafts are never merge targets: every draft carries the SAME placeholder rule,
// so unrelated corrections all matched each other at sim 1.0 and collapsed into
// one episode with an inflated freq, which dragged it into the HOT bucket
// (field report 2026-07-31: EP-20260709-001 reached freq5 from unrelated flags).
export function findSimilarActive(episodes, rule, threshold = MERGE_THRESHOLD) {
  let best = null;
  let bestSim = 0;
  for (const ep of episodes) {
    if (ep.status !== 'active' || isDraft(ep)) continue;
    const sim = ruleSimilarity(ep.rule, rule);
    if (sim >= threshold && sim > bestSim) {
      best = ep;
      bestSim = sim;
    }
  }
  return best ? { ep: best, sim: bestSim } : null;
}

// --- IO helpers -------------------------------------------------------------

function loadEpisodes(p = EPISODES_PATH) {
  if (!fs.existsSync(p)) return [];
  return fs
    .readFileSync(p, 'utf8')
    .split('\n')
    .map((l) => l.trim())
    .filter(Boolean)
    .map((l) => JSON.parse(l));
}

function saveEpisodes(episodes, p = EPISODES_PATH) {
  fs.mkdirSync(path.dirname(p), { recursive: true });
  const body = episodes.map((e) => JSON.stringify(e)).join('\n');
  fs.writeFileSync(p, body + (body ? '\n' : ''), 'utf8');
}

function dateStamp(d = new Date()) {
  return d.toISOString().slice(0, 10).replace(/-/g, '');
}

function fail(msg) {
  process.stderr.write(`error: ${msg}\n`);
  process.exit(1);
}

function findEpisode(episodes, id) {
  const ep = episodes.find((e) => e.id === id);
  if (!ep) fail(`episode not found: ${id}`);
  return ep;
}

// --- Commands ---------------------------------------------------------------

function cmdCapture() {
  const raw = fs.readFileSync(0, 'utf8').trim(); // fd 0 = stdin
  if (!raw) fail('capture expects an episode JSON on stdin');
  let input;
  try {
    input = JSON.parse(raw);
  } catch (e) {
    fail(`invalid JSON on stdin: ${e.message}`);
  }
  if (!input.context || !input.rule) {
    fail('episode requires at least "context" and "rule" fields');
  }
  const episodes = loadEpisodes();
  const now = new Date();

  // Repeat of an existing active lesson -> bump its freq and refresh recency
  // (it happened again, now), rather than appending a near-duplicate. Set
  // "merge": false in the input to force a distinct episode. An incoming draft
  // never merges either: its rule is a placeholder, so any match would be on
  // boilerplate rather than on the actual lesson.
  if (input.merge !== false && !isDraft(input)) {
    const match = findSimilarActive(episodes, input.rule);
    if (match) {
      match.ep.freq = (match.ep.freq ?? 1) + 1;
      match.ep.ts = now.toISOString();
      saveEpisodes(episodes);
      process.stdout.write(
        `merged into ${match.ep.id} -> freq${match.ep.freq} ` +
          `(repeat, rule sim ${match.sim.toFixed(2)}); ts refreshed\n`,
      );
      return;
    }
  }

  const id = nextId(episodes.map((e) => e.id), dateStamp(now));
  const episode = {
    id,
    ts: now.toISOString(),
    type: input.type || 'correction',
    agent: input.agent || process.env.LEARNINGS_AGENT || 'agent',
    source: input.source || 'owner',
    context: input.context,
    error: input.error || '',
    rule: input.rule,
    impact: input.impact || 'medium',
    tags: input.tags || [],
    freq: 1,
    status: 'active',
  };
  episodes.push(episode);
  saveEpisodes(episodes);
  process.stdout.write(`captured ${id} (impact=${episode.impact})\n`);
}

// A draft is an auto-captured episode whose real rule is still a placeholder:
// tagged needs-rule/draft, or the rule text still reads "DRAFT ... rule pending".
// These clog the inject top-5 until closed (rule written) or archived.
export function isDraft(ep) {
  const tags = ep.tags || [];
  if (tags.includes('needs-rule') || tags.includes('draft')) return true;
  return /^\s*draft\b|rule pending/i.test(ep.rule || '');
}

function cmdDrafts() {
  const drafts = loadEpisodes().filter((e) => e.status === 'active' && isDraft(e));
  if (!drafts.length) {
    process.stdout.write('no open drafts\n');
    return;
  }
  process.stdout.write(
    `${drafts.length} open draft(s) — write the real rule (learnings ` +
      `capture, it auto-merges) or archive:\n`,
  );
  for (const ep of drafts) {
    const ctx = (ep.context || '').replace(/\n/g, ' ').slice(0, 90);
    process.stdout.write(`  ${ep.id}  [${ep.impact}/freq${ep.freq}]  ${ctx}\n`);
  }
}

function activeSorted(episodes, now) {
  return episodes
    .filter((e) => e.status === 'active')
    .map((e) => ({ ep: e, score: computeScore(e, now) }))
    .sort((a, b) => b.score - a.score);
}

function cmdScore() {
  const now = Date.now();
  const rows = activeSorted(loadEpisodes(), now);
  if (!rows.length) {
    process.stdout.write('no active episodes\n');
    return;
  }
  for (const { ep, score } of rows) {
    process.stdout.write(
      `${score.toFixed(2)}  ${ep.id}  [${ep.impact}/freq${ep.freq}]  ${ep.rule}\n`,
    );
  }
}

function cmdLint() {
  const now = Date.now();
  const episodes = loadEpisodes().filter((e) => e.status === 'active');
  const buckets = { HOT: [], PROMOTE: [], STALE: [] };
  for (const ep of episodes) {
    for (const tag of classify(ep, now)) buckets[tag].push(ep);
  }
  const section = (name, hint, list) => {
    process.stdout.write(`\n## ${name} ${hint}\n`);
    if (!list.length) {
      process.stdout.write('  (none)\n');
      return;
    }
    for (const ep of list) {
      process.stdout.write(`  ${ep.id}  [freq${ep.freq}]  ${ep.rule}\n`);
    }
  };
  section('HOT', '(freq>=3 — rule not working, change the system)', buckets.HOT);
  section('PROMOTE', '(score>0.8 — propose promotion to rules, owner approves)', buckets.PROMOTE);
  section('STALE', '(score<0.15 — propose archival)', buckets.STALE);
  process.stdout.write('\n');
}

function mutate(id, fn, okMsg) {
  const episodes = loadEpisodes();
  const ep = findEpisode(episodes, id);
  fn(ep);
  saveEpisodes(episodes);
  process.stdout.write(okMsg(ep));
}

function cmdBump(id) {
  mutate(
    id,
    (ep) => {
      ep.freq = (ep.freq ?? 1) + 1;
    },
    (ep) => `bumped ${ep.id} -> freq${ep.freq}\n`,
  );
}

// Close a draft: replace its placeholder rule with the real one (read from stdin)
// and drop the draft/needs-rule tags. This is how a weekly review resolves the
// auto-captured drafts that `drafts` lists — capturing a fresh episode would NOT
// merge onto the draft (its placeholder rule isn't similar to the real rule).
function cmdResolve(id) {
  const rule = fs.readFileSync(0, 'utf8').trim(); // fd 0 = stdin
  if (!rule) fail('resolve expects the real rule text on stdin');
  mutate(
    id,
    (ep) => {
      ep.rule = rule;
      ep.tags = (ep.tags || []).filter((t) => t !== 'draft' && t !== 'needs-rule');
    },
    (ep) => `resolved ${ep.id} -> rule set, draft tags cleared\n  ${ep.rule}\n`,
  );
}

function cmdPromote(id) {
  mutate(
    id,
    (ep) => {
      ep.status = 'promoted';
    },
    (ep) =>
      `promoted ${ep.id} -> standing canon (decay-exempt). ` +
      `Now surfaced in every session by the inject hook. No RED-file edit needed.\n  ${ep.rule}\n`,
  );
}

// Promoted canon: decay-exempt standing rules. The SessionStart inject hook consumes
// this so approved lessons stay in-context permanently (until archived). This is what
// closes Layer 2->3 in the GREEN zone.
function cmdPromoted() {
  const promoted = loadEpisodes().filter((e) => e.status === 'promoted');
  if (!promoted.length) {
    process.stdout.write('no promoted canon\n');
    return;
  }
  for (const ep of promoted) {
    const rule = ep.rule.replace(/\n/g, ' ');
    process.stdout.write(`${ep.id}  [${ep.impact}]  ${rule}\n`);
  }
}

function cmdArchive(id) {
  mutate(
    id,
    (ep) => {
      ep.status = 'archived';
    },
    (ep) => `archived ${ep.id}\n`,
  );
}

function renderScoredTable(episodes, now) {
  const rows = activeSorted(episodes, now);
  const lines = [
    '| Score | ID | Impact | Freq | Rule |',
    '|-------|----|--------|------|------|',
  ];
  for (const { ep, score } of rows) {
    const rule = ep.rule.replace(/\|/g, '\\|').replace(/\n/g, ' ');
    lines.push(`| ${score.toFixed(2)} | ${ep.id} | ${ep.impact} | ${ep.freq} | ${rule} |`);
  }
  return lines.join('\n');
}

function cmdReport(write) {
  const now = Date.now();
  const episodes = loadEpisodes();
  const table = renderScoredTable(episodes, now);
  const block = `${SCORED_MARKER_START}\n_Auto-generated by learnings-engine. Do not edit by hand._\n\n${table}\n${SCORED_MARKER_END}`;

  if (!write) {
    process.stdout.write(block + '\n');
    return;
  }

  // --write: back up LEARNINGS.md, then replace (or append) the scored block only.
  let content = fs.existsSync(LEARNINGS_PATH) ? fs.readFileSync(LEARNINGS_PATH, 'utf8') : '';
  if (content) {
    const stamp = new Date().toISOString().replace(/[:.]/g, '').slice(0, 15);
    fs.copyFileSync(LEARNINGS_PATH, `${LEARNINGS_PATH}.bak_engine_${stamp}`);
  }
  const re = new RegExp(`${SCORED_MARKER_START}[\\s\\S]*?${SCORED_MARKER_END}`);
  if (re.test(content)) {
    content = content.replace(re, () => block); // fn form: avoid $-token interpretation
  } else {
    content = content.replace(/\s*$/, '\n') + `\n## Scored (auto)\n\n${block}\n`;
  }
  fs.writeFileSync(LEARNINGS_PATH, content, 'utf8');
  process.stdout.write(`LEARNINGS.md updated (backup written)\n`);
}

// --- CLI dispatch -----------------------------------------------------------

function main(argv) {
  const [cmd, arg] = argv;
  switch (cmd) {
    case 'capture':
      return cmdCapture();
    case 'score':
      return cmdScore();
    case 'lint':
      return cmdLint();
    case 'drafts':
      return cmdDrafts();
    case 'resolve':
      return arg ? cmdResolve(arg) : fail('resolve requires an episode id');
    case 'bump':
      return arg ? cmdBump(arg) : fail('bump requires an episode id');
    case 'promote':
      return arg ? cmdPromote(arg) : fail('promote requires an episode id');
    case 'promoted':
      return cmdPromoted();
    case 'archive':
      return arg ? cmdArchive(arg) : fail('archive requires an episode id');
    case 'report':
      return cmdReport(arg === '--write');
    default:
      process.stdout.write(
        'usage: learnings-engine.mjs <capture|score|lint|drafts|resolve|bump|promote|promoted|archive|report> [arg]\n',
      );
      process.exit(cmd ? 1 : 0);
  }
}

// Run only when executed directly, so tests can import the pure helpers.
if (process.argv[1] && fileURLToPath(import.meta.url) === path.resolve(process.argv[1])) {
  main(process.argv.slice(2));
}
