# Architecture

## Runtime

```
systemd: <name>-agent.service ── bin/run-agent.sh (main process, health loop)
                                   └─ tmux session <name>-agent
                                        └─ claude TUI  (--dangerously-load-development-channels
                                             │           server:dashi-channel)
                                             └─ bun MCP server = dashi-channel plugin
                                                  ├─ Telegram long polling / sendMessage
                                                  ├─ webhook 127.0.0.1:<port> (hooks → plugin)
                                                  └─ DM file inbox + one watcher per chat
systemd: <name>-ratewatch.service ── bin/ratewatch.sh (watches the tmux pane)
cron: auth-monitor, snapshot, cleanup-media, learnings-lint, memory rotation
```

- The TUI needs a PTY, hence tmux. `run-agent.sh` exits when bun, the webhook port or
  the tmux session disappears; `Restart=always` respawns the whole stack.
- Private messages use the file inbox (patch 0007): the plugin commits each DM to disk
  and a watcher pastes it into the pane with a verified Enter, so a message cannot be
  lost to a dropped MCP notification.
- `ratewatch.sh` handles the two silent freezes: the rate-limit menu (answers «wait»)
  and a stuck composer (presses Enter once the pending text is stable across two polls
  with no active turn).

## Layout on the server

```
~/agents/<name>/.claude/            AGENT_WS
  CLAUDE.md, core/                  identity + memory (hot/warm/cold), from core/
  hooks/, scripts/, skills/         core hooks + server hooks, memory scripts
  bin/                              server scripts (run-agent, ratewatch, crons)
  agent.conf                        non-secret settings, KEY="value"
  dashi-plugin/plugin/              built plugin; the Claude session's project dir
    .claude/settings.json           hooks + permissions for the plugin session
  state/telegram/config.json        plugin config (mode 600)
  logs/
~/.config/tg-agent/<name>/          secrets (700): channel.conf, claude-auth.conf
~/.claude-agent-<name>/             CLAUDE_CONFIG_DIR, one per agent
```

The Claude session runs in the plugin dir, so `~/agents/<name>/.claude/CLAUDE.md` loads
as an ancestor and core hooks are called with `CLAUDE_PROJECT_DIR=<agent home>`.

## Default kit (kit/)

`kit/` holds the skills every agent gets (grouped by category, listed in
`kit/manifest.tsv`), the helper programs `agent-keys` and `agent-login`, the web-tool
routing rule and the tool map. It sits outside `core/` because `core/` is synced from the
core source repo and overwritten by `scripts/sync-core.sh`; anything the kit appends to
`core/rules.md` or `tools/TOOLS.md` is therefore added by `kit/install-kit.sh`, once, with
a heading as the idempotency guard. The installer copies the kit to `$AGENT_WS/kit`, links
each skill into `$AGENT_WS/skills/`, and installs pinned upstream tools and plugins;
optional items only warn on failure. Keys go to `keys.env` in the secrets directory, never
into the agent home. See `kit/README.md`.

## Configuration

Plugin precedence: env > `state/telegram/config.json` > built-in defaults. Upstream
defaults contain the upstream author's bot and user IDs; both layers override them, and
the installer test asserts no upstream ID survives. `webhook.enabled`, `owner_chat_ids`
and `permission_relay` exist only in config.json.

`agent.conf` and `channel.conf` are plain `KEY="value"` lines readable by both bash
`source` and systemd `EnvironmentFile`; the installer rejects `"`, `$`, backticks and
backslashes in values.

## Hooks in the plugin session

| Event | Hooks |
|---|---|
| PreToolUse | block-dangerous (Bash), protect-files (Edit/Write) |
| PostToolUse | log-commands |
| UserPromptSubmit | post-to-webhook, inject-channel-reminder, local-recall, correction-detector |
| Stop | write-handoff, post-to-webhook |
| PreCompact | precompact-backup |

The plugin writes the last `reply` text into `core/hot/recent-plugin.md`;
`write-handoff` merges hot files into `core/hot/handoff.md`, which CLAUDE.md includes.
That is how context survives `/compact` and restarts.

## Team layer (install-fleet.sh)

