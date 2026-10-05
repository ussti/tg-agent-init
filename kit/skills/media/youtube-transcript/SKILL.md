---
name: youtube-transcript
description: Fetch the transcript / subtitles of a YouTube video as plain text. Use when the user shares a YouTube URL and wants its transcript, summary, or content. Not for an audio file or a voice message — use groq-voice. No API key (uses yt-dlp).
---

# YouTube Transcript

Pulls a video's subtitles (auto-generated or uploaded) and returns clean plain text. No API key —
uses `yt-dlp` locally.

## Setup (one-time)

```bash
pip install yt-dlp     # or: brew install yt-dlp
```

## Usage

```bash
bash scripts/yt-transcript.sh "https://www.youtube.com/watch?v=..."        # default lang en
bash scripts/yt-transcript.sh "https://youtu.be/..." ru                     # a specific language
```

Output is the transcript text on stdout (timestamps and markup stripped, consecutive duplicate lines
collapsed). If the video has no subtitles in the requested language, it says so.
