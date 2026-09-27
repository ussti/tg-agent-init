#!/usr/bin/env bash
# Hook: Stop — generates handoff.md by merging ALL core/hot/recent*.md files
# Source: HOOKS.md write-handoff pattern + dual-recall §13 + Bug #2 (multi-file merge)
#
# Behavior:
#   - Reads every core/hot/recent*.md (the Stop hook writes recent.md; extra recent-*.md files merge if present).
#   - Parses entries by "### YYYY-MM-DD HH:MM" headers, merges, sorts ascending by timestamp.
#   - Takes last 10 unique entries, redacts secrets, atomic write to handoff.md (tmp+mv).
#   - Tolerates missing files. If no entries found anywhere, leaves handoff.md untouched.
#   - Deduplication: entries with identical header line + body collapse to one
#     (`sort -u` on the full record). Independent entries with same timestamp but
#     different content are kept as separate records.
#   - Timestamps: header format "YYYY-MM-DD HH:MM" — the writer uses a wall-clock formatter (local tz). If
#     files ever diverge on tz, sort order may drift but uniqueness still works.
#     The "Last update" line emits UTC for unambiguous comparison.
set -euo pipefail

WORKSPACE="$CLAUDE_PROJECT_DIR/.claude"
HOT_DIR="$WORKSPACE/core/hot"
HANDOFF="$HOT_DIR/handoff.md"

# Collect every recent*.md file. nullglob ensures empty match yields no args.
shopt -s nullglob
ALL_RECENTS=("$HOT_DIR"/recent.md "$HOT_DIR"/recent-*.md)
shopt -u nullglob

# Filter to only existing readable files; skip backups and tmp files.
RECENTS=()
for f in "${ALL_RECENTS[@]}"; do
  bn=$(basename "$f")
  [[ -f "$f" && -r "$f" ]] || continue
  [[ "$bn" == .* ]] && continue           # skip .recent.md.tmp.* and dotfiles
  [[ "$bn" == *.bak_* ]] && continue       # skip *.bak_YYYYMMDD_HHMMSS
  [[ "$bn" == *.pre-trim ]] && continue    # skip *.pre-trim
  RECENTS+=("$f")
done

if [ ${#RECENTS[@]} -eq 0 ]; then
  exit 0
fi

# Merge + sort + dedup + take last 10. awk splits each file into "### ts" blocks,
# emits one record per block prefixed with the header line as sort key,
# separated by NUL. Pipeline: sort -z -u (dedup full records), tail -z -n 10,
# strip prefix, separate with blank lines.
MERGED=$(awk '
  FNR == 1 {
    # New file — flush any pending entry from prior file and reset state
    # so the new file is preamble (lines before first "### ") is dropped
    # instead of being glued to the last entry of the previous file.
    if (header != "") printf "%s\t%s\0", header, current
    header = ""
    current = ""
  }
  /^### / {
    if (header != "") {
      printf "%s\t%s\0", header, current
    }
    header = $0
    current = $0 "\n"
    next
  }
  {
    if (header != "") current = current $0 "\n"
  }
  END {
    if (header != "") printf "%s\t%s\0", header, current
  }
' "${RECENTS[@]}" \
  | sort -z -u \
  | tail -z -n 10 \
  | awk 'BEGIN { RS="\0" } NF > 0 { sub(/^[^\t]*\t/, ""); print; print "" }')

# Empty merge guard — if all files were headerless / empty, do nothing.
if [ -z "$MERGED" ]; then
  exit 0
fi

# Secret-redaction before any write to handoff.md (committed via auto-snapshot).
REDACTED=$(printf '%s' "$MERGED" | sed -E \
  -e 's/[0-9]{8,12}:[A-Za-z0-9_-]{30,}/***REDACTED-TELEGRAM-TOKEN***/g' \
  -e 's/AKIA[0-9A-Z]{16}/***REDACTED-AWS-KEY***/g' \
  -e 's/sk-[A-Za-z0-9]{32,}/***REDACTED-OPENAI-KEY***/g' \
  -e 's/sk-ant-[A-Za-z0-9_-]{40,}/***REDACTED-ANTHROPIC-KEY***/g' \
  -e 's/ghp_[A-Za-z0-9]{36}/***REDACTED-GITHUB-PAT***/g' \
  -e 's/gho_[A-Za-z0-9]{36}/***REDACTED-GITHUB-OAUTH***/g' \
  -e 's/xox[bpars]-[A-Za-z0-9-]{20,}/***REDACTED-SLACK-TOKEN***/g' \
  -e 's/(apify_api_)[A-Za-z0-9]{30,}/\1***REDACTED***/g' \
  -e 's/(BEGIN [A-Z ]*PRIVATE KEY)[^-]*/\1***REDACTED-PRIVATE-KEY***/g')

# Atomic write — same-dir tmp + rename so partial handoff.md is never observable.
# Same-dir = metadata-only rename, no EXDEV. Cleanup on early exit.
TMP="$HOT_DIR/.handoff.md.tmp.$$"
trap 'rm -f "$TMP"' EXIT

# Build source list for the header banner (basenames only).
SOURCES=""
for f in "${RECENTS[@]}"; do
  SOURCES="$SOURCES $(basename "$f")"
done
SOURCES="${SOURCES# }"

{
  echo "# handoff.md -- Last 10 entries (auto-generated)"
  echo
  echo "_Merged from: $SOURCES — multi-file merge. Auto-regenerated on Stop hook._"
  echo "_Last update: $(date -u +'%Y-%m-%dT%H:%M:%SZ')_"
  echo "_@included into CLAUDE.md context._"
  echo
  echo "---"
  echo
  echo "$REDACTED"
} > "$TMP"

mv "$TMP" "$HANDOFF"
trap - EXIT
exit 0
