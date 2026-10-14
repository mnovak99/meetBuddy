import json
from pathlib import Path

from meeting_pipeline.cli import EXIT_FAILED, EXIT_OK, EXIT_USAGE, main


def read_status(recording_dir: Path) -> dict:
    return json.loads((recording_dir / "status.json").read_text(encoding="utf-8"))


def test_valid_folder_writes_done(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text('{"app": "teams"}', encoding="utf-8")

    assert main([str(tmp_path)]) == EXIT_OK

    status = read_status(tmp_path)
    assert status["state"] == "done"
    assert status["error"] is None
    assert status["schemaVersion"] == 1
    assert "updatedAt" in status


def test_missing_meta_writes_failed(tmp_path: Path) -> None:
    assert main([str(tmp_path)]) == EXIT_FAILED

    status = read_status(tmp_path)
    assert status["state"] == "failed"
    assert "meta.json not found" in status["error"]


def test_invalid_meta_json_writes_failed(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text("{not json", encoding="utf-8")

    assert main([str(tmp_path)]) == EXIT_FAILED

    status = read_status(tmp_path)
    assert status["state"] == "failed"
    assert "not valid JSON" in status["error"]


def test_meta_must_be_object(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text("[1, 2]", encoding="utf-8")

    assert main([str(tmp_path)]) == EXIT_FAILED
    assert read_status(tmp_path)["state"] == "failed"


def test_missing_folder_exits_with_usage_error(tmp_path: Path) -> None:
    missing = tmp_path / "does-not-exist"

    assert main([str(missing)]) == EXIT_USAGE
    assert not missing.exists()


def test_status_write_leaves_no_temp_files(tmp_path: Path) -> None:
    (tmp_path / "meta.json").write_text("{}", encoding="utf-8")

    main([str(tmp_path)])
    main([str(tmp_path)])  # re-run on the same folder must be safe

    assert sorted(p.name for p in tmp_path.iterdir()) == ["meta.json", "status.json"]
