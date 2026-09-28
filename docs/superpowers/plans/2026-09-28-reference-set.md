# Reference set -- implementation plan

**Goal:** replace the short generic identity templates with a reference set derived from the
operator's own working agent: same structure and rules, personal data removed, personal parts
turned into `<!-- onboard: ... -->` slots that the future `/onboard` skill fills by asking.

**Source of truth:** the core source repo (`templates/`). tg-agent-init receives
the result through `scripts/sync-core.sh`. Both repos: branch `feature/reference-set`, no push
to `main`.

## Layers

| Layer | Where | Installed by |
|---|---|---|
| Base (one agent, no team) | `templates/` in the core repo -> `core/templates/` here | install.sh / install-server.sh |
| Team (brain + swarm + coordinator) | `server/templates/team-rules.md` | install-fleet.sh |

Everything about subagents, the shared brain, the swarm and fleet peers leaves the base layer.
The team layer already carries brain recall/write rules, swarm routing, escalation to the
coordinator and `list_my_pending` -- checked, nothing to add.

## Slot convention

`<!-- onboard: <question> -->` directly under the heading it fills. Not a `{{KEY}}`
placeholder: installers leave it untouched, render-template.py does not fail on it, and
`/onboard` finds every slot with one grep.

## Tasks

1. **CLAUDE.md.template** -- operator's agent CLAUDE.md minus Coordination, subagent tactics,
   team table, G-Brain section, Models table; Data hierarchy without the database tier;
   Access zones without AGENTS.md; escalation step 2 without «second model» as a requirement.
   Style personal bits (emoji, signature phrases, punctuation) -> slot.
2. **global-CLAUDE.md.template** -- operator's global file minus name, Telegram ID, timezone
   literal, Hierarchy block (operator/agents/safety-net bot), workspace-snapshot git rule.
   Coder-only sections (code style, git, deploy, coder skills) stay in `coder-overlay.md`,
   installed on «do you write code? y».
3. **core/rules.md.template** -- operator's rules.md structure; drop secrets path, private
   library recall rule, workspace-commit rule (brain/snapshot); commit language ->
   `{{LANGUAGE}}`; language-specific writing rules -> slot.
4. **core/USER.md.template** -- headings exactly as the operator's USER.md (Profile, Links,
   Goals, Communication Style, What operator needs from this agent, Channels); one slot
   question per heading.
5. **tools/TOOLS.md.template** -- Workspace, Memory layers, Skills installed, Model; Services /
   Accounts / Secrets (paths only) as empty slots.
6. **Drop core/AGENTS.md** from the base: template, both installers, core tests, docs mentions.
   Its recall note moves to TOOLS.md, `{{PRIMARY_MODEL}}` to TOOLS.md.
7. **Sync** into tg-agent-init (`scripts/sync-core.sh`), update install-server.sh.

## Checks

- core repo: `bash tests/run-tests.sh` (templates present, install renders, no `{{` left,
  no server/brain terms in the base).
- tg-agent-init: full test suite + `scripts/leak-scan.sh` with the external entities list.
- `grep -c 'onboard:'` per file: every USER.md heading has a slot.
- Manual diff against the operator's files: each removal listed for review.

## Out of scope

`/onboard` itself -- only after the operator approves the reference set.
