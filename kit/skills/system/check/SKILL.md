---
name: check
description: Self-check of the agent's kit -- proves that keys, tools, skills and plugins actually work, then tries each keyed skill with the operator one action at a time. Use when the operator types /check, asks "проверь, что ты умеешь", "что у тебя работает", "проверь ключи", after update.sh, and as the last step of /onboard.
---

# Check

Two parts: a silent machine check, then short live tries with the operator. Keys are never
asked, shown or repeated here -- they are entered only in the terminal with `agent-keys`.

## 1. Machine check (silent)

```bash
"$AGENT_WS/kit/bin/agent-selfcheck" --json
```

Run it with the Bash tool timeout raised to 600000 ms: it usually takes under a minute, but
each probe may wait up to 30 seconds when a service hangs. It does a live re-check of every saved key, one real call per tool
(agent-browser, crawl4ai, markdown-new, yt-dlp, Google login), every kit skill visible in
`skills/`, the superpowers and vercel plugins installed and enabled, and a write -> read ->
delete round-trip for quick-reminders and learnings. Each row has `group`, `name`, `status`,
`why`, `fix`. Statuses:

- `works` -- passed;
- `not connected` -- a key, login or tool is absent: a setup step, not a failure;
- `unchecked` -- a key is saved, but its service could not be reached right now;
- `broken` -- the call failed or the key was rejected.

Send the operator ONE summary through the channel reply tool (the operator does not read the
terminal), in the operator's language:

1. one line with four counts: works, unchecked, not connected, broken;
2. `broken` rows, each with why and the fix command in a code block;
3. `not connected` rows, each with what it would unlock and the fix command;
4. `works` rows collapsed into one line of names. `unchecked` rows go with them, marked
   "key saved, the service did not answer".

Key fixes are `agent-keys add <service>`, the Google login is `agent-login google`; both run in
the server terminal, not in the chat.

## 2. Live tries (one at a time)

Then offer the tries below, **one message per try**, in this order. Skip a try whose
prerequisite is not `works`/`unchecked`. "skip" / "пропусти" moves to the next one; "stop" /
"хватит" ends the check.

| Try | Prerequisite | Ask the operator to | Then |
|-----|--------------|---------------------|------|
| groq-voice | key `groq` | send a short voice message | transcribe it with the groq-voice skill, show the text |
| perplexity-research | key `perplexity` | ask about any fresh news | answer with sources via perplexity-research |
| cal | key `cal` | say "покажи брони" or skip | list the upcoming bookings via the cal skill |
| youtube-transcript | tool `youtube-transcript (yt-dlp)` or key `transcriptapi` | send a YouTube link | short summary from the transcript |
| last30days | skill `last30days` | name a topic | run last30days on it, short digest |
| markdown-new | tool `markdown-new` | send a link to an article | 3-line summary from markdown-new |
| file | always | send any file (pdf, docx, photo) | download it and say what is inside |

After each try say in one line whether it worked. If it failed, say why and the fix, then move
on. Finish with one line: what works now, and that `/check` can be run again any time (after
`update.sh`, after adding a key). A key added with `agent-keys add` reaches the skills only
after the agent restarts; until then its row says "this session started without it".

## Rules

- Never print, echo or log a key value; if the operator pastes a key into the chat, do not
  repeat it, and point to `agent-keys add <service>` in the terminal.
- A skipped or absent key is "not connected", never a failure.
- Round-trip probes use throwaway files; the operator's reminders and lessons are untouched.
- The same steps run standalone (/check) and as the last step of /onboard.
