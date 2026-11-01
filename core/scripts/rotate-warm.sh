#!/usr/bin/env bash
# rotate-warm.sh -- move decisions older than WARM_DAYS out of warm/decisions.md.
# Runs daily at 04:30 via cron. No LLM calls, deterministic.
#
# An entry is a "## " or "### " heading that starts with YYYY-MM-DD, plus
# everything up to the next dated heading or the next undated heading of the
# same or a higher level (so "###" subheadings under a "##" entry go with it).
# Entries dated before today minus WARM_DAYS move verbatim to
# core/archive/YYYY-MM.md (by entry month) and leave one index line in
# core/MEMORY.md. Undated sections are never touched. ROTATE_TODAY=YYYY-MM-DD
# overrides today (tests).
set -euo pipefail

AGENT_WS="${AGENT_WS:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
DECISIONS="$AGENT_WS/core/warm/decisions.md"
MEMORY="$AGENT_WS/core/MEMORY.md"
ARCHIVE_DIR="$AGENT_WS/core/archive"
WARM_DAYS=14
TODAY="${ROTATE_TODAY:-$(date +%F)}"
LOG_DIR="$AGENT_WS/logs"
LOG_FILE="$LOG_DIR/memory-cron.log"

mkdir -p "$LOG_DIR"

log() {
    echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] [rotate-warm] $*" >> "$LOG_FILE" 2>/dev/null || true
}

if [ ! -f "$DECISIONS" ]; then
    log "decisions.md missing, skip"
    exit 0
fi

python3 - "$DECISIONS" "$MEMORY" "$ARCHIVE_DIR" "$TODAY" "$WARM_DAYS" <<'PY'
import datetime
import os
import re
import sys
from pathlib import Path

dec_path, mem_path, archive_dir = Path(sys.argv[1]), Path(sys.argv[2]), Path(sys.argv[3])
cutoff = datetime.date.fromisoformat(sys.argv[4]) - datetime.timedelta(days=int(sys.argv[5]))
HOOK_MAX = 100

heading = re.compile(r'^(#{1,6}) (.*)$')
dated = re.compile(r'^(\d{4}-\d{2}-\d{2})\b')
lines = dec_path.read_text(encoding='utf-8').splitlines(keepends=True)


def entry_date(line):
    m = heading.match(line.rstrip('\n'))
    if not m or len(m.group(1)) not in (2, 3):
        return None
    d = dated.match(m.group(2))
    if not d:
        return None
    try:
        return len(m.group(1)), datetime.date.fromisoformat(d.group(1))
    except ValueError:
        return None


# (start, end, date) spans of dated entries.
entries = []
i = 0
while i < len(lines):
    found = entry_date(lines[i])
    if not found:
        i += 1
        continue
    level, date = found
    j = i + 1
    while j < len(lines):
        m = heading.match(lines[j].rstrip('\n'))
        if m and (entry_date(lines[j]) or len(m.group(1)) <= level):
            break
        j += 1
    entries.append((i, j, date))
    i = j

stale = [e for e in entries if e[2] < cutoff]
if not stale:
    sys.exit(0)


def index_line(text, date):
    first, *rest = text.splitlines()
    title = re.sub(r'\s+', ' ', heading.match(first).group(2).replace('[', '').replace(']', ''))
    # First line of the body (a subheading's text counts), as plain text.
    line = next((l.strip() for l in rest if l.strip() and l.strip() != '---'), '')
    m = heading.match(line)
    hook = m.group(2) if m else re.sub(r'^[-*+]\s+', '', line)
    hook = re.sub(r'\*\*|__', '', hook).strip()
    if len(hook) > HOOK_MAX:
        hook = hook[:HOOK_MAX - 1].rstrip() + '…'
    link = f"- [{title}](archive/{date:%Y-%m}.md)"
    return f"{link} — {hook}" if hook else link


archive_dir.mkdir(parents=True, exist_ok=True)
index = []
# Archive and index first: a crash before decisions.md is rewritten
# duplicates an entry on the next run instead of losing it.
for start, end, date in sorted(stale, key=lambda e: e[2]):
    text = ''.join(lines[start:end]).rstrip() + '\n'
    with (archive_dir / f"{date:%Y-%m}.md").open('a', encoding='utf-8') as f:
        f.write('\n' + text)
    index.append(index_line(text, date))

mem = mem_path.read_text(encoding='utf-8') if mem_path.exists() else '# MEMORY.md\n'
mem_path.write_text(mem.rstrip('\n') + '\n' + '\n'.join(index) + '\n', encoding='utf-8')

drop = set()
for start, end, _ in stale:
    drop.update(range(start, end))
kept = ''.join(l for n, l in enumerate(lines) if n not in drop).strip('\n')
tmp = dec_path.with_suffix('.md.tmp')
tmp.write_text(kept + '\n' if kept else '', encoding='utf-8')
os.replace(tmp, dec_path)
print(f"rotated: {len(stale)} entr(y/ies) older than {cutoff} to archive/")
PY

log "rotate-warm complete"
