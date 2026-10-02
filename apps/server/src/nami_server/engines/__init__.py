"""Model backends. Each engine is used from the runtime's single model thread only."""

from typing import Protocol

import numpy as np

from ..config import Settings


class EngineUnavailable(RuntimeError):
    pass


class TranscriptionEngine(Protocol):
    id: str
    loaded: bool

    def load(self) -> None: ...

    def transcribe(self, samples: np.ndarray, language: str | None) -> str: ...


class ChatEngine(Protocol):
    id: str
    loaded: bool

    def load(self) -> None: ...

    def complete(self, messages: list[dict[str, str]], max_tokens: int, temperature: float) -> str: ...


def build(settings: Settings) -> tuple[list[TranscriptionEngine], list[ChatEngine]]:
    if settings.backend == "fake":
        from .fake import FakeChat, FakeTranscription
        return [FakeTranscription(settings.fake_text)], [FakeChat()]
    if settings.backend == "mlx":
        from .mlx import MLXChat, ParakeetTranscription
        return ([ParakeetTranscription(settings.transcription_model)],
                [MLXChat(settings.cleanup_model, settings.cleanup_revision, settings.cleanup_adapter)])
    raise ValueError(f"Unknown backend {settings.backend!r}. Use mlx or fake.")
