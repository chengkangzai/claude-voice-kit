"""VoiceMode's mouth player process, started with Claude's voice volume applied (see voice_gain.py)."""
import os, sys
sys.path.insert(0, os.path.expanduser("~/.voicemode/lib"))
import voice_gain  # noqa: E402
voice_gain.install(mouth=False)
from voice_mode.mouth.__main__ import main  # noqa: E402
sys.exit(main(sys.argv[1:]))
