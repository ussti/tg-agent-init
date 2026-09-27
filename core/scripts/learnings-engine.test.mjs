// learnings-engine.test.mjs -- unit tests for the pure scoring/classify core.
// Run: node --test scripts/learnings-engine.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  IMPACT_WEIGHTS,
  computeRecency,
  computeFrequency,
  computeImpact,
  computeScore,
  classify,
  nextId,
  DECAY_DAYS,
  normalizeText,
  tokenSet,
  jaccard,
  ruleSimilarity,
  findSimilarActive,
  isDraft,
} from './learnings-engine.mjs';

const DAY = 86_400_000;
const NOW = Date.UTC(2026, 5, 24); // fixed clock for deterministic recency

test('computeImpact maps known levels and defaults unknown to low', () => {
  assert.equal(computeImpact('critical'), 1.0);
  assert.equal(computeImpact('high'), 0.7);
  assert.equal(computeImpact('medium'), 0.4);
  assert.equal(computeImpact('low'), 0.1);
  assert.equal(computeImpact('garbage'), IMPACT_WEIGHTS.low);
  assert.equal(computeImpact(undefined), IMPACT_WEIGHTS.low);
});

test('computeRecency decays linearly over DECAY_DAYS and clamps at 0', () => {
  assert.equal(computeRecency(0), 1);
  assert.equal(computeRecency(DECAY_DAYS / 2), 0.5);
  assert.equal(computeRecency(DECAY_DAYS), 0);
  assert.equal(computeRecency(DECAY_DAYS + 10), 0); // clamped, never negative
});

test('computeFrequency saturates at 3 repeats', () => {
  assert.ok(Math.abs(computeFrequency(1) - 1 / 3) < 1e-9);
  assert.equal(computeFrequency(3), 1);
  assert.equal(computeFrequency(10), 1); // capped
});

test('computeScore blends recency 40 / freq 30 / impact 30', () => {
  // fresh + critical + freq1 = 0.4*1 + 0.3*(1/3) + 0.3*1 = 0.8
  const ep = { ts: new Date(NOW).toISOString(), impact: 'critical', freq: 1 };
  assert.ok(Math.abs(computeScore(ep, NOW) - 0.8) < 1e-9);
});

test('computeScore drops as the episode ages', () => {
  const fresh = { ts: new Date(NOW).toISOString(), impact: 'high', freq: 1 };
  const old = { ts: new Date(NOW - 40 * DAY).toISOString(), impact: 'high', freq: 1 };
  assert.ok(computeScore(fresh, NOW) > computeScore(old, NOW));
});

test('classify flags PROMOTE above 0.8', () => {
  const ep = { ts: new Date(NOW).toISOString(), impact: 'critical', freq: 3 };
  assert.ok(classify(ep, NOW).includes('PROMOTE'));
});

test('classify flags STALE below 0.15', () => {
  const ep = { ts: new Date(NOW - 100 * DAY).toISOString(), impact: 'low', freq: 1 };
  assert.ok(classify(ep, NOW).includes('STALE'));
});

test('classify flags HOT when freq >= 3 regardless of score', () => {
  const ep = { ts: new Date(NOW - 100 * DAY).toISOString(), impact: 'low', freq: 5 };
  assert.ok(classify(ep, NOW).includes('HOT'));
});

test('nextId increments within a day and resets per date', () => {
  assert.equal(nextId([], '20260624'), 'EP-20260624-001');
  assert.equal(nextId(['EP-20260624-001'], '20260624'), 'EP-20260624-002');
  assert.equal(nextId(['EP-20260623-009'], '20260624'), 'EP-20260624-001');
  // gaps tolerated: max+1
  assert.equal(nextId(['EP-20260624-001', 'EP-20260624-004'], '20260624'), 'EP-20260624-005');
});

// --- auto-merge similarity --------------------------------------------------

test('normalizeText lowercases, keeps Cyrillic, collapses punctuation', () => {
  assert.equal(normalizeText('Не пиши <b>тег</b>, экранируй!'), 'не пиши b тег b экранируй');
  assert.equal(normalizeText('  A---B  '), 'a b');
});

test('jaccard is overlap over union; disjoint = 0, identical = 1', () => {
  assert.equal(jaccard(tokenSet('foo bar'), tokenSet('foo bar')), 1);
  assert.equal(jaccard(tokenSet('foo bar'), tokenSet('baz qux')), 0);
  assert.ok(Math.abs(jaccard(tokenSet('foo bar baz'), tokenSet('foo bar')) - 2 / 3) < 1e-9);
});

test('ruleSimilarity: normalized-identical -> 1, near-paraphrase high, unrelated low', () => {
  assert.equal(ruleSimilarity('Bump on repeat.', 'bump on repeat'), 1);
  assert.ok(ruleSimilarity('always quote shell variables', 'quote shell variables always') > 0.6);
  assert.ok(ruleSimilarity('backup before deploy', 'never force push to main') < 0.3);
});

test('findSimilarActive returns best active match above threshold, skips archived', () => {
  const eps = [
    { id: 'A', status: 'active', rule: 'quote shell variables in scripts' },
    { id: 'B', status: 'archived', rule: 'quote shell variables in scripts' },
    { id: 'C', status: 'active', rule: 'use pathlib not os path' },
  ];
  const m = findSimilarActive(eps, 'always quote shell variables in scripts', 0.6);
  assert.equal(m.ep.id, 'A');
  assert.equal(findSimilarActive(eps, 'totally unrelated lesson text here', 0.6), null);
});

test('findSimilarActive never merges onto a draft (shared placeholder rule)', () => {
  const PLACEHOLDER = 'DRAFT — rule pending: agent must formulate the preventive rule.';
  const eps = [
    { id: 'D1', status: 'active', rule: PLACEHOLDER, tags: ['autocapture', 'draft', 'needs-rule'] },
    { id: 'R1', status: 'active', rule: 'quote shell variables in scripts', tags: [] },
  ];
  // Two unrelated auto-captures share the placeholder verbatim — sim 1.0, and
  // before the fix they collapsed into one episode with a bogus freq.
  assert.equal(findSimilarActive(eps, PLACEHOLDER, 0.6), null);
  // Real rules still merge as before.
  assert.equal(findSimilarActive(eps, 'always quote shell variables in scripts', 0.6).ep.id, 'R1');
});

test('isDraft flags placeholder rules and needs-rule tag, not real rules', () => {
  assert.equal(isDraft({ rule: 'DRAFT — rule pending: formulate later', tags: [] }), true);
  assert.equal(isDraft({ rule: 'anything', tags: ['autocapture', 'needs-rule'] }), true);
  assert.equal(isDraft({ rule: 'always backup before deploy', tags: [] }), false);
});
