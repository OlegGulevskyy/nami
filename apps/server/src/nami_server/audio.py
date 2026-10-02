"""Decode uploads to the format every engine takes: mono float32 PCM at 16 kHz, in [-1, 1]."""

import shutil
import struct
import subprocess

import numpy as np

SAMPLE_RATE = 16_000
_PCM, _FLOAT, _EXTENSIBLE = 1, 3, 0xFFFE


class AudioError(ValueError):
    pass


def decode(data: bytes) -> np.ndarray:
    if not data:
        raise AudioError("The audio file is empty.")
    # The app records 16 kHz mono, so its WAV uploads skip ffmpeg entirely.
    if data[:4] == b"RIFF" and data[8:12] == b"WAVE":
        samples, rate = _read_wav(data)
        if rate == SAMPLE_RATE:
            return samples
    return _ffmpeg(data)


def _read_wav(data: bytes) -> tuple[np.ndarray, int]:
    fmt, payload, offset = None, None, 12
    while offset + 8 <= len(data):
        chunk, size = data[offset:offset + 4], struct.unpack_from("<I", data, offset + 4)[0]
        body = data[offset + 8:offset + 8 + size]
        if chunk == b"fmt ":
            fmt = body
        elif chunk == b"data":
            payload = body
        offset += 8 + size + (size & 1)
    if fmt is None or payload is None or len(fmt) < 16:
        raise AudioError("The WAV file has no audio format or data.")
    tag, channels, rate, _, _, bits = struct.unpack_from("<HHIIHH", fmt)
    if tag == _EXTENSIBLE and len(fmt) >= 26:
        tag = struct.unpack_from("<H", fmt, 24)[0]
    dtypes = {(_PCM, 16): ("<i2", 32768.0), (_PCM, 32): ("<i4", 2147483648.0), (_FLOAT, 32): ("<f4", 1.0)}
    if (tag, bits) not in dtypes or channels < 1:
        raise AudioError("WAV audio must be 16- or 32-bit PCM, or 32-bit float.")
    dtype, scale = dtypes[tag, bits]
    frame = channels * bits // 8
    samples = np.frombuffer(payload[:len(payload) - len(payload) % frame], dtype=dtype)
    samples = samples.astype(np.float32) / scale
    if channels > 1:
        samples = samples.reshape(-1, channels).mean(axis=1)
    if not np.isfinite(samples).all():
        raise AudioError("The audio contains non-finite samples.")
    return np.clip(samples, -1, 1), rate


def _ffmpeg(data: bytes) -> np.ndarray:
    if shutil.which("ffmpeg") is None:
        raise AudioError("Send 16 kHz WAV audio, or install ffmpeg on the server to accept other formats.")
    result = subprocess.run(
        ["ffmpeg", "-nostdin", "-loglevel", "error", "-i", "pipe:0",
         "-f", "f32le", "-ac", "1", "-ar", str(SAMPLE_RATE), "pipe:1"],
        input=data, capture_output=True,
    )
    if result.returncode:
        raise AudioError("Cannot decode the audio: " + result.stderr.decode(errors="replace").strip())
    return np.frombuffer(result.stdout, dtype="<f4").astype(np.float32)
