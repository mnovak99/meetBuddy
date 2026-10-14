"""Validation of a recording folder created by the Swift app."""

import json
from pathlib import Path
from typing import Any

META_FILE = "meta.json"


class InvalidRecordingError(Exception):
    """The folder exists, but its content is not a usable recording."""


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
