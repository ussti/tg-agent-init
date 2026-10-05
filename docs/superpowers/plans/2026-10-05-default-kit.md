# Default Kit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** every agent installed by `install-server.sh` comes with the approved default kit of
skills, plugins and CLI tools already in place, plus an optional «Keys» step and optional
Google / GitHub / Vercel logins.

**Architecture:** the kit lives in a new top-level `kit/` folder, outside `core/`, because
`scripts/sync-core.sh` replaces `core/` wholesale. Skills are grouped by category
(`kit/skills/<category>/<skill>/`); the installer copies `kit/` into the workspace and flattens it
with relative symlinks into `$AGENT_WS/skills/<skill>`, because Claude Code discovers skills only
one level deep. Third-party programs are installed from their official source (npm, pipx, git at
a pinned commit, plugin marketplaces); keys go into `$SECRETS_DIR/keys.env` (mode 600) that
`run-agent.sh` sources into the agent pane.

**Tech Stack:** bash (installer, `set -euo pipefail`), Python 3 stdlib (`agent-keys`,
`agent-login`, unittest), Claude Code plugin CLI, npm, pipx, git.

**Spec:** the approved list in this plan's «Approved kit» section (Kris, Telegram msg 14365 +
approval 14366 «Все ок», web-tool routing promised in msg 14370). There is no separate spec file;
that section is the spec.

## Approved kit (the spec)

| Category | Item | Source | Key |
|---|---|---|---|
| system | superpowers | plugin `superpowers@claude-plugins-official` (MIT) | none |
| system | skill-creator | bundled, anthropics/skills (Apache-2.0) | none |
| system | skill-finder | ours (fleet `shared/skills/skill-finder`) | none |
| system | agent-introspection | ours, base by Chip — taken as is | none |
| system | learnings | ours (fleet `shared/skills/learnings`, paths generalised) | none |
| system | quick-reminders | ours (already in `core/skills`) | none |
| system | onboard | ours (stays in `core/skills`) | none |
| research | perplexity-research | ours, rewritten description + WebSearch fallback | `PERPLEXITY_API_KEY` (paid) |
| research | agent-browser | npm `agent-browser@0.38.2` (Vercel Labs, Apache-2.0) + our safety config + skill | none |
| research | markdown-new | ours (already in `core/skills`) | optional `JINA_API_KEY` |
| research | crawl4ai | pipx `crawl4ai==0.9.4` (Apache-2.0) + our skill | none |
| research | last30days | git `mvanhorn/last30days-skill@e93c8249` (MIT) | optional `BRAVE_API_KEY`, `SCRAPECREATORS_API_KEY` |
| office | gws | pipx `gws-cli==1.5.0` (MIT), full access, + our skill | Google login (own OAuth client) |
| office | cal | ours (inbox `tools/cal`, key path generalised) + skill | `CAL_API_KEY` |
| office | docx / pdf / pptx / xlsx | plugin `document-skills@anthropic-agent-skills` (marketplace `anthropics/skills`) | none |
| media | groq-voice | ours (already in `core/skills`) | `GROQ_API_KEY` (free) |
| media | youtube-transcript | ours (yt-dlp via pipx) | optional `TRANSCRIPT_API_KEY` (paid) |
| dev | senior-brainstorm | ours (MIT) | none |
| dev | GitHub | `gh auth login` device flow (gh from apt / official) | login, optional |
| dev | Vercel | plugin `vercel@claude-plugins-official` + `vercel login` | login, optional |

Removed: `deep-research`, the old read-only `gws` curl wrapper, bizmozg-pack, `present`.

## Global Constraints

- Third-party programs only from their official source, pinned versions as listed above.
- Our own skills come from the fleet copies, with every personal reference removed; `scripts/leak-scan.sh` must stay clean.
- Keys are entered only in the terminal, hidden (`getpass`), never via Telegram, never echoed, never logged.
- `keys.env` lives in `$SECRETS_DIR` (dir 700, file 600); nothing key-bearing lands in `$AGENT_HOME`.
- Every key and every login is optional: Enter skips, a skipped item can be added later with one command (`agent-keys add <service>`, `agent-login <service>`).
- Network failures (offline, registry down) only warn; the install never dies on an optional item.
- No root needed: npm installs with `--prefix "$HOME/.local"`, Python tools via `pipx`.
- `TG_AGENT_NONINTERACTIVE=1` skips every prompt (keys from `TG_AGENT_KEY_<NAME>` env vars only).
- bash: `set -euo pipefail`, quoted vars; Python: type hints, Google docstrings, pathlib, logging not print for diagnostics (user-facing prompts may print).
- Commits in Russian, branch `feature/default-kit`, PR to `main`, no push to `main`.

## Review Focus

1. Key with a trailing newline / spaces pasted from a password manager → stripped, validated, stored clean.
2. Re-running `agent-keys add groq` when the key exists → asks to replace, keeps the old one on Enter, never duplicates the line in `keys.env`.
3. Validation endpoint unreachable (offline, 5xx, timeout) → key is saved with status «not verified», not rejected; only HTTP 401/403 rejects.
4. Second install over an existing agent (the installer moves old dirs to `.bak_*`) → symlinks in the new workspace point inside the new workspace, none dangle into the backup.
5. Machine without `node`/`npm` or `pipx` → the dependent items are skipped with a one-line hint, every other kit item still installs.

Each line is pinned by a test in the owning task (Tasks 1, 5, 4).

---

## File Structure

```
kit/
  README.md                         what is in the kit, keys, later commands (replaces core/skills/README.md)
  manifest.tsv                      category, skill, source kind — single list the installer and tests read
  install-kit.sh                    copy kit into the workspace, flatten skills, install deps + plugins
  bin/agent-keys                    Python: setup | add <svc> | list ; writes keys.env, live validation
  bin/agent-login                   Python: google | github | vercel ; guided logins
  config/agent-browser.json         safety defaults (content boundaries, output cap, idle timeout)
  rules/web-tools.md                routing table appended to core/rules.md
  skills/system/{skill-creator,skill-finder,agent-introspection,learnings,quick-reminders}/
  skills/research/{perplexity-research,agent-browser,markdown-new,crawl4ai,last30days}/
  skills/office/{gws,cal}/
  skills/media/{groq-voice,youtube-transcript}/
  skills/dev/{senior-brainstorm}/
  tests/test_agent_keys.py          unittest, local HTTP server for validation
  tests/test_agent_login.py         unittest, google paste-back parsing
core/skills/                        only onboard/ remains (sync-core copies only onboard)
install-server.sh                   calls kit/install-kit.sh, keys step, login step
server/bin/run-agent.sh             sources keys.env when present
scripts/sync-core.sh                copies only skills/onboard
tests/run-tests.sh                  kit section, fake npm/pipx/git
```

`last30days` skill folder holds only a small `SKILL.md` stub plus `UPSTREAM` (repo + commit);
the installer clones upstream into `$AGENT_WS/kit/vendor/last30days` and replaces the stub
folder with a symlink to `vendor/last30days/skills/last30days`.

---

### Task 1: Kit skeleton, manifest and skill flattening

**Files:**
- Create: `kit/manifest.tsv`, `kit/install-kit.sh`
- Move (git mv): `core/skills/{skill-creator,quick-reminders}` → `kit/skills/system/`, `core/skills/markdown-new` → `kit/skills/research/`, `core/skills/{groq-voice,youtube-transcript}` → `kit/skills/media/`
- Delete (git rm): `core/skills/deep-research`, `core/skills/gws`
- Modify: `install-server.sh:192` (core skills copy), `scripts/sync-core.sh:27`
- Test: `tests/run-tests.sh` (new «kit» checks in the installer section)

**Interfaces:**
- Produces: `kit/install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>` — exit 0 always unless the workspace is missing; env `KIT_SKIP_DEPS=1` skips network installs (used by tests until Task 4 adds fakes).
- Produces: `kit/manifest.tsv` columns `category<TAB>skill<TAB>kind` where kind ∈ `bundled|upstream`.

- [ ] **Step 1: Write the failing checks** — append after the «keys folder filled» check in `tests/run-tests.sh`:

