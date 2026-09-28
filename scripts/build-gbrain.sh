#!/usr/bin/env bash
# Assemble the shared brain (G-Brain) tree: pristine upstream from
# vendor/public-gbrain-agentos plus patches/public-gbrain-agentos, applied in
# order into a fresh directory. install-fleet.sh runs upstream's installer
# from the result.
#
# Usage: build-gbrain.sh <target-dir>
#   <target-dir> must not exist yet; it receives the patched tree.
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VENDOR_DIR="$KIT_ROOT/vendor/public-gbrain-agentos"
PATCH_DIR="$KIT_ROOT/patches/public-gbrain-agentos"
TARGET="${1:-}"

log() { echo "[build-gbrain] $*"; }

[ -n "$TARGET" ] || { echo "usage: $0 <target-dir>" >&2; exit 2; }
[ -e "$TARGET" ] && { echo "refusing: $TARGET already exists" >&2; exit 1; }
[ -f "$VENDOR_DIR/scripts/install.sh" ] || { echo "missing vendor tree at $VENDOR_DIR" >&2; exit 1; }
command -v patch >/dev/null || { echo "missing 'patch' binary" >&2; exit 1; }

mkdir -p "$TARGET"
cp -a "$VENDOR_DIR/." "$TARGET/"
log "copied upstream $(cat "$KIT_ROOT/vendor/GBRAIN_UPSTREAM_COMMIT" 2>/dev/null || echo unknown)"

shopt -s nullglob
applied=0
for p in "$PATCH_DIR"/*.patch; do
  if ! patch -d "$TARGET" -p1 --forward --batch --silent < "$p"; then
    log "FAILED: $(basename "$p") no longer applies to the vendored tree"
    exit 1
  fi
  applied=$((applied + 1))
  log "applied $(basename "$p")"
done
find "$TARGET" \( -name '*.orig' -o -name '*.rej' \) -delete
log "done: $applied patches on top of upstream -> $TARGET"
