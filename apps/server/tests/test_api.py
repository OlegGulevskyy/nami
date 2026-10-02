import numpy as np
import pytest
from fastapi.testclient import TestClient
from test_audio import pcm16_wav

from nami_server.app import create_app
from nami_server.config import QWEN4_REVISION, Settings

WAV = pcm16_wav(np.zeros(16_000, dtype=np.float32))


def client(**overrides) -> TestClient:
    return TestClient(create_app(Settings(backend="fake", fake_text="hello world", **overrides)))


def test_transcription_returns_openai_shaped_json():
    with client() as api:
        response = api.post("/v1/audio/transcriptions", files={"file": ("a.wav", WAV, "audio/wav")})
        assert response.status_code == 200, response.text
        assert response.json() == {"text": "hello world"}
        assert response.headers["Server-Timing"].startswith("total;dur=")


def test_transcription_as_text():
    with client() as api:
        response = api.post("/v1/audio/transcriptions", files={"file": ("a.wav", WAV)},
                            data={"response_format": "text"})
        assert response.text == "hello world"


def test_invalid_audio_and_unknown_model_are_client_errors(monkeypatch):
    monkeypatch.setattr("nami_server.audio.shutil.which", lambda _: None)
    with client() as api:
        assert api.post("/v1/audio/transcriptions", files={"file": ("a.mp3", b"junk")}).status_code == 400
        response = api.post("/v1/audio/transcriptions", files={"file": ("a.wav", WAV)}, data={"model": "nope"})
        assert response.status_code == 404


def test_models_report_preloaded_engines():
    with client() as api:
        api.post("/v1/audio/transcriptions", files={"file": ("a.wav", WAV)})  # queued behind preload
        data = api.get("/v1/models").json()["data"]
        assert {(m["id"], m["kind"], m["loaded"]) for m in data} == {
            ("fake-transcription", "transcription", True), ("fake-chat", "chat", True)}


def test_chat_completion():
    with client() as api:
        response = api.post("/v1/chat/completions", json={
            "messages": [{"role": "system", "content": "Clean up."}, {"role": "user", "content": "um hi"}]})
        assert response.status_code == 200, response.text
        body = response.json()
        assert body["object"] == "chat.completion" and body["model"] == "fake-chat"
        assert body["choices"][0]["message"] == {"role": "assistant", "content": "um hi"}
        streamed = api.post("/v1/chat/completions", json={"messages": [{"role": "user", "content": "x"}],
                                                          "stream": True})
        assert streamed.status_code == 400


def test_token_protects_everything_but_health():
    with client(token="secret") as api:
        assert api.get("/health").status_code == 200
        assert api.get("/v1/models").status_code == 401
        assert api.get("/v1/models", headers={"Authorization": "Bearer wrong"}).status_code == 401
        assert api.get("/v1/models", headers={"Authorization": "Bearer secret"}).status_code == 200


def test_environment_configuration():
    settings = Settings.from_environment({"NAMI_SERVER_BACKEND": "fake", "NAMI_SERVER_TOKEN": "t",
                                          "NAMI_SERVER_PRELOAD": "0"})
    assert (settings.backend, settings.token, settings.preload) == ("fake", "t", False)
    assert Settings.from_environment({}).cleanup_revision == QWEN4_REVISION
    custom = Settings.from_environment({"NAMI_SERVER_CLEANUP_MODEL": "/models/mine"})
    assert custom.cleanup_revision is None


def test_unknown_backend_fails_fast():
    with pytest.raises(ValueError, match="Unknown backend"):
        create_app(Settings(backend="cuda"))