```bash
check "kit copied into the workspace" test -f "$WS/kit/manifest.tsv"
check "every manifest skill is a symlink that resolves to SKILL.md" bash -c '
  while IFS=$'"'"'\t'"'"' read -r cat skill kind; do
    case "$cat" in ""|\#*) continue ;; esac
    [ -L "'"$WS"'/skills/$skill" ] || { echo "not a link: $skill"; exit 1; }
    [ "$kind" = upstream ] && continue
    [ -f "'"$WS"'/skills/$skill/SKILL.md" ] || { echo "no SKILL.md: $skill"; exit 1; }
  done < "'"$WS"'/kit/manifest.tsv"'
check "skill links are relative and stay inside the workspace" bash -c \
  "for l in '$WS'/skills/*; do [ -L \"\$l\" ] || continue; t=\$(readlink \"\$l\"); \
   case \"\$t\" in /*) exit 1 ;; esac; \
   case \"\$(readlink -f \"\$l\")\" in '$WS'/*) ;; *) exit 1 ;; esac; done"
check "onboard still a plain folder from core" test -f "$WS/skills/onboard/SKILL.md"
check "deep-research and the old gws wrapper are gone" bash -c \
  "[ ! -e '$WS/skills/deep-research' ] && ! grep -q GOOGLE_ACCESS_TOKEN -r '$WS/skills/' 2>/dev/null"
```

- [ ] **Step 2: Run, expect FAIL** — `bash tests/run-tests.sh 2>&1 | grep -E "kit|symlink|deep-research"` → `FAIL kit copied into the workspace`.

- [ ] **Step 3: Move skills and write the manifest**

```bash
mkdir -p kit/skills/{system,research,office,media,dev}
git mv core/skills/skill-creator core/skills/quick-reminders kit/skills/system/
git mv core/skills/markdown-new kit/skills/research/
git mv core/skills/groq-voice core/skills/youtube-transcript kit/skills/media/
git rm -r -q core/skills/deep-research core/skills/gws
```

`kit/manifest.tsv` (Tasks 2–3 add their rows; rows for not-yet-ported skills are added by the task that ports them):

```
# category	skill	kind
system	skill-creator	bundled
system	quick-reminders	bundled
research	markdown-new	bundled
media	groq-voice	bundled
media	youtube-transcript	bundled
```

- [ ] **Step 4: Write `kit/install-kit.sh` (link part)**

```bash
#!/usr/bin/env bash
# install-kit.sh -- put the default kit into an agent workspace.
# Copies kit/ to $AGENT_WS/kit, links every manifest skill into $AGENT_WS/skills
# (Claude Code finds skills one level deep only), then installs upstream tools and
# plugins. Optional items never fail the install: they warn and print the later command.
# Usage: kit/install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>
set -euo pipefail

SRC_KIT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENT_WS="${1:?usage: install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>}"
CLAUDE_CONFIG_DIR="${2:?usage: install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>}"
[ -d "$AGENT_WS" ] || { echo "[kit] no workspace at $AGENT_WS" >&2; exit 1; }
KIT="$AGENT_WS/kit"

say() { echo "[kit] $*"; }
warn() { echo "[kit] WARN: $*" >&2; }

say "copying kit into $KIT"
mkdir -p "$KIT"
cp -R "$SRC_KIT"/. "$KIT/"
rm -rf "$KIT/tests"
find "$KIT/skills" "$KIT/bin" -name '*.sh' -exec chmod +x {} +
chmod +x "$KIT"/bin/* 2>/dev/null || true

link_skills() {
  local cat skill kind
  while IFS=$'\t' read -r cat skill kind; do
    case "$cat" in ''|\#*) continue ;; esac
    ln -sfn "../kit/skills/$cat/$skill" "$AGENT_WS/skills/$skill"
  done < "$KIT/manifest.tsv"
}
say "linking skills"
mkdir -p "$AGENT_WS/skills"
link_skills
```

- [ ] **Step 5: Wire into the installer** — `install-server.sh:192` replace `cp -R "$C"/skills/. "$AGENT_WS/skills/"` with:

```bash
cp -R "$C"/skills/onboard "$AGENT_WS/skills/"
```

and right after the `channel-rules.md` append (line 208) add:

```bash
# Default kit: skills by category, upstream tools, plugins (kit/README.md).
KIT_SKIP_DEPS="${KIT_SKIP_DEPS:-0}" bash "$KIT_DIR/kit/install-kit.sh" "$AGENT_WS" "$CLAUDE_CONFIG_DIR"
```

Move the `find "$AGENT_WS/skills" -name '*.sh' -exec chmod +x` line to stay after it (it already follows; keep `-L` so links are followed: `find -L "$AGENT_WS/skills" ...`).

`render-template.py --tree "$AGENT_WS"` runs before the kit copy, so kit files are never rendered — kit content must contain no `{{...}}` placeholders (check in Step 1 of Task 2).

- [ ] **Step 6: sync-core copies only onboard** — `scripts/sync-core.sh:27`:

```bash
cp -R "$SRC/templates" "$SRC/hooks" "$SRC/scripts" "$STAGE/core/"
mkdir -p "$STAGE/core/skills"
cp -R "$SRC/skills/onboard" "$STAGE/core/skills/"   # the rest of the kit lives in kit/
```

Delete `core/skills/README.md` (`git rm`); its content moves to `kit/README.md` in Task 8.

- [ ] **Step 7: Run tests, expect PASS** — `KIT_SKIP_DEPS=1 bash tests/run-tests.sh` (export `KIT_SKIP_DEPS=1` in the installer env block at `tests/run-tests.sh:75` until Task 4). Expected: all old checks plus the 5 new ones `ok`.

- [ ] **Step 8: Commit**

```bash
git add -A kit core/skills install-server.sh scripts/sync-core.sh tests/run-tests.sh
git commit -m "feat(kit): папка kit/ с категориями скиллов и плоскими ссылками в skills/"
```

---

### Task 2: Port our system and dev skills

**Files:**
- Create: `kit/skills/system/{skill-finder,agent-introspection,learnings}/`, `kit/skills/dev/senior-brainstorm/`
- Modify: `kit/manifest.tsv`, `scripts/leak-scan.sh` (scan `kit/` too, if it does not already)
- Test: `tests/run-tests.sh`

**Interfaces:**
- Consumes: `kit/manifest.tsv` format from Task 1.

- [ ] **Step 1: Failing checks**

```bash
check "kit has no template placeholders" bash -c "! grep -rn '{{[A-Z_]*}}' '$KIT/kit'"
check "kit skills carry no fleet paths" bash -c \
  "! grep -rnE 'claude-lab|maimozg|/home/edgelab|shared/secrets' '$KIT/kit/skills'"
check "system and dev skills linked" bash -c \
  "for s in skill-finder agent-introspection learnings senior-brainstorm; do \
   test -f '$WS/skills/'\$s/SKILL.md || exit 1; done"
```

- [ ] **Step 2: Run, expect FAIL** on «system and dev skills linked».

- [ ] **Step 3: Copy and generalise**

```bash
cp -RL ~/.claude-lab/shared/skills/skill-finder        kit/skills/system/
cp -RL ~/.claude-lab/shared/skills/agent-introspection kit/skills/system/
cp -RL ~/.claude-lab/shared/skills/learnings           kit/skills/system/
cp -RL ~/.claude-lab/maimozg/.claude/skills/senior-brainstorm kit/skills/dev/
grep -rnE 'claude-lab|maimozg|edgelab|Kris|shared/' kit/skills/system kit/skills/dev
```

Fix every hit by hand:
- `learnings/SKILL.md`: fleet engine path → `$CLAUDE_PROJECT_DIR/scripts/learnings-engine.mjs` (the core installs it into `$AGENT_WS/scripts/`); remove fleet agent names from examples.
- `agent-introspection/SKILL.md`: taken as is (Kris, msg 14360); only the «staging server» line in «Автор» stays, it names no person.
- `senior-brainstorm`: keep its LICENSE (MIT); if the folder has none, add the MIT text with the upstream author from its SKILL.md header.

Add rows:

```
system	skill-finder	bundled
system	agent-introspection	bundled
system	learnings	bundled
dev	senior-brainstorm	bundled
```

