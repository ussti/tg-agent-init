---
name: onboard
description: First-run personalization of this agent. Use when the operator types /onboard or asks to "set me up", "get to know me", "настрой меня", "давай познакомимся", and at the start of a session when core/USER.md still has `<!-- onboard:` slots. Asks one question per slot and writes the answers into USER.md, CLAUDE.md, rules.md and TOOLS.md.
---

# Onboard

The identity files ship as a reference set with `<!-- onboard: <question> -->` slots. This skill
turns each slot into the operator's own answer. It writes ONLY where a slot stands; every other
line of CLAUDE.md, rules.md and USER.md stays as shipped (those files are operator-only, and
running /onboard is the operator's permission for exactly these slots).

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
4. Secrets: the Secrets slot takes a folder path only. If the operator pastes a key, do not
   repeat it back, do not write it anywhere, tell them to put it in a file in that folder and
   give you the path. Exit 3 from `fill` means the same.
5. When the list is done, show the operator everything written, grouped by file, and ask
   whether to correct anything. Corrections go through a direct edit of those same lines only.
6. Finish with one line: onboarding done, the new profile is loaded from the next session
   (USER.md, CLAUDE.md and rules.md are read at session start).

## Rules

- One question per message. No questionnaires, no numbered lists of questions.
- Do not rewrite, reorder or "improve" any line outside the slots.
- Re-running /onboard asks only what is still open (skipped slots).
