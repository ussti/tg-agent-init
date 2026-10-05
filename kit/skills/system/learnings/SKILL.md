---
name: learnings
description: >
  Learnings System v2 — self-improvement через scoring ошибок.
  3 слоя: Episodes (сырой лог) → Learnings (scored) → Rules (promoted).
  Используй когда: (1) пользователь поправил действие, (2) обнаружена ошибка,
  (3) нужен отчёт по learnings, (4) lint/audit накопленных уроков.
---

## Wiring

Движок лежит в `$CLAUDE_PROJECT_DIR/scripts/learnings-engine.mjs` и сам находит рабочую
папку агента: эпизоды пишутся в `core/learnings/episodes.jsonl`, отчёт в `core/LEARNINGS.md`.
Переменные окружения нужны только для нестандартных путей:

```bash
ENGINE="node $CLAUDE_PROJECT_DIR/scripts/learnings-engine.mjs"
# optional overrides:
# export LEARNINGS_EPISODES=/path/to/episodes.jsonl
# export LEARNINGS_FILE=/path/to/LEARNINGS.md
```

## Архитектура

```
Layer 1: Episodes    — core/learnings/episodes.jsonl (append-only, source of truth)
Layer 2: Learnings   — core/LEARNINGS.md (scored view, regenerated via `report --write`)
Layer 3: Canon       — promoted episodes (status=promoted), GREEN-zone standing rules
```

**Layer 2→3 closure.** `promote <id>` marks an episode `status=promoted`. Promoted
episodes are the approved standing canon: **decay-exempt** and surfaced into EVERY
session by the SessionStart inject hook (which runs `learnings promoted`). This closes
the loop in the GREEN zone — `promote` never auto-edits the RED files rules.md /
CLAUDE.md, so no human has to hand-paste into a protected file for a lesson to become
permanent. The owner approves each promotion (weekly lint surfaces PROMOTE candidates
and asks); on the owner's «да» the agent runs `learnings promote <id>`. Identity-level rules
that truly belong in rules.md/CLAUDE.md remain the owner's manual call — promoted canon is
the automatic tier just below that.

Тесты движка: `node --test scripts/learnings-engine.test.mjs` (из папки агента).

## CLI

Engine: `$CLAUDE_PROJECT_DIR/scripts/learnings-engine.mjs`

```bash
ENGINE="node $CLAUDE_PROJECT_DIR/scripts/learnings-engine.mjs"

# Record new episode. AUTO-MERGE: if the rule is >=0.6 similar to an existing
# active episode, this bumps that episode's freq and refreshes its ts (a repeat)
# instead of appending a duplicate — that is how freq>=2 (and promotion) is
# reached without a manual `bump`. Force a distinct episode with "merge": false.
echo '{"context":"...","error":"...","rule":"...","impact":"high","tags":["workflow"]}' | $ENGINE capture

# View scored learnings
$ENGINE score

# Lint: find HOT (freq 3+), STALE (score < 0.15), PROMOTE (score > 0.8)
$ENGINE lint

# Drafts: open auto-capture episodes whose rule is still a placeholder.
$ENGINE drafts

# Resolve a draft: pipe the real rule in, it replaces the placeholder and drops
# the draft tags. (A fresh `capture` would NOT merge onto a draft — the placeholder
# rule isn't similar to the real one — so use resolve, not capture, to close drafts.)
echo 'always quote shell variables in scripts' | $ENGINE resolve EP-20260709-001

# Promote learning to standing canon (decay-exempt, injected every session)
$ENGINE promote EP-20260411-007

# List the promoted canon (what the inject hook surfaces)
$ENGINE promoted

# Archive stale learning
$ENGINE archive EP-20260411-009

# Bump frequency (repeat violation)
$ENGINE bump EP-20260411-001

# Generate markdown report
$ENGINE report
```

## Scoring

Composite score: `Recency (40%) + Frequency (30%) + Impact (30%)`

- Recency: `max(0, 1 - ageDays / 30)` — decay to 0 over 30 days
- Frequency: `min(1, freq / 3)` — 3+ violations = max score
- Impact: critical=1.0, high=0.7, medium=0.4, low=0.1

## Thresholds

| Condition | Action |
|---|---|
| Score > 0.8 | Propose promotion to rules (via owner) |
| Score < 0.15 | Propose archival |
| Freq 3+ in 30 days | ALERT: rule not working, change system |

## Weekly review (mandatory step)

The loop only closes if someone returns to the drafts and repeats. Every weekly
learnings/self-audit run MUST:

1. `$ENGINE drafts` — for each open draft either `resolve <id>` (write the real
   preventive rule) or `archive <id>`. Never leave a draft open across two reviews;
   unresolved placeholders clog the SessionStart inject top-5.
2. `$ENGINE lint` — STALE bucket → propose archival; HOT bucket → the rule is not
   working, escalate a system change (hook/CLAUDE.md), not another episode.
3. PROMOTE bucket → propose to owner; on OK `$ENGINE promote <id>`.

Promotion needs freq>=2 (a freq=1 episode tops out at score 0.80, gate is >0.8).
Freq now accrues automatically: a repeat capture auto-merges and bumps. Manual
`bump <id>` remains for a repeat you catch that wasn't re-captured.

## When to record

Record ONLY when:
- Owner explicitly corrected ("no, do it this way", "wrong")
- Expensive error (access, security, infrastructure, data)
- Repeated pattern (same mistake twice)
- Owner sets new standard/rule

Do NOT record:
- Normal clarifications
- Choice between options
- Minor style tweaks without pattern

## Episode format

```json
{
  "id": "EP-YYYYMMDD-NNN",
  "ts": "ISO8601",
  "type": "correction|insight|knowledge_gap",
  "agent": "agent",
  "source": "owner|experience|review",
  "context": "situation",
  "error": "what went wrong",
  "rule": "rule for the future",
  "impact": "critical|high|medium|low",
  "tags": ["tag1"],
  "freq": 1,
  "status": "active|promoted|archived"
}
```

## Access zones for auto-fix

| Zone | Files | Who edits |
|---|---|---|
| GREEN | SKILL.md, TOOLS.md, LEARNINGS.md | Agent autonomously |
| YELLOW | AGENTS.md, decisions.md | Agent with justification |
| RED | rules.md, CLAUDE.md | Owner only |

## What to do at freq 3+

| Error type | Action |
|---|---|
| Forgot a step | Add hook (PreToolUse/PostToolUse) |
| Wrong response style | Update CLAUDE.md or rules.md (via owner) |
| Used wrong tool | Update TOOLS.md |
| Asked unnecessary question | Add rule to CLAUDE.md (via owner) |
| Code error | Add test or lint rule |

## Hooks integration

This kit ships the engine only; no automatic capture hooks are installed. Record
episodes yourself in-session, following «When to record», and review them in the
weekly run: `$ENGINE lint`, then `$ENGINE report --write` to refresh `core/LEARNINGS.md`.
