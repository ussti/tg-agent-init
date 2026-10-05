---
name: perplexity-research
description: >
  Deep web research with citations through the Perplexity Sonar API: one request
  gathers and cross-checks many sources. Use when the user wants a detailed answer
  with sources, a serious fact-check, or a market / competitor overview.
  Not for quick facts or a single page — use the built-in WebSearch / WebFetch.
  Needs PERPLEXITY_API_KEY; without it, say so and fall back to WebSearch.
---

# Perplexity Research -- web search with sources

Search the web, fact-check claims, analyze trends, and find best practices using the
Perplexity Sonar API. The key is read from the environment variable `PERPLEXITY_API_KEY`.

## Usage

1. Check the key: `[ -n "${PERPLEXITY_API_KEY:-}" ]` (see "No key" below if it is empty).
2. Query the Sonar API.
3. Return structured results with the sources it cites.

## Example

```bash
curl -X POST "https://api.perplexity.ai/chat/completions" \
  -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "sonar",
    "messages": [
      {"role": "user", "content": "What are the best practices for Claude Code agent architecture in 2026?"}
    ]
  }'
```

## Reading the response

The answer is `choices[0].message.content`; the sources are in the top-level
`citations` array (list of URLs). Pipe through jq:

```bash
... | jq -r '.choices[0].message.content, "", "Sources:", (.citations[]? | "- " + .)'
```

Always list the sources next to the answer.

## No key

If `PERPLEXITY_API_KEY` is empty, tell the user the key is not set (add later:
`agent-keys add perplexity`) and do the research with WebSearch instead.

## When to use

- Current events, news, trends
- Best practices and recommendations
- Fact-checking claims
- Competitor analysis
- Technology comparisons
- Market research
