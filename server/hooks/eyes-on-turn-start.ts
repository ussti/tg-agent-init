// eyes-on-turn-start.ts -- UserPromptSubmit hook: the 👀 read receipt at the START of a turn.
//
// The plugin's read-receipt-hook.ts reacts only on Stop (end of turn). This hook
// reacts as soon as the message enters the agent's turn. It reuses the plugin
// hook's parsing and config and appends to the same dedup log, so the Stop hook
// stays as a fallback and never sends a second reaction.
//
// Installed into <workspace>/hooks/; the plugin lives at <workspace>/dashi-plugin/plugin.
// Invariants: stdout is ALWAYS empty (UserPromptSubmit stdout lands in the model
// context), exit 0 on any error, the token comes only from the channel env file.
import { appendFileSync, mkdirSync } from 'fs'
import { dirname } from 'path'
import {
  loadChannelEnvFile,
  loadSeen,
  parseChannelRefs,
  refKey,
  resolveReactConfig,
  resolveStatePath,
} from '../dashi-plugin/plugin/scripts/read-receipt-hook.ts'

const REACT_TIMEOUT_MS = 5000

async function main(): Promise<void> {
  const input = JSON.parse(await Bun.stdin.text()) as { prompt?: string; session_id?: string }
  const refs = parseChannelRefs(input.prompt ?? '')
  if (refs.length === 0) return

  const env = { ...loadChannelEnvFile(process.env), ...process.env }
  const config = resolveReactConfig(env)
  if ('kind' in config) return
  const statePath = resolveStatePath(env, input.session_id)
  const seen = statePath ? loadSeen(statePath) : new Set<string>()

  const handled: string[] = []
  for (const ref of refs) {
    if (seen.has(refKey(ref))) continue
    try {
      const res = await fetch(config.url, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${config.token}` },
        body: JSON.stringify({ chat_id: ref.chat_id, message_id: ref.message_id }),
        signal: AbortSignal.timeout(REACT_TIMEOUT_MS),
      })
      if (res.ok) handled.push(refKey(ref))
      else process.stderr.write(`eyes-on-turn-start: react responded ${res.status}\n`)
    } catch (err) {
      process.stderr.write(`eyes-on-turn-start: ${err instanceof Error ? err.message : 'error'}\n`)
    }
  }
  if (statePath && handled.length > 0) {
    mkdirSync(dirname(statePath), { recursive: true })
    appendFileSync(statePath, handled.map((k) => `${k}\n`).join(''), { mode: 0o600 })
  }
}

await main().catch(() => {})
process.exit(0)
