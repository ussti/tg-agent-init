#!/usr/bin/env python3
"""
Silent-reply detector + Stop-hook blocker for a tg-agent plugin session.

Called synchronously from post-to-webhook.sh on Stop hook events. Walks the
transcript backward to find whether the current turn called
`mcp__dashi-channel__reply`.

Behavior:
  - reply found       -> exit 0, reset state.
  - reply MISSING:
      block_count < 2 -> exit 2 with stderr message (harness blocks Stop and
                         feeds stderr to Claude as continuation prompt).
      block_count >=2 -> exit 0, fire direct Telegram alert (safety net).

State per transcript_path lives in $LOG_DIR/silent-state/<hash>.json.

Args:
  argv[1]: BODY (JSON payload from Claude hook stdin, with chatId injected)
  argv[2]: CHAT_ID (where to send alert when retry budget exhausted)

Exit: 0 (normal / alert-fired) or 2 (block Stop, force continuation).
"""
import hashlib
import json
import os
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

TAIL_BYTES = 256 * 1024
REPLY_TOOL = "mcp__dashi-channel__reply"
TOKEN_FILE = Path(os.environ.get("SECRETS_DIR", "/nonexistent")) / "channel.conf"
STATE_DIR = Path(os.environ.get("LOG_DIR") or f"/tmp/tg-agent-{os.getuid()}") / "silent-state"
MAX_BLOCKS = 2


def log(msg: str) -> None:
    print(msg, flush=True)


def read_tail(path: str) -> list[str]:
    """Return list of complete lines from the tail of file."""
    try:
        with open(path, "rb") as f:
            f.seek(0, 2)
            size = f.tell()
            f.seek(max(0, size - TAIL_BYTES))
            data = f.read().decode("utf-8", errors="ignore")
    except OSError:
        return []
    lines = data.split("\n")
    if size > TAIL_BYTES:
        lines = lines[1:]
    return [ln for ln in lines if ln.strip()]


def check_silent_reply(transcript_path: str) -> tuple[bool, str]:
    """Returns (is_silent, last_user_prompt_excerpt)."""
    lines = read_tail(transcript_path)
    last_user_text = ""

    has_reply = False
    for line in reversed(lines):
        try:
            obj = json.loads(line)
        except (ValueError, TypeError):
            continue
        if not isinstance(obj, dict):
            continue
        msg = obj.get("message")
        if not isinstance(msg, dict):
            continue
        role = msg.get("role")
        content = msg.get("content")

        if role == "user":
            if (
                isinstance(content, list)
                and content
                and all(
                    isinstance(c, dict) and c.get("type") == "tool_result"
                    for c in content
                )
            ):
                continue
            last_user_text = _extract_user_text(content)
            break

        if role != "assistant":
            continue
        if not isinstance(content, list):
            continue
        for c in content:
            if not isinstance(c, dict):
                continue
            if c.get("type") == "tool_use" and c.get("name") == REPLY_TOOL:
                has_reply = True
                break
        if has_reply:
            break

    return (not has_reply, last_user_text)


def _extract_user_text(content) -> str:
    """Pull human-readable text from a user message content array."""
    if isinstance(content, str):
        return _strip_channel_wrapper(content)[:150]
    if isinstance(content, list):
        for c in content:
            if isinstance(c, dict) and c.get("type") == "text":
                t = (c.get("text") or "").strip()
                if t:
                    return _strip_channel_wrapper(t)[:150]
    return ""


def _strip_channel_wrapper(text: str) -> str:
    text = re.sub(r"<channel[^>]*>", "", text)
    text = re.sub(r"</channel>", "", text)
    return text.strip()


def read_bot_token() -> str:
    try:
        with open(TOKEN_FILE) as f:
            for line in f:
                if line.startswith("TELEGRAM_BOT_TOKEN="):
                    return line.split("=", 1)[1].strip().strip("\"'")
    except OSError:
        pass
    return ""


def fire_alert(chat_id: str, last_user: str) -> bool:
    token = read_bot_token()
    if not token:
        log("ALERT skip no-token")
        return False
    excerpt = last_user if last_user else "(no inbound prompt found)"
    text = (
        f"The agent finished a turn without replying to «{excerpt}» "
        f"(retry budget exhausted). Send the message again or ask a direct question."
    )
    url = f"https://api.telegram.org/bot{token}/sendMessage"
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode("utf-8")
    req = urllib.request.Request(url, data=data, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=5) as resp:
            code = resp.getcode()
        log(f"ALERT silent_reply fired http={code} last_user='{excerpt[:50]}'")
        return True
    except Exception as err:  # noqa: BLE001
        log(f"ALERT silent_reply failed: {err}")
        return False


def _state_path(transcript_path: str) -> Path:
    h = hashlib.sha256(transcript_path.encode("utf-8")).hexdigest()[:16]
    return STATE_DIR / f"{h}.json"


def load_state(transcript_path: str) -> dict:
    p = _state_path(transcript_path)
    if not p.exists():
        return {"block_count": 0}
    try:
        return json.loads(p.read_text())
    except (OSError, ValueError):
        return {"block_count": 0}


def save_state(transcript_path: str, state: dict) -> None:
    try:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        _state_path(transcript_path).write_text(json.dumps(state))
    except OSError as err:
        log(f"STATE save failed: {err}")


def main() -> int:
    if len(sys.argv) < 3:
        return 0
    body_raw = sys.argv[1]
    chat_id = sys.argv[2]

    try:
        body = json.loads(body_raw)
    except (ValueError, TypeError):
        return 0
    if not isinstance(body, dict):
        return 0

    transcript = body.get("transcript_path")
    if not isinstance(transcript, str) or not transcript:
        return 0
    if not os.path.isfile(transcript):
        return 0

    is_silent, last_user = check_silent_reply(transcript)
    state = load_state(transcript)
    block_count = int(state.get("block_count", 0) or 0)

    if not is_silent:
        if block_count > 0:
            save_state(transcript, {"block_count": 0})
            log(f"BLOCK reset (reply found after {block_count} block(s))")
        return 0

    if block_count < MAX_BLOCKS:
        new_count = block_count + 1
        save_state(transcript, {"block_count": new_count})
        excerpt = last_user if last_user else "(no inbound prompt found)"
        msg = (
            f"HARD RULE violation: a turn must not end without calling "
            f"mcp__dashi-channel__reply. The user ({chat_id}) will NOT see "
            f"your answer to «{excerpt[:120]}». Call reply now with the real "
            f"answer (format='html'). Attempt {new_count}/{MAX_BLOCKS}."
        )
        print(msg, file=sys.stderr)
        log(f"BLOCK silent_reply attempt={new_count}/{MAX_BLOCKS} last_user='{excerpt[:50]}'")
        return 2

    save_state(transcript, {"block_count": 0})
    log(f"BLOCK budget exhausted ({block_count}), falling back to alert")
    fire_alert(str(chat_id), last_user)
    return 0


if __name__ == "__main__":
    sys.exit(main())
