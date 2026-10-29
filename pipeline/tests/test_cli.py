import json
import logging
import signal
import subprocess
from pathlib import Path

import numpy as np
import pytest
from conftest import FakeDiarizer, FakeTranscriber, fake_claude, make_recording, silence, tone

from meeting_pipeline import claude, cli, stages, status
from meeting_pipeline.cli import EXIT_FAILED, EXIT_OK, EXIT_TERMINATED, EXIT_USAGE, main
from meeting_pipeline.config import Config
from meeting_pipeline.models import Turn


def read_status(recording_dir: Path) -> dict:
    return json.loads((recording_dir / "status.json").read_text(encoding="utf-8"))


@pytest.fixture
def fakes(monkeypatch: pytest.MonkeyPatch, vault: Path) -> tuple[FakeDiarizer, FakeTranscriber]:
    """Replace the models and Claude with fakes, use a temporary vault; returns the fakes."""
    diarizer = FakeDiarizer([Turn(0.0, 5.0, "SPEAKER_00"), Turn(7.0, 12.0, "SPEAKER_01")])
    transcriber = FakeTranscriber(languages=["cs", "sk", "cs"])
    monkeypatch.setattr(
        cli.stages,
        "default_components",
        lambda config: stages.Components(
            diarize=diarizer, transcribe=transcriber, claude=fake_claude
        ),
    )
    monkeypatch.setattr(cli, "load_config", lambda: Config(obsidian_vault_path=str(vault)))
    return diarizer, transcriber


def test_recording_is_transcribed(recording_dir: Path, fakes) -> None:
    assert main([str(recording_dir)]) == EXIT_OK

    status = read_status(recording_dir)
    assert status["state"] == "done"
    transcript = json.loads((recording_dir / "transcript.json").read_text(encoding="utf-8"))
    speakers = {segment["speaker"] for segment in transcript["segments"]}
    assert speakers == {"SPEAKER_00", "SPEAKER_01", "USER"}
    assert (recording_dir / "transcript.txt").is_file()
    assert (recording_dir / "diarization.json").is_file()


def test_rerun_reuses_finished_work(recording_dir: Path, fakes) -> None:
    diarizer, transcriber = fakes
    main([str(recording_dir)])
    calls = len(transcriber.calls)

    assert main([str(recording_dir)]) == EXIT_OK

    assert diarizer.calls == 1
    assert len(transcriber.calls) == calls


def test_force_redoes_transcription(recording_dir: Path, fakes) -> None:
    diarizer, _ = fakes
    main([str(recording_dir)])
    main([str(recording_dir), "--force"])
    assert diarizer.calls == 2


def test_recording_without_microphone(tmp_path: Path, fakes) -> None:
    folder = tmp_path / "recording"
    folder.mkdir()
    make_recording(folder, tone(12))
    assert main([str(folder)]) == EXIT_OK
    transcript = json.loads((folder / "transcript.json").read_text(encoding="utf-8"))
    assert all(segment["track"] == "app" for segment in transcript["segments"])


def test_unfinished_recording_is_refused(tmp_path: Path, fakes) -> None:
    folder = tmp_path / "recording"
    folder.mkdir()
    make_recording(folder, silence(2), ended=False)
    assert main([str(folder)]) == EXIT_FAILED
    assert "not finished" in read_status(folder)["error"]


