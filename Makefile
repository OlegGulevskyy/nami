# Run from the repository root. Each target runs in its app's directory.
# Pass extra flags with ARGS, for example: make server ARGS="--port 9000"

MACOS := apps/macos
SERVER := apps/server

.DEFAULT_GOAL := help
.PHONY: help app app-build app-test app-distribute server server-lan server-fake server-test test

help: ## List targets
	@grep -E '^[a-z-]+:.*## ' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*## "} {printf "  make %-15s %s\n", $$1, $$2}'

app: ## Build, sign, and open the macOS app
	cd $(MACOS) && ./Scripts/app.sh $(ARGS)

app-build: ## Build and sign the macOS app without opening it
	cd $(MACOS) && ./Scripts/app.sh --no-open $(ARGS)

app-test: ## Run the macOS checks CI runs
	cd $(MACOS) && python3 -m unittest discover -s Scripts -p 'test_*.py'
	cd $(MACOS) && swift test --no-parallel $(ARGS)
	cd $(MACOS) && python3 Scripts/smoke.py

app-distribute: ## Notarize a shareable ZIP (needs the nami-notary profile)
	cd $(MACOS) && ./Scripts/distribute.sh $(ARGS)

server: ## Serve the models on this Mac only
	cd $(SERVER) && uv run --extra mlx nami-server $(ARGS)

server-lan: ## Serve the models to your network; set NAMI_SERVER_TOKEN
	cd $(SERVER) && uv run --extra mlx nami-server --host 0.0.0.0 $(ARGS)

server-fake: ## Serve canned results without models, for client work
	cd $(SERVER) && uv run nami-server --backend fake $(ARGS)

server-test: ## Lint and test the server
	cd $(SERVER) && uv run ruff check . && uv run pytest $(ARGS)

test: app-test server-test ## Run every check
