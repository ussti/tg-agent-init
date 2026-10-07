#!/usr/bin/env bash
# smoke-kit.sh -- install the kit for real into a throwaway HOME and check every tool.
# Usage: scripts/smoke-kit.sh <REPORT_MD>
# Gates: each pinned tool installed at its pinned version and starts. Informational:
# the trial last30days search (keyless Reddit is often blocked from datacenter IPs).
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPORT="${1:?usage: smoke-kit.sh <REPORT_MD>}"
V="$REPO/kit/versions.env"
[ -r "$V" ] || { echo "[smoke] no $V" >&2; exit 2; }
pin() { sed -n "s/^$1=//p" "$V" | tr -d '\r' | head -n 1; }

SMOKE_HOME="${SMOKE_HOME:-$(mktemp -d)}"
export HOME="$SMOKE_HOME"
export PATH="$HOME/.local/bin:$PATH"
WS="$HOME/ws"
mkdir -p "$WS"
failed=0

row() { echo "| $1 | $2 | $3 |" >> "$REPORT"; echo "[smoke] $1: $2 $3"; }
gate() {  # gate <name> <detail-on-success> <cmd...>
  local name="$1" detail="$2"; shift 2
  local out
  if out="$("$@" 2>&1)"; then
    row "$name" ok "$detail"
  else
    row "$name" FAIL "$(printf '%s' "$out" | tail -n 1 | tr '|' '/' | cut -c1-120)"
    failed=1
  fi
}
has_version() {  # has_version <expected> <cmd...>: command output contains the version
  local want="$1"; shift
  "$@" 2>&1 | grep -qF "$want"
}
pipx_version() {  # pipx_version <package> -> installed version
  pipx list --json | python3 -c \
    "import json,sys; v=json.load(sys.stdin)['venvs'].get(sys.argv[1]); \
print(v['metadata']['main_package']['package_version'] if v else '')" "$1"
}

{ echo; echo "| Check | Result | Detail |"; echo "|---|---|---|"; } >> "$REPORT"

echo "[smoke] installing the kit into $WS (HOME=$HOME)"
if bash "$REPO/kit/install-kit.sh" "$WS" "$HOME/.claude-agent-smoke" > "$HOME/install.log" 2>&1
then
  row "kit install" ok "$(grep -c 'WARN' "$HOME/install.log" || true) warnings"
else
  row "kit install" FAIL "exit $?, see job log"; failed=1
fi
grep 'WARN' "$HOME/install.log" || true

ab="$(pin AGENT_BROWSER_VERSION)"; vc="$(pin VERCEL_CLI_VERSION)"
gws="$(pin GWS_CLI_VERSION)"; c4="$(pin CRAWL4AI_VERSION)"
l30="$(pin LAST30DAYS_COMMIT)"

gate "agent-browser $ab" "--version matches" has_version "$ab" agent-browser --version
gate "vercel CLI $vc" "--version matches" has_version "$vc" npx --yes "vercel@$vc" --version
gate "gws-cli $gws" "pipx version matches" test "$(pipx_version gws-cli)" = "$gws"
gate "gws-cli starts" "--help" gws-cli --help
gate "crawl4ai $c4" "pipx version matches" test "$(pipx_version crawl4ai)" = "$c4"
gate "crwl starts" "--help" crwl --help
gate "yt-dlp" "$(yt-dlp --version 2>/dev/null || echo missing)" yt-dlp --version
L30="$WS/kit/vendor/last30days"
gate "last30days ${l30:0:12}" "checkout on pin" test "$(git -C "$L30" rev-parse HEAD)" = "$l30"
gate "last30days skill linked" "SKILL.md present" test -f "$WS/skills/last30days/SKILL.md"
gate "last30days starts" "--help" python3 "$L30/skills/last30days/scripts/last30days.py" --help

if [ "${SMOKE_SKIP_SEARCH:-0}" = 1 ]; then
  row "last30days trial search" skipped "SMOKE_SKIP_SEARCH=1"
else
  out="$(timeout 300 python3 "$L30/skills/last30days/scripts/last30days.py" "claude code" \
    --search reddit --quick --emit compact 2>&1 || true)"
  threads="$(printf '%s' "$out" | grep -oE 'Reddit: [0-9]+ threads' | grep -oE '[0-9]+' \
    | head -n 1 || true)"
  row "last30days trial search (info)" "${threads:-0} Reddit threads" \
    "informational; runner IPs are often blocked"
fi

echo "[smoke] done, failed=$failed"
exit "$failed"
