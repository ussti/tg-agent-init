#!/usr/bin/env bash
# Hourly snapshot of the agent workspace into a local git repository.
#
# The workspace (<AGENT_HOME>) gets its own repo on first run. Each snapshot is
# a commit on the `auto-snapshots` branch built from a private index, so HEAD,
# the working tree and any branch a human uses are never touched. Skips when the
# tree did not change. Off-host copy is opt-in: set SNAPSHOT_REMOTE to a git
# URL you control (private!) and the branch is pushed there too.
#
# Excluded (see the .gitignore written below): the built plugin and its
# node_modules, logs, runtime state, backups. Secrets live outside AGENT_HOME.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "$HERE/lib.sh"
load_agent_conf

REPO="${AGENT_HOME:?AGENT_HOME unset}"
BRANCH="${SNAPSHOT_BRANCH:-auto-snapshots}"
LOG_FILE="$LOG_DIR/snapshot.log"
mkdir -p "$LOG_DIR"
log() { echo "[$(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >> "$LOG_FILE"; }

cd "$REPO"
if [ ! -d .git ]; then
  git init -q
  git config user.name "${AGENT_NAME:-agent} snapshot"
  git config user.email "snapshot@localhost"
  log "initialized local snapshot repo in $REPO"
fi
if [ ! -f .gitignore ]; then
  cat > .gitignore <<'EOF'
.claude/dashi-plugin/
node_modules/
.claude/logs/
.claude/state/
.claude/backups/
*.log
.env
.env.*
*.key
*.pem
secrets/
EOF
fi

WORK_DIR="$(mktemp -d)"
trap 'find "$WORK_DIR" -mindepth 0 -delete 2>/dev/null || true' EXIT
export GIT_INDEX_FILE="$WORK_DIR/index"

git add -A
TREE="$(git write-tree)"

PARENT_ARGS=()
if PARENT="$(git rev-parse --verify --quiet "refs/heads/$BRANCH")"; then
  if [ "$TREE" = "$(git rev-parse "$PARENT^{tree}")" ]; then
    log "no change, skip"
    exit 0
  fi
  PARENT_ARGS=(-p "$PARENT")
fi

COMMIT="$(echo "auto-snapshot $(date -u +%Y-%m-%dT%H:%M:%SZ)" | git commit-tree "$TREE" "${PARENT_ARGS[@]}")"
git update-ref "refs/heads/$BRANCH" "$COMMIT"
log "ok: snapshot $COMMIT"

if [ -n "${SNAPSHOT_REMOTE:-}" ]; then
  if git push --quiet "$SNAPSHOT_REMOTE" "refs/heads/$BRANCH:refs/heads/$BRANCH" 2>>"$LOG_FILE"; then
    log "pushed to remote"
  else
    log "fail: push to remote"
    exit 1
  fi
fi
