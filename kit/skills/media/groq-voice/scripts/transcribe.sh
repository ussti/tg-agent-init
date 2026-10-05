#!/usr/bin/env bash
# groq-voice — transcribe audio via Groq Whisper. Requires GROQ_API_KEY.
set -euo pipefail

: "${GROQ_API_KEY:?set GROQ_API_KEY — get one free at https://console.groq.com/keys}"
FILE="${1:?usage: transcribe.sh <audio-file> [model]}"
MODEL="${2:-whisper-large-v3-turbo}"
[ -f "$FILE" ] || { echo "no such file: $FILE" >&2; exit 1; }

curl -sS --fail https://api.groq.com/openai/v1/audio/transcriptions \
  -H "Authorization: Bearer ${GROQ_API_KEY}" \
  -F "file=@${FILE}" \
  -F "model=${MODEL}" \
  -F "response_format=text"
