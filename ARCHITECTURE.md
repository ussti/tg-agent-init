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

## Build

`vendor/dashi-plugin/` is an untouched `git archive` of the pinned upstream commit.
`scripts/build-plugin.sh` copies it and applies `patches/dashi-plugin/*.patch` in order;
the installer runs this at install time. `core/` is synced from the core source repo by
`scripts/sync-core.sh` (version in `core/CORE_VERSION`).

## Tests

`tests/run-tests.sh`: leak scan, `bash -n` on every script, ratewatch detector tests,
and a full non-interactive install into a throwaway HOME (network and `bun install`
skipped) with checks on file modes, placeholders, IDs, hook targets and unit rendering.
`--with-plugin` adds the plugin build, typecheck and its test suite.
