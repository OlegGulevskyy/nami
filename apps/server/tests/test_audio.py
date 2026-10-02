import io
import struct
import wave

import numpy as np
import pytest

from nami_server import audio


def pcm16_wav(samples: np.ndarray, rate: int = 16_000, channels: int = 1) -> bytes:
    buffer = io.BytesIO()
    with wave.open(buffer, "wb") as file:
        file.setnchannels(channels)
        file.setsampwidth(2)
        file.setframerate(rate)
        file.writeframes((samples * 32767).astype("<i2").tobytes())
    return buffer.getvalue()


def float_wav(samples: np.ndarray, rate: int = 16_000) -> bytes:
    data = samples.astype("<f4").tobytes()
    fmt = struct.pack("<HHIIHH", 3, 1, rate, rate * 4, 4, 32)
    body = b"WAVE" + b"fmt " + struct.pack("<I", len(fmt)) + fmt + b"data" + struct.pack("<I", len(data)) + data
    return b"RIFF" + struct.pack("<I", len(body)) + body


def test_pcm16_wav_is_decoded_without_ffmpeg():
    tone = np.sin(np.linspace(0, 100, 16_000)).astype(np.float32) * 0.5
    decoded = audio.decode(pcm16_wav(tone))
    assert decoded.dtype == np.float32 and len(decoded) == 16_000
    assert np.abs(decoded - tone).max() < 1e-3


def test_float_wav_is_decoded_exactly():
    tone = np.linspace(-1, 1, 1600, dtype=np.float32)
    assert np.array_equal(audio.decode(float_wav(tone)), tone)


def test_stereo_is_mixed_to_mono():
    left_right = np.tile([0.5, -0.5], 800).astype(np.float32)
    assert np.abs(audio.decode(pcm16_wav(left_right, channels=2))).max() < 1e-3


def test_non_finite_samples_are_rejected():
    with pytest.raises(audio.AudioError, match="non-finite"):
        audio.decode(float_wav(np.array([0, np.nan], dtype=np.float32)))


def test_unsupported_input_without_ffmpeg_explains_the_fix(monkeypatch):
    monkeypatch.setattr(audio.shutil, "which", lambda _: None)
    with pytest.raises(audio.AudioError, match="install ffmpeg"):
        audio.decode(b"not audio")
    with pytest.raises(audio.AudioError, match="install ffmpeg"):
        audio.decode(pcm16_wav(np.zeros(800, dtype=np.float32), rate=44_100))


def test_empty_upload_is_rejected():
    with pytest.raises(audio.AudioError, match="empty"):
        audio.decode(b"")
