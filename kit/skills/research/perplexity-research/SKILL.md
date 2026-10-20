---
name: perplexity-research
description: >
  Deep web research with citations through the Perplexity Agent API: one request
  gathers and cross-checks many sources. Use when the user wants a detailed answer
  with sources, a serious fact-check, or a market / competitor overview.
  Not for quick facts or a single page — use the built-in WebSearch / WebFetch.
  Not for what people discussed in the last 30 days (Reddit, X, HN threads) — use last30days.
  Needs PERPLEXITY_API_KEY; without it, say so and fall back to WebSearch.
---

# Perplexity Research -- web search with sources

Search the web, fact-check claims, analyze trends, and find best practices using the
Perplexity Agent API. The key is read from the environment variable `PERPLEXITY_API_KEY`.

## Usage

1. Check the key: `[ -n "${PERPLEXITY_API_KEY:-}" ]` (see "No key" below if it is empty).
2. Query the Agent API.
3. Return structured results with the sources it cites.

## Example

```bash
curl -s -X POST "https://api.perplexity.ai/v1/agent" \
  -H "Authorization: Bearer $PERPLEXITY_API_KEY" \
  -H "Content-Type: application/json" \
  -d '{
    "preset": "fast",
    "input": "What are the best practices for Claude Code agent architecture in 2026?"
  }'
```

`preset` sets the depth: `fast` for everyday questions, `low` for multi-step
comparisons, `high` for a deep review (slower and more expensive). The old
`/chat/completions` endpoint is closed and answers 403.

## Reading the response

`output` is a list of steps: a `search_results` item with the sources and a
`message` item with the answer text. Pipe through jq:

```bash
... | jq -r '([.output[] | select(.type == "message") | .content[]
        | select(.type == "output_text") | .text] | join("\n")),
      "", "Sources:",
      (.output[] | select(.type == "search_results") | .results[]
        | "- \(.title) \(.url)")'
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