def test_missing_audio_writes_failed(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text(
        '{"endedAt": "2026-10-14T15:00:00+02:00"}', encoding="utf-8"
    )

    assert main([str(tmp_path)]) == EXIT_FAILED
    assert "audio.m4a not found" in read_status(tmp_path)["error"]


def test_missing_meta_writes_failed(tmp_path: Path) -> None:
    assert main([str(tmp_path)]) == EXIT_FAILED

    status = read_status(tmp_path)
    assert status["state"] == "failed"
    assert "meta.json not found" in status["error"]


def test_invalid_meta_json_writes_failed(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text("{not json", encoding="utf-8")

    assert main([str(tmp_path)]) == EXIT_FAILED
    assert "not valid JSON" in read_status(tmp_path)["error"]


def test_missing_folder_exits_with_usage_error(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist"

    assert main([str(missing)]) == EXIT_USAGE
    assert not missing.exists()


def test_status_write_leaves_no_temp_files(recording_dir: Path, fakes) -> None:
    main([str(recording_dir)])
    assert not list(recording_dir.glob(".*.tmp"))


def test_missing_vault_setting_fails_early(recording_dir: Path, fakes, monkeypatch) -> None:
    diarizer, _ = fakes
    monkeypatch.setattr(cli, "load_config", lambda: Config(obsidian_vault_path=""))

    assert main([str(recording_dir)]) == EXIT_FAILED

    assert "obsidianVaultPath" in read_status(recording_dir)["error"]
    assert diarizer.calls == 0


def test_without_diarization_the_note_is_still_written(
    recording_dir: Path, fakes, monkeypatch: pytest.MonkeyPatch, vault: Path
) -> None:
    from meeting_pipeline.models import ModelError

    def unavailable(samples):
        raise ModelError("Model není přístupný: potvrď jeho podmínky")

    _, transcriber = fakes
    monkeypatch.setattr(
        cli.stages,
        "default_components",
        lambda config: stages.Components(
            diarize=unavailable, transcribe=transcriber, claude=fake_claude
        ),
    )

    assert main([str(recording_dir)]) == EXIT_OK

    status = read_status(recording_dir)
    assert status["state"] == "done"
    assert "Bez rozlišení mluvčích" in status["error"]
    transcript = json.loads((recording_dir / "transcript.json").read_text(encoding="utf-8"))
    assert {s["speaker"] for s in transcript["segments"]} == {"SPEAKER_00", "USER"}
    assert transcript["models"]["diarization"] is None
    assert not (recording_dir / "diarization.json").exists()  # tried again on --force


def test_states_are_reported_in_order(recording_dir: Path, fakes, monkeypatch) -> None:
    states: list[str] = []
    original = status.write_status

    def recording_write(folder, state, **kwargs):
        states.append(state.value)
        return original(folder, state, **kwargs)

    monkeypatch.setattr(status, "write_status", recording_write)  # the reporter's writes
    monkeypatch.setattr(cli, "write_status", recording_write)  # the final write

    assert main([str(recording_dir)]) == EXIT_OK

    assert list(dict.fromkeys(states)) == ["transcribing", "summarizing", "writing", "done"]


def test_languages_and_whisper_model_come_from_the_config(
    recording_dir: Path, fakes, monkeypatch, vault: Path
) -> None:
    _, transcriber = fakes
    monkeypatch.setattr(
        cli,
        "load_config",
        lambda: Config(
            obsidian_vault_path=str(vault),
            transcript_languages=("sk", "en"),
            whisper_model="mlx-community/whisper-small",
        ),
    )

    assert main([str(recording_dir)]) == EXIT_OK

    transcript = json.loads((recording_dir / "transcript.json").read_text(encoding="utf-8"))
    assert transcript["models"]["asr"] == "mlx-community/whisper-small"
    # The first chunk was detected as Czech, which is not allowed: redone in Slovak (the first
    # configured language); the short microphone chunk takes the meeting's language.
    assert [language for _, language in transcriber.calls] == [None, "sk", None, "sk"]


def test_default_components_follow_the_config(monkeypatch: pytest.MonkeyPatch) -> None:
    seen: dict[str, object] = {}
    monkeypatch.setattr(stages, "hf_token", lambda: "hf_token")
    monkeypatch.setattr(stages, "load_vocabulary", lambda: [])
    monkeypatch.setattr(stages, "whisper_token_counter", lambda: len)

    def diarize(samples, token, *, threads):
        seen.update(token=token, threads=threads)
        return []

    def transcribe(samples, *, initial_prompt, language, model):
        seen.update(whisper=model)
        return "cs", []

    def run_claude(prompt, schema, *, cwd, allowed_tools=(), model=None):
        seen.update(claude=model)
        return {}

    monkeypatch.setattr(stages.models, "diarize", diarize)
    monkeypatch.setattr(stages.models, "transcribe", transcribe)
    monkeypatch.setattr(stages, "run_claude", run_claude)
    config = Config(
        whisper_model="mlx-community/whisper-small", claude_model="haiku", pipeline_threads=2
    )

    parts = stages.default_components(config)
    parts.diarize(np.zeros(16, dtype=np.float32))
    parts.transcribe(np.zeros(16, dtype=np.float32), initial_prompt=None, language=None)
    parts.claude("prompt", {}, cwd=Path("."))

    assert seen == {
        "token": "hf_token",
        "threads": 2,
        "whisper": "mlx-community/whisper-small",
        "claude": "haiku",
    }


def test_unexpected_error_is_reported_as_failed(recording_dir: Path, fakes, monkeypatch) -> None:
    def broken(samples, *, initial_prompt, language):
        raise RuntimeError("MLX exploded")

    diarizer, _ = fakes
    monkeypatch.setattr(
        cli.stages,
        "default_components",
        lambda config: stages.Components(diarize=diarizer, transcribe=broken, claude=fake_claude),
    )

    assert main([str(recording_dir)]) == EXIT_FAILED

    status = read_status(recording_dir)
    assert status["state"] == "failed"
    assert status["error"] == "RuntimeError: MLX exploded"


def test_damaged_caches_are_rebuilt(recording_dir: Path, fakes) -> None:
    diarizer, _ = fakes
    for name in ("diarization.json", "transcript.json", "cleaned.json", "summary.json"):
        (recording_dir / name).write_text("{broken", encoding="utf-8")

    assert main([str(recording_dir)]) == EXIT_OK

    assert read_status(recording_dir)["state"] == "done"
    assert diarizer.calls == 1
    summary = json.loads((recording_dir / "summary.json").read_text(encoding="utf-8"))
    assert summary["summary"]


def test_verbose_enables_debug_logging(recording_dir: Path, fakes) -> None:
    root = logging.getLogger()
    level = root.level
    try:
        main([str(recording_dir), "--verbose"])
        assert root.level == logging.DEBUG
    finally:
        root.setLevel(level)


def test_debug_logging_from_the_config(recording_dir: Path, fakes, monkeypatch, vault) -> None:
    monkeypatch.setattr(
        cli, "load_config", lambda: Config(obsidian_vault_path=str(vault), debug_logging=True)
    )
    root = logging.getLogger()
    level = root.level
    try:
        main([str(recording_dir)])
        assert root.level == logging.DEBUG
    finally:
        root.setLevel(level)


def test_sigterm_stops_claude_and_exits_with_143(monkeypatch: pytest.MonkeyPatch) -> None:
    child = subprocess.Popen(["/bin/sleep", "60"])
    monkeypatch.setattr(claude, "_child", child)

    with pytest.raises(SystemExit) as stop:
        cli.handle_sigterm(signal.SIGTERM, None)

    assert stop.value.code == EXIT_TERMINATED == 143
    assert child.wait(timeout=5) == -signal.SIGTERM


def test_sigterm_during_a_stage_leaves_the_status_in_progress(
    recording_dir: Path, fakes, monkeypatch
) -> None:
    def interrupted(samples, *, initial_prompt, language):
        cli.handle_sigterm(signal.SIGTERM, None)  # what the signal does in the main thread

    diarizer, _ = fakes
    monkeypatch.setattr(
        cli.stages,
        "default_components",
        lambda config: stages.Components(
            diarize=diarizer, transcribe=interrupted, claude=fake_claude
        ),
    )

    with pytest.raises(SystemExit) as stop:
        main([str(recording_dir)])

    assert stop.value.code == EXIT_TERMINATED
    assert read_status(recording_dir)["state"] == "transcribing"  # no final status
    assert (recording_dir / "diarization.json").is_file()  # finished stages stay cached
    assert not list(recording_dir.glob(".*.tmp"))


def test_sigterm_handler_is_restored_after_the_run(recording_dir: Path, fakes) -> None:
    before = signal.getsignal(signal.SIGTERM)
    main([str(recording_dir)])
    assert signal.getsignal(signal.SIGTERM) is before
