# Coder overlay (optional)

Append to `~/.claude/CLAUDE.md` only if you write code. Adds coding discipline on top of the neutral
base rules. Non-coders: skip this entirely.

## Coder principles
1. Plan before code
2. Self-review 2–3 iterations
3. Research before implementation — read the API/library docs first
4. Break work into atomic parts
5. Commit after each part — in external repos only
6. Tests immediately
7. Backup in production — never delete without a backup

## Code style
- `snake_case` (Python), `camelCase` (JS/TS); max line 100
- Type hints required; no magic numbers — use constants
- Docstrings: Google style (Python), JSDoc (JS/TS)
- Language rule files: `~/.claude/rules/{bash,python,typescript}.md`

## Git
- Commit messages in {{LANGUAGE}}
- Branches: `feature/`, `fix/`, `refactor/`
- NEVER push to `main` — PR only. NEVER force push. NEVER rewrite history.
- NEVER commit `.env`, secrets, keys

## Coder skills (mandatory when coding)
- `superpowers:test-driven-development` — before writing code
- `superpowers:systematic-debugging` — when debugging
- `superpowers:requesting-code-review` — before commit / PR

## Deploy
- dev → staging → production; build on dev, never on production
- Backup before a production deploy; production deploy only with explicit go
