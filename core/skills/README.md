# Skills

The agent's core (memory, recall, self-learning) needs **no skills** — these are optional add-ons.
Three kinds are set up here, all from neutral / official sources (no third-party catalog lock-in):

## 1. Bundled in this kit (copied, with their licenses)

| Skill | What | Key | License |
|-------|------|-----|---------|
| `quick-reminders` | local reminders (add/list/done) | none | MIT (this kit) |
| `groq-voice` | audio → text (Groq Whisper) | `GROQ_API_KEY` | MIT (this kit) |
| `youtube-transcript` | YouTube subtitles → text (yt-dlp) | none | MIT (this kit) |
| `markdown-new` | URL → clean Markdown (Jina Reader) | optional `JINA_API_KEY` | MIT (this kit) |
| `gws` | Google Workspace read (Gmail/Drive/Calendar) | `GOOGLE_ACCESS_TOKEN` | MIT (this kit) |
| `deep-research/*` | structured multi-step research | none (uses native search) | MIT — Weizhena/Deep-Research-skills |
| `skill-creator` | scaffold your own skills | none | Apache-2.0 — anthropics/skills |

The five wrappers are original to this kit. `deep-research` and `skill-creator` are bundled from
their upstream projects under their own licenses (see each folder's LICENSE / NOTICE).

## 2. Install as plugins (official / upstream — not copied)

Some tools are living plugins; install from source so you get updates:

```text
# superpowers (obra/superpowers, MIT) — TDD, debugging, planning, review, brainstorming
/plugin marketplace add obra/superpowers
/plugin install superpowers@superpowers-marketplace

# Brave Search (brave/brave-search-skills, MIT) — optional web-search backend for deep-research
/plugin marketplace add brave/brave-search-skills
/plugin install brave-search-skills@brave-search
```

Brave needs a free `BRAVE_SEARCH_API_KEY` (https://api.search.brave.com). It's optional —
`deep-research` also works with the agent's native search.

## 3. Add your own

Browse the neutral open registry at https://skills.sh, or use the `skill-finder` skill to search +
security-audit candidates, then `npx skills add <owner>/<repo>`. Prefer official (vendor-built) and
permissively-licensed skills.

## Keys

Skills that need a key degrade gracefully without it (they tell you what to set). Put keys in your
shell profile or a per-project `.envrc` (direnv) — never commit them.