- [ ] **Step 4: leak-scan covers kit/** — open `scripts/leak-scan.sh`, add `kit` to the scanned roots if the list is explicit.

- [ ] **Step 5: Run** `bash scripts/leak-scan.sh && KIT_SKIP_DEPS=1 bash tests/run-tests.sh` → all ok.

- [ ] **Step 6: Commit** — `git commit -m "feat(kit): skill-finder, agent-introspection, learnings, senior-brainstorm"`

---

### Task 3: Research and office skills (wrappers for upstream tools)

**Files:**
- Create: `kit/skills/research/{perplexity-research,agent-browser,crawl4ai,last30days}/SKILL.md`, `kit/skills/research/last30days/UPSTREAM`, `kit/config/agent-browser.json`, `kit/skills/office/gws/SKILL.md`, `kit/skills/office/cal/{SKILL.md,cal}`
- Modify: `kit/manifest.tsv`
- Test: `tests/run-tests.sh`

**Interfaces:**
- Produces: env names the skills read — `PERPLEXITY_API_KEY`, `CAL_API_KEY`, `BRAVE_API_KEY`, `SCRAPECREATORS_API_KEY`, `TRANSCRIPT_API_KEY`, `JINA_API_KEY`. Task 5 writes exactly these names into `keys.env`.
- Produces: `kit/skills/research/last30days/UPSTREAM` with two lines `repo=https://github.com/mvanhorn/last30days-skill` and `commit=e93c8249d8ba073e8e88c388ed1f0fc403ffd86e` — read by Task 4.

- [ ] **Step 1: Failing checks**

```bash
check "every kit skill description says when to use it" bash -c '
  for f in '"$KIT"'/kit/skills/*/*/SKILL.md; do
    awk "/^---/{n++} n==1" "$f" | grep -qiE "use (it )?when|use for|когда" || { echo "$f"; exit 1; }
  done'
check "perplexity falls back to WebSearch without a key" \
  grep -q "WebSearch" "$KIT/kit/skills/research/perplexity-research/SKILL.md"
check "cal tool reads CAL_API_KEY from the environment" \
  grep -q "CAL_API_KEY" "$KIT/kit/skills/office/cal/cal"
check "cal tool compiles" python3 -m py_compile "$KIT/kit/skills/office/cal/cal"
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: perplexity-research** — copy fleet `SKILL.md`, drop the fleet key path, new frontmatter:

```yaml
---
name: perplexity-research
description: >
  Deep web research with citations through the Perplexity Sonar API: one request
  gathers and cross-checks many sources. Use when the user wants a detailed answer
  with sources, a serious fact-check, or a market / competitor overview.
  Not for quick facts or a single page — use the built-in WebSearch / WebFetch.
  Needs PERPLEXITY_API_KEY; without it, say so and fall back to WebSearch.
---
```

Body keeps the curl example with `Authorization: Bearer $PERPLEXITY_API_KEY`, adds a «No key» section: «If `PERPLEXITY_API_KEY` is empty, tell the user the key is not set (add later: `agent-keys add perplexity`) and do the research with WebSearch instead.»

- [ ] **Step 4: agent-browser** — copy fleet `SKILL.md` minus the fleet wrapper path and Instagram/HikerAPI lines; keep «Use it for / Prefer lighter tools / Always close». `kit/config/agent-browser.json`:

```json
{
  "args": "--no-sandbox",
  "contentBoundaries": true,
  "maxOutput": 50000,
  "idleTimeout": "15m"
}
```

- [ ] **Step 5: crawl4ai** — copy fleet `SKILL.md`, replace the fleet venv path with the plain `crwl` command (pipx puts it on `~/.local/bin`).

- [ ] **Step 6: last30days stub** — `SKILL.md` stub (replaced by the upstream skill when the clone succeeds):

```markdown
---
name: last30days
description: >
  What people discussed about a topic in the last 30 days (Reddit, Hacker News,
  GitHub, Polymarket; X/TikTok/Instagram with optional keys). Use when the user
  asks what is trending, what people say about X lately, or recent reactions.
  Not installed yet — tell the user to rerun the installer with network access.
---
The upstream skill could not be downloaded during install. Rerun
`bash kit/install-kit.sh <workspace> <claude-config-dir>` with network access.
```

plus `UPSTREAM` with the two lines from Interfaces.

- [ ] **Step 7: gws** — new `kit/skills/office/gws/SKILL.md` for gws-cli full access:

```yaml
---
name: gws
description: >
  Google Workspace through gws-cli with full access: Gmail (read, draft, send),
  Calendar, Drive, Docs, Sheets, Slides, Contacts, and Markdown↔Docs convert.
  Use when the user asks about their mail, calendar, files or documents.
  Sending mail, deleting files and sharing are outward actions — confirm with the user first.
  Not logged in yet? Tell the user to run `agent-login google` in the server terminal.
---
```

Body: `gws-cli --help`, per-service `gws-cli <service> --help`, `gws-cli auth status`, the confirm-first rule for send / delete / share.

- [ ] **Step 8: cal** — copy `~/.claude-lab/inbox/.claude/tools/cal` to `kit/skills/office/cal/cal`; replace the secrets-file read with:

```python
API_KEY_ENV: str = "CAL_API_KEY"

def load_api_key() -> str:
    """Return the Cal.com API key from the environment.

    Raises:
        SystemExit: when the key is not set, with the command that adds it.
    """
    key = os.environ.get(API_KEY_ENV, "").strip()
    if not key:
        raise SystemExit("cal: CAL_API_KEY is not set. Add it: agent-keys add cal")
    return key
```

`SKILL.md`:

```yaml
---
name: cal
description: >
  Cal.com bookings and availability through the bundled `cal` tool: list event types,
  upcoming bookings, free slots, create / cancel / reschedule bookings.
  Use when the user asks about their Cal.com schedule or booking links.
  Booking and cancelling notify other people — confirm first. Needs CAL_API_KEY.
---
```

Body lists the tool's subcommands from `cal --help` with the path `"$CLAUDE_PROJECT_DIR/skills/cal/cal"`.

- [ ] **Step 9: manifest rows**

```
research	perplexity-research	bundled
research	agent-browser	bundled
research	crawl4ai	bundled
research	last30days	upstream
office	gws	bundled
office	cal	bundled
```

- [ ] **Step 10: Run** `bash scripts/leak-scan.sh && KIT_SKIP_DEPS=1 bash tests/run-tests.sh` → all ok.

- [ ] **Step 11: Commit** — `git commit -m "feat(kit): скиллы research и office: perplexity, agent-browser, crawl4ai, last30days, gws, cal"`

---

### Task 4: Upstream tools and plugins

**Files:**
- Modify: `kit/install-kit.sh` (deps + plugins), `install-server.sh:22-23,294-309` (plugin block moves into the kit)
- Test: `tests/run-tests.sh` (fake `npm`, `pipx`, `git`, `node` on PATH)

**Interfaces:**
- Consumes: `kit/skills/research/last30days/UPSTREAM` (Task 3), `$CLAUDE_BIN` exported by `install-server.sh`.
- Produces: tool commands on `~/.local/bin`: `agent-browser`, `crwl`, `gws-cli`, `yt-dlp`; plugins in `$CLAUDE_CONFIG_DIR`.

- [ ] **Step 1: Fakes + failing checks** — in `tests/run-tests.sh` next to the fake claude, create logging fakes:

```bash
for tool in npm pipx git; do
  cat > "$WORK/bin/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool \$*" >> "\${FAKE_TOOLS_LOG:-/dev/null}"
[ "\${FAKE_TOOLS_FAIL:-0}" = 1 ] && exit 1
if [ "$tool" = git ] && [ "\$1" = clone ]; then
  d="\${@: -1}"; mkdir -p "\$d/skills/last30days"
  printf -- '---\nname: last30days\ndescription: upstream. Use when testing.\n---\n' \
    > "\$d/skills/last30days/SKILL.md"
fi
exit 0
EOF
  chmod +x "$WORK/bin/$tool"
done
export FAKE_TOOLS_LOG="$WORK/tools.log"; : > "$FAKE_TOOLS_LOG"
```

Drop `KIT_SKIP_DEPS=1` from the installer env. Checks:

```bash
check "agent-browser from npm, pinned, no root" \
  grep -q "npm install -g --prefix $FAKE_HOME/.local agent-browser@0.38.2" "$FAKE_TOOLS_LOG"
check "python tools from pipx, pinned" bash -c "grep -q 'pipx install gws-cli==1.5.0' '$FAKE_TOOLS_LOG' && \
  grep -q 'pipx install crawl4ai==0.9.4' '$FAKE_TOOLS_LOG' && grep -q 'pipx install yt-dlp' '$FAKE_TOOLS_LOG'"
check "last30days cloned at the pinned commit and linked" bash -c \
  "grep -q 'git clone https://github.com/mvanhorn/last30days-skill' '$FAKE_TOOLS_LOG' && \
   grep -q 'checkout e93c8249d8ba073e8e88c388ed1f0fc403ffd86e' '$FAKE_TOOLS_LOG' && \
   grep -q 'description: upstream' '$WS/skills/last30days/SKILL.md'"
check "agent-browser safety config installed" \
  jq -e '.contentBoundaries == true and .maxOutput == 50000' "$FAKE_HOME/.agent-browser/config.json"
check "kit plugins installed into the agent's config dir" bash -c \
  "for p in superpowers@claude-plugins-official document-skills@anthropic-agent-skills \
   vercel@claude-plugins-official; do grep -q \"plugin install \$p\" '$FAKE_CLAUDE_LOG' || exit 1; done; \
   grep -q 'marketplace add anthropics/skills' '$FAKE_CLAUDE_LOG'"
```

