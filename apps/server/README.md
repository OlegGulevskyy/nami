# Nami server

Runs Nami's speech and cleanup models on one machine so other devices on the network
can use them without downloading anything. It loads the same weights the macOS app
runs on-device:

| Kind | Model | App equivalent |
| --- | --- | --- |
| Transcription | `mlx-community/parakeet-tdt-0.6b-v3` (NVIDIA Parakeet TDT v3, 25 languages) | Fast engine (FluidAudio Core ML) |
| Cleanup (chat) | `mlx-community/Qwen3-4B-Instruct-2507-4bit`, same pinned revision | Qwen 3 · 4B Instruct |

Python, because training and fine-tuning tools (mlx-lm LoRA, PyTorch, Hugging Face)
are Python-first. Inference runs in native MLX/Metal kernels, so the HTTP layer adds
negligible time. Models stay loaded and warmed up, and all inference runs on one
dedicated thread, so requests queue for the GPU instead of competing for it.

## Run

Requires Apple Silicon and [uv](https://docs.astral.sh/uv/) (`brew install uv`).

```sh
cd apps/server
uv sync --extra mlx
uv run nami-server                         # this Mac only: http://127.0.0.1:8765
NAMI_SERVER_TOKEN=change-me uv run nami-server --host 0.0.0.0   # devices on your network
```

On first start, models download into the Hugging Face cache (`~/.cache/huggingface`),
about 2.5 GB for Parakeet and 2.3 GB for Qwen. Startup does not wait for models to load:
`/health` responds immediately, and early requests wait in the queue until the models are ready.

## API

Request and response shapes follow OpenAI's, so standard clients work. Send
`Authorization: Bearer $NAMI_SERVER_TOKEN` when a token is set; `/health` is always open.

```sh
curl localhost:8765/v1/models
curl localhost:8765/v1/audio/transcriptions -F file=@recording.wav        # {"text": "..."}
curl localhost:8765/v1/chat/completions -H 'Content-Type: application/json' \
  -d '{"messages": [{"role": "user", "content": "um hello there"}], "max_tokens": 256}'
```

- **Transcription** accepts 16 kHz WAV (PCM or float, any channel count) without extra
  tools. Other formats and sample rates need `ffmpeg` on the server. Parakeet detects
  the language itself, so `language` is accepted but ignored.
- **Chat** is not streamed yet. The app builds its cleanup prompt itself, so the server
  needs no prompt changes when the prompt evolves.
- Every response carries a `Server-Timing` header with the total time spent handling it.

## Configuration

| Variable | Default |
| --- | --- |
| `NAMI_SERVER_TOKEN` | unset: no authentication |
| `NAMI_SERVER_BACKEND` | `mlx`; `fake` returns canned results with no models |
| `NAMI_SERVER_PRELOAD` | `1`: load and warm up models at startup |
| `NAMI_SERVER_TRANSCRIPTION_MODEL` | Parakeet v3 (Hugging Face repo or local folder) |
| `NAMI_SERVER_CLEANUP_MODEL` / `_REVISION` | Qwen 3 4B Instruct at the app's revision |
| `NAMI_SERVER_CLEANUP_ADAPTER` | unset: LoRA adapters from `mlx_lm.lora` |

## Training

Cleanup fine-tuning already works with the installed tools: train LoRA adapters with
`uv run --extra mlx mlx_lm.lora --model mlx-community/Qwen3-4B-Instruct-2507-4bit --train --data <dir>`,
then point `NAMI_SERVER_CLEANUP_ADAPTER` at the adapter folder.

## Develop

```sh
uv sync
uv run ruff check .
uv run pytest            # fake engines only: no models, GPU, or network
```

A new backend (for example CUDA on a Linux box) implements `TranscriptionEngine` and
`ChatEngine` in `src/nami_server/engines/` and registers itself in `engines.build`.
