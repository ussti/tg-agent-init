#!/usr/bin/env bash
# memory-rotate.sh -- keep core/MEMORY.md an index when it grows past threshold.
# Runs daily at 21:00 via cron. No LLM calls.
#
# MEMORY.md is a one-line-per-topic index into core/archive/ (rotate-warm.sh
# writes it). When the file is over 5KB, every prose section in it -- a "## "
# or "### " heading through the next heading of the same or a higher level or
# the next index line -- moves verbatim to archive/YYYY-MM.md (the month of the
# heading's date, else this month) and is replaced in place by one index line.
# Index lines and the header are never moved. ROTATE_TODAY=YYYY-MM-DD
# overrides today (tests).
set -euo pipefail

AGENT_WS="${AGENT_WS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
MEMORY="$AGENT_WS/core/MEMORY.md"
ARCHIVE_DIR="$AGENT_WS/core/archive"
LOG_DIR="$AGENT_WS/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"
SIZE_LIMIT=5120  # 5KB
TODAY="${ROTATE_TODAY:-$(date +%F)}"

mkdir -p "$LOG_DIR" "$ARCHIVE_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [memory-rotate] $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$MEMORY" ]; then
    log "MEMORY.md missing, skip"
    exit 0
fi

SIZE=$(wc -c < "$MEMORY" | tr -d ' ')
if [ "$SIZE" -le "$SIZE_LIMIT" ]; then
    log "MEMORY.md ok (${SIZE}B)"
    exit 0
fi

RESULT=$(python3 - "$MEMORY" "$ARCHIVE_DIR" "$TODAY" <<'PY'
import os
import re
import sys
from pathlib import Path

memory, archive_dir, today = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
HOOK_MAX = 100

heading = re.compile(r'^(#{1,6}) (.*)$')
dated = re.compile(r'^(\d{4})-(\d{2})-\d{2}\b')
index_entry = re.compile(r'^- \[.*\]\(archive/[^)]*\)')
# Separator + marker the old rotate-warm.sh wrote before every appended section.
marker = re.compile(r'^(---|\(rotated from .*\))$')


def section_level(line):
    m = heading.match(line.rstrip('\n'))
    return len(m.group(1)) if m and len(m.group(1)) in (2, 3) else None


def index_line(text, month):
    """Same format as rotate-warm.sh: "- [title](archive/YYYY-MM.md) — hook"."""
    first, *rest = text.splitlines()
    title = re.sub(r'\s+', ' ', heading.match(first).group(2).replace('[', '').replace(']', ''))
    line = next((l.strip() for l in rest if l.strip() and not marker.match(l.strip())), '')
    m = heading.match(line)
    hook = m.group(2) if m else re.sub(r'^[-*+]\s+', '', line)
    hook = re.sub(r'\*\*|__', '', hook).strip()
    if len(hook) > HOOK_MAX:
        hook = hook[:HOOK_MAX - 1].rstrip() + '…'
    link = f"- [{title}](archive/{month}.md)"
    return f"{link} — {hook}" if hook else link


lines = memory.read_text(encoding='utf-8').splitlines(keepends=True)
out, moved = [], {}
i = 0
while i < len(lines):
    level = section_level(lines[i])
    if level is None:
        if not marker.match(lines[i].strip()):
            out.append(lines[i])
        i += 1
        continue
    j = i + 1
    while j < len(lines):
        other = section_level(lines[j])
        if (other is not None and other <= level) or index_entry.match(lines[j]):
            break
        j += 1
    body = lines[i:j]
    while body and (not body[-1].strip() or marker.match(body[-1].strip())):
        body.pop()  # the next section's separator, not this one's text
    text = ''.join(body).rstrip() + '\n'
    d = dated.match(heading.match(lines[i].rstrip('\n')).group(2))
    month = f"{d.group(1)}-{d.group(2)}" if d else today[:7]
    moved.setdefault(month, []).append(text)
    out.append(index_line(text, month) + '\n')
    i = j

if not moved:
    print("nothing to move")
    sys.exit(0)

archive_dir.mkdir(parents=True, exist_ok=True)
# Archive first: a crash before MEMORY.md is rewritten duplicates a section
# in the archive on the next run instead of losing it.
for month, texts in moved.items():
    with (archive_dir / f"{month}.md").open('a', encoding='utf-8') as f:
        f.write(''.join('\n' + t for t in texts))
kept = re.sub(r'\n{3,}', '\n\n', ''.join(out)).rstrip('\n') + '\n'
tmp = memory.with_suffix('.md.tmp')
tmp.write_text(kept, encoding='utf-8')
os.replace(tmp, memory)
print(f"moved {sum(map(len, moved.values()))} section(s) to archive/")
PY
)

log "MEMORY.md ${SIZE}B: ${RESULT}"