And a second, offline run (reuse the existing offline-install block that sets `FAKE_CLAUDE_FAIL=1`; add `FAKE_TOOLS_FAIL=1`):

```bash
check "offline: install still finishes, kit skills linked" test -L "$WS_OFF/skills/gws"
check "offline: last30days keeps the stub" grep -q "Not installed yet" "$WS_OFF/skills/last30days/SKILL.md"
```

Missing-tool case (Review Focus 5): a third run with `PATH` that has no `npm`/`pipx` fakes (`rm "$WORK/bin/npm" "$WORK/bin/pipx"` in a copied bin dir):

```bash
check "no npm/pipx: other kit items still installed" bash -c \
  "test -f '$WS_NOTOOLS/skills/gws/SKILL.md' && grep -q 'plugin install superpowers' '$FAKE_CLAUDE_LOG'"
```

- [ ] **Step 2: Run, expect FAIL.**

- [ ] **Step 3: Deps block in `kit/install-kit.sh`**

```bash
readonly AGENT_BROWSER_VERSION="0.38.2"
readonly CRAWL4AI_VERSION="0.9.4"
readonly GWS_CLI_VERSION="1.5.0"
readonly LOCAL_PREFIX="$HOME/.local"

try() { "$@" < /dev/null > /dev/null 2>&1; }

install_deps() {
  if command -v npm > /dev/null; then
    try npm install -g --prefix "$LOCAL_PREFIX" "agent-browser@$AGENT_BROWSER_VERSION" \
      || warn "agent-browser not installed; later: npm install -g --prefix ~/.local agent-browser@$AGENT_BROWSER_VERSION"
  else
    warn "npm not found: agent-browser skipped (install Node.js, then rerun kit/install-kit.sh)"
  fi
  mkdir -p "$HOME/.agent-browser"
  [ -f "$HOME/.agent-browser/config.json" ] || cp "$KIT/config/agent-browser.json" "$HOME/.agent-browser/config.json"

  if command -v pipx > /dev/null; then
    local pkg
    for pkg in "gws-cli==$GWS_CLI_VERSION" "crawl4ai==$CRAWL4AI_VERSION" yt-dlp; do
      try pipx install "$pkg" || warn "$pkg not installed; later: pipx install '$pkg'"
    done
  else
    warn "pipx not found: gws-cli, crawl4ai, yt-dlp skipped (sudo apt install pipx, then rerun)"
  fi

  local repo commit dest
  repo="$(sed -n 's/^repo=//p' "$KIT/skills/research/last30days/UPSTREAM")"
  commit="$(sed -n 's/^commit=//p' "$KIT/skills/research/last30days/UPSTREAM")"
  dest="$KIT/vendor/last30days"
  if try git clone "$repo" "$dest" && try git -C "$dest" checkout "$commit" \
     && [ -f "$dest/skills/last30days/SKILL.md" ]; then
    ln -sfn "../kit/vendor/last30days/skills/last30days" "$AGENT_WS/skills/last30days"
  else
    warn "last30days not downloaded; the skill tells the agent how to fix it"
  fi
}
```

The fake `git` receives `-C <dir> checkout <commit>`; the check greps `checkout e93c…`, which matches.
Note in `kit/README.md` (Task 8): agent-browser downloads Chrome on first use (`agent-browser install`), crawl4ai needs `crawl4ai-setup` once — the installer runs both with `try` after the pipx/npm step:

```bash
  command -v agent-browser > /dev/null && { try agent-browser install || warn "agent-browser: Chrome download failed; later: agent-browser install"; }
  command -v crawl4ai-setup > /dev/null && { try crawl4ai-setup || warn "crawl4ai: browser setup failed; later: crawl4ai-setup"; }
```

- [ ] **Step 4: Plugins block** — move from `install-server.sh:22-23,294-309` into `kit/install-kit.sh`:

```bash
readonly -a MARKETPLACES=("anthropics/claude-plugins-official" "anthropics/skills")
readonly -a KIT_PLUGINS=(
  "superpowers@claude-plugins-official"
  "vercel@claude-plugins-official"
  "document-skills@anthropic-agent-skills"
)

install_plugins() {
  local m p claude_bin="${CLAUDE_BIN:-$(command -v claude || true)}"
  [ -n "$claude_bin" ] || { warn "claude not found: plugins skipped"; return 0; }
  for m in "${MARKETPLACES[@]}"; do
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" try "$claude_bin" plugin marketplace add "$m" \
      || warn "marketplace $m unreachable"
  done
  for p in "${KIT_PLUGINS[@]}"; do
    CLAUDE_CONFIG_DIR="$CLAUDE_CONFIG_DIR" try "$claude_bin" plugin install "$p" \
      || warn "could not install $p; later: CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\" claude plugin install $p"
  done
}

if [ "${KIT_SKIP_DEPS:-0}" != 1 ]; then
  install_deps
  install_plugins
fi
say "done"
```

The installer's call to `install-kit.sh` must therefore run **after** `CLAUDE_CONFIG_DIR` is prepared (after line 290); move the call there and keep only the skill copy order constraint (kit after `render-template.py --tree`). Delete `PLUGIN_MARKETPLACE_REPO` / `DEFAULT_PLUGINS` and the old block from `install-server.sh`; update the existing «superpowers installed» check to the new log lines (it greps `plugin install superpowers@claude-plugins-official`, still true).

- [ ] **Step 5: Run** `bash tests/run-tests.sh` → all ok, including the three offline / no-tool checks.

- [ ] **Step 6: Commit** — `git commit -m "feat(kit): установка agent-browser, crawl4ai, gws-cli, yt-dlp, last30days и плагинов из официальных источников"`

---

### Task 5: «Keys» step — `agent-keys`

**Files:**
- Create: `kit/bin/agent-keys`, `kit/tests/test_agent_keys.py`
- Modify: `install-server.sh:104-108,143,224-226` (Groq prompt → keys step), `server/bin/run-agent.sh:126`, `server/bin/lib.sh:41`
- Test: `kit/tests/test_agent_keys.py`, `tests/run-tests.sh`

**Interfaces:**
- Consumes: env names from Task 3.
- Produces: CLI `agent-keys setup | add <service> | list`; env `AGENT_KEYS_FILE` (default `$SECRETS_DIR/keys.env`, `SECRETS_DIR` from `agent.conf`); `keys_conf()` in `lib.sh` returning `$SECRETS_DIR/keys.env`.
- Produces: Python functions `load_keys(path: Path) -> dict[str, str]`, `save_key(path: Path, name: str, value: str) -> None`, `validate(service: Service, value: str, timeout: float = 10.0) -> str` returning `"ok" | "invalid" | "unverified"`.

Services (name, env var, where to get it, check):

| id | env | get it | check |
|---|---|---|---|
| groq | `GROQ_API_KEY` | console.groq.com/keys — free | `GET https://api.groq.com/openai/v1/models`, `Authorization: Bearer` |
| perplexity | `PERPLEXITY_API_KEY` | perplexity.ai/settings/api — paid | `POST https://api.perplexity.ai/chat/completions` `{"model":"sonar","messages":[{"role":"user","content":"ping"}],"max_tokens":1}` |
| cal | `CAL_API_KEY` | app.cal.com/settings/developer/api-keys | `GET https://api.cal.com/v2/me`, Bearer, `cal-api-version: 2024-08-13` |
| brave | `BRAVE_API_KEY` | api.search.brave.com — 2,000 free / month | `GET https://api.search.brave.com/res/v1/web/search?q=test&count=1`, `X-Subscription-Token` |
| scrapecreators | `SCRAPECREATORS_API_KEY` | scrapecreators.com — 10,000 free calls | `GET https://api.scrapecreators.com/v1/reddit/search?query=test`, `x-api-key` |
| transcriptapi | `TRANSCRIPT_API_KEY` | transcriptapi.com — paid, optional | `GET https://transcriptapi.com/api/v2/youtube/transcript?video_url=dQw4w9WgXcQ`, Bearer |
| jina | `JINA_API_KEY` | jina.ai/reader — optional | none (format only) |

