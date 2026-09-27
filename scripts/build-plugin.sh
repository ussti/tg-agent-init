#!/usr/bin/env bash
# Assemble the runnable dashi plugin: pristine upstream from vendor/ plus the
# kit patch series from patches/, applied in order into a fresh directory.
#
# Usage: build-plugin.sh <target-dir>
#   <target-dir> must not exist yet; it receives the patched plugin tree.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$KIT_ROOT/vendor/dashi-plugin"
PATCH_DIR="$KIT_ROOT/patches/dashi-plugin"
TARGET="${1:-}"

log() { echo "[build-plugin] $*"; }

[ -n "$TARGET" ] || { echo "usage: $0 <target-dir>" >&2; exit 2; }
[ -e "$TARGET" ] && { echo "refusing: $TARGET already exists" >&2; exit 1; }
[ -d "$VENDOR_DIR/plugin" ] || { echo "missing vendor tree at $VENDOR_DIR" >&2; exit 1; }
command -v patch >/dev/null || { echo "missing 'patch' binary" >&2; exit 1; }

mkdir -p "$TARGET"
cp -a "$VENDOR_DIR/." "$TARGET/"
log "copied upstream $(cat "$KIT_ROOT/vendor/UPSTREAM_COMMIT" 2>/dev/null || echo unknown)"

# GNU patch, not git apply: the target may sit inside an unrelated git
# work tree, where git apply resolves paths against that repo's root.
shopt -s nullglob
applied=0
for p in "$PATCH_DIR"/*.patch; do
  if ! patch -d "$TARGET" -p1 --forward --batch --silent < "$p"; then
    log "FAILED: $(basename "$p") — rerun scripts/update-vendor.sh to rebase the series"
    exit 1
  fi
  applied=$((applied + 1))
  log "applied $(basename "$p")"
done
find "$TARGET" \( -name '*.orig' -o -name '*.rej' \) -delete
log "done: $applied patches on top of upstream -> $TARGET"
