"""status.json: progress of the pipeline, watched by the Swift app."""

import json
import os
import tempfile
from datetime import datetime
from enum import StrEnum
from pathlib import Path

STATUS_FILE = "status.json"
SCHEMA_VERSION = 1


class State(StrEnum):
    QUEUED = "queued"
    TRANSCRIBING = "transcribing"
    SUMMARIZING = "summarizing"
    WRITING = "writing"
    DONE = "done"
    NEEDS_SUMMARY = "needs_summary"
    FAILED = "failed"


def write_status(
    recording_dir: Path,
    state: State,
    *,
    message: str | None = None,
    error: str | None = None,
) -> Path:
    """Write status.json atomically, so the app never reads a half-written file."""
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "state": state.value,
        "updatedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "error": error,
        "message": message,
    }
    target = recording_dir / STATUS_FILE
    # Write to a temp file in the same folder, then rename: rename is atomic on one volume.
    fd, tmp_name = tempfile.mkstemp(prefix=".status.", suffix=".tmp", dir=recording_dir)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp:
            json.dump(payload, tmp, ensure_ascii=False, indent=2)
            tmp.write("\n")
        os.replace(tmp_name, target)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    return target
