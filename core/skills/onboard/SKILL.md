---
name: onboard
description: First-run personalization of this agent. Use when the operator types /onboard or asks to "set me up", "get to know me", "настрой меня", "давай познакомимся", and at the start of a session when core/USER.md still has `<!-- onboard:` slots. Asks one question per slot and writes the answers into USER.md and TOOLS.md.
---

# Onboard

The identity files ship as a reference set: the operator's defaults (communication style, what
the operator needs, writing rules) are already written, and only what the kit cannot know is left
as `<!-- onboard: <question> -->` slots -- profile, links, goals, overrides of the defaults, and
services. This skill turns each slot into the operator's own answer. It writes ONLY where a slot
stands; every other line of CLAUDE.md, rules.md and USER.md stays as shipped (those files are
operator-only, and running /onboard is the operator's permission for exactly these slots).

## Tool

`python3 <this skill dir>/onboard_slots.py list` -- open slots as JSON (`id`, `file`,
`heading`, `question`), already in asking order.
`python3 <this skill dir>/onboard_slots.py fill <id>` -- replaces slot `<id>` with stdin.
Exit 3 means the answer looked like a key or token and was NOT written.

The script finds the workspace itself (the folder with `core/USER.md`). If it cannot, pass
`--root <path>`.

## Flow

1. Run `list`. Empty -> say onboarding is complete and stop. Otherwise tell the operator in one
   line how many questions there are and that any of them can be skipped.
2. Ask the slots **one at a time**, in the order `list` returns. Ask in the operator's language
   (the `Language` line of USER.md), in your own words, keeping the meaning of the question.
   If the conversation runs through a chat channel, every question goes out through that
   channel's reply tool -- the operator does not read the terminal.
3. After each answer, write it with `fill`:
   - Files are English. Turn the answer into 1-5 short `- ` bullets in English, keeping the
     operator's facts. Names, links and quotes stay verbatim.
   - Never add anything the operator did not say. A vague answer stays vague -- ask one
     follow-up at most, then write what you have.
   - "skip" / "пропусти" / "later" -> do not call `fill`; the slot stays for the next run.
   - "nothing" / "нет" / "none" -> `fill` with `- none`.
4. The Overrides slot (USER.md): before asking, show the defaults it overrides -- the bullets of
   USER.md `Communication Style` and `What operator needs from this agent`, and the `Response
   format` bullets of rules.md -- retold briefly in the operator's language, then ask what to
   change. "All good" / "всё ок" -> `fill` with `- none`. Otherwise write only the changes, each
   as a bullet that names what it replaces (e.g. `- Emoji allowed (replaces "No emoji")`).
5. Keys are never asked: the installer already wrote the keys folder into TOOLS.md. Services are
   names only; a service that is not connected yet is still written, marked `(not connected)`.
   If the operator pastes a key, do not repeat it back, do not write it anywhere, and point to
   the keys folder from TOOLS.md. Exit 3 from `fill` means the same.
6. When the list is done, show the operator everything written, grouped by file, and ask
   whether to correct anything. Corrections go through a direct edit of those same lines only.
7. Finish with one line: onboarding done, the new profile is loaded from the next session
   (USER.md, CLAUDE.md and rules.md are read at session start).

## Rules

- One question per message. No questionnaires, no numbered lists of questions.
- Do not rewrite, reorder or "improve" any line outside the slots.
- Re-running /onboard asks only what is still open (skipped slots).
