#!/usr/bin/env node
// local-recall.mjs -- UserPromptSubmit hook. Local, keyword-based memory recall.
// Replaces server/embedding recall: greps the cold memory corpus for the prompt's
// salient words and injects the top matches as context. Pure fs + string ops.
// No database, no embeddings, no network. Deterministic and transparent.
//
// Input:  UserPromptSubmit JSON on stdin ({ prompt, ... }).
// Output: JSON on stdout with hookSpecificOutput.additionalContext, or nothing on no hit.
// Never blocks: any error exits 0 silently so a bad recall never breaks the turn.

import fs from 'node:fs';
import path from 'node:path';

const MAX_HITS = 5;          // top-N blocks injected
const MAX_BLOCK_CHARS = 600; // truncate long blocks
const MAX_TERMS = 8;         // salient keywords kept from the prompt
const MIN_TERM_LEN = 3;

// Stopwords: common RU + EN words that carry no recall signal.
const STOP = new Set(`
a an the and or but if then else for to of in on at by with from as is are was were be been being
do does did done have has had will would can could should may might must not no yes it its this that
these those i you he she we they me him her us them my your his our their what which who whom how why
where when about into over under again more most some any all each every
и в во не что он на я с со как а то все она так его но да ты к у же вы за бы по только ее мне было вот
от меня еще нет о из ему теперь когда даже ну вдруг ли если уже или ни быть был него до вас нибудь
опять уж вам ведь там потом себя ничего ей может они тут где есть надо ней для мы тебя их чем была
сам чтоб без будто чего раз тоже себе под будет ж кто этот того потому этого какой совсем ним здесь
этом один почти мой тем чтобы нее сейчас были куда зачем всех можно при об хоть над больше эту нас про
это эта эти этих
`.trim().split(/\s+/));

function readStdin() {
  try { return fs.readFileSync(0, 'utf8'); } catch { return ''; }
}

function extractTerms(prompt) {
  const seen = new Set();
  const terms = [];
  for (const raw of (prompt.toLowerCase().match(/[\p{L}\p{N}][\p{L}\p{N}_-]*/gu) || [])) {
    if (raw.length < MIN_TERM_LEN || STOP.has(raw) || seen.has(raw)) continue;
    seen.add(raw);
    terms.push(raw);
  }
  // Prefer the longer (more specific) terms.
  terms.sort((a, b) => b.length - a.length);
  return terms.slice(0, MAX_TERMS);
}

// Corpus, newest/most-relevant first. Recency breaks score ties.
function corpusFiles(claudeDir) {
  const core = path.join(claudeDir, 'core');
  const files = [
    path.join(core, 'hot', 'handoff.md'),
    path.join(core, 'warm', 'decisions.md'),
    path.join(core, 'LEARNINGS.md'),
    path.join(core, 'MEMORY.md'),
  ];
  const archive = path.join(core, 'archive');
  try {
    for (const f of fs.readdirSync(archive).filter((n) => n.endsWith('.md')).sort().reverse()) {
      files.push(path.join(archive, f));
    }
  } catch { /* no archive yet */ }
  return files;
}

// Split a file into blocks on markdown headers; fall back to the whole file.
function blocks(text) {
  const parts = text.split(/(?=^#{1,4} )/m).map((s) => s.trim()).filter(Boolean);
  return parts.length ? parts : [text.trim()].filter(Boolean);
}

function scoreBlock(block, terms) {
  const lower = block.toLowerCase();
  let score = 0;
  for (const t of terms) if (lower.includes(t)) score += 1;
  return score;
}

// Real content of a block: drop the header line, HTML comments, and italic note
// lines. Empty template stubs (header + <!-- ... --> only) return '' and are skipped,
// so recall never surfaces boilerplate on a fresh agent.
function meaningful(block) {
  return block
    .replace(/<!--[\s\S]*?-->/g, '')
    .split('\n')
    .filter((l) => {
      const t = l.trim();
      if (!t) return false;
      if (t.startsWith('#')) return false;      // headers
      if (/^_.*_$/.test(t)) return false;         // italic note lines
      return true;
    })
    .join(' ')
    .trim();
}

function main() {
  const body = readStdin();
  let prompt = '';
  try { prompt = (JSON.parse(body).prompt || '').toString(); } catch { prompt = body; }
  const terms = extractTerms(prompt);
  if (!terms.length) return;

  const claudeDir = process.env.CLAUDE_PROJECT_DIR
    ? path.join(process.env.CLAUDE_PROJECT_DIR, '.claude')
    : path.resolve(path.dirname(new URL(import.meta.url).pathname), '..');

  const hits = [];
  let recency = 0;
  for (const file of corpusFiles(claudeDir)) {
    let text;
    try { text = fs.readFileSync(file, 'utf8'); } catch { continue; }
    const src = path.basename(file);
    for (const block of blocks(text)) {
      const score = scoreBlock(block, terms);
      if (score > 0 && meaningful(block)) hits.push({ score, recency, src, block });
    }
    recency -= 1; // earlier files (handoff, decisions) rank above later (archive)
  }
  if (!hits.length) return;

  hits.sort((a, b) => b.score - a.score || b.recency - a.recency);

  const chosen = hits.slice(0, MAX_HITS).map(({ src, block }) => {
    const snippet = block.length > MAX_BLOCK_CHARS ? block.slice(0, MAX_BLOCK_CHARS) + ' …' : block;
    return `[${src}]\n${snippet}`;
  });

  const context =
    `<relevant-memory>\n` +
    `Possibly-relevant notes from memory (keyword match on: ${terms.join(', ')}). ` +
    `Treat as context, verify before relying on it.\n\n` +
    chosen.join('\n\n---\n\n') +
    `\n</relevant-memory>`;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: context },
  }));
}

try { main(); } catch { /* never block the turn */ }
process.exit(0);
