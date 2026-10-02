import argparse
import dataclasses
import logging

import uvicorn

from .app import create_app
from .config import Settings


def main() -> None:
    parser = argparse.ArgumentParser(prog="nami-server", description="Serve Nami's models over HTTP.")
    parser.add_argument("--host", default="127.0.0.1",
                        help="Address to listen on. Use 0.0.0.0 to accept devices on your network.")
    parser.add_argument("--port", type=int, default=8765)
    parser.add_argument("--backend", choices=["mlx", "fake"], help="Default: mlx, or NAMI_SERVER_BACKEND.")
    parser.add_argument("--no-preload", action="store_true", help="Load models on first use instead of at startup.")
    args = parser.parse_args()

    settings = Settings.from_environment()
    if args.backend:
        settings = dataclasses.replace(settings, backend=args.backend)
    if args.no_preload:
        settings = dataclasses.replace(settings, preload=False)
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    if args.host not in ("127.0.0.1", "localhost", "::1") and settings.token is None:
        logging.warning("Listening on %s without NAMI_SERVER_TOKEN: anyone on the network can use it.", args.host)
    # One process: models live in memory, and a second worker would load another copy.
    uvicorn.run(create_app(settings), host=args.host, port=args.port, workers=1)


if __name__ == "__main__":
    main()
