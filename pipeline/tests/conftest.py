"""Shared test helpers: synthetic recordings (never real ones) and fake models."""

import json
import subprocess
import wave
from pathlib import Path

import numpy as np
import pytest

from meeting_pipeline.models import RawSegment, Turn

RATE = 16_000


def tone(seconds: float, amplitude: float = 0.3, frequency: float = 440.0) -> np.ndarray:
    t = np.arange(int(seconds * RATE)) / RATE
    return (amplitude * np.sin(2 * np.pi * frequency * t)).astype(np.float32)


def silence(seconds: float) -> np.ndarray:
    return np.zeros(int(seconds * RATE), dtype=np.float32)


def write_m4a(samples: np.ndarray, path: Path) -> None:
    """16 kHz float samples → WAV (stdlib) → AAC .m4a with macOS afconvert."""
    wav = path.with_suffix(".wav")
    with wave.open(str(wav), "wb") as writer:
        writer.setnchannels(1)
        writer.setsampwidth(2)
        writer.setframerate(RATE)
        writer.writeframes((np.clip(samples, -1, 1) * 32767).astype("<i2").tobytes())
    subprocess.run(
        ["/usr/bin/afconvert", "-f", "m4af", "-d", "aac", str(wav), str(path)], check=True
    )
    wav.unlink()


def make_recording(
    folder: Path, app: np.ndarray, mic: np.ndarray | None = None, ended: bool = True
) -> Path:
    write_m4a(app, folder / "audio.m4a")
    meta: dict = {
        "schemaVersion": 1,
        "source": "teams",
        "startedAt": "2026-10-14T14:00:00+02:00",
        "audio": {"file": "audio.m4a"},
    }
    if ended:
        meta["endedAt"] = "2026-10-14T15:00:00+02:00"
    if mic is not None:
        write_m4a(mic, folder / "mic.m4a")
        meta["microphone"] = {"file": "mic.m4a", "device": "Test mic"}
    (folder / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return folder


class FakeTranscriber:
    """Returns one segment per chunk. Detected languages are taken from `languages` in call order
    (for calls without a fixed language); a fixed language is echoed back."""

    def __init__(self, languages: list[str] | None = None) -> None:
        self.languages = list(languages or [])
        self.calls: list[tuple[float, str | None]] = []

    def __call__(self, samples: np.ndarray, *, initial_prompt: str | None, language: str | None):
        seconds = len(samples) / RATE
        self.calls.append((round(seconds, 1), language))
        detected = language or (self.languages.pop(0) if self.languages else "cs")
        return detected, [RawSegment(start=0.0, end=seconds, text=f"text {len(self.calls)}")]


class FakeDiarizer:
    def __init__(self, turns: list[Turn]) -> None:
        self.turns = turns
        self.calls = 0

    def __call__(self, samples: np.ndarray) -> list[Turn]:
        self.calls += 1
        return self.turns


@pytest.fixture
def vault(tmp_path: Path) -> Path:
    path = tmp_path / "vault"
    path.mkdir()
    return path


@pytest.fixture
def recording_dir(tmp_path: Path) -> Path:
    """A finished recording: 12 s of "meeting" audio and a microphone track with one utterance."""
    app = np.concatenate([tone(5), silence(2), tone(5, frequency=220)])
    mic = np.concatenate([silence(3), tone(2, amplitude=0.2), silence(7)])
    folder = tmp_path / "recording"
    folder.mkdir()
    return make_recording(folder, app, mic)


def fake_claude(prompt: str, schema: dict, *, cwd: Path, allowed_tools=()) -> dict:
    """Canned Claude answers: names for both speakers, one correction, a summary with one task
    for the user and the first frame of the recording (if any) as shared content."""
    if "drop_ids" in schema["properties"]:
        return {
            "speakers": [
                {"label": "SPEAKER_00", "name": "Petr Novák", "confident": True},
                {"label": "SPEAKER_01", "name": "Jana", "confident": False},
            ],
            "corrections": [{"id": 0, "text": "Opravený text"}],
            "drop_ids": [],
            "vocabulary_suggestions": [
                {
                    "term": "Grafana",
                    "heard_as": ["grafána"],
                    "category": "product",
                    "description": "Dashboardy",
                }
            ],
        }
    meta = json.loads((cwd / "meta.json").read_text(encoding="utf-8"))
    frames = meta.get("frames") or []
    return {
        "summary": "Probírali jsme plán sprintu.",
        "key_points": ["Nasazení v pátek"],
        "decisions": [],
        "my_tasks": [{"task": "Připravit odhad", "due": "do pátku"}],
        "others_tasks": [{"person": "Petr Novák", "task": "Poslat specifikaci", "due": None}],
        "open_questions": [],
        "name_mentions": [{"time": "14:00", "context": "Petr se ptá na odhad"}],
        "shared_content": [
            {"frame": f["file"], "time": "14:00", "title": "Dashboard", "description": "Graf chyb."}
            for f in frames[:1]
        ],
        "timeline": [{"time": "14:00", "topic": "Plán sprintu"}],
    }
