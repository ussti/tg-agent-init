---
name: agent-browser
description: >
  Browser automation CLI for AI agents. Use when the user needs to interact with a
  website: navigate pages, fill forms, click buttons, take screenshots, extract data,
  test a web app, log in to a site, or automate any browser task. Also for exploratory
  testing and QA. For simply reading an ordinary article or docs page, lighter tools
  (WebFetch, markdown-new, crawl4ai) are fine.
allowed-tools: Bash(agent-browser:*), Bash(npx agent-browser:*)
---

# agent-browser

Fast browser automation CLI for AI agents. Chrome/Chromium via CDP with
accessibility-tree snapshots and compact `@eN` element refs.

Install: `npm i -g agent-browser && agent-browser install`

## Start here

This file is a discovery stub, not the usage guide. Before running any
`agent-browser` command, load the actual workflow content from the CLI:

```bash
agent-browser skills get core             # start here: workflows, patterns, troubleshooting
agent-browser skills get core --full      # include full command reference and templates
```

The CLI serves skill content that always matches the installed version.
Run `agent-browser skills list` to see the specialized skills available.

## Use it for

- Pages that need clicks, forms, logins or JavaScript rendering
- Screenshots of a live page
- Testing a web app end to end

## Prefer lighter tools

For reading an ordinary article or docs page use WebFetch or markdown-new; for a
JavaScript-rendered page or a whole site use crawl4ai.

## Always close

Close the browser when the task is done (`agent-browser close`) so sessions do not
pile up on the server.