Validation rule: HTTP 401 or 403 → `invalid`; 2xx, 402, 429, other 4xx → `ok` (the key was recognised); network error, timeout, 5xx → `unverified` (saved, with a note). A 402 / 429 means a valid key without credit or over a limit — say so.

- [ ] **Step 1: Failing unit tests** — `kit/tests/test_agent_keys.py`:

```python
"""Tests for kit/bin/agent-keys."""

import http.server
import importlib.machinery
import importlib.util
import os
import stat
import tempfile
import threading
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]


def load_module():
    """Load the extension-less agent-keys script as a module."""
    loader = importlib.machinery.SourceFileLoader("agent_keys", str(KIT / "bin" / "agent-keys"))
    spec = importlib.util.spec_from_loader("agent_keys", loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


ak = load_module()


class Handler(http.server.BaseHTTPRequestHandler):
    """Answers 200 for the good key, 401 otherwise, 500 on /boom."""

    def _answer(self) -> None:
        if self.path.startswith("/boom"):
            code = 500
        elif "good" in (self.headers.get("Authorization", "") + self.headers.get("x-api-key", "")):
            code = 200
        else:
            code = 401
        self.send_response(code)
        self.end_headers()

    do_GET = _answer
    do_POST = _answer

    def log_message(self, *args: object) -> None:
        return


class KeysFileTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.path = self.dir / "keys.env"

    def test_save_creates_600_file(self) -> None:
        ak.save_key(self.path, "GROQ_API_KEY", "gsk_1")
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        self.assertEqual(ak.load_keys(self.path), {"GROQ_API_KEY": "gsk_1"})

    def test_replace_does_not_duplicate(self) -> None:
        ak.save_key(self.path, "GROQ_API_KEY", "a")
        ak.save_key(self.path, "CAL_API_KEY", "c")
        ak.save_key(self.path, "GROQ_API_KEY", "b")
        text = self.path.read_text()
        self.assertEqual(text.count("GROQ_API_KEY="), 1)
        self.assertEqual(ak.load_keys(self.path)["GROQ_API_KEY"], "b")

    def test_value_is_stripped(self) -> None:
        self.assertEqual(ak.clean_value("  gsk_1 \r\n"), "gsk_1")

    def test_shell_unsafe_value_rejected(self) -> None:
        for bad in ('a"b', "a$b", "a`b", "a\\b", "a b"):
            with self.assertRaises(ValueError):
                ak.clean_value(bad)


class ValidateTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.server = http.server.HTTPServer(("127.0.0.1", 0), Handler)
        threading.Thread(target=cls.server.serve_forever, daemon=True).start()
        cls.base = f"http://127.0.0.1:{cls.server.server_port}"

    @classmethod
    def tearDownClass(cls) -> None:
        cls.server.shutdown()

    def svc(self, path: str = "/check") -> "ak.Service":
        return ak.Service("t", "T_KEY", "test", "here", "GET", self.base + path, "bearer")

    def test_good_key_ok(self) -> None:
        self.assertEqual(ak.validate(self.svc(), "good"), "ok")

    def test_bad_key_invalid(self) -> None:
        self.assertEqual(ak.validate(self.svc(), "bad"), "invalid")

    def test_server_error_unverified(self) -> None:
        self.assertEqual(ak.validate(self.svc("/boom"), "good"), "unverified")

    def test_unreachable_unverified(self) -> None:
        dead = ak.Service("t", "T_KEY", "test", "here", "GET", "http://127.0.0.1:9/x", "bearer")
        self.assertEqual(ak.validate(dead, "good", timeout=1.0), "unverified")


class ListTest(unittest.TestCase):
    def test_list_never_prints_values(self) -> None:
        path = Path(tempfile.mkdtemp()) / "keys.env"
        ak.save_key(path, "GROQ_API_KEY", "gsk_secret_value")
        out = ak.render_list(path)
        self.assertIn("groq", out)
        self.assertNotIn("gsk_secret_value", out)


if __name__ == "__main__":
    unittest.main()
```

In `tests/run-tests.sh` (syntax section): `check "agent-keys unit tests" python3 -m unittest discover -s "$KIT/kit/tests" -p 'test_agent_keys.py'`.

- [ ] **Step 2: Run** `python3 -m unittest discover -s kit/tests -p 'test_agent_keys.py' -v` → FAIL (`No such file`).

- [ ] **Step 3: Implement `kit/bin/agent-keys`**

```python
#!/usr/bin/env python3
"""agent-keys -- add API keys for the agent's skills, hidden input, live check.

Keys go into keys.env in the agent's secrets dir (mode 600). The agent pane
sources that file at start, so a new key works after the agent restarts.

Usage:
    agent-keys setup            walk through every service, Enter skips
    agent-keys add <service>    add or replace one key
    agent-keys list             which keys are set (never shows values)
"""

from __future__ import annotations

import argparse
import getpass
import json
import logging
import os
import re
import sys
import tempfile
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

LOG = logging.getLogger("agent-keys")
TIMEOUT_S: float = 10.0
FILE_MODE: int = 0o600
SAFE_VALUE = re.compile(r"^[A-Za-z0-9._:/+=-]+$")
LINE = re.compile(r'^([A-Z][A-Z0-9_]*)="(.*)"$')
REJECT_CODES: frozenset[int] = frozenset({401, 403})


@dataclass(frozen=True)
class Service:
    """One key-bearing service.

    Attributes:
        id: short name used on the command line.
        env: environment variable the skills read.
        label: what the key unlocks, shown before the prompt.
        url: where to get the key.
        method: HTTP method of the check, or "" for no live check.
        check_url: endpoint that answers 401/403 for a wrong key.
        auth: "bearer", "x-api-key" or "x-subscription-token".
        body: JSON body for POST checks.
        extra: extra headers.
    """

    id: str
    env: str
    label: str
    url: str
    method: str = ""
    check_url: str = ""
    auth: str = "bearer"
    body: str = ""
    extra: tuple[tuple[str, str], ...] = ()


SERVICES: tuple[Service, ...] = (
    Service("groq", "GROQ_API_KEY", "voice messages → text (free)",
            "https://console.groq.com/keys", "GET",
            "https://api.groq.com/openai/v1/models"),
    Service("perplexity", "PERPLEXITY_API_KEY", "deep research with sources (paid)",
            "https://www.perplexity.ai/settings/api", "POST",
            "https://api.perplexity.ai/chat/completions",
            body=json.dumps({"model": "sonar", "max_tokens": 1,
                             "messages": [{"role": "user", "content": "ping"}]})),
    Service("cal", "CAL_API_KEY", "Cal.com bookings",
            "https://app.cal.com/settings/developer/api-keys", "GET",
            "https://api.cal.com/v2/me", extra=(("cal-api-version", "2024-08-13"),)),
    Service("brave", "BRAVE_API_KEY", "web search for last30days (2,000 free / month)",
            "https://api.search.brave.com/app/keys", "GET",
            "https://api.search.brave.com/res/v1/web/search?q=test&count=1",
            auth="x-subscription-token"),
    Service("scrapecreators", "SCRAPECREATORS_API_KEY",
            "TikTok / Instagram / X for last30days (10,000 free calls)",
            "https://scrapecreators.com", "GET",
            "https://api.scrapecreators.com/v1/reddit/search?query=test", auth="x-api-key"),
    Service("transcriptapi", "TRANSCRIPT_API_KEY",
            "YouTube transcripts when yt-dlp is blocked (paid, optional)",
            "https://transcriptapi.com", "GET",
            "https://transcriptapi.com/api/v2/youtube/transcript?video_url=dQw4w9WgXcQ"),
    Service("jina", "JINA_API_KEY", "higher limits for markdown-new (optional)",
            "https://jina.ai/reader"),
)


def clean_value(raw: str) -> str:
    """Strip whitespace and refuse characters that break a KEY="value" file.

    Args:
        raw: the pasted value.

    Returns:
        The cleaned value.

    Raises:
        ValueError: when the value has quotes, $, backticks, backslashes or spaces.
    """
    value = raw.strip()
    if value and not SAFE_VALUE.match(value):
        raise ValueError("the key has characters a key never has (space, quote, $, `, \\)")
    return value


