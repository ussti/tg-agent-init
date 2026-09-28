# Vendored components

## dashi-plugin

- Upstream: https://github.com/qwwiwi/dashi-plugin-claude-code
- Pinned commit: see `UPSTREAM_COMMIT`
- License: Apache License 2.0 (`dashi-plugin/LICENSE`); copyright stays with the upstream authors
- `vendor/dashi-plugin/` is an unmodified `git archive` of the pinned commit.
  Do not edit files there — every change lives in `patches/dashi-plugin/`.

### Statement of changes (Apache-2.0 §4b)

`scripts/build-plugin.sh` copies the upstream tree and applies these patches in order:

| Patch | Change |
|---|---|
| 0001 memory-read-reply-tool-args | Hot memory records the text of the last `reply` tool call instead of the last assistant text block; fixes an off-by-one when a turn ends on a tool call. Synthetic `tool_result` user messages no longer count as a turn boundary. |
| 0002 status-simple-typing-option | `status.simple_typing` / `TELEGRAM_STATUS_SIMPLE_TYPING`: collapse activity status into a plain «typing…» indicator. |
| 0003 redact-keep-html-closing-tags | Redactor no longer swallows closing HTML tags adjacent to a masked value. |
| 0004 telegram-flood-window-latch | Rate limiter latches an active flood window per chat and refuses retries beyond the wait budget instead of probing the API inside the ban. |
| 0005 telegram-flood-deadline-persists | Flood deadlines are persisted in the state dir and restored on boot, so a restart does not extend the ban. |
| 0006 tests-simple-typing-fixtures | Test fixtures carry the new `simple_typing` field. |
| 0007 dm-file-inbox-delivery | `TELEGRAM_DM_DELIVERY_MODE=inbox`: private messages are committed as files and pasted into the TUI by the multichat watcher with a verified Enter, instead of an MCP notification that can be lost. |
| 0008 memory-hot-filename-from-config | `HOT_MEMORY_FILENAME` is resolved once at bootstrap and passed to the memory writer as config (`hotFilename`), so the hot file name (e.g. `recent-plugin.md`) actually takes effect. |
| 0009 tests-memory-fixtures-and-fake-api | Memory tests use reply-tool fixtures (follows 0001); fake Telegram API implements `editRichMessage`. |
| 0010 tests-redact-regressions | Regression tests: Drive file IDs, hyphenated IDs and URL slugs stay unmasked. |
| 0011 claude-md-raw-html-reply-rule | `plugin/CLAUDE.md`: rule to pass raw HTML tags to `reply` and escape only literal `& < >`. |

Refreshing upstream: `scripts/update-vendor.sh` (keeps the old tree if any patch stops applying).

## public-gbrain-agentos

- Upstream: https://github.com/qwwiwi/public-gbrain-agentos
- Pinned commit: see `GBRAIN_UPSTREAM_COMMIT`
- License: Apache License 2.0 (`public-gbrain-agentos/LICENSE`); copyright stays with the upstream authors
- `vendor/public-gbrain-agentos/` is an unmodified tree of the pinned commit, checked by
  `GBRAIN_TREE_SHA256` in the leak scan. Do not edit files there — every change lives in
  `patches/public-gbrain-agentos/`.

### Statement of changes (Apache-2.0 §4b)

`scripts/build-gbrain.sh` copies the upstream tree and applies these patches in order;
`install-fleet.sh` runs upstream's `scripts/install.sh` from the result.

| Patch | Change |
|---|---|
| 0001 swarm-worker-drop-agentid | The swarm worker no longer sends `agentId` in the webhook body: the dashi-plugin webhook treats it as a routing key and answers 404 for any value but its own. The worker test asserts the field is absent. |
