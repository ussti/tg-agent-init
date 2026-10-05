# Default kit

The skills and tools every agent gets after `install-server.sh`. The kit is a folder of
skills grouped by category plus a few helper programs. It lives outside `core/` on
purpose: `core/` is synced from the core source repo and overwritten, the kit is owned
here.

```
kit/
  manifest.tsv         category, skill, kind -- the single list of kit skills
  skills/<category>/<skill>/SKILL.md
  bin/agent-keys       add API keys (hidden input, live check)
  bin/agent-login      Google / GitHub / Vercel logins
  rules/web-tools.md   internet-tool routing rule, appended to core/rules.md
  TOOLS-kit.md         tool map, appended to tools/TOOLS.md
  config/              agent-browser safety config
  install-kit.sh       the installer
```

`install-kit.sh <AGENT_WS> <CLAUDE_CONFIG_DIR>` copies the kit to `$AGENT_WS/kit`, links
every manifest skill into `$AGENT_WS/skills/`, appends the routing rule and the tool map
(each once, a heading guards a rerun), then installs upstream tools and plugins. A network
failure only warns; the install never dies on an optional item.

## Skills

Categories: system, research, office, media, dev. Key or login column: every one is
optional, Enter skips, add it later with the command shown.

| Category | Skill | Key or login | Later command |
|---|---|---|---|
| system | superpowers (plugin) | none | |
| system | skill-creator | none | |
| system | skill-finder | none | |
| system | agent-introspection | none | |
| system | learnings | none | |
| system | quick-reminders | none | |
| system | onboard | none | |
| research | perplexity-research | `PERPLEXITY_API_KEY` (paid) | `agent-keys add perplexity` |
| research | agent-browser | none | |
| research | markdown-new | optional `JINA_API_KEY` | `agent-keys add jina` |
| research | crawl4ai | none | |
| research | last30days | optional `BRAVE_API_KEY`, `SCRAPECREATORS_API_KEY` | `agent-keys add brave` / `scrapecreators` |
| office | gws | Google login (own OAuth client) | `agent-login google` |
| office | cal | `CAL_API_KEY` | `agent-keys add cal` |
| office | docx, pdf, pptx, xlsx (plugin) | none | |
| media | groq-voice | `GROQ_API_KEY` (free) | `agent-keys add groq` |
| media | youtube-transcript | optional `TRANSCRIPT_API_KEY` (paid) | `agent-keys add transcriptapi` |
| dev | senior-brainstorm | none | |
| dev | GitHub | optional login | `agent-login github` |
| dev | Vercel (plugin) | optional login | `agent-login vercel` |

## Sources and licenses

Third-party programs come only from their official source, at the pinned version.

| Item | Source | License |
|---|---|---|
| superpowers | plugin `superpowers@claude-plugins-official` | MIT |
| skill-creator | bundled copy, anthropics/skills | Apache-2.0 (`skills/system/skill-creator/LICENSE.txt`) |
| agent-browser | npm `agent-browser@0.38.2` (Vercel Labs) | Apache-2.0 |
| crawl4ai | pipx `crawl4ai==0.9.4` | Apache-2.0 |
| last30days | git `mvanhorn/last30days-skill` at the commit pinned in `skills/research/last30days/UPSTREAM` | MIT |
| gws | pipx `gws-cli==1.5.0` | MIT |
| docx, pdf, pptx, xlsx | plugin `document-skills@anthropic-agent-skills` (marketplace `anthropics/skills`) | see upstream |
| Vercel | plugin `vercel@claude-plugins-official`, CLI `vercel@62.2.0` | see upstream |
| GitHub | `gh` from apt or the official site | see upstream |
| senior-brainstorm | our skill, `skills/dev/senior-brainstorm/LICENSE` | MIT |
| skill-finder, agent-introspection, learnings, quick-reminders, onboard, perplexity-research, markdown-new, groq-voice, youtube-transcript, cal | our skills (some with an upstream base; no separate license file) | see upstream |

yt-dlp (for youtube-transcript) is installed with pipx from the official package.

## Add a skill

1. Create `kit/skills/<category>/<skill>/SKILL.md` (frontmatter with `name` and a
   `description` that does not overlap with its neighbours).
2. Add a row to `kit/manifest.tsv`: `<category><TAB><skill><TAB>bundled`.
3. Add the skill to `TOOLS-kit.md` and the table above. `tests/run-tests.sh` fails when a
   manifest skill is missing from the tool map.
4. If the skill needs a key, add the service to `SERVICES` in `bin/agent-keys`.
5. Run `scripts/leak-scan.sh` and `tests/run-tests.sh`.
