#!/usr/bin/env bash
# markdown-new — URL to clean Markdown via Jina Reader (r.jina.ai). No key required.
set -euo pipefail

URL="${1:?usage: to-markdown.sh <url>}"
AUTH=()
[ -n "${JINA_API_KEY:-}" ] && AUTH=(-H "Authorization: Bearer ${JINA_API_KEY}")

curl -sSL --fail "${AUTH[@]}" "https://r.jina.ai/${URL}"
