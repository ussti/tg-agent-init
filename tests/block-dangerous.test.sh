#!/usr/bin/env bash
# block-dangerous.test.sh -- force-push spellings are blocked, ordinary pushes pass.
set -euo pipefail

HOOK="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/core/hooks/block-dangerous.sh"
fail=0

check() {
  local want="$1" cmd="$2" got
  if jq -n --arg c "$cmd" '{tool_input:{command:$c}}' | bash "$HOOK" >/dev/null 2>&1; then
    got=allow
  else
    got=block
  fi
  if [ "$got" = "$want" ]; then
    echo "  ok   $got  $cmd"
  else
    echo "  FAIL $got  $cmd (want $want)"
    fail=1
  fi
}

# Split so the literal flag does not trip hooks on the machine running the suite.
LONG="--for""ce"

check block "git push origin -f"
check block "git push -f"
check block "git push origin main -uf"
check block "git push origin +main"
check block "git push $LONG-with-lease"
check block "git push origin main $LONG"
check allow "git push"
check allow "git push --tags"
check allow "git push -u origin fix/foo"
check allow "git push -u origin refactor/info-f"
check allow "git push origin feature/fast-loop"
check allow "git push origin HEAD:refs/heads/x"
check allow "git commit -m 'fix' && git push origin fix/a"

exit "$fail"
