"""A recording folder created by the Swift app (schema of meta.json: shared/meta.schema.json)."""

import json
from dataclasses import dataclass
from pathlib import Path
from typing import Any

META_FILE = "meta.json"


class InvalidRecordingError(Exception):
    """The folder exists, but its content is not a usable recording."""


@dataclass(frozen=True)
class Recording:
    folder: Path
    meta: dict[str, Any]

    @property
    def audio(self) -> Path:
        """The meeting app's audio (the other participants)."""
        return self.folder / self.meta.get("audio", {}).get("file", "audio.m4a")

    @property
    def microphone(self) -> Path | None:
        """The user's microphone track, if it was recorded."""
        name = (self.meta.get("microphone") or {}).get("file")
        path = self.folder / name if name else None
        return path if path and path.is_file() else None


def load_meta(recording_dir: Path) -> dict[str, Any]:
    """Return the parsed meta.json of a recording folder.

    Raises NotADirectoryError if the folder does not exist (status.json cannot be written then)
    and InvalidRecordingError if meta.json is missing or malformed.
    """
    if not recording_dir.is_dir():
        raise NotADirectoryError(f"Recording folder does not exist: {recording_dir}")

    meta_path = recording_dir / META_FILE
    if not meta_path.is_file():
        raise InvalidRecordingError(f"{META_FILE} not found")

    try:
        meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError) as exc:
        raise InvalidRecordingError(f"{META_FILE} is not valid JSON: {exc}") from exc

    if not isinstance(meta, dict):
        raise InvalidRecordingError(f"{META_FILE} must contain a JSON object")
    return meta


def load_recording(recording_dir: Path) -> Recording:
    recording = Recording(folder=recording_dir, meta=load_meta(recording_dir))
    if not recording.audio.is_file():
        raise InvalidRecordingError(f"{recording.audio.name} not found")
    if not recording.meta.get("endedAt"):
        raise InvalidRecordingError("the recording is not finished yet (meta.json has no endedAt)")
    return recording
