---
name: gws
description: >
  Google Workspace through gws-cli with full access: Gmail (read, draft, send),
  Calendar, Drive, Docs, Sheets, Slides, Contacts, and Markdown↔Docs convert.
  Use when the user asks about their mail, calendar, files or documents.
  Sending mail, deleting files and sharing are outward actions — confirm with the user first.
  Not logged in yet? Tell the user to run `agent-login google` in the server terminal.
---

# gws — Google Workspace

Everything goes through `gws-cli`.

```bash
gws-cli --help                 # list services
gws-cli <service> --help       # commands of one service (gmail, calendar, drive, docs, sheets, slides, contacts)
gws-cli auth status            # is the account logged in?
```

Start with `gws-cli auth status`. If it reports no login, ask the user to run
`agent-login google` in the server terminal, then retry.

## Confirm first

Reading and drafting are safe. These affect other people or are hard to undo, so
show the user exactly what will happen and wait for an explicit yes:

- sending an email (including replies and forwards)
- deleting or trashing files, events, messages
- sharing a file or changing its permissions
- inviting people to a calendar event
