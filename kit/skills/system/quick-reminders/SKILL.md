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

Storage: `${REMINDERS_FILE:-$AGENT_WS/core/reminders.md}` (`AGENT_WS` comes from agent.conf; without it the
file falls back to `${CLAUDE_PROJECT_DIR}/.claude/core/reminders.md`).

## Notes

- Open reminders are `- [ ]`, completed are `- [x]`.
- This is deliberately minimal — for anything larger, use a dedicated task tool.
