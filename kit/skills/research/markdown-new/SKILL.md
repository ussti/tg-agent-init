---
name: markdown-new
description: Convert any web page / article URL to clean Markdown, cutting ~80% of tokens vs raw HTML. Use when reading web pages, articles, or docs. No API key (uses the free Jina Reader).
---

# markdown-new — URL to clean Markdown

Turns a web page into clean, readable Markdown so the agent reads content, not HTML boilerplate.
Backend: the free [Jina Reader](https://jina.ai/reader) (`r.jina.ai`) — no API key for normal use.

## Usage

```bash
bash scripts/to-markdown.sh "https://example.com/article"
```

Output is Markdown on stdout. For heavy use, Jina offers an optional API key (set `JINA_API_KEY`)
for higher rate limits — the skill works without it.

## Note

This is a convenience wrapper. Claude Code's built-in web fetch also works; use this when you want
the token-lean Markdown form specifically.
