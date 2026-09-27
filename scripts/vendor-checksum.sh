#!/usr/bin/env bash
# Print one sha256 over a vendored tree: sorted relative paths + file contents.
# Used by update-vendor.sh (record) and leak-scan.sh (verify).
set -euo pipefail
dir="${1:?usage: vendor-checksum.sh <dir>}"
[ -d "$dir" ] || { echo "no such dir: $dir" >&2; exit 1; }
cd "$dir"
find . -type f -not -path './node_modules/*' -print0 | LC_ALL=C sort -z \
  | xargs -0 sha256sum | sha256sum | cut -d' ' -f1
