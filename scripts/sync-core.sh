#!/usr/bin/env bash
# sync-core.sh -- copy the agent core (identity/memory templates, hooks, memory
# scripts, skills, memory cron) from a local-agent-kit checkout (the core source repo) into core/.
#
# The core is the same one the local kit installs; this kit only adds the
# Telegram server layer on top. Examples, tests, installer and docs of the
# source repo are NOT copied. A few source comments name the original operator
# and agents; they are rewritten by generic patterns below, and the leak scan
# (scripts/leak-scan.sh) is the gate that proves nothing personal remains.
#
# Usage: scripts/sync-core.sh <core-source checkout>
set -euo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${1:-}"
[ -n "$SRC" ] && [ -d "$SRC/templates" ] || {
  echo "usage: $0 <core-source checkout>" >&2
  exit 2
}
SRC="$(cd "$SRC" && pwd)"
DEST="$KIT_DIR/core"
STAGE="$(mktemp -d)"
trap 'find "$STAGE" -mindepth 0 -delete 2>/dev/null || true' EXIT

echo "[sync-core] source: $SRC"
mkdir -p "$STAGE/core/cron"
cp -R "$SRC/templates" "$SRC/hooks" "$SRC/scripts" "$STAGE/core/"
mkdir -p "$STAGE/core/skills"
cp -R "$SRC/skills/onboard" "$STAGE/core/skills/"   # the rest of the kit lives in kit/
cp "$SRC/cron/install-cron.sh" "$STAGE/core/cron/"

python3 - "$STAGE/core" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
# (file glob, pattern, replacement) -- generic, no names in this script
RULES = [
    ("scripts/learnings-engine.mjs", r"(Learnings System v2 engine) for [A-Z][A-Za-z]+\.", r"\1."),
    ("scripts/learnings-engine.mjs", r"RED file\. [A-Z][a-z]+ still approves", "RED file. The operator still approves"),
    ("scripts/learnings-engine.mjs", r"\([a-z]+, (\d{4}-\d{2}-\d{2}): ", r"(field report \1: "),
    ("hooks/write-handoff.sh", r"\(Asia/[A-Za-z_]+ local-tz\)", "(local tz)"),
]
for rel, pat, rep in RULES:
    path = root / rel
    text = path.read_text(encoding="utf-8")
    new, count = re.subn(pat, rep, text)
    if count == 0:
        print(f"[sync-core] note: pattern not found in {rel}: {pat}")
    path.write_text(new, encoding="utf-8")
PY

VERSION="$(git -C "$SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
echo "$VERSION" > "$STAGE/core/CORE_VERSION"

if [ -d "$DEST" ]; then
  mv "$DEST" "$STAGE/core.old"
fi
mv "$STAGE/core" "$DEST"
echo "[sync-core] core/ updated to core-source $VERSION"
echo "[sync-core] next: scripts/leak-scan.sh must pass before commit"
