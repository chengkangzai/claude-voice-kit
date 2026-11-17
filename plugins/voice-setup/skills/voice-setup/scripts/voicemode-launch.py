"""Start VoiceMode with local tweaks applied at runtime (survives `uv tool upgrade`).

- Louder chimes: VoiceMode builds its chimes very quietly (~4-8% of full scale), far below
  speech. Scale them by VOICEMODE_CHIME_GAIN (default 4) without editing site-packages.
"""
import os, re, sys

import numpy as np
from voice_mode import core

_orig = core.generate_chime


def _louder_chime(*args, **kwargs):
    chime = _orig(*args, **kwargs)
    try:
        gain = float(os.environ.get("VOICEMODE_CHIME_GAIN", "4"))
    except ValueError:
        gain = 1.0
    if gain == 1.0:
        return chime
    return np.clip(chime.astype(np.float32) * gain, -32000, 32000).astype(np.int16)


core.generate_chime = _louder_chime

from voice_mode.cli import voice_mode  # noqa: E402

if __name__ == "__main__":
    sys.argv[0] = re.sub(r"(-script\.pyw|\.exe)?$", "", sys.argv[0])
    sys.exit(voice_mode())
