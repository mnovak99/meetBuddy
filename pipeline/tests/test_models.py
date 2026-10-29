"""mlx-whisper is replaced by a fake module: the real one needs the model download."""

import sys
import types

import pytest
from conftest import silence

from meeting_pipeline.models import ModelError, transcribe


def test_whisper_model_is_passed_through(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: dict = {}

    def fake(samples, **kwargs):
        seen.update(kwargs)
        return {"language": "cs", "segments": [{"start": 0, "end": 1, "text": " Ahoj "}]}

    monkeypatch.setitem(sys.modules, "mlx_whisper", types.SimpleNamespace(transcribe=fake))

    language, segments = transcribe(
        silence(1), initial_prompt=None, language=None, model="mlx-community/whisper-small"
    )

    assert language == "cs"
    assert [s.text for s in segments] == ["Ahoj"]
    assert seen["path_or_hf_repo"] == "mlx-community/whisper-small"


def test_whisper_errors_become_model_errors(monkeypatch: pytest.MonkeyPatch) -> None:
    def explode(*args, **kwargs):
        raise RuntimeError("boom")

    monkeypatch.setitem(sys.modules, "mlx_whisper", types.SimpleNamespace(transcribe=explode))

    with pytest.raises(ModelError, match=r"Whisper \(mlx-community/x\) failed: RuntimeError: boom"):
        transcribe(silence(1), initial_prompt=None, language=None, model="mlx-community/x")