def load_keys(path: Path) -> dict[str, str]:
    """Read KEY="value" lines; a missing file is an empty dict."""
    if not path.exists():
        return {}
    keys: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        match = LINE.match(line.strip())
        if match:
            keys[match.group(1)] = match.group(2)
    return keys


def save_key(path: Path, name: str, value: str) -> None:
    """Set one key, replacing an old line; atomic write, mode 600."""
    keys = load_keys(path)
    keys[name] = value
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    body = "# agent keys -- written by agent-keys, sourced by run-agent.sh\n"
    body += "".join(f'{k}="{v}"\n' for k, v in sorted(keys.items()))
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix=".keys.")
    try:
        os.fchmod(fd, FILE_MODE)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


def validate(service: Service, value: str, timeout: float = TIMEOUT_S) -> str:
    """Live-check a key.

    Returns:
        "ok" when the service recognised the key, "invalid" on 401/403,
        "unverified" when the service could not be reached or failed.
    """
    if not service.method:
        return "unverified"
    headers = {"User-Agent": "agent-keys", **dict(service.extra)}
    if service.auth == "bearer":
        headers["Authorization"] = f"Bearer {value}"
    elif service.auth == "x-api-key":
        headers["x-api-key"] = value
    else:
        headers["X-Subscription-Token"] = value
    data = None
    if service.body:
        data = service.body.encode()
        headers["Content-Type"] = "application/json"
    request = urllib.request.Request(service.check_url, data=data, headers=headers,
                                     method=service.method)
    try:
        with urllib.request.urlopen(request, timeout=timeout):
            return "ok"
    except urllib.error.HTTPError as err:
        if err.code in REJECT_CODES:
            return "invalid"
        return "unverified" if err.code >= 500 else "ok"
    except (urllib.error.URLError, TimeoutError, OSError):
        return "unverified"


def keys_path() -> Path:
    """keys.env location: AGENT_KEYS_FILE, else $SECRETS_DIR/keys.env."""
    explicit = os.environ.get("AGENT_KEYS_FILE")
    if explicit:
        return Path(explicit)
    secrets = os.environ.get("SECRETS_DIR")
    if not secrets:
        raise SystemExit("agent-keys: SECRETS_DIR is not set (run it from the agent's server account)")
    return Path(secrets) / "keys.env"


def render_list(path: Path) -> str:
    """One line per service: set / not set. Never prints values."""
    keys = load_keys(path)
    return "\n".join(f"{s.id:15} {'set' if keys.get(s.env) else '-':4} {s.label}"
                     for s in SERVICES)


def ask_one(service: Service, path: Path) -> None:
    """Prompt for one key (hidden), check it, save it. Enter skips."""
    current = load_keys(path).get(service.env)
    print(f"\n{service.id}: {service.label}\n  get it: {service.url}")
    if current:
        print("  already set; Enter keeps it")
    while True:
        raw = getpass.getpass("  key (hidden, Enter to skip): ")
        try:
            value = clean_value(raw)
        except ValueError as err:
            print(f"  {err}; try again")
            continue
        if not value:
            print("  skipped" + (f"; later: agent-keys add {service.id}" if not current else ""))
            return
        status = validate(service, value)
        if status == "invalid":
            print("  the service rejected this key; try again or Enter to skip")
            continue
        save_key(path, service.env, value)
        note = {"ok": "checked, saved",
                "unverified": "saved, but not checked (service unreachable)"}[status]
        print(f"  {note}")
        return


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(prog="agent-keys")
    sub = parser.add_subparsers(dest="cmd", required=True)
    sub.add_parser("setup")
    add = sub.add_parser("add")
    add.add_argument("service", choices=[s.id for s in SERVICES])
    sub.add_parser("list")
    args = parser.parse_args(argv)
    path = keys_path()
    if args.cmd == "list":
        print(render_list(path))
        return 0
    targets = SERVICES if args.cmd == "setup" else [s for s in SERVICES if s.id == args.service]
    for service in targets:
        ask_one(service, path)
    print("\nRestart the agent to load new keys: systemctl --user restart <agent>.service")
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

(The restart command printed at the end must match the real unit name — read it from `server/systemd/` while implementing and render it via `AGENT_NAME` from the environment, falling back to the generic text.)

- [ ] **Step 4: Run unit tests** → PASS.

- [ ] **Step 5: Installer + runtime**
  - `install-server.sh:104-108`: remove the Groq prompt; keep `TG_AGENT_GROQ_KEY` support by writing it via `save_key` in the keys step.
  - `VOICE_PROVIDER`: keep `groq` when a Groq key is known **at the time channel.conf is rendered**; since the keys step runs after secrets are written, move the keys step **before** `render channel.conf` and compute `VOICE_PROVIDER` from `keys.env`:

```bash
# ---------------------------------------------------------------- keys (optional)
KEYS_FILE="$SECRETS_DIR/keys.env"
( umask 077; mkdir -p "$SECRETS_DIR" )
for kv in GROQ_API_KEY PERPLEXITY_API_KEY CAL_API_KEY BRAVE_API_KEY \
          SCRAPECREATORS_API_KEY TRANSCRIPT_API_KEY JINA_API_KEY; do
  envname="TG_AGENT_KEY_${kv%_API_KEY}"
  [ "$kv" = GROQ_API_KEY ] && [ -n "${TG_AGENT_GROQ_KEY:-}" ] && printf -v "$envname" '%s' "$TG_AGENT_GROQ_KEY"
  [ -n "${!envname:-}" ] && AGENT_KEYS_FILE="$KEYS_FILE" python3 - "$kv" "${!envname}" <<'PY'
import importlib.machinery, os, sys
m = importlib.machinery.SourceFileLoader("ak", os.environ["KIT_DIR"] + "/kit/bin/agent-keys").load_module()
m.save_key(__import__("pathlib").Path(os.environ["AGENT_KEYS_FILE"]), sys.argv[1], m.clean_value(sys.argv[2]))
PY
done
if [ "$NONINTERACTIVE" != "1" ]; then
  say "keys for skills -- all optional, Enter skips, add later with: agent-keys add <service>"
  AGENT_KEYS_FILE="$KEYS_FILE" python3 "$KIT_DIR/kit/bin/agent-keys" setup || true
fi
[ -f "$KEYS_FILE" ] && chmod 600 "$KEYS_FILE"
grep -q '^GROQ_API_KEY=' "$KEYS_FILE" 2>/dev/null && VOICE_PROVIDER="groq"
```

  (export `KIT_DIR` before the heredoc.) The channel plugin reads `GROQ_API_KEY` from the pane environment, which now includes `keys.env`; drop the `printf 'GROQ_API_KEY=...' >> channel.conf` lines.
  - `server/bin/lib.sh:41` add `keys_conf() { printf '%s/keys.env' "${SECRETS_DIR:?SECRETS_DIR unset}"; }`.
  - `server/bin/run-agent.sh:126`:

```bash
KEYS_CONF="$(keys_conf)"
LAUNCH_CMD="set -a; . '$TG_AGENT_CONF'; . '$CHANNEL_CONF'"
[ -f "$KEYS_CONF" ] && LAUNCH_CMD+="; . '$KEYS_CONF'"
LAUNCH_CMD+="; set +a"
```

  - Put `agent-keys` on PATH: `ln -sfn "$AGENT_WS/kit/bin/agent-keys" "$HOME/.local/bin/agent-keys"` in `install-kit.sh`; since several agents can share a server user, the link target is the last-installed agent — `agent-keys` therefore needs `SECRETS_DIR`; print the full command `SECRETS_DIR=... agent-keys add <svc>` in the installer summary instead of relying on the global link. (Decision: no global link; the summary prints `"$AGENT_WS/kit/bin/agent-keys" add <service>` with `SECRETS_DIR` exported inline.)

- [ ] **Step 6: run-tests checks**

```bash
# installer env gets TG_AGENT_KEY_CAL=cal_test_123
check "keys.env mode 600 in the secrets dir" test "$(stat -c %a "$SEC/keys.env")" = 600
check "key from env stored once" test "$(grep -c '^CAL_API_KEY=' "$SEC/keys.env")" = 1
check "key never in the workspace" bash -c "! grep -rqF cal_test_123 '$FAKE_HOME/agents'"
check "run-agent sources keys.env when present" grep -q "KEYS_CONF" "$WS/bin/run-agent.sh"
check "groq key from env enables voice" bash -c \
  "grep -q '^GROQ_API_KEY=' '$SEC/keys.env' && grep -q 'VOICE_PROVIDER=\"groq\"' '$WS/agent.conf'"
```

