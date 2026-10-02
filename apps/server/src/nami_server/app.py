"""HTTP API. Endpoint shapes follow OpenAI's, so standard clients and tools work against it."""

import asyncio
import logging
import secrets
import time
from collections.abc import Callable
from concurrent.futures import ThreadPoolExecutor
from contextlib import asynccontextmanager
from functools import partial
from typing import Annotated, Literal, TypeVar

from fastapi import Depends, FastAPI, File, Form, HTTPException, Request, UploadFile
from fastapi.responses import PlainTextResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel, Field

from . import audio, engines
from .config import Settings

log = logging.getLogger("nami_server")
T = TypeVar("T")


class Runtime:
    """Every model call runs on one thread: MLX state is per-thread and the GPU is one device.
    Requests queue here instead of competing for memory and Metal command buffers."""

    def __init__(self, settings: Settings):
        self.transcription, self.chat = engines.build(settings)
        self._executor = ThreadPoolExecutor(max_workers=1, thread_name_prefix="nami-models")

    async def run(self, function: Callable[..., T], *args, **kwargs) -> T:
        return await asyncio.get_running_loop().run_in_executor(self._executor, partial(function, *args, **kwargs))

    def preload(self) -> None:
        for engine in [*self.transcription, *self.chat]:
            self._executor.submit(self._load, engine)

    @staticmethod
    def _load(engine) -> None:
        started = time.perf_counter()
        log.info("Loading %s…", engine.id)
        try:
            engine.load()
        except Exception:
            # Requests retry the load and report the failure to the client.
            log.exception("Could not load %s", engine.id)
            return
        log.info("Ready: %s (%.1fs)", engine.id, time.perf_counter() - started)

    def shutdown(self) -> None:
        self._executor.shutdown(wait=False, cancel_futures=True)


def _select(available: list, requested: str | None, kind: str):
    if not requested:
        return available[0]
    for engine in available:
        if engine.id == requested:
            return engine
    raise HTTPException(404, f"No {kind} model {requested!r}. See GET /v1/models.")


class Message(BaseModel):
    role: Literal["system", "user", "assistant"]
    content: str


class ChatRequest(BaseModel):
    model: str | None = None
    messages: list[Message] = Field(min_length=1)
    max_tokens: int = Field(512, ge=1, le=8192)
    temperature: float = Field(0.0, ge=0, le=2)
    stream: bool = False


def create_app(settings: Settings | None = None) -> FastAPI:
    settings = settings or Settings.from_environment()
    runtime = Runtime(settings)

    @asynccontextmanager
    async def lifespan(_: FastAPI):
        if settings.preload:
            runtime.preload()
        yield
        runtime.shutdown()

    bearer = HTTPBearer(auto_error=False)

    def authorize(credentials: Annotated[HTTPAuthorizationCredentials | None, Depends(bearer)]) -> None:
        if settings.token is None:
            return
        if credentials is None or not secrets.compare_digest(credentials.credentials, settings.token):
            raise HTTPException(401, "Missing or invalid bearer token.", headers={"WWW-Authenticate": "Bearer"})

    app = FastAPI(title="Nami server", lifespan=lifespan)
    app.state.runtime = runtime
    protected = [Depends(authorize)]

    async def run_engine(function: Callable[..., T], *args) -> T:
        try:
            return await runtime.run(function, *args)
        except engines.EngineUnavailable as error:
            raise HTTPException(503, str(error)) from error

    @app.middleware("http")
    async def timing(request: Request, call_next):
        started = time.perf_counter()
        response = await call_next(request)
        response.headers["Server-Timing"] = f"total;dur={(time.perf_counter() - started) * 1000:.1f}"
        return response

    @app.get("/health")
    async def health():
        return {"status": "ok"}

    @app.get("/v1/models", dependencies=protected)
    async def models():
        return {"object": "list", "data": [
            {"id": engine.id, "object": "model", "kind": kind, "loaded": engine.loaded}
            for kind, available in (("transcription", runtime.transcription), ("chat", runtime.chat))
            for engine in available
        ]}

    @app.post("/v1/audio/transcriptions", dependencies=protected)
    async def transcriptions(
        file: Annotated[UploadFile, File()],
        model: Annotated[str | None, Form()] = None,
        language: Annotated[str | None, Form()] = None,
        response_format: Annotated[Literal["json", "text"], Form()] = "json",
    ):
        engine = _select(runtime.transcription, model, "transcription")
        try:
            samples = audio.decode(await file.read())
        except audio.AudioError as error:
            raise HTTPException(400, str(error)) from error
        text = await run_engine(engine.transcribe, samples, language)
        return PlainTextResponse(text) if response_format == "text" else {"text": text}

    @app.post("/v1/chat/completions", dependencies=protected)
    async def chat_completions(request: ChatRequest):
        if request.stream:
            raise HTTPException(400, "Streaming is not supported yet.")
        engine = _select(runtime.chat, request.model, "chat")
        messages = [message.model_dump() for message in request.messages]
        text = await run_engine(engine.complete, messages, request.max_tokens, request.temperature)
        return {
            "id": "chatcmpl-" + secrets.token_hex(12),
            "object": "chat.completion",
            "created": int(time.time()),
            "model": engine.id,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}],
        }

    return app
