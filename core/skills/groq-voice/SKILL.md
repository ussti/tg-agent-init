---
name: groq-voice
description: Transcribe an audio file (voice message, recording) to text via Groq Whisper. Use when the user sends audio or asks to transcribe a voice note / audio file. Requires GROQ_API_KEY.
---

# Groq Voice — audio transcription

Transcribes audio to text using Groq's hosted Whisper. Fast and cheap.

## Setup (one-time)

Get a free key at https://console.groq.com/keys and export it:

```bash
export GROQ_API_KEY="your-key"
```

Without the key the skill is inert (it will tell you to set it) — nothing else breaks.

## Usage

```bash
bash scripts/transcribe.sh /path/to/audio.m4a            # default model
bash scripts/transcribe.sh /path/to/audio.mp3 whisper-large-v3
```

Supports the formats Whisper accepts (m4a, mp3, wav, ogg, webm, …). Output is plain text on stdout.
