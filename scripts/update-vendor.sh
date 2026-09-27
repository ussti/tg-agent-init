#!/usr/bin/env bash
# Refresh vendor/dashi-plugin from the upstream repository and check that the
# kit patch series still applies. On failure the previous vendor tree is kept.
#
# Usage: update-vendor.sh [ref]     (default ref: main)
# Env:   DASHI_UPSTREAM_URL         (default: the public upstream on GitHub)
set -euo pipefail

KIT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
UPSTREAM_URL="${DASHI_UPSTREAM_URL:-https://github.com/qwwiwi/dashi-plugin-claude-code.git}"
REF="${1:-main}"
VENDOR_DIR="$KIT_ROOT/vendor/dashi-plugin"
BACKUP_ROOT="$KIT_ROOT/.cache/vendor-backups"
WORK="$(mktemp -d)"

log() { echo "[update-vendor] $*"; }
cleanup() { [ -d "$WORK" ] && find "$WORK" -mindepth 0 -delete 2>/dev/null || true; }
trap cleanup EXIT

log "fetching $UPSTREAM_URL ($REF)"
git clone -q --depth 1 --branch "$REF" "$UPSTREAM_URL" "$WORK/src"
commit="$(git -C "$WORK/src" rev-parse HEAD)"
old="$(cat "$KIT_ROOT/vendor/UPSTREAM_COMMIT" 2>/dev/null || echo none)"
if [ "$commit" = "$old" ]; then
  log "already at $commit — nothing to do"
  exit 0
fi

mkdir -p "$WORK/new"
git -C "$WORK/src" archive HEAD | tar -x -C "$WORK/new"

# Dry-run the series against the new tree before touching vendor/.
mkdir -p "$WORK/trial"
cp -a "$WORK/new/." "$WORK/trial/"
failed=""
for p in "$KIT_ROOT"/patches/dashi-plugin/*.patch; do
  patch -d "$WORK/trial" -p1 --forward --batch --silent < "$p" >/dev/null 2>&1 \
    || failed="$failed $(basename "$p")"
done
if [ -n "$failed" ]; then
  log "patches no longer apply on $commit:$failed"
  log "vendor/ left at $old; rebase those patches, then rerun"
  exit 1
fi

mkdir -p "$BACKUP_ROOT"
mv "$VENDOR_DIR" "$BACKUP_ROOT/dashi-plugin-$old-$(date +%Y%m%d%H%M%S)"
mv "$WORK/new" "$VENDOR_DIR"
echo "$commit" > "$KIT_ROOT/vendor/UPSTREAM_COMMIT"
"$KIT_ROOT/scripts/vendor-checksum.sh" "$VENDOR_DIR" > "$KIT_ROOT/vendor/UPSTREAM_TREE_SHA256"
log "vendor updated $old -> $commit; previous tree kept under .cache/vendor-backups"
log "next: scripts/build-plugin.sh <dir> && (cd <dir>/plugin && bun install && bun test)"
