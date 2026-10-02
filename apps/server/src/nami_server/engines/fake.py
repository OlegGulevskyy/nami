"""Deterministic engines for tests and CI. No models, network, or GPU."""

import numpy as np


class FakeTranscription:
    id = "fake-transcription"
    loaded = False

    def __init__(self, text: str):
        self.text = text

    def load(self) -> None:
        self.loaded = True

    def transcribe(self, samples: np.ndarray, language: str | None) -> str:
        return self.text


class FakeChat:
    id = "fake-chat"
    loaded = False

    def load(self) -> None:
        self.loaded = True

    def complete(self, messages: list[dict[str, str]], max_tokens: int, temperature: float) -> str:
        return next((m["content"] for m in reversed(messages) if m["role"] == "user"), "")
