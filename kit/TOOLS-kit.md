
## Default kit

This section supersedes the «Skills installed» table above.
Skills come from the kit installed at `$AGENT_WS/kit`. A skill without its key or login
stays inert and says what to set; nothing else breaks. Every key and login is optional.

### System

| Skill | What it does | Key or login | Later command |
|-------|--------------|--------------|---------------|
| superpowers | planning, TDD, debugging, review, brainstorming (plugin) | none | |
| skill-creator | create and improve skills | none | |
| skill-finder | find an existing skill for a task | none | |
| agent-introspection | self-audit and clarifying questions | none | |
| learnings | score mistakes, promote repeated lessons to rules | none | |
| quick-reminders | one-off reminders in the agent's workspace | none | |
| onboard | first-run questions: profile, goals, style, services | none | |

### Research

| Skill | What it does | Key or login | Later command |
|-------|--------------|--------------|---------------|
| perplexity-research | answers with sources from many sites (WebSearch fallback) | `PERPLEXITY_API_KEY` (paid) | `agent-keys add perplexity` |
| agent-browser | act on a site: forms, clicks, screenshots | none | |
| markdown-new | clean Markdown from one URL | optional `JINA_API_KEY` | `agent-keys add jina` |
| crawl4ai | whole site or JS-only page, verbatim text | none | |
| last30days | what people said about a topic in the last 30 days | optional `BRAVE_API_KEY`, `SCRAPECREATORS_API_KEY` | `agent-keys add brave`, `agent-keys add scrapecreators` |

### Office

| Skill | What it does | Key or login | Later command |
|-------|--------------|--------------|---------------|
| gws | Google Workspace: Gmail, Calendar, Drive, Docs, Sheets, Slides, Contacts, Tasks | Google login (own OAuth client) | `agent-login google` |
| cal | Cal.com bookings | `CAL_API_KEY` | `agent-keys add cal` |
| docx, pdf, pptx, xlsx | read and write Office files and PDF (plugin `document-skills`) | none | |

### Media

| Skill | What it does | Key or login | Later command |
|-------|--------------|--------------|---------------|
| groq-voice | voice message to text | `GROQ_API_KEY` (free) | `agent-keys add groq` |
| youtube-transcript | transcript of a YouTube video | optional `TRANSCRIPT_API_KEY` (paid) | `agent-keys add transcriptapi` |

### Dev

| Skill | What it does | Key or login | Later command |
|-------|--------------|--------------|---------------|
| senior-brainstorm | architecture and stack decisions for a product | none | |
| GitHub | `gh` CLI | optional login | `agent-login github` |
| Vercel | deploys (plugin `vercel`) | optional login | `agent-login vercel` |

### Keys

Keys live in `keys.env` in the secrets folder (mode 600). Enter them only in the terminal,
never in Telegram. Input is hidden and the key is checked live.

```bash
"$AGENT_WS/kit/bin/agent-keys" list            # which keys are set, never shows values
"$AGENT_WS/kit/bin/agent-keys" add <service>   # add or replace one key
"$AGENT_WS/kit/bin/agent-keys" setup           # walk through every service, Enter skips
```

Services: groq, perplexity, cal, brave, scrapecreators, transcriptapi, jina.
A new key works after the agent restarts.

### Logins

```bash
"$AGENT_WS/kit/bin/agent-login" google    # needs your own OAuth client; prints the guide
"$AGENT_WS/kit/bin/agent-login" github
"$AGENT_WS/kit/bin/agent-login" vercel
"$AGENT_WS/kit/bin/agent-login" status    # which logins are active
```

Run them in the terminal on the server, not through the bot.
