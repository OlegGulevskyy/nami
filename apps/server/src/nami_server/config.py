import os
from dataclasses import dataclass

# Same weights and revision as the macOS app's "Qwen 3 · 4B Instruct" cleanup model.
QWEN4_REPOSITORY = "mlx-community/Qwen3-4B-Instruct-2507-4bit"
QWEN4_REVISION = "50d427756c6b1b2fe0c0a10f67fbda1fc8e82c1b"
# The app's Fast engine runs this model through Core ML (FluidAudio "ultra").
PARAKEET_REPOSITORY = "mlx-community/parakeet-tdt-0.6b-v3"


@dataclass(frozen=True)
class Settings:
    """Read from NAMI_SERVER_* environment variables; command-line flags override them."""

    # mlx: Apple Silicon. fake: canned results for tests and CI, no models.
    backend: str = "mlx"
    # Optional shared secret. Without it, anyone who can reach the port can use the models.
    token: str | None = None
    preload: bool = True
    transcription_model: str = PARAKEET_REPOSITORY
    cleanup_model: str = QWEN4_REPOSITORY
    cleanup_revision: str | None = QWEN4_REVISION
    # LoRA adapters from `mlx_lm.lora`, applied on top of the cleanup model.
    cleanup_adapter: str | None = None
    fake_text: str = "hello world"

    @classmethod
    def from_environment(cls, environ: dict[str, str] = os.environ) -> "Settings":
        def value(name: str) -> str | None:
            return environ.get(f"NAMI_SERVER_{name}") or None

        defaults = cls()
        cleanup_model = value("CLEANUP_MODEL")
        return cls(
            backend=value("BACKEND") or defaults.backend,
            token=value("TOKEN"),
            preload=(value("PRELOAD") or "1").lower() not in ("0", "false", "no"),
            transcription_model=value("TRANSCRIPTION_MODEL") or defaults.transcription_model,
            cleanup_model=cleanup_model or defaults.cleanup_model,
            # A custom model must not inherit the pinned revision of the default one.
            cleanup_revision=value("CLEANUP_REVISION") or (None if cleanup_model else defaults.cleanup_revision),
            cleanup_adapter=value("CLEANUP_ADAPTER"),
            fake_text=value("FAKE_TEXT") or defaults.fake_text,
        )
