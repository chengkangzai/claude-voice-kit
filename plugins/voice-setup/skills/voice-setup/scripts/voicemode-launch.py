"""Start VoiceMode with local tweaks applied at runtime (survives `uv tool upgrade`).

- Louder chimes: VoiceMode builds its chimes very quietly (~4-8% of full scale), far below
  speech. Scale them by VOICEMODE_CHIME_GAIN (default 4) without editing site-packages.
- Voice volume without touching the Mac's volume: every sounddevice OutputStream this
  process opens is scaled by the gain in ~/.voicemode/voice-gain (written by Hammerspoon,
  per output device, ⌃⌥] / ⌃⌥[). The system volume and other apps (YouTube, music) are
  left alone. Gain above 1 is soft-limited instead of clipping.
"""
import os, re, sys, time

import numpy as np
import sounddevice as sd
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

# ---- voice gain -------------------------------------------------------------
GAIN_FILE = os.path.expanduser("~/.voicemode/voice-gain")
_cache = {"t": 0.0, "g": 1.0}


def voice_gain() -> float:
    now = time.monotonic()
    if now - _cache["t"] > 0.25:          # re-read at most 4x/s so hotkeys apply mid-sentence
        _cache["t"] = now
        try:
            with open(GAIN_FILE) as fh:
                _cache["g"] = max(0.0, min(4.0, float(fh.read().strip() or 1)))
        except (OSError, ValueError):
            _cache["g"] = 1.0
    return _cache["g"]


def _scale(a, g):
    """Scale a block in place-compatible form; returns a new array of the same dtype."""
    if g == 1.0:
        return a
    arr = np.asarray(a)
    if arr.dtype == np.int16:
        x = arr.astype(np.float32) / 32768.0
    else:
        x = arr.astype(np.float32, copy=False)
    y = x * g
    if g > 1.0:
        y = np.tanh(y)                    # soft limiter: loud, never harsh clipping
    if arr.dtype == np.int16:
        return np.clip(y * 32767.0, -32768, 32767).astype(np.int16)
    return y.astype(arr.dtype, copy=False)


_BaseOut = sd.OutputStream


class GainOutputStream(_BaseOut):
    def __init__(self, *args, callback=None, **kwargs):
        if callback is not None:
            user_cb = callback

            def callback(outdata, frames, t, status):  # noqa: F811
                user_cb(outdata, frames, t, status)
                g = voice_gain()
                if g != 1.0:
                    outdata[:] = _scale(outdata, g)
        super().__init__(*args, callback=callback, **kwargs)

    def write(self, data):
        return super().write(_scale(data, voice_gain()))


sd.OutputStream = GainOutputStream

from voice_mode.cli import voice_mode  # noqa: E402

if __name__ == "__main__":
    sys.argv[0] = re.sub(r"(-script\.pyw|\.exe)?$", "", sys.argv[0])
    sys.exit(voice_mode())
