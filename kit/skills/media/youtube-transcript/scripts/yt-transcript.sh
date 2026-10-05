#!/usr/bin/env bash
# youtube-transcript — fetch subtitles via yt-dlp; optional TRANSCRIPT_API_KEY fallback
# (transcriptapi.com) when yt-dlp is missing or finds no subtitles.
set -euo pipefail

URL="${1:?usage: yt-transcript.sh <youtube-url> [lang]}"
LANG="${2:-en}"
API_ENDPOINT="https://transcriptapi.com/api/v2/youtube/transcript"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

# Fallback: transcriptapi.com. The key goes to curl through a 0600 header file, never argv.
api_fallback() {
  local hdr="$TMP/auth.hdr" body="$TMP/api.out"
  command -v curl >/dev/null 2>&1 || { echo "curl not installed" >&2; return 1; }
  ( umask 077; printf 'Authorization: Bearer %s\n' "$TRANSCRIPT_API_KEY" > "$hdr" )
  curl -fsS --max-time 60 -G "$API_ENDPOINT" -H "@$hdr" \
    --data-urlencode "video_url=$URL" --data-urlencode "format=text" \
    --data-urlencode "include_timestamp=false" --data-urlencode "language=$LANG" \
    -o "$body" || { echo "transcriptapi request failed" >&2; return 1; }
  # format=text may come back as JSON with a string/list transcript or as raw text.
  python3 - "$body" <<'PY'
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
try:
    data = json.loads(raw)
except ValueError:
    sys.stdout.write(raw if raw.endswith("\n") else raw + "\n")
    sys.exit(0)
tr = data.get("transcript", "") if isinstance(data, dict) else ""
if isinstance(tr, list):
    tr = "\n".join(str(seg.get("text", "")) for seg in tr if isinstance(seg, dict))
if not str(tr).strip():
    sys.stderr.write("transcriptapi returned no transcript\n")
    sys.exit(1)
print(str(tr).strip())
PY
}

VTT=""
if command -v yt-dlp >/dev/null 2>&1; then
  yt-dlp --quiet --no-warnings --skip-download \
    --write-auto-subs --write-subs --sub-lang "$LANG" --sub-format vtt \
    -o "$TMP/%(id)s.%(ext)s" "$URL" >/dev/null 2>&1 || true
  VTT="$(find "$TMP" -name '*.vtt' | head -1)"
fi

if [ -z "$VTT" ]; then
  if [ -n "${TRANSCRIPT_API_KEY:-}" ]; then
    api_fallback
    exit $?
  fi
  if ! command -v yt-dlp >/dev/null 2>&1; then
    echo "yt-dlp not installed — pip install yt-dlp (or set TRANSCRIPT_API_KEY for transcriptapi.com)" >&2
  else
    echo "no subtitles found for lang=$LANG (set TRANSCRIPT_API_KEY to enable the transcriptapi.com fallback)" >&2
  fi
  exit 1
fi

# Strip WEBVTT header, timestamp lines, inline tags; drop blanks; collapse consecutive duplicates.
grep -vE '^(WEBVTT|Kind:|Language:|[0-9]{2}:[0-9]{2}:[0-9]{2})' "$VTT" \
  | sed -E 's/<[^>]+>//g' \
  | grep -vE '^[[:space:]]*$' \
  | awk '$0 != prev { print } { prev = $0 }'
