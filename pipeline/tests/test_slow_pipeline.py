"""End-to-end run with the real models and real Claude on a synthetic meeting (macOS voices).

Slow (downloads ~2 GB of models on the first run), needs the Hugging Face token with access to the
pyannote model and a logged-in `claude`. The note goes to a temporary vault, never the real one.
Run explicitly: `uv run pytest -m slow -s`.
"""

import json
import subprocess
from pathlib import Path

import numpy as np
import pytest
from conftest import make_recording, silence

from meeting_pipeline import cli
from meeting_pipeline.audio import load_audio
from meeting_pipeline.cli import EXIT_OK, main
from meeting_pipeline.config import Config
from meeting_pipeline.keychain import hf_token

pytestmark = pytest.mark.slow

CZECH = "Dobrý den, dnes probereme plán sprintu a nasazení nové verze aplikace do produkce."
SLOVAK = "Dobrý deň, ďakujem za pozvanie. Máme otázku k termínu dodania a k cene licencie."
USER = "Já připravím odhad do pátku a pošlu ho e-mailem."


def say(text: str, voice: str, folder: Path, name: str) -> np.ndarray:
    path = folder / f"{name}.aiff"
    subprocess.run(["/usr/bin/say", "-v", voice, "-o", str(path), text], check=True)
    return load_audio(path)


def test_synthetic_meeting(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    if not hf_token():
        pytest.skip("Hugging Face token not in the Keychain")
    voices = tmp_path / "voices"
    voices.mkdir()
    czech = say(CZECH, "Zuzana", voices, "cs")
    slovak = say(SLOVAK, "Laura", voices, "sk")
    user = say(USER, "Zuzana", voices, "user")

    # Meeting audio: Czech speaker, pause, Slovak speaker. Microphone: the user in between.
    app = np.concatenate([czech, silence(len(user) / 16_000 + 2), slovak, silence(1)])
    mic = np.concatenate(
        [silence(len(czech) / 16_000 + 1), user, silence(len(slovak) / 16_000 + 2)]
    )
    recording = tmp_path / "recording"
    recording.mkdir()
    make_recording(recording, app, mic)

    vault = tmp_path / "vault"
    vault.mkdir()
    monkeypatch.setattr(cli, "load_config", lambda: Config(obsidian_vault_path=str(vault)))

    assert main([str(recording)]) == EXIT_OK, (recording / "status.json").read_text()
    status = json.loads((recording / "status.json").read_text(encoding="utf-8"))
    assert status["state"] == "done", status
    note = json.loads((recording / "note.json").read_text(encoding="utf-8"))["notePath"]
    print(Path(note).read_text(encoding="utf-8"))

    segments = json.loads((recording / "transcript.json").read_text(encoding="utf-8"))["segments"]
    print((recording / "transcript.txt").read_text(encoding="utf-8"))
    app_languages = {s["language"] for s in segments if s["track"] == "app"}
    assert {"cs", "sk"} <= app_languages
    assert any(s["speaker"] == "USER" and "pátku" in s["text"].lower() for s in segments)
    assert any("sprint" in s["text"].lower() for s in segments)
