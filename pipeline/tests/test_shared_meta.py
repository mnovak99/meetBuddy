"""shared/meta.example.json must match shared/meta.schema.json and pass the pipeline's checks.

The Swift app decodes the same example in its unit tests (RecordingMetaTests).
"""

import json
import shutil
from pathlib import Path

from meeting_pipeline.recording import load_meta

SHARED = Path(__file__).resolve().parents[2] / "shared"


def load(name: str) -> dict:
    return json.loads((SHARED / name).read_text(encoding="utf-8"))


def test_example_has_required_keys() -> None:
    schema = load("meta.schema.json")
    example = load("meta.example.json")

    assert set(schema["required"]) <= set(example)
    assert set(schema["properties"]["audio"]["required"]) <= set(example["audio"])
    for frame in example["frames"]:
        assert set(schema["properties"]["frames"]["items"]["required"]) <= set(frame)


def test_example_has_only_known_keys() -> None:
    schema = load("meta.schema.json")
    example = load("meta.example.json")

    assert set(example) <= set(schema["properties"])


def test_pipeline_accepts_example(tmp_path: Path) -> None:
    shutil.copy(SHARED / "meta.example.json", tmp_path / "meta.json")

    assert load_meta(tmp_path)["source"] == "teams"
