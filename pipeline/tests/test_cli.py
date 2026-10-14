import json
from pathlib import Path

import pytest
from conftest import FakeDiarizer, FakeTranscriber, fake_claude, make_recording, silence, tone

from meeting_pipeline import cli, stages
from meeting_pipeline.cli import EXIT_FAILED, EXIT_OK, EXIT_USAGE, main
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
        lambda: stages.Components(diarize=diarizer, transcribe=transcriber, claude=fake_claude),
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
    assert not list(recording_dir.glob(".status.*"))


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
        lambda: stages.Components(diarize=unavailable, transcribe=transcriber, claude=fake_claude),
    )

    assert main([str(recording_dir)]) == EXIT_OK

    status = read_status(recording_dir)
    assert status["state"] == "done"
    assert "Bez rozlišení mluvčích" in status["error"]
    transcript = json.loads((recording_dir / "transcript.json").read_text(encoding="utf-8"))
    assert {s["speaker"] for s in transcript["segments"]} == {"SPEAKER_00", "USER"}
    assert transcript["models"]["diarization"] is None
    assert not (recording_dir / "diarization.json").exists()  # tried again on --force
