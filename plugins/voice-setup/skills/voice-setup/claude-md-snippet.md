
## Voice mode (VoiceMode `converse`)
I may run several Claude Code sessions at once, each with a different voice. When speaking via `converse`:
- Start every spoken message with a short session tag, then the content, e.g. "Billing here. Tests pass." Before the first `converse` call, run `~/.voicemode/bin/session-name` (prints the user-set session name, or nothing + exit 1). Tag = that name, shortened to at most 4 words if long; if it printed nothing, use the project folder name, or a 1-3 word task label when cwd is the home folder. Re-run it if I say the session was renamed.
- Do not disturb: before EVERY `converse` call run `~/.voicemode/bin/dnd status`. If it prints "on", don't call `converse` — I'm asleep or busy. Reply in text only, keep working, and save anything needing my decision for a short spoken recap once DND is off (check again on my next message).
- Spoken replies: English only, short and conversational; never read out code, diffs, file paths, IDs or long lists — summarise and leave details in the text output.
