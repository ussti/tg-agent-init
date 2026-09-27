#!/usr/bin/env bash
# youtube-transcript — fetch subtitles via yt-dlp. No API key.
set -euo pipefail

URL="${1:?usage: yt-transcript.sh <youtube-url> [lang]}"
LANG="${2:-en}"
command -v yt-dlp >/dev/null 2>&1 || { echo "yt-dlp not installed — pip install yt-dlp" >&2; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
yt-dlp --quiet --no-warnings --skip-download \
  --write-auto-subs --write-subs --sub-lang "$LANG" --sub-format vtt \
  -o "$TMP/%(id)s.%(ext)s" "$URL" >/dev/null 2>&1 || true

VTT="$(find "$TMP" -name '*.vtt' | head -1)"
[ -n "$VTT" ] || { echo "no subtitles found for lang=$LANG" >&2; exit 1; }

# Strip WEBVTT header, timestamp lines, inline tags; drop blanks; collapse consecutive duplicates.
grep -vE '^(WEBVTT|Kind:|Language:|[0-9]{2}:[0-9]{2}:[0-9]{2})' "$VTT" \
  | sed -E 's/<[^>]+>//g' \
  | grep -vE '^[[:space:]]*$' \
  | awk '$0 != prev { print } { prev = $0 }'
