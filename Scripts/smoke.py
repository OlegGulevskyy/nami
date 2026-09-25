#!/usr/bin/env python3
"""Exercise the built CLI with generated silence and the fake engine. No microphone/network."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import wave

binary = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/nami-bench").resolve()


def run(*args, succeeds=True):
    result = subprocess.run([str(binary), *args], capture_output=True, text=True, cwd=root)
    assert (result.returncode == 0) == succeeds, result.stdout + result.stderr
    return result


with tempfile.TemporaryDirectory(prefix="nami-smoke-") as temporary:
    root = Path(temporary)
    audio = root / "silence.wav"
    with wave.open(str(audio), "wb") as wav:
        wav.setnchannels(1)
        wav.setsampwidth(2)
        wav.setframerate(16000)
        wav.writeframes(b"\x00\x00" * 16000 * 6)
    run("help")
    result = run("transcribe", "--engine", "fake", "--fake-text", "hello world", "--audio", str(audio))
    assert "hello world" in result.stdout
    assert "Audio file:" in result.stdout and "96000 samples at 16000 Hz" in result.stdout
    rows = [dict(id=f"fake-{i}", audio="silence.wav", reference="hello world", language="en",
                 category="synthetic", condition="silence", referenceVerified=True) for i in range(20)]
    manifest = root / "manifest.json"
    manifest.write_text(json.dumps(rows))
    output = root / "report.json"
    args = ["benchmark", "--engine", "fake", "--fake-text", "hello world", "--manifest", str(manifest),
            "--output", str(output), "--repetitions", "2"]
    run(*args)
    report = json.loads(output.read_text())
    assert report["engine"] == "fake"
    assert report["overall"]["runCount"] == 40
    assert report["overall"]["normalizedExactMatchFraction"] == 1
    assert report["byLanguage"]["en"]["runCount"] == 40
    assert report["warmupRunsExcluded"] == 1
    assert all(row["audioSeconds"] == 6 for row in report["runs"])
    original = output.read_bytes()
    run(*args, succeeds=False)
    assert output.read_bytes() == original, "Existing report was overwritten"
    output.unlink()
    rows[0]["referenceVerified"] = False
    manifest.write_text(json.dumps(rows))
    run(*args, succeeds=False)
    assert not output.exists(), "Invalid corpus produced a success report"
    run("record", "--engine", "fake", "--seconds", "nan", succeeds=False)
    run("transcribe", "--audio", str(audio), "--model-folder", str(root / "missing"), succeeds=False)

    # Default project config, paths with spaces, and explicit overrides (no model load).
    config = root / "nami.json"
    config.write_text(json.dumps(dict(engine="fake", language="en", modelFolder="models/my model")))
    run("transcribe", "--audio", str(audio), "--fake-text", "configured engine")
    rows[0]["referenceVerified"] = True
    manifest.write_text(json.dumps(rows))
    configured_args = ["benchmark", "--manifest", str(manifest), "--output", str(output), "--repetitions", "1"]
    run(*configured_args)
    report = json.loads(output.read_text())
    assert report["engine"] == "fake"
    assert report["modelFolder"] == str(root / "models/my model")
    output.unlink()
    run(*configured_args, "--model-folder", "~/Nami model override")
    assert json.loads(output.read_text())["modelFolder"] == str(Path.home() / "Nami model override")
    output.unlink()

    alternate = root / "settings" / "alternate.json"
    alternate.parent.mkdir()
    alternate.write_text(json.dumps(dict(engine="whisperkit", modelFolder="../another model")))
    run(*configured_args, "--config", str(alternate), "--engine", "fake")
    assert json.loads(output.read_text())["modelFolder"] == str(root / "another model")
    config.write_text("{ broken json")
    result = run("transcribe", "--audio", str(audio), succeeds=False)
    assert "Cannot read configuration" in result.stderr
    run("transcribe", "--audio", str(audio), "--config", str(root / "absent.json"), succeeds=False)
print("CLI smoke passed: fake transcription/benchmarks, config defaults/overrides/path resolution, validation, overwrite protection.")