(set `TG_AGENT_GROQ_KEY=gsk_test_1` in the installer env; adjust the existing groq-related checks to the new file.)

- [ ] **Step 7: Run all** → `bash tests/run-tests.sh` all ok.

- [ ] **Step 8: Commit** — `git commit -m "feat(kit): шаг «Ключи» — скрытый ввод, живая проверка, keys.env 600"`

---

### Task 6: Logins — `agent-login google | github | vercel`

**Files:**
- Create: `kit/bin/agent-login`, `kit/tests/test_agent_login.py`
- Modify: `install-server.sh` (optional login step after the keys step, interactive only), `kit/install-kit.sh` (chmod)
- Test: `kit/tests/test_agent_login.py`, `tests/run-tests.sh`

**Interfaces:**
- Produces: CLI `agent-login google [--client-secret PATH] | github | vercel | status`.
- Produces: `parse_redirect(url: str) -> tuple[int, str]` — port and query string of the pasted `http://localhost:<port>/?state=...&code=...` URL.

**Google on a headless server (paste-back):** `gws-cli auth` starts a local server on `127.0.0.1:<random port>` and prints the consent URL to stderr. The user opens the URL on their laptop, approves, the browser lands on `http://localhost:<port>/?code=…` and shows «cannot connect» — that is expected. The user copies that address and pastes it into the terminal; `agent-login` sends it to the waiting local server with `urllib`, gws-cli finishes and saves the token. No SSH tunnel, no relay server.

Before that, the student needs their own OAuth Desktop client (gws-cli has no shared one): `agent-login google` prints the short guide (console.cloud.google.com → new project → enable Gmail/Drive/Calendar/Docs/Sheets/Slides/People APIs → OAuth consent screen «External», add own email as test user → Credentials → OAuth client «Desktop app» → download JSON), asks for the JSON path (or `--client-secret`), runs `gws-cli auth import-credentials <path>`, then the paste-back flow.

- [ ] **Step 1: Failing unit tests**

```python
"""Tests for kit/bin/agent-login."""

import importlib.machinery
import importlib.util
import unittest
from pathlib import Path

KIT = Path(__file__).resolve().parents[1]
loader = importlib.machinery.SourceFileLoader("agent_login", str(KIT / "bin" / "agent-login"))
spec = importlib.util.spec_from_loader("agent_login", loader)
al = importlib.util.module_from_spec(spec)
loader.exec_module(al)


class ParseRedirectTest(unittest.TestCase):
    def test_localhost_url(self) -> None:
        port, query = al.parse_redirect("http://localhost:43123/?state=s1&code=4/abc&scope=x")
        self.assertEqual(port, 43123)
        self.assertEqual(query, "state=s1&code=4/abc&scope=x")

    def test_loopback_ip_and_spaces(self) -> None:
        port, _ = al.parse_redirect("  http://127.0.0.1:5000/?code=c&state=s \n")
        self.assertEqual(port, 5000)

    def test_rejects_foreign_host(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://evil.example:5000/?code=c")

    def test_rejects_url_without_code(self) -> None:
        with self.assertRaises(ValueError):
            al.parse_redirect("http://localhost:5000/?error=access_denied")

    def test_extract_consent_url(self) -> None:
        text = "===\nGoogle OAuth Authorization Required\n\nhttps://accounts.google.com/o/oauth2/auth?x=1\n\n==="
        self.assertEqual(al.extract_consent_url(text), "https://accounts.google.com/o/oauth2/auth?x=1")


if __name__ == "__main__":
    unittest.main()
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Implement `kit/bin/agent-login`**

```python
#!/usr/bin/env python3
"""agent-login -- optional logins for the agent: Google, GitHub, Vercel.

Usage:
    agent-login google [--client-secret PATH]
    agent-login github
    agent-login vercel
    agent-login status
"""

from __future__ import annotations

import argparse
import os
import re
import shutil
import subprocess
import sys
import urllib.parse
import urllib.request
from pathlib import Path

LOOPBACK_HOSTS: frozenset[str] = frozenset({"localhost", "127.0.0.1"})
CONSENT_URL = re.compile(r"https://accounts\.google\.com/\S+")
URL_WAIT_S: float = 30.0
FINISH_WAIT_S: float = 60.0

GOOGLE_GUIDE = """\
Google login needs your own OAuth client (one time, about 5 minutes):
  1. console.cloud.google.com -> create a project
  2. APIs & Services -> Library: enable Gmail, Google Drive, Google Calendar,
     Google Docs, Google Sheets, Google Slides, People API
  3. OAuth consent screen: External, add your own email as a test user
  4. Credentials -> Create credentials -> OAuth client ID -> Desktop app -> Download JSON
  5. Copy the JSON to this server (e.g. scp) and give its path below
"""


def parse_redirect(raw: str) -> tuple[int, str]:
    """Port and query of the pasted localhost redirect URL.

    Raises:
        ValueError: not a loopback URL, or no authorization code in it.
    """
    parts = urllib.parse.urlsplit(raw.strip())
    if parts.hostname not in LOOPBACK_HOSTS or not parts.port:
        raise ValueError("this is not the localhost address from the browser bar")
    if "code" not in urllib.parse.parse_qs(parts.query):
        raise ValueError("no authorization code in the address (was access denied?)")
    return parts.port, parts.query


def extract_consent_url(text: str) -> str | None:
    """First Google consent URL in gws-cli output, or None."""
    match = CONSENT_URL.search(text)
    return match.group(0) if match else None


def need(tool: str, hint: str) -> str:
    """Path of a CLI tool or exit with an install hint."""
    path = shutil.which(tool)
    if not path:
        raise SystemExit(f"agent-login: {tool} not found. {hint}")
    return path


def login_google(client_secret: str | None) -> int:
    """Import the OAuth client, then run gws-cli auth with paste-back."""
    gws = need("gws-cli", "Install: pipx install gws-cli==1.5.0")
    status = subprocess.run([gws, "auth", "status"], capture_output=True, text=True)
    if status.returncode == 0:
        print("Google: already logged in. Re-login: gws-cli auth --force")
        return 0
    if not client_secret:
        print(GOOGLE_GUIDE)
        client_secret = input("Path to the downloaded JSON: ").strip()
    secret_path = Path(client_secret).expanduser()
    if not secret_path.is_file():
        raise SystemExit(f"agent-login: no file at {secret_path}")
    subprocess.run([gws, "auth", "import-credentials", str(secret_path)], check=True)
    proc = subprocess.Popen([gws, "auth"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            text=True, env={**os.environ, "BROWSER": "false"})
    seen = ""
    url = None
    assert proc.stdout is not None
    for line in proc.stdout:
        seen += line
        url = extract_consent_url(seen)
        if url:
            break
    if not url:
        proc.kill()
        raise SystemExit("agent-login: gws-cli printed no login URL:\n" + seen[-500:])
    print("\n1. Open this link on your computer and allow access:\n\n" + url)
    print("\n2. The browser ends on a page that does not load (localhost) -- that is expected.")
    print("   Copy the whole address from the browser bar and paste it here.\n")
    while True:
        try:
            port, query = parse_redirect(input("Address: "))
            break
        except ValueError as err:
            print(f"  {err}; try again")
    try:
        urllib.request.urlopen(f"http://127.0.0.1:{port}/?{query}", timeout=FINISH_WAIT_S).read()
    except OSError as err:
        proc.kill()
        raise SystemExit(f"agent-login: could not hand the code to gws-cli: {err}")
    proc.wait(timeout=FINISH_WAIT_S)
    print("Google: logged in." if proc.returncode == 0 else "Google: login failed, run again.")
    return proc.returncode


def login_github() -> int:
    """gh device flow: prints a code, the user enters it at github.com/login/device."""
    gh = need("gh", "Install: sudo apt install gh")
    return subprocess.run([gh, "auth", "login", "--hostname", "github.com",
                           "--git-protocol", "https", "--web"]).returncode


def login_vercel() -> int:
    """Vercel CLI login (device flow when there is no browser)."""
    vercel = shutil.which("vercel")
    if not vercel:
        npx = need("npx", "Install Node.js first")
        return subprocess.run([npx, "--yes", "vercel@latest", "login"]).returncode
    return subprocess.run([vercel, "login"]).returncode


def show_status() -> int:
    """One line per login, never tokens."""
    checks = {"google": ["gws-cli", "auth", "status"], "github": ["gh", "auth", "status"],
              "vercel": ["vercel", "whoami"]}
    for name, cmd in checks.items():
        ok = shutil.which(cmd[0]) and subprocess.run(cmd, capture_output=True).returncode == 0
        print(f"{name:7} {'logged in' if ok else '-'}")
    return 0


def main(argv: list[str] | None = None) -> int:
    """CLI entry point."""
    parser = argparse.ArgumentParser(prog="agent-login")
    sub = parser.add_subparsers(dest="cmd", required=True)
    google = sub.add_parser("google")
    google.add_argument("--client-secret")
    for name in ("github", "vercel", "status"):
        sub.add_parser(name)
    args = parser.parse_args(argv)
    if args.cmd == "google":
        return login_google(args.client_secret)
    return {"github": login_github, "vercel": login_vercel, "status": show_status}[args.cmd]()


if __name__ == "__main__":
    sys.exit(main())
```


Implementation check before relying on `BROWSER=false`: gws-cli decides `can_open_browser` via `webbrowser.get()`; on a server without a display that already raises and it prints the URL. Verify on this server with `BROWSER=false gws-cli auth --account test` (kill after the URL appears) and record the exact output in the commit message body.

- [ ] **Step 4: Installer step** (interactive only, after keys):

```bash
if [ "$NONINTERACTIVE" != "1" ]; then
  say "logins -- optional, each can be done later"
  for svc in google github vercel; do
    read -r -p "Log in to $svc now? [y/N] " yn || yn=n
    case "$yn" in
      y|Y) python3 "$AGENT_WS/kit/bin/agent-login" "$svc" || say "WARN: $svc login not finished; later: $AGENT_WS/kit/bin/agent-login $svc" ;;
      *) say "later: $AGENT_WS/kit/bin/agent-login $svc" ;;
    esac
  done
