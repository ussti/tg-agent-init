#!/usr/bin/env bash
# trim-hot.sh -- trim hot memory (recent.md + recent-plugin.md + handoff.md) by size and age.
# Runs daily at 05:00 via cron. No LLM calls, deterministic.
#
# Behavior:
#   - recent.md / recent-plugin.md > 12KB: keep last 50 "### " entries, shrink until < 12KB (min 20).
#   - handoff.md > 12KB: drop whole oldest "### " entries (min 3), backup .pre-trim.
#   - handoff.md mtime > 6h: overwrite with "stale" placeholder.
set -euo pipefail

AGENT_WS="${AGENT_WS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
RECENT="$AGENT_WS/core/hot/recent.md"
RECENT_PLUGIN="$AGENT_WS/core/hot/recent-plugin.md"
HANDOFF="$AGENT_WS/core/hot/handoff.md"
LOG_DIR="$AGENT_WS/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [trim-hot] $*" >> "$LOG_FILE" 2>/dev/null || true
}

# -------- recent journals: size cap (recent.md + recent-plugin.md) --------
RECENT_LIMIT=12288  # 12KB
RECENT_MIN_ENTRIES=20  # floor wins over the size cap -- never shrink below this

trim_recent() {
    local f="$1" limit="$2" name SIZE
    name=$(basename "$f")
    [ -f "$f" ] || return 0
    SIZE=$(wc -c < "$f" | tr -d ' ')
    if [ "$SIZE" -gt "$limit" ]; then
        cp "$f" "${f}.pre-trim"
        python3 - "$f" "$limit" "$name" "$RECENT_MIN_ENTRIES" <<'PY'
import re, sys
path = sys.argv[1]
limit = int(sys.argv[2])
name = sys.argv[3]
min_entries = int(sys.argv[4])
content = open(path, encoding='utf-8').read()
header_match = re.match(r'^#[^#].*\n', content)
header = header_match.group(0) if header_match else "# Hot memory -- rolling journal\n\n"
entries = list(re.finditer(r'^### ', content, re.MULTILINE))
total = len(entries)
if total > 50:
    keep_from = entries[-50].start()
    trimmed = header + "\n" + content[keep_from:]
    entries = list(re.finditer(r'^### ', trimmed, re.MULTILINE))
else:
    trimmed = content
while len(trimmed.encode('utf-8')) > limit and len(entries) > min_entries:
    # Drop the oldest entry and re-slice from the next-oldest. Offsets must be
    # recomputed against the CURRENT trimmed, else later iterations cut stale.
    next_start = entries[1].start()
    trimmed = header + "\n" + trimmed[next_start:]
    entries = list(re.finditer(r'^### ', trimmed, re.MULTILINE))
open(path, 'w', encoding='utf-8').write(trimmed)
final = len(list(re.finditer(r'^### ', trimmed, re.MULTILINE)))
print(f"{name} trimmed: {total} -> {final} entries, {len(trimmed.encode('utf-8'))}B")
PY
        log "$name trimmed from ${SIZE}B"
    else
        log "$name ok (${SIZE}B)"
    fi
}

trim_recent "$RECENT" "$RECENT_LIMIT"
trim_recent "$RECENT_PLUGIN" "$RECENT_LIMIT"

# -------- handoff.md: staleness + byte cap --------
HANDOFF_SIZE_LIMIT=12288
HANDOFF_STALE_HOURS=6
HANDOFF_MIN_ENTRIES=3

if [ -f "$HANDOFF" ]; then
    FILE_MOD=$(stat -c%Y "$HANDOFF" 2>/dev/null || echo 0)
    NOW=$(date +%s)
    AGE_HOURS=$(( (NOW - FILE_MOD) / 3600 ))

    if [ "$AGE_HOURS" -ge "$HANDOFF_STALE_HOURS" ]; then
        cat > "$HANDOFF" <<STALE
# handoff.md -- last 10 entries (@include)

Previous session ended more than ${HANDOFF_STALE_HOURS}h ago. Context stale.
Start a fresh session: recall recent work from core/hot/recent.md if needed.
STALE
        log "handoff.md stale (${AGE_HOURS}h), cleared"
    else
        SIZE=$(wc -c < "$HANDOFF" | tr -d ' ')
        if [ "$SIZE" -gt "$HANDOFF_SIZE_LIMIT" ]; then
            cp "$HANDOFF" "${HANDOFF}.pre-trim"
            TMPFILE=$(mktemp "${HANDOFF}.XXXXXX")
            python3 - "$HANDOFF" "$TMPFILE" "$HANDOFF_SIZE_LIMIT" "$HANDOFF_MIN_ENTRIES" <<'PY'
"""Drop whole oldest entries until the file fits.

Cutting must land on a "### " boundary: a blind byte cut leaves a half entry,
which reads as fact and misleads the next session (it did, 2026-08-01).

Entry order is NOT fixed across the fleet -- write-handoff.sh here sorts
ascending (newest last), other agents emit newest-first. So decide which end
is the old one by comparing the first and last entry timestamps, and drop from
there. Guessing the order deletes the freshest entries instead.
"""
import re
import sys
from pathlib import Path

handoff = Path(sys.argv[1])
tmpfile = Path(sys.argv[2])
max_bytes = int(sys.argv[3])
min_entries = int(sys.argv[4])

ENTRY_RE = re.compile(r"^### ", re.MULTILINE)
# No "^" anchor: this is matched at a known entry offset via match(text, pos),
# and "^" only matches at the real string start, never at pos > 0.
STAMP_RE = re.compile(r"### (\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2})")


def stamp(text, pos):
    """Timestamp of the entry starting at pos, or '' when unparseable."""
    m = STAMP_RE.match(text, pos)
    return m.group(1).replace("T", " ") if m else ""


content = handoff.read_text(encoding="utf-8", errors="replace")
starts = [m.start() for m in ENTRY_RE.finditer(content)]

# Newest-first only when the timestamps say so; on ties or unparseable headers
# fall through to ascending, matching this agent's writer.
newest_first = bool(starts) and stamp(content, starts[0]) > stamp(content, starts[-1])

while len(content.encode("utf-8")) > max_bytes and len(starts) > min_entries:
    if newest_first:
        content = content[: starts[-1]].rstrip() + "\n"
    else:
        content = content[: starts[0]] + content[starts[1]:]
    starts = [m.start() for m in ENTRY_RE.finditer(content)]

tmpfile.write_text(content, encoding="utf-8")
PY
            mv "$TMPFILE" "$HANDOFF"
            log "handoff.md trimmed from ${SIZE}B to <=${HANDOFF_SIZE_LIMIT}B"
        fi
    fi
fi

log "trim-hot complete"
