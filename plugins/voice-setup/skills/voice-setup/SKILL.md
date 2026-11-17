---
name: voice-setup
description: Set up, update, repair or uninstall two-way voice for Claude Code on an Apple Silicon Mac — talk to Claude and hear it reply, fully local (no cloud, no API keys). Installs VoiceMode MCP with mlx-audio speech, a different voice per session, sessions saying their name, a floating "who's speaking" overlay, voice-only volume hotkeys, and a voice Do Not Disturb with quiet hours. Use when the user asks to install/set up/repair/uninstall voice mode, or says "/voice-setup". Also use after the plugin was updated ("update my voice setup").
---

# Voice setup for Claude Code

Gives every Claude Code session on this Mac a voice. One install; works in all sessions.

| Piece | What it does |
|---|---|
| VoiceMode MCP (`voice-mode` 9.0.2, user scope) | `converse` tool: Claude speaks, then listens for the reply |
| mlx-audio service (127.0.0.1:8890) | Local speech-to-text (Whisper large-v3-turbo) + text-to-speech (Kokoro). Apple Silicon only |
| `scripts/voice-mode-session` | MCP launcher: each session claims a different voice |
| `scripts/session-name` | Session announces its name ("Billing here. …") |
| Hammerspoon overlay (optional) | Bottom-right pill: which session is speaking / listening / waiting, plus every busy Claude Code session |
| Hammerspoon volume (optional) | ⌃⌥↑ / ⌃⌥↓ change Claude's voice volume only; saved |
| Away mode + inbox (`away`, `presence`, `inbox`, Hammerspoon) | Away after 60 min with no keyboard/mouse/voice, or ⌃⌥A / "brb". Sessions queue messages instead of speaking; a "welcome back" summary is read when you return |
| Dictation pause (Hammerspoon `voice_mic.lua`) | When another app uses the mic (Claude Code /voice dictation, Zoom, Teams), a speaking session is muted and new voice turns wait until you stop |
| Voice DND (`scripts/dnd` + Hammerspoon) | Sessions stay silent (text only) while on; hard-mutes the Mac if one speaks anyway; silences macOS alert sounds (terminal bell) and restores them after. ⌃⌥D toggle + daily quiet hours. Separate from macOS Do Not Disturb |

