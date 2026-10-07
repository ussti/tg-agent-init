# Agent doctor -- design

Status: draft for review. Implementation starts after PR #11 (versions file) and PR #9
(prepare-server.sh) are merged.

## Goal

Every server set up with tg-agent-init gets a second, separate Telegram bot -- the
**doctor**. It is a copy of the operator's own system bot (Richard on the reference
server): a Claude Code session behind its own bot, running as its own Linux user with
passwordless root through sudo. The owner writes to it when an agent misbehaves; it reads
logs, configs and code of any agent on the server and fixes them in place.

Working agents never get root. The doctor is the only component with it.

The module is mandatory: an install is not reported as finished until the doctor is up.

## What the owner said (2026-10-07)

- «агента для настройки и устранения ошибок непосредственно в коде. У него есть отдельный
  главный доступ к агентам и к серверу, которого нет у остальных агентов»
- «Нам нужен бот такой же, как Ричард ... доступ к root»
- «сделаем обязательным модулем»
- «я хочу, чтобы мы сделали именно так, как устроен мой бот Ричард»
- user name: `doctor`
- Alerts and the health watchdog are out of scope; the doctor answers when asked.

## Reference: how Richard is built (verified on the reference server)

- Package: `claude-code-telegram` (github.com/RichardAtCT/claude-code-telegram), tag
  `v1.6.0`, installed with pip from git into a venv (`/opt/richard/venv`, Python 3.12).
- Unit written by hand: `User=edgelab`, `WorkingDirectory=/opt/richard`,
  `EnvironmentFile=/opt/richard/.env`, `HOME` and `PATH` (with `~/.local/bin`) set,
  `Restart=on-failure`, `RestartSec=10`.
- Claude login: the user's own `claude` login (subscription), no API key.
- Behaviour from the package code: every Telegram message is one Agent SDK call; the
  session resumes per user + directory and resets on `/new` or after 24 h. File tools are
  confined to `APPROVED_DIRECTORY`; Bash is checked only for commands that change files
  outside it, and `sudo` is not checked. Agentic mode (default) does not filter message
  text. The project `CLAUDE.md` in the working directory is loaded as instructions.

Differences we take on purpose, versus Richard:

| Richard | doctor | Why |
|---|---|---|
| runs as the main user | runs as its own user `doctor` | the agents' user keeps no root |
| `Restart=on-failure` | `Restart=always` | a clean exit must not leave the server without a doctor |
| sandbox setting unknown | `SANDBOX_ENABLED=false` set explicitly | package default is `true`; the OS sandbox (bwrap) sets no-new-privileges and `sudo` fails inside it |
| env file in `/opt` | `/etc/agent-doctor/env`, root:doctor 640 | token outside the code dir, unreadable by agents |

## Components

All new files live under `server/doctor/` plus one installer at the repo root.

### 1. `install-doctor.sh` (repo root, run as root)

One command, re-runnable. Steps:

1. Checks: running as root; Ubuntu/Debian; at least one agent installed (an `agent.conf`
   found, see *Finding agents*). Without an agent it stops with the command to run first.
2. User `doctor` (`useradd -m -s /bin/bash`), if missing.
3. sudo: writes `/etc/sudoers.d/agent-doctor` = `doctor ALL=(ALL) NOPASSWD:ALL`, mode
   440, validated with `visudo -cf` on a temp file before it is moved into place. The
   agents' user gets nothing.
4. Python: package needs Python >= 3.11. Uses `uv` (installed into `/usr/local/bin` if
   missing) to create `/opt/agent-doctor/venv` with a managed Python 3.12, then
   `uv pip install "git+https://github.com/RichardAtCT/claude-code-telegram@<tag>"`.
   The tag comes from `kit/versions.env` (`DOCTOR_BOT_TAG=v1.6.0`).
5. Claude Code for `doctor`: `claude.ai/install.sh` run as `doctor` (same way
   prepare-server.sh installs it for the agent user).
6. Bot token: asks for a token from a new BotFather bot, input hidden; checks it with
   `getMe`; refuses the token of any existing agent (compared against the agents' bot
   usernames). Owner ID: taken from the agent's `agent.conf` (`OWNER_CHAT_ID`), shown for
   confirmation.
7. Env file `/etc/agent-doctor/env` from `server/doctor/env.template` (root:doctor, 640):
   token, bot username, `ALLOWED_USERS=<owner id>`, `AGENTIC_MODE=true`, `APPROVED_DIRECTORY=/home/doctor`,
   `SANDBOX_ENABLED=false`, `CLAUDE_CLI_PATH=/home/doctor/.local/bin/claude`, cost cap.
8. `/home/doctor/CLAUDE.md` from `server/doctor/CLAUDE.md` (overwritten on re-run; a
   copy of the previous one is kept as `CLAUDE.md.bak_<stamp>`), plus
   `/home/doctor/bin/list-agents.sh`.
9. Unit `/etc/systemd/system/agent-doctor.service` from
   `server/doctor/agent-doctor.service.template`, `daemon-reload`, `enable`.
10. Claude login: prints the one command the owner runs (`su - doctor -c claude` then
    `/login`) and waits; then checks `claude -p ping` as `doctor` succeeds.
11. Starts the unit, waits until it is active for 20 s in a row, then sends the owner a
    first message through the Bot API: «Я doctor, наладчик сервера. Пиши, если агент
    сломался». Done line: `== Doctor is up (@<bot>)`.

Re-run with everything in place: no prompts except a confirmation, nothing duplicated,
the package reinstalled only when the tag in `versions.env` changed.

