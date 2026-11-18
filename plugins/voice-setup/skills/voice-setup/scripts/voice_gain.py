"""Claude's voice volume, applied to its own audio only (the Mac volume is never touched).

Hammerspoon writes the per-device gain to ~/.voicemode/voice-gain (atomic rename).
Do Not Disturb (~/.voicemode/dnd) forces the gain to 0 live, without muting the Mac.

install() patches, in this process:
  * sounddevice.OutputStream: write() data and callback output are scaled (incl. the
    last partial buffer of a callback that raises CallbackStop)
  * pydub.playback.play (VoiceMode's fallback when sounddevice fails)
  * voice_mode.mouth's player process spawn, so it starts via voicemode-mouth.py
A background thread polls the files; the realtime callback only reads a float.
Gain changes ramp over one block (no clicks). A soft knee above 0.85 full scale stops
gains above 1 from clipping, and is linear below the knee.
"""
import math
import os
import sys
import threading
import time
import types

import numpy as np

HOME = os.path.expanduser("~")
GAIN_FILE = os.path.join(HOME, ".voicemode", "voice-gain")
DND_FILE = os.path.join(HOME, ".voicemode", "dnd")
MOUTH_SCRIPT = os.path.join(HOME, ".voicemode", "bin", "voicemode-mouth.py")
MAX_GAIN = 3.0
KNEE = 0.85

_gain = 1.0          # last valid gain from the file
_effective = 1.0     # what playback uses (0 during DND)
_started = False


def parse_gain(text, fallback):
    try:
        g = float(text.strip())
    except (ValueError, AttributeError):
        return fallback
    if not math.isfinite(g):
        return fallback
    return max(0.0, min(MAX_GAIN, g))


def refresh():
    """Read the files once; keeps the last valid gain on a missing/garbled file."""
    global _gain, _effective
    try:
        with open(GAIN_FILE) as fh:
            _gain = parse_gain(fh.read(), _gain)
    except OSError:
        pass
    _effective = 0.0 if os.path.exists(DND_FILE) else _gain
    return _effective


def current():
    return _effective


def _poll():
    while True:
        try:
            refresh()
        except Exception:  # noqa: BLE001  never let the poller die
            pass
        time.sleep(0.2)


def start_poller():
    global _started
    if _started:
        return
    _started = True
    refresh()
    threading.Thread(target=_poll, name="voice-gain", daemon=True).start()


def _limit(y):
    """Soft knee: linear up to KNEE, then tanh towards full scale (continuous, slope 1 at KNEE)."""
    a = np.abs(y)
    m = a > KNEE
    if m.any():
        r = 1.0 - KNEE
        y[m] = np.sign(y[m]) * (KNEE + r * np.tanh((a[m] - KNEE) / r))
    return y


def apply(block, g_from, g_to):
    """Return block scaled from g_from to g_to (linear ramp across the block), same dtype/shape."""
    arr = np.asarray(block)
    if g_from == 1.0 and g_to == 1.0:
        return arr
    if arr.dtype == np.int16:
        y = arr.astype(np.float32) / 32768.0
    elif arr.dtype == np.float32:
        y = arr.astype(np.float32, copy=True)
    else:
        y = arr.astype(np.float64, copy=True)
    n = y.shape[0] if y.ndim else 0
    if g_from == g_to or n < 2:
        y *= g_to
    else:
        ramp = np.linspace(g_from, g_to, n, dtype=y.dtype)
        y *= ramp.reshape((n,) + (1,) * (y.ndim - 1))
    if max(g_from, g_to) > 1.0:
        _limit(y)
    if arr.dtype == np.int16:
        return np.clip(y * 32767.0, -32768, 32767).astype(np.int16)
    return y.astype(arr.dtype, copy=False)


def _patch_sounddevice():
    import sounddevice as sd
    if getattr(sd.OutputStream, "_voice_gain", False):
        return
    Base = sd.OutputStream

    class GainOutputStream(Base):
        _voice_gain = True

        def __init__(self, *args, callback=None, **kwargs):
            self._g_prev = current()
            if callback is not None:
                user_cb = callback

                def callback(outdata, frames, t, status):  # noqa: F811
                    try:
                        user_cb(outdata, frames, t, status)
                    except sd.CallbackStop:
                        self._scale_out(outdata)   # the final partial buffer still plays
                        raise
                    self._scale_out(outdata)
            super().__init__(*args, callback=callback, **kwargs)

        def _scale_out(self, outdata):
            g = current()
            if g != 1.0 or self._g_prev != 1.0:
                outdata[:] = apply(outdata, self._g_prev, g)
            self._g_prev = g

        def write(self, data):
            g = current()
            out = apply(data, self._g_prev, g)
            self._g_prev = g
            return super().write(out)

    sd.OutputStream = GainOutputStream


def _patch_pydub():
    try:
        import pydub.playback as pb
    except Exception:  # noqa: BLE001
        return
    if getattr(pb.play, "_voice_gain", False):
        return
    orig = pb.play

    def play(seg):
        g = current()
        if g <= 0.0:
            return None                      # DND / zero volume: stay silent
        if g != 1.0:
            seg = seg.apply_gain(20 * math.log10(g))
        return orig(seg)

    play._voice_gain = True
    pb.play = play


def _patch_mouth():
    """The mouth player runs in its own process: start it through voicemode-mouth.py."""
    try:
        import subprocess
        import voice_mode.mouth as mouth
    except Exception:  # noqa: BLE001
        return
    if not os.path.exists(MOUTH_SCRIPT) or isinstance(getattr(mouth, "subprocess", None), types.SimpleNamespace):
        return
    real = subprocess

    def Popen(args, *a, **kw):
        if (isinstance(args, (list, tuple)) and len(args) >= 3
                and list(args[1:3]) == ["-m", "voice_mode.mouth"]):
            args = [args[0], MOUTH_SCRIPT, *args[3:]]
        return real.Popen(args, *a, **kw)

    shim = types.SimpleNamespace(**{k: getattr(real, k) for k in dir(real) if not k.startswith("__")})
    shim.Popen = Popen
    mouth.subprocess = shim


def install(mouth=True):
    start_poller()
    _patch_sounddevice()
    _patch_pydub()
    if mouth:
        _patch_mouth()


def play_wav(path):
    """Play a 16-bit WAV through the gain-aware stream. Returns True if it played to the end."""
    import wave
    import sounddevice as sd
    install(mouth=False)
    with wave.open(path, "rb") as w:
        if w.getsampwidth() != 2:
            raise ValueError("only 16-bit WAV supported")
        rate, ch = w.getframerate(), w.getnchannels()
        frames = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
    frames = frames.reshape(-1, ch) if ch > 1 else frames
    with sd.OutputStream(samplerate=rate, channels=ch, dtype="int16") as s:
        step = max(1, rate // 20)            # 50 ms blocks: volume changes apply mid-clip
        for i in range(0, len(frames), step):
            s.write(np.ascontiguousarray(frames[i:i + step]))
    return True