Files referenced below live next to this SKILL.md (`$SKILL_DIR` = the folder containing it — the skill's base directory, inside the plugin cache when installed as a plugin).

**Already installed?** If `~/.voicemode/bin/voice-mode-session` exists, this is an update: skip to **Update** at the bottom.

User settings live in config files that updates never overwrite:
- `~/.voicemode/voicemode.env` — `VOICEMODE_VOICES=<main voice>`, language
- `~/.voicemode/quiet-hours` — one line `HH:MM HH:MM` (DND start end, 24h) or `off`

## Rules while installing

- Ask the user before each step that installs an app or edits `~/.claude/CLAUDE.md`. Don't use any installer's `-y` / auto-accept-all flag.
- Keep every service on `127.0.0.1`. **Do not** install VoiceMode's `kokoro` or `whisper` services: kokoro-fastapi fails to build on recent Macs (old `tokenizers` needs Rust) and both bind `0.0.0.0` (exposed on the LAN). mlx-audio replaces both.
- If a step fails, stop and tell the user what failed, with the error. Don't improvise around it.

## Step 0 — Ask the user (one AskUserQuestion call)

1. **Language they will speak**: English only (most accurate, recommended) / auto-detect (mixed languages). English → `VOICEMODE_WHISPER_LANGUAGE=en`; auto → leave it unset.
2. **Main voice** (first session gets it; others rotate): `af_heart` (American female, best quality), `bf_emma` (British female), `bm_george` (British male), `am_michael` (American male).
3. **Extras**: overlay + volume hotkeys + DND quiet hours (needs Hammerspoon, free) / none (DND then works only via the `dnd` command).
4. **Quiet hours** (only if extras): when Claude must never speak, e.g. 23:30 → 08:00 (default) / 00:30 → 09:00 / no schedule (⌃⌥D only). This is independent of macOS Do Not Disturb/Focus — many people keep those on all day.

## Step 1 — Check prerequisites

```bash
uname -m                     # must be arm64 (Apple Silicon). Intel Mac → stop: mlx-audio won't run.
sw_vers -productVersion
which brew uv || true
df -h ~ | tail -1            # need ~5 GB free (models download on first use)
```
- No Homebrew → ask the user to install it from https://brew.sh (needs their password), then continue.
- No uv → `curl -LsSf https://astral.sh/uv/install.sh | sh` (ask first), then use `~/.local/bin/uv`.

## Step 2 — Install VoiceMode + the speech service

```bash
brew install ffmpeg portaudio
uv tool install voice-mode==9.0.2
voicemode service install mlx-audio
voicemode service enable mlx-audio      # auto-start at login
voicemode service start mlx-audio
```
If `voicemode` isn't on PATH, use `~/.local/bin/voicemode`.

## Step 3 — Configure (local only)

`~/.voicemode/voicemode.env` is created by VoiceMode (mostly comments). Back it up, then append — don't rewrite it:

```bash
cp ~/.voicemode/voicemode.env ~/.voicemode/voicemode.env.bak 2>/dev/null || true
printf '\n# voice-setup skill: local mlx-audio only, no cloud fallback\nVOICEMODE_TTS_BASE_URLS=http://127.0.0.1:8890/v1\nVOICEMODE_STT_BASE_URLS=http://127.0.0.1:8890/v1\nVOICEMODE_PREFER_LOCAL=true\nVOICEMODE_VOICES=<MAIN_VOICE>\n' >> ~/.voicemode/voicemode.env
```
If they chose English only, also append `VOICEMODE_WHISPER_LANGUAGE=en`. Check there is now exactly one active (uncommented) line per key: `grep -vE '^\s*(#|$)' ~/.voicemode/voicemode.env`. If an earlier active line duplicates a key, comment out the old one.

## Step 4 — Per-session voice launcher + helpers

```bash
mkdir -p ~/.voicemode/bin
cp "$SKILL_DIR"/scripts/{voice-mode-session,voice-sessions,session-name,voice-identity,dnd,claude-activity,dnd-guard,away,presence,inbox,inbox-speak,inbox-catchup,voicemode-launch.py} ~/.voicemode/bin/
chmod +x ~/.voicemode/bin/*
```
The launcher reads the main voice from `VOICEMODE_VOICES` (Step 3) and gives it to the first session; others rotate through English Kokoro voices. No editing needed.

Start the DND guard (holds VoiceMode's mic lock while DND is on, so no session can speak, chime or listen — even sessions that started before the CLAUDE.md rule):
```bash
mkdir -p ~/.voicemode/logs/dnd-guard
cat > ~/Library/LaunchAgents/com.voicemode.dnd-guard.plist <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>com.voicemode.dnd-guard</string>
  <key>ProgramArguments</key><array><string>$HOME/.voicemode/bin/dnd-guard</string></array>
  <key>RunAtLoad</key><true/><key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME/.voicemode/logs/dnd-guard/dnd-guard.log</string>
  <key>StandardErrorPath</key><string>$HOME/.voicemode/logs/dnd-guard/dnd-guard.log</string>
</dict></plist>
EOF
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.voicemode.dnd-guard.plist
launchctl list | grep dnd-guard          # expect a pid and 0
```

Register the MCP server for **all** projects (user scope):
```bash
claude mcp remove --scope user voicemode 2>/dev/null || true
claude mcp add --scope user voicemode -- "$HOME/.voicemode/bin/voice-mode-session"
claude mcp get voicemode     # expect: Scope: User config, Status: ✔ Connected
```

## Step 5 — Global voice etiquette (ask first, then append to `~/.claude/CLAUDE.md`)

Append `$SKILL_DIR/claude-md-snippet.md` to the end of `~/.claude/CLAUDE.md` (create it if missing). Don't replace existing content. If they chose auto-detect language, delete the words "English only," from the pasted text.

## Step 6 — Test the speech service

The first request downloads the models (~1–3 min). Then:
```bash
T=$(mktemp -d)
curl -s -m 300 http://127.0.0.1:8890/v1/audio/speech -H 'Content-Type: application/json' \
  -d '{"model":"mlx-community/Kokoro-82M-bf16","input":"Voice mode is ready.","voice":"<MAIN_VOICE>","response_format":"wav"}' -o "$T/t.wav"
afplay "$T/t.wav"            # user should hear it
curl -s -m 300 http://127.0.0.1:8890/v1/audio/transcriptions -F file=@"$T/t.wav" \
  -F model=mlx-community/whisper-large-v3-turbo-asr-4bit
rm -rf "$T"
```
Pass: they heard the sentence and the transcript text matches.

## Step 7 (optional) — Overlay + volume hotkeys

```bash
brew install --cask hammerspoon
mkdir -p ~/.hammerspoon
cp "$SKILL_DIR"/hammerspoon/{voice_overlay.lua,voice_volume.lua,voice_presence.lua,voice_mic.lua} ~/.hammerspoon/
```
If `~/.hammerspoon/init.lua` already exists, **append** the snippet below instead of overwriting it (and skip `hs.menuIcon(false)` if they use the menu icon). Otherwise create it with:
```lua
hs.autoLaunch(true)
hs.menuIcon(false)
require("hs.ipc")

voiceVolume = require("voice_volume")
voiceVolume.start()

voicePresence = require("voice_presence")
voicePresence.onSpeakStart = voiceVolume.speakStart
voicePresence.onSpeakEnd = voiceVolume.speakEnd

voiceOverlay = require("voice_overlay")
voiceOverlay.presence = voicePresence
voiceOverlay.onSpeakStart = voiceVolume.speakStart
voiceOverlay.onSpeakEnd = voiceVolume.speakEnd
voiceOverlay.start()

voicePresence.onChange = voiceOverlay.refresh
voicePresence.start()

voiceMic = require("voice_mic")
voiceMic.overlay = voiceOverlay
voiceOverlay.mic = voiceMic
voiceMic.onChange = voiceOverlay.refresh
voiceMic.start()
```
The auto-away limit is `M.IDLE_LIMIT = 60 * 60` in `voice_presence.lua` (seconds).
Write the quiet hours from Step 0 (24h local time; crossing midnight is fine):
```bash
printf '23:30 08:00\n' > ~/.voicemode/quiet-hours     # or: printf 'off\n' > ~/.voicemode/quiet-hours
```
Hammerspoon re-reads this file every minute, so later changes need no reload.

Launch: `open /Applications/Hammerspoon.app` (by path — Spotlight may not have indexed it yet). Verify:
```bash
hs -c 'return voiceOverlay.state()'    # e.g. "holder=nil/nil | visible=nil"
hs -c 'return voiceVolume.state()'
```
If `hs` hangs, Hammerspoon isn't running yet. Wait a few seconds and retry; use `timeout 8 hs ...`.

## Step 8 — Hand over

Tell the user, in plain words:
- **Open a new Claude Code session** (running sessions don't see the new tool), then type `/voicemode:converse` or just say "let's talk by voice".
- macOS will ask for **microphone access** for their terminal app the first time: allow it.
- It takes turns: Claude speaks, then listens. Stop talking for ~3 s and it sends what you said.
- First reply after a reboot is slow (~30–60 s, models loading).
- Each session gets a different voice and says its name first. Name a session with `/rename`.
- `~/.voicemode/bin/voice-sessions` lists which session has which voice.
- With the extras: the pill in the bottom-right shows who's talking; ⌃⌥↑ / ⌃⌥↓ change Claude's voice volume only.
- Away: ⌃⌥A, or tell a session "brb". Also automatic after an hour with no keyboard, mouse or voice reply. Sessions queue their messages; when you touch the keyboard again you get a short "Welcome back" and then each session that queued something delivers it itself, in its own voice, so you can answer it directly. `~/.voicemode/bin/inbox list` shows what's waiting.
- Do Not Disturb: ⌃⌥D toggles it (🌙/🔔 shown on screen); it also turns on/off at the quiet hours by itself. Terminal: `~/.voicemode/bin/dnd on|off|status`. While on, sessions answer in text and save questions for later.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `converse` says no TTS/STT available | `voicemode service status`; `voicemode service start mlx-audio`; `curl -s 127.0.0.1:8890/v1/models` |
| Every session has the same voice | Sessions started before setup — restart them. Check `claude mcp get voicemode` points at `voice-mode-session` |
| Transcripts come out in the wrong language | Set `VOICEMODE_WHISPER_LANGUAGE=en` in `~/.voicemode/voicemode.env`, new session |
| Overlay shows "Claude" with no voice | That session started before the launcher was installed — restart it |
| Volume stuck at the voice level, or Mac stuck muted | `hs -c 'hs.reload()'` (restores volume); unmute with the keyboard |
| A session still speaks or chimes during DND | `launchctl list \| grep dnd-guard` (should show a pid); log: `~/.voicemode/logs/dnd-guard/dnd-guard.log` |
| Claude silent though DND should be off | `~/.voicemode/bin/dnd status` → `~/.voicemode/bin/dnd off`; check `~/.voicemode/quiet-hours` |

## Update (plugin was updated, or the user asks to update)

Re-copy the program files; never touch the config files listed at the top.
```bash
cp "$SKILL_DIR"/scripts/{voice-mode-session,voice-sessions,session-name,voice-identity,dnd,claude-activity,dnd-guard,away,presence,inbox,inbox-speak,inbox-catchup,voicemode-launch.py} ~/.voicemode/bin/
chmod +x ~/.voicemode/bin/*
[ -f ~/.hammerspoon/voice_overlay.lua ] && cp "$SKILL_DIR"/hammerspoon/{voice_overlay.lua,voice_volume.lua,voice_presence.lua,voice_mic.lua} ~/.hammerspoon/ \
  && (timeout 8 hs -c 'hs.reload()' >/dev/null 2>&1; true)
```
- Older installs had quiet hours inside `voice_volume.lua`. If `~/.voicemode/quiet-hours` doesn't exist, ask the user for their hours and create it (the new Lua defaults to 00:30–09:00 without it).
- If `~/.hammerspoon/init.lua` doesn't mention `voice_mic`, add the voiceMic block from Step 7.
- If `~/.hammerspoon/init.lua` doesn't mention `voice_presence`, update its voice block to match Step 7 (older installs predate away mode).
- Compare `$SKILL_DIR/claude-md-snippet.md` with the "Voice mode" section in `~/.claude/CLAUDE.md`; if the snippet has new rules, show the user the difference and update the section with their OK.
- If `~/Library/LaunchAgents/com.voicemode.dnd-guard.plist` is missing, create it and bootstrap it as in Step 4. Otherwise restart the guard so it runs the new script: `launchctl kickstart -k gui/$(id -u)/com.voicemode.dnd-guard`.
- Tell the user to restart Claude Code sessions that use voice (the launcher only runs at session start).

## Uninstall

```bash
claude mcp remove --scope user voicemode
launchctl bootout gui/$(id -u)/com.voicemode.dnd-guard 2>/dev/null; rm -f ~/Library/LaunchAgents/com.voicemode.dnd-guard.plist
voicemode service disable mlx-audio; voicemode service stop mlx-audio
uv tool uninstall voice-mode; uv tool uninstall mlx-audio 2>/dev/null
rm -rf ~/.voicemode
claude plugin uninstall voice-setup@claude-voice-kit 2>/dev/null
rm -f ~/.hammerspoon/voice_overlay.lua ~/.hammerspoon/voice_volume.lua ~/.hammerspoon/voice_presence.lua ~/.hammerspoon/voice_mic.lua   # then remove the voice lines from ~/.hammerspoon/init.lua
```
Remove the "Voice mode" section from `~/.claude/CLAUDE.md`. Models stay in `~/.cache/huggingface` (delete the `mlx-community--Kokoro*` / `*whisper*` folders to free space).
