# claude-voice-kit

Talk to [Claude Code](https://claude.com/claude-code) and hear it talk back, fully on your Mac.
No cloud speech services, no API keys.

- **Two-way voice** in every Claude Code session ([VoiceMode](https://github.com/mbailey/voicemode) MCP + local [mlx-audio](https://github.com/Blaizzy/mlx-audio): Whisper large-v3-turbo + Kokoro)
- **A different voice per session**, and each session says its name first ("Billing here. CI passed.")
- **Who's-speaking overlay**: a small pill in the corner shows which session is speaking, listening or waiting, and every Claude Code session that is busy
- **Voice-only volume**: `⌃⌥]` / `⌃⌥[` change Claude's voice without touching your music
- **Away mode**: after an hour with no keyboard, mouse or voice reply (or `⌃⌥A` / "brb"), sessions queue their messages instead of speaking, and when you return each session delivers its own message in its own voice, so you answer it directly
- **Doesn't talk over you**: while you dictate (Claude Code `/voice`) or are on a Zoom/Teams call, a speaking session is muted and new voice turns wait
- **Voice Do Not Disturb**: `⌃⌥D` or daily quiet hours. A guard holds the mic lock so no session can speak, chime or listen; sessions answer in text instead, the Mac is muted if one speaks anyway, and macOS alert sounds (the terminal bell when a session needs you) are silenced

Requires an Apple Silicon Mac (M1 or newer), Claude Code, and about 5 GB free. Overlay, volume and DND use [Hammerspoon](https://www.hammerspoon.org/) (free, optional).

## Install

```bash
claude plugin marketplace add chengkangzai/claude-voice-kit
claude plugin install voice-setup@claude-voice-kit
```

Then, in a Claude Code session:

```
/voice-setup
```

Claude walks you through it, asks before installing apps or editing your `CLAUDE.md`, and plays a test sentence at the end.
Open a new session and type `/voicemode:converse` to start talking.

## Update

```bash
claude plugin marketplace update claude-voice-kit
claude plugin update voice-setup@claude-voice-kit
```

Then tell Claude "update my voice setup". It re-copies the scripts and keeps your settings
(`~/.voicemode/voicemode.env`, `~/.voicemode/quiet-hours`).

## Settings

| What | Where |
|---|---|
| Main voice, language | `~/.voicemode/voicemode.env` (`VOICEMODE_VOICES`, `VOICEMODE_WHISPER_LANGUAGE`) |
| Quiet hours | `~/.voicemode/quiet-hours`, e.g. `23:30 08:00`, or `off` |
| DND now | `⌃⌥D`, or `~/.voicemode/bin/dnd on\|off\|status` |
| Move the overlay | hold `⌃⌥` and drag it (clicks pass through otherwise); `⌃⌥O` cycles screen corners; `⌃⌥H` hides/shows it |
| Away now / what's waiting | `⌃⌥A`, `~/.voicemode/bin/away on\|off`, `~/.voicemode/bin/inbox list` |
| Which session has which voice | `~/.voicemode/bin/voice-sessions` |

## How it works

Every Claude Code session starts its own VoiceMode MCP process through a small launcher that claims a free voice.
Speech goes through one local mlx-audio server on `127.0.0.1:8890`. VoiceMode's mic lock lets one session talk at a time.
Hammerspoon follows VoiceMode's event log (`~/.voicemode/logs/events/`) to draw the overlay, switch volume and enforce DND.

Uninstall steps are at the end of [`SKILL.md`](plugins/voice-setup/skills/voice-setup/SKILL.md).

## License

MIT
