---
name: learnings
description: >
  Learnings System v2 — self-improvement через scoring ошибок.
  3 слоя: Episodes (сырой лог) → Learnings (scored) → Rules (promoted).
  Используй когда: (1) пользователь поправил действие, (2) обнаружена ошибка,
  (3) нужен отчёт по learnings, (4) lint/audit накопленных уроков.
---

## Wiring

Движок установлен в папку агента: `$CLAUDE_PROJECT_DIR/.claude/scripts/learnings-engine.mjs`.
Он сам находит рабочую папку `.claude/`: эпизоды пишутся в `core/learnings/episodes.jsonl`,
отчёт в `core/LEARNINGS.md`. Если `CLAUDE_PROJECT_DIR` в Bash не задана, скрипт ищется
от текущей папки; убедись, что файл существует, прежде чем запускать.
Переменные окружения нужны только для нестандартных путей:

```bash
ENGINE="node ${CLAUDE_PROJECT_DIR:-$PWD}/.claude/scripts/learnings-engine.mjs"
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

**Layer 2→3.** `promote <id>` помечает эпизод как `status=promoted`. Такой эпизод
освобождён от затухания и считается утверждённым каноном. Автоматически в сессию он
не попадает: в этой установке нет хука, который читает движок при старте. Поэтому
в начале каждой сессии запускай `$ENGINE promoted` и учитывай выданные правила.
`promote` не правит файлы rules.md и CLAUDE.md. Каждое повышение утверждает владелец:
еженедельный `lint` показывает кандидатов на PROMOTE, агент спрашивает, и только после
«да» запускает `$ENGINE promote <id>`. Правила уровня идентичности, которые должны
жить в rules.md или CLAUDE.md, остаются ручным решением владельца.

Тесты движка: `node --test .claude/scripts/learnings-engine.test.mjs` (из корня агента).

## CLI

Engine: `$CLAUDE_PROJECT_DIR/.claude/scripts/learnings-engine.mjs`

```bash
ENGINE="node ${CLAUDE_PROJECT_DIR:-$PWD}/.claude/scripts/learnings-engine.mjs"

# Record new episode. AUTO-MERGE: if the rule is >=0.6 similar to an existing
# active episode, this bumps that episode's freq and refreshes its ts (a repeat)
# instead of appending a duplicate — that is how freq>=2 (and promotion) is
# reached without a manual `bump`. Force a distinct episode with "merge": false.
echo '{"context":"...","error":"...","rule":"...","impact":"high","tags":["workflow"]}' | $ENGINE capture

# View scored learnings
$ENGINE score

# Lint: find HOT (freq 3+), STALE (score < 0.15), PROMOTE (score > 0.8)
$ENGINE lint

# Drafts (optional): episodes whose rule is still a placeholder.
$ENGINE drafts

# Resolve a draft: pipe the real rule in, it replaces the placeholder and drops
# the draft tags. (A fresh `capture` would NOT merge onto a draft — the placeholder
# rule isn't similar to the real one — so use resolve, not capture, to close drafts.)
echo 'always quote shell variables in scripts' | $ENGINE resolve EP-20260709-001

# Promote learning to standing canon (decay-exempt; read it with `promoted`)
$ENGINE promote EP-20260411-007

# List the promoted canon (run at the start of every session)
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

## Weekly review

Раз в неделю, при самоаудите или по просьбе владельца:

1. `$ENGINE lint` — корзина STALE: предложить архивацию; HOT: правило не работает,
   нужна системная правка (хук или CLAUDE.md), а не ещё один эпизод;
   PROMOTE: предложить владельцу, после «да» выполнить `$ENGINE promote <id>`.
2. `$ENGINE report --write` — обновить `core/LEARNINGS.md`.
3. Необязательно: `$ENGINE drafts` показывает эпизоды с правилом-заглушкой, если такие
   появились при ручном создании. Для каждого — `resolve <id>` с настоящим правилом
   или `archive <id>`.

Для повышения нужен freq>=2 (эпизод с freq=1 набирает максимум 0.80, а порог >0.8).
Повторный `capture` с похожим правилом сам сливается с прежним эпизодом и повышает freq;
`bump <id>` нужен, когда повтор заметил, но заново не записал.

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

Установка содержит только движок. Хуков автозахвата и вставки канона при старте сессии
нет; хук `correction-detector` лишь напоминает записать урок. Записывай эпизоды сам
по правилам «When to record», а `$ENGINE promoted` запускай в начале сессии.