fi
```

- [ ] **Step 5: Run** unit tests + `bash tests/run-tests.sh` (`check "agent-login unit tests" python3 -m unittest discover -s "$KIT/kit/tests" -p 'test_agent_login.py'`) → PASS.

- [ ] **Step 6: Commit** — `git commit -m "feat(kit): входы Google, GitHub, Vercel — по желанию, Google без туннеля"`

---

### Task 7: Web-tool routing rule and description audit

**Files:**
- Create: `kit/rules/web-tools.md`
- Modify: `kit/install-kit.sh` (append to rules.md), all kit `SKILL.md` descriptions where they overlap
- Test: `tests/run-tests.sh`

- [ ] **Step 1: Failing check**

```bash
check "web-tool routing table in rules.md" bash -c \
  "grep -q '## Which internet tool' '$WS/core/rules.md' && \
   test \$(grep -cE '^\| .* \| (WebSearch|WebFetch|crawl4ai|agent-browser|perplexity-research|last30days)' '$WS/core/rules.md') -ge 6"
```

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: `kit/rules/web-tools.md`**

```markdown

## Which internet tool

Pick the lightest tool that does the job:

| Need | Tool |
|---|---|
| A quick fact, a date, a price, «what is X» | WebSearch |
| Text of one page (article, docs) | WebFetch, or `markdown-new` for clean Markdown |
| A whole site, a page that needs JS, or text verbatim | crawl4ai |
| Act on a site: forms, login, clicks, screenshots, QA | agent-browser |
| A detailed answer with sources from many sites, a serious fact-check | perplexity-research (WebSearch if no key) |
| What people discussed in the last 30 days | last30days |

Instagram and other accounts that ban automation: never through agent-browser.
```

`install-kit.sh`: `cat "$KIT/rules/web-tools.md" >> "$AGENT_WS/core/rules.md"` (idempotent guard: skip if the heading is already there).

- [ ] **Step 4: Description audit** — print every kit description side by side:

```bash
for f in kit/skills/*/*/SKILL.md; do echo "== $f"; awk '/^---/{n++; next} n==1' "$f" | sed -n '/description/,$p'; done
```

Resolve each overlap with an explicit «Not for … — use …» line, at minimum:
- markdown-new ↔ crawl4ai ↔ agent-browser (one page / whole site / actions);
- perplexity-research ↔ last30days (sourced answer / recent discussion);
- youtube-transcript ↔ groq-voice (YouTube link / audio file or voice message);
- skill-finder ↔ skill-creator (find existing / write new);
- learnings ↔ agent-introspection (log a mistake / review own work and process).
The check from Task 3 Step 1 («says when to use it») guards the result.

- [ ] **Step 5: Run** → all ok. **Step 6: Commit** — `git commit -m "feat(kit): правило выбора интернет-инструмента и разведение описаний скиллов"`

---

### Task 8: Docs and the workspace map

**Files:**
- Create: `kit/README.md`
- Modify: `core/templates/tools/TOOLS.md.template:31-45`, `README.md` (top-level, install section), `ARCHITECTURE.md` (kit layer)
- Test: `tests/run-tests.sh`

- [ ] **Step 1: Failing check**

```bash
check "TOOLS.md lists every kit skill" bash -c \
  "cut -f2 '$KIT/kit/manifest.tsv' | grep -v '^#' | grep -v '^$' | \
   while read -r s; do grep -q \"\\b\$s\\b\" '$WS/tools/TOOLS.md' || { echo \$s; exit 1; }; done"
check "TOOLS.md has the later commands" bash -c \
  "grep -q 'agent-keys add' '$WS/tools/TOOLS.md' && grep -q 'agent-login' '$WS/tools/TOOLS.md'"
```

Note: `core/templates/` is overwritten by sync-core. So the TOOLS.md kit table must be appended by `install-kit.sh` from `kit/TOOLS-kit.md` (same pattern as `web-tools.md`), not edited in the core template. Create `kit/TOOLS-kit.md` and append it; leave `core/templates/` untouched except removing the old «Skills installed» rows only if the source repo does the same (otherwise the append explains the current set and the core table stays as base).

- [ ] **Step 2: Run** → FAIL.

- [ ] **Step 3: Write `kit/TOOLS-kit.md`** — table by category (skill, what, key or login, later command), the keys section (`"$AGENT_WS/kit/bin/agent-keys" list | add <service>`), the logins section (`agent-login google|github|vercel|status`), restart note. Write `kit/README.md` for repo readers: same table + sources and licenses (from «Approved kit») + how to add a skill (folder in a category + manifest row). Update top-level `README.md` install section with the Keys and Logins steps; `ARCHITECTURE.md` one paragraph on the kit layer and why it is outside `core/`.

- [ ] **Step 4: Run** → all ok. **Step 5: Commit** — `git commit -m "docs(kit): README набора, карта инструментов агента, архитектура"`

---

### Task 9: Real install check and PR

- [ ] **Step 1:** full test suite: `bash tests/run-tests.sh` and `python3 -m unittest discover -s kit/tests -v` — all green, paste the totals into the PR body.
- [ ] **Step 2:** real network install into a throwaway HOME on this machine (not production, nothing on systemd):

```bash
T=$(mktemp -d)
HOME="$T" TG_AGENT_NONINTERACTIVE=1 TG_AGENT_TEST_SKIP_GETME=1 TG_AGENT_TEST_SKIP_BUN=1 \
  TG_AGENT_BOT_TOKEN="123456789:$(printf 'x%.0s' $(seq 1 35))" AGENT_NAME=kitcheck OWNER_CHAT_ID=1 \
  bash install-server.sh --no-systemd --no-cron --no-live-test 2>&1 | tee "$T/install.log"
ls -la "$T/agents/kitcheck/.claude/skills"
HOME="$T" "$T/.local/bin/agent-browser" --version
HOME="$T" "$T/.local/bin/gws-cli" --version
HOME="$T" "$T/.local/bin/crwl" --help | head -3
CLAUDE_CONFIG_DIR="$T/.claude-agent-kitcheck" claude plugin list
```

Expected: every manifest skill resolves, the four CLIs answer, `claude plugin list` shows superpowers, vercel, document-skills. Record versions in the PR. Remove `$T` afterwards only with Kris's go (it is outside the repo, but deletion is red zone).
- [ ] **Step 3:** `bash scripts/leak-scan.sh` clean; `git diff origin/main --stat` reviewed.
- [ ] **Step 4:** cross-review with superpowers:requesting-code-review on the whole branch.
- [ ] **Step 5:** push branch, open PR to `main` (Russian title, body: what changed, tests, real-install result, «🤖 Generated with [Claude Code](https://claude.com/claude-code)»). Merge — Kris.
