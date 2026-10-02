"""Apple Silicon engines on MLX (Metal). Install with `uv sync --extra mlx`."""

from pathlib import Path

import numpy as np

from ..audio import SAMPLE_RATE
from . import EngineUnavailable


def _model_id(source: str) -> str:
    return Path(source.rstrip("/")).name.lower()


class ParakeetTranscription:
    """NVIDIA Parakeet TDT v3: 25 European languages, detected automatically."""

    # Whole-clip decoding is fastest; long recordings are split like `parakeet-mlx --chunk-duration`.
    chunk_seconds = 120.0
    overlap_seconds = 15.0

    def __init__(self, source: str):
        self.source = source
        self.id = _model_id(source)
        self.loaded = False
        self._model = None

    def load(self) -> None:
        if self.loaded:
            return
        try:
            from parakeet_mlx import from_pretrained
        except ImportError as error:
            raise EngineUnavailable("Install the MLX backend: uv sync --extra mlx") from error
        try:
            self._model = from_pretrained(self.source)
        except Exception as error:
            raise EngineUnavailable(f"Cannot load {self.source}: {error}") from error
        self.loaded = True
        # Compile Metal kernels now, so the first real request is as fast as the rest.
        self.transcribe(np.zeros(SAMPLE_RATE, dtype=np.float32), None)

    def transcribe(self, samples: np.ndarray, language: str | None) -> str:
        import mlx.core as mx
        from parakeet_mlx.alignment import (
            merge_longest_common_subsequence,
            merge_longest_contiguous,
            sentences_to_result,
            tokens_to_sentences,
        )
        from parakeet_mlx.audio import get_logmel

        self.load()
        model = self._model
        audio = mx.array(samples, dtype=mx.bfloat16)
        if len(samples) < model.preprocessor_config.hop_length:
            return ""
        chunk = int(self.chunk_seconds * SAMPLE_RATE)
        if len(samples) <= chunk:
            return model.generate(get_logmel(audio, model.preprocessor_config))[0].text
        overlap = int(self.overlap_seconds * SAMPLE_RATE)
        tokens = []
        for start in range(0, len(samples), chunk - overlap):
            end = min(start + chunk, len(samples))
            if end - start < model.preprocessor_config.hop_length:
                break
            result = model.generate(get_logmel(audio[start:end], model.preprocessor_config))[0]
            for token in result.tokens:
                token.start += start / SAMPLE_RATE
                token.end = token.start + token.duration
            if not tokens:
                tokens = result.tokens
                continue
            try:
                tokens = merge_longest_contiguous(tokens, result.tokens, overlap_duration=self.overlap_seconds)
            except RuntimeError:
                tokens = merge_longest_common_subsequence(
                    tokens, result.tokens, overlap_duration=self.overlap_seconds)
        return sentences_to_result(tokens_to_sentences(tokens)).text


class MLXChat:
    """Any mlx-lm model; defaults to the app's Qwen 3 4B Instruct cleanup model."""

    def __init__(self, source: str, revision: str | None, adapter: str | None):
        self.source, self.revision, self.adapter = source, revision, adapter
        self.id = _model_id(source)
        self.loaded = False
        self._model = self._tokenizer = None

    def load(self) -> None:
        if self.loaded:
            return
        try:
            from mlx_lm import load
        except ImportError as error:
            raise EngineUnavailable("Install the MLX backend: uv sync --extra mlx") from error
        try:
            self._model, self._tokenizer = load(self.source, revision=self.revision, adapter_path=self.adapter)
        except Exception as error:
            raise EngineUnavailable(f"Cannot load {self.source}: {error}") from error
        self.loaded = True
        self.complete([{"role": "user", "content": "Hi"}], max_tokens=1, temperature=0)

    def complete(self, messages: list[dict[str, str]], max_tokens: int, temperature: float) -> str:
        from mlx_lm import generate
        from mlx_lm.sample_utils import make_sampler

        self.load()
        prompt = self._tokenizer.apply_chat_template(messages, tokenize=False, add_generation_prompt=True)
        return generate(self._model, self._tokenizer, prompt, max_tokens=max_tokens,
                        sampler=make_sampler(temp=temperature))