### 2. `server/doctor/agent-doctor.service.template`

```
[Unit]
Description=Agent doctor (Telegram, root through sudo)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=doctor
WorkingDirectory=/home/doctor
EnvironmentFile=/etc/agent-doctor/env
Environment=HOME=/home/doctor
Environment=PATH=/home/doctor/.local/bin:/usr/local/bin:/usr/bin:/bin
ExecStart=/opt/agent-doctor/venv/bin/claude-telegram-bot
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
```

`claude-telegram-bot` is the package's console script (entry point `src.main:run`).

### 3. `server/doctor/CLAUDE.md` -- the doctor's instructions

English text (it is a durable instruction file), answers to the owner in her language.
Content:

- Who it is: the server's doctor; the only process with root; agents are its patients.
- Finding agents: run `~/bin/list-agents.sh` -- it lists every `agent.conf` under
  `/home/*/` (any depth up to the install layout) and the `*-agent.service` units, with
  their state. Never rely on a list written at install time.
- Where things are, per agent (paths read from its `agent.conf`): workspace, logs
  (`<ws>/logs/`), secrets dir (exists, never printed), units `<name>-agent.service` and
  `<name>-ratewatch.service`, `journalctl -u`, crontab of the agent's user, the kit repo
  copy and `update.sh`.
- How it works on an agent: as that agent's user through `sudo -u <user> -H`, so files
  keep the right owner; root only for systemd, packages and system files.
- Diagnosis order: service state -> recent journal -> agent logs -> config -> code.
- Rules:
  - backup before any edit (`<file>.bak_<stamp>`), show the diff after;
  - never delete memory, the profile, keys, logins or backups;
  - never print secret values; may say whether a key is set;
  - irreversible or wide actions (deleting data, reinstalling, changing another agent's
    model, anything touching several agents) -- plan first, act after the owner's «да»;
  - after a fix: restart what is needed and show that it came back.
- Updating an agent: `sudo -u <user> -H bash -lc 'cd ~/tg-agent-init && ./update.sh'`.

### 4. `server/doctor/list-agents.sh`

Read-only helper. Output per agent: name, Linux user, workspace, unit states. Exit 0 with
«no agents found» when empty.

### 5. `server/doctor/env.template`

Variables only, no values except non-secret defaults. Rendered with the existing
`scripts/render-template.py`.

### 6. Hooks into existing scripts

- `install-server.sh`: the final block stops printing «== Done» as the last word when no
  doctor is found (`systemctl is-enabled agent-doctor.service` fails). It prints
  «Agent is up. One step left: the doctor» and the exact command
  `sudo bash ~/tg-agent-init/install-doctor.sh`. When the doctor already exists, it
  prints the usual done line.
- `prepare-server.sh` (PR #9): at the end, a line that after the first agent the doctor
  is installed with that command.
- `kit/versions.env` (PR #11): new key `DOCTOR_BOT_TAG`.
- `scripts/bump-versions.py` (PR #11): new source kind "GitHub tag" for
  `RichardAtCT/claude-code-telegram`, same flow as the other sources (weekly PR, tests,
  smoke).
- README: section «Наладчик (doctor)» -- what it is, why it has root, how to talk to it.

## Finding agents

Agents are found at run time, not listed at install: `agent.conf` under `/home/*/`
(matching update.sh's `*/.claude/agent.conf`, excluding `*.bak_*`) and
`systemctl list-units '*-agent.service'`. This differs from the earlier chat wording
(«список при установке»): a second agent added later is seen without re-installing the
doctor.

## Security

- Root is held by one Linux user that only the doctor process runs as; no agent user is
  in sudoers.
- Only the owner's Telegram ID can talk to it (`ALLOWED_USERS`).
- Token: hidden input, file 640 root:doctor, never echoed, never in the repo, never sent
  through Telegram.
- The doctor bot is a different bot from every agent; the installer refuses a reused
  token.
- `SANDBOX_ENABLED=false` is a deliberate trade: the doctor needs sudo. Its limits are the
  owner allow-list and the rules in its CLAUDE.md.

## Error handling

- Any failed step stops with what failed and the command to retry; earlier steps are
  kept (re-run is safe).
- `visudo -cf` failure: the sudoers file is not installed; the installer stops.
- `getMe` failure: asks for the token again (3 tries).
- Unit not active after 60 s: prints the last 30 journal lines and stops.

## Tests (offline, in `tests/run-tests.sh`)

1. Templates render with no leftover `{{...}}`; the unit file passes
   `systemd-analyze verify` when available.
2. The sudoers line passes `visudo -cf`.
3. `install-doctor.sh` in a dry-run mode (`TG_DOCTOR_DRY_RUN=1`, fake root dir) creates
   the expected files with the expected modes; a second run changes nothing.
4. `list-agents.sh` against a fixture tree with 0, 1 and 2 agents.
5. Leak scan: no token-like strings in rendered files except the env file; the env file
   mode is 640.
6. `install-server.sh` final block: with and without a doctor unit, prints the right
   ending.
7. bump-versions: the GitHub-tag source parses a fixture API response.

Real install (one fresh VPS, manual, before merge): install agent -> install doctor ->
from Telegram ask the doctor to list agents, read an agent's log and restart its unit.

## Out of scope

- Alerts, health watchdog, reviving agents without being asked.
- Mac install.
- More than one doctor per server; access for anyone but the owner.

## Cost cap

`CLAUDE_MAX_COST_PER_REQUEST=5` (USD) in the env file; the owner can change it there.
