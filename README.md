# Nami

Local-first dictation for macOS, plus an optional server that runs the same models
for devices that should not download them.

| Path | What | Stack | CI |
| --- | --- | --- | --- |
| [`apps/macos`](apps/macos) | The Nami app, CLIs, benchmarks, and release tooling | Swift, Xcode | [`macos.yml`](.github/workflows/macos.yml): test, build, sign, notarize, release |
| [`apps/server`](apps/server) | Inference server for the local network | Python, FastAPI, MLX | [`server.yml`](.github/workflows/server.yml): lint, test, MLX install check |
| [`design`](design) | Brand assets | | |

Each app is self-contained, with its own commands documented in its README. CI runs
only for the apps a pull request touches. Stable `v1.2.3` releases ship the macOS app.

From the repository root, `make` lists shortcuts for the common tasks:

```sh
make app           # build, sign, and open the macOS app
make server        # serve the models on this Mac (needs uv: brew install uv)
NAMI_SERVER_TOKEN=change-me make server-lan    # serve them to your network
make test          # every check CI runs
make server ARGS="--port 9000"                 # extra flags go in ARGS
```