```
                 ┌──────────── G-Brain (upstream public-gbrain-agentos + patches) ────────────┐
agent A ─ MCP ──▶│ gbrain-memory :8767   gbrain-recall :8768   gbrain-swarm :8766 ── Postgres  │
agent B ─ MCP ──▶│                                   gbrain-swarm-worker ─┐                   │
                 └────────────────────────────────────────────────────────┼───────────────────┘
                     webhook 127.0.0.1:<agent port>/hooks/agent (bearer)  ▼
                                                    agent B's dashi-channel plugin → TUI prompt
```

- One brain per server, one bearer token per agent (`issue-agent-token.py`), stored as
  `GBRAIN_BEARER` in the agent's `channel.conf`. The pane sources that file, so
  `${GBRAIN_BEARER}` in the plugin's `.mcp.json` resolves at session start; the token
  never lands in the agent tree. `settings.local.json` enables the three servers.
- The swarm worker reads `/etc/gbrain/fleet.env` through the drop-in
  `gbrain-swarm-worker.service.d/tg-agent-fleet.conf`: `AGENT_GATEWAYS` (agent → webhook
  URL), `AGENT_GATEWAY_AUTH` (agent → `bearer:env:FLEET_<NAME>_WEBHOOK_TOKEN`, the
  plugin's webhook secret), `OWNER_CHAT_ID`, `COORDINATOR_AGENT`. Tasks sent to the
  coordinator are ack-only; other agents execute, report to the owner and notify the
  coordinator.
- Patch 0001 removes `agentId` from the worker's webhook body; without it every delivery
  to a dashi webhook gets 404. install-fleet refuses a brain that lacks it.
- `core/rules.md` of each agent gets a block between `team-layer:start/end` markers,
  rendered from `server/templates/team-rules.md`; a re-run replaces it in place.
- Plan, then apply. Everything up to `# ===== apply` only reads; every refusal happens
  there, before the first write or token.
- Wiring: `server/fleet/brain-wiring.py` classifies each agent's `.mcp.json` as
  `local`, `remote`, `unknown` or `mixed`. A brain entry is any server with `gbrain` in
  its name, URL path or command, or a URL on ports 8766-8768; its role comes from the
  name (`mem`/`memory`, `rec`/`recall`, `sw`/`swarm`), else the port. stdio entries
  (`mcp-remote`) are placed by the URL in their args. Local means `localhost`,
  `*.localhost`, any loopback or unspecified address (IPv4 shorthand and v4-mapped
  included), or the server's hostname / `hostname -I` addresses. A `${VAR}` host or a
  stdio entry without URL is `unknown`; local plus remote entries, or a remote wiring
  missing or duplicating a role, is `mixed`. Both stop the run.
- Remote shared brain: an agent whose three roles all point at another server stays
  wired as it is: no `.mcp.json` rewrite, no `GBRAIN_BEARER`, no entry in `fleet.env`;
  only its rules block is rewritten. When every agent is remote, the local brain,
  tokens, worker drop-in and backup are skipped; leftovers of earlier runs (backup
  cron, `fleet.env`, the drop-in) and a stale `GBRAIN_BEARER` are only warned about,
  with backup-first manual steps, never deleted.
- Broken-wiring signature: a local agent with `GBRAIN_TOKEN` in `channel.conf` that
  `.mcp.json` never references, or a `.mcp.json?*` backup that classifies as
  remote/mixed, looks like an earlier run rewired a remote brain. The run stops with
  restore guidance. `--replace-remote-brain` rewires such agents (and remote ones) to
  127.0.0.1 and records them in `fleet.conf` as `FLEET_LOCAL_BRAIN`, so later runs
  skip the check for them. Every `.mcp.json` change leaves
  `.mcp.json.bak_fleet_<stamp>[_n]` next to it.
- Roster: `~/.config/tg-agent/fleet-roster` (`name: one-line role`, `#` comments;
  `--roster FILE` for another path) lists teammates across servers. The rules block lists
  them in file order, then local agents the file omits; a file role beats the CLAUDE.md
  first line. A role ending in `(coordinator)` marks the coordinator (one at most);
  `--coordinator` / `TG_FLEET_COORDINATOR` wins over it. With a remote agent on the
  server the roster is required and the coordinator must be explicit (flag, env or
  marker, never `fleet.conf`) and listed in the roster. The coordinator may be any roster
  name; a remote coordinator with local agents is warned about, because the local
  worker only knows local webhooks.
- Team state: `~/.config/tg-agent/fleet.conf` (`FLEET_AGENTS`, `FLEET_COORDINATOR`,
  `FLEET_LOCAL_BRAIN`).
  `/etc/gbrain/tg-agent-fleet.marker` records that the kit installed the brain; a brain
  without it needs `--use-existing-brain`, which also rotates tokens.
- Backup: `server/fleet/gbrain-backup.sh`, cron 03:17 as root, `pg_dump -Fc` + vault
  tarball into `/var/backups/gbrain`, 14 days kept. Restore steps are in the script header.
- Smoke: `server/fleet/mcp-smoke.py` does what Claude Code does on each server
  (`initialize`, keep `Mcp-Session-Id`, `notifications/initialized`) and then calls one
  tool with the agent's token. Upstream serves only `GBRAIN_TOOLS=core`, so the calls are
  memory `supersede_decision` on a missing decision (passes on the expected "Original
  decision not found", which comes after the token and write-scope checks; nothing is
  written), recall `recent {"scope":"30-decisions","limit":1}`, swarm `ack` on a
  nonexistent task id. A key without write scope on `30-decisions` fails the memory call
  with a scope error before the lookup; that still proves the key, so it passes with a
  note. Remote agents are smoked on their own URLs with the bearer variable their
  `.mcp.json` names; a missing or literal key, an unset variable or an unreadable URL is
  a failure (the literal is never printed), and so is an agent with zero passing
  checks. Upstream runs
  the servers in stateful streamable-http mode, so a bare `tools/list` without a session
  gets 400; and the bearer is checked only inside tool handlers, so `tools/list` would
  pass with any token. Any failure stops the run.
- Guards run before the first token is issued, because issuing revokes the agent's
  previous token: foreign worker drop-ins, missing `.mcp.json` / `core/rules.md`, an
  unknown coordinator. Rotation together with `--no-restart` is refused (live agents
  would keep dead tokens). A brain dir without the brain's python or token script is
  refused instead of installed over. Ports 8766-8768 are fixed by upstream's units.
- Known limit: a swarm task reaches the receiving agent through the dashi webhook, which
  hands it to the session as an MCP channel notification. If the session is busy or
  restarting, that notification can be lost; the delivery stays in the brain
  (`get_delivery`, `list_my_pending`), but nobody is woken up for it.

## Build

`vendor/dashi-plugin/` is an untouched `git archive` of the pinned upstream commit.
`scripts/build-plugin.sh` copies it and applies `patches/dashi-plugin/*.patch` in order;
the installer runs this at install time. `core/` is synced from the core source repo by
`scripts/sync-core.sh` (version in `core/CORE_VERSION`). The brain follows the same
pattern: `vendor/public-gbrain-agentos/` + `patches/public-gbrain-agentos/` →
`scripts/build-gbrain.sh`, run by install-fleet.

## Tests

`tests/run-tests.sh`: leak scan, `bash -n` on every script, ratewatch detector tests,
and a full non-interactive install into a throwaway HOME (network and `bun install`
skipped) with checks on file modes, placeholders, IDs, hook targets and unit rendering.
Then the brain build (worker tests when `GBRAIN_TEST_PYTHON` is set) and an install-fleet
run over two agents against a fake token issuer, fake `systemctl` and
`tests/fake-brain-mcp.py` (stateful like upstream: 400 without a session, bad token →
tool error): tokens, `.mcp.json`, rules block, `fleet.env`, drop-in, cron, smoke with
live and dead tokens (only core tools called), idempotent re-run, rotation, adoption of
an existing brain and every refusal, including that refusals issue no tokens. Section 6a
covers a remote shared brain (wiring and key untouched, smoke on the remote URLs through
`TG_FLEET_TEST_SMOKE_HOST`), an all-remote server (no local brain), the roster file with
a remote coordinator, and `--replace-remote-brain`. Section 6c covers the classifier
(loopback forms, own host, variable host, stdio and renamed entries, mixed and partial
wiring), the broken-wiring signature and its acknowledgement, the required roster and
coordinator, leftover warnings and the smoke failure modes; refusals there are checked
to leave the agent files unchanged.
`--with-plugin` adds the plugin build, typecheck and its test suite.
