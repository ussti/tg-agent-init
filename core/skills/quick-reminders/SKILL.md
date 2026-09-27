---
name: quick-reminders
description: Local reminders — add, list, and complete short reminders stored in the agent's own workspace. No API key, no network. Use when the user says "remind me", "add a reminder", "what are my reminders", "mark reminder done".
---

# Quick Reminders

Tiny local to-do list stored in `core/reminders.md` inside the agent workspace. Pure filesystem —
no key, no service.

## Usage

```bash
bash scripts/reminders.sh add "call the dentist"
bash scripts/reminders.sh list
bash scripts/reminders.sh done 3      # complete the reminder on line 3
```

Storage: `${CLAUDE_PROJECT_DIR}/.claude/core/reminders.md` (override with `REMINDERS_FILE`).

## Notes

- Open reminders are `- [ ]`, completed are `- [x]`.
- This is deliberately minimal — for anything larger, use a dedicated task tool.
