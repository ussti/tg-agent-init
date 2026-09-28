#!/usr/bin/env bash
# Fail if the kit carries personal identifiers or secret-shaped strings.
#
# Two passes:
#   1. entities — one extended regex per line, read from a list kept OUTSIDE
#      the repo (the list itself names the people it protects).
#   2. secrets  — generic credential shapes, always on.
#
# vendor/dashi-plugin/ and vendor/public-gbrain-agentos/ are upstream code,
# kept byte-identical to public commits: pass 1 tolerates upstream's own names
# (UPSTREAM_ALLOW), pass 2 is replaced by integrity checks against
# vendor/UPSTREAM_TREE_SHA256 and vendor/GBRAIN_TREE_SHA256 (their test suites
# are full of canary tokens). In patches/, lines added to test files are
# fixtures and skipped by pass 2; everything else is scanned.
#
# Usage: leak-scan.sh [kit-root]
# Env:   LEAK_ENTITIES_FILE (default ~/.config/tg-agent-init/leak-entities.txt)
set -euo pipefail

KIT_ROOT="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
ENTITIES="${LEAK_ENTITIES_FILE:-$HOME/.config/tg-agent-init/leak-entities.txt}"
UPSTREAM_ALLOW='thrall|edgelab'

SECRET_PATTERNS=(
  '[0-9]{8,10}:AA[A-Za-z0-9_-]{30,}'          # Telegram bot token
  'sk-ant-[A-Za-z0-9_-]{20,}'                  # Anthropic key / OAuth token
  'gh[pousr]_[A-Za-z0-9]{30,}'                 # GitHub token
  'gsk_[A-Za-z0-9]{20,}'                       # Groq key
  'sk-[A-Za-z0-9]{32,}'                        # generic sk- key
  'AKIA[0-9A-Z]{16}'                           # AWS access key id
  '-----BEGIN [A-Z ]*PRIVATE KEY-----'         # PEM private key
)

GREP_EXCLUDES=(--exclude-dir=.git --exclude-dir=node_modules --exclude-dir=.cache)
# Basename matches: also skips patches/<same name>, which the passes below cover.
VENDOR_EXCLUDES=(--exclude-dir=dashi-plugin --exclude-dir=public-gbrain-agentos)
fail=0

log() { echo "[leak-scan] $*"; }

if [ -f "$ENTITIES" ]; then
  hits="$(grep -rnIiE -f "$ENTITIES" "${GREP_EXCLUDES[@]}" "${VENDOR_EXCLUDES[@]}" \
            --exclude=leak-scan.sh "$KIT_ROOT" || true)"
  # --exclude-dir matches basenames, so patches/dashi-plugin was skipped above.
  patch_hits="$(grep -rnIiE -f "$ENTITIES" "$KIT_ROOT/patches" 2>/dev/null || true)"
  vendor_hits="$(grep -rnIiE -f "$ENTITIES" "${GREP_EXCLUDES[@]}" \
            "$KIT_ROOT/vendor/dashi-plugin" "$KIT_ROOT/vendor/public-gbrain-agentos" 2>/dev/null \
            | grep -viE "$UPSTREAM_ALLOW" || true)"
  hits="$(printf '%s\n%s\n%s\n' "$hits" "$patch_hits" "$vendor_hits" | sed '/^$/d')"
  if [ -n "$hits" ]; then
    log "FAIL: personal entities found:"
    printf '%s\n' "$hits" | cut -c1-200
    fail=1
  else
    log "entities: clean ($(grep -cv '^\s*$' "$ENTITIES") patterns)"
  fi
else
  log "WARN: entity list $ENTITIES not found — pass 1 skipped"
  [ "${LEAK_SCAN_REQUIRE_ENTITIES:-0}" = 1 ] && fail=1
fi

# Added lines of non-test files inside patches, as "patch:line<TAB>text".
patch_payload() {
  local f
  for f in "$KIT_ROOT"/patches/*/*.patch; do
    [ -f "$f" ] || continue
    awk -v f="$f" '
      /^\+\+\+ / { file = $2; next }
      /^\+/ && file !~ /(\/tests?\/|\.test\.)/ { print f ":" NR "\t" substr($0, 2) }
    ' "$f"
  done
}

secret_fail=0
for pat in "${SECRET_PATTERNS[@]}"; do
  hits="$(grep -rnIE -e "$pat" "${GREP_EXCLUDES[@]}" "${VENDOR_EXCLUDES[@]}" \
            --exclude=leak-scan.sh "$KIT_ROOT" | cut -d: -f1,2 || true)"
  hits="$hits$(patch_payload | grep -E -e "$pat" | cut -f1 || true)"
  if [ -n "$hits" ]; then
    # Print only file:line — never the matched value.
    log "FAIL: secret-shaped string ($pat) at:"
    printf '%s\n' "$hits"
    secret_fail=1
  fi
done
[ "$secret_fail" -eq 1 ] && fail=1

# vendor_integrity DIR SUMFILE: the vendored tree must match its pinned hash.
vendor_integrity() {
  local dir="$KIT_ROOT/vendor/$1" sum_file="$KIT_ROOT/vendor/$2" actual
  [ -d "$dir" ] || return 0
  actual="$("$KIT_ROOT/scripts/vendor-checksum.sh" "$dir")"
  if [ "$actual" != "$(cat "$sum_file" 2>/dev/null)" ]; then
    log "FAIL: vendor/$1 differs from the pinned upstream tree"
    fail=1
  else
    log "vendor/$1: matches pinned upstream tree"
  fi
}
vendor_integrity dashi-plugin UPSTREAM_TREE_SHA256
vendor_integrity public-gbrain-agentos GBRAIN_TREE_SHA256
[ "$secret_fail" -eq 0 ] && log "secrets: clean"

exit "$fail"
