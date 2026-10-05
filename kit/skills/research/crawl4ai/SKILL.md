---
name: crawl4ai
description: >
  Local web crawler (Crawl4AI) with a real headless browser: returns full verbatim
  markdown and can crawl a whole site by links. Use when a page is empty or broken
  without JavaScript, when the verbatim text is needed rather than a summary, or when
  a whole site must be pulled (site audit, docs dump). For a single ordinary article
  or docs page prefer WebFetch / markdown-new, which are faster. Free, no API key.
---

# crawl4ai — local crawler

The CLI is `crwl` (installed with pipx, on `~/.local/bin`).

## When to use what

| Task | Tool |
|---|---|
| One ordinary page, need an answer about it | WebFetch |
| One page, full markdown | markdown-new or `crwl` |
| Page rendered by JavaScript / empty without it | `crwl` |
| Whole site or a section of it | `crwl --deep-crawl` |

## Commands

Single page to markdown:

```bash
crwl crawl https://example.com -o md -O page.md
```

`-o md-fit` drops navigation/boilerplate more aggressively (good for articles, may cut
useful blocks on landing pages — compare with `md` if in doubt).

Whole site, breadth-first, capped:

```bash
crwl crawl https://example.com --deep-crawl bfs --max-pages 30 -o md -O site.md
```

- Always set `--max-pages`; start small (10–30) and raise only if needed.
- Output is all pages concatenated; each page starts with its own `#` heading.
- `-bc` bypasses the local cache (`~/.crawl4ai/`) when a page changed.
- One page takes roughly 10 s, a 5-page deep crawl roughly 16 s.

## Do not

- Do not use `-q` / `-j` (question / LLM extraction): they need an LLM provider key that
  is not configured. Crawl to markdown, then read the file yourself.
- Do not crawl behind logins or scrape personal data without the user's go.
- Write outputs into the project folder, not to `/tmp`.
