"""status.json: progress of the pipeline, watched by the Swift app."""

import logging
import threading
from collections.abc import Callable
from datetime import datetime
from enum import StrEnum
from pathlib import Path
from typing import Self

from meeting_pipeline.files import write_json

log = logging.getLogger(__name__)

STATUS_FILE = "status.json"
SCHEMA_VERSION = 1
# The app stops a run whose status.json did not change for 30 minutes; stay well under that.
HEARTBEAT_SECONDS = 60.0


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
    write_json(target, payload, indent=2)
    return target


# Progress callback of the stages: the current state and a short Czech message for the menu.
Reporter = Callable[[State, str], None]


class StatusReporter:
    """Reports progress to status.json and keeps it fresh while a long stage runs (heartbeat).

    The app kills a run whose status.json has not changed for 30 minutes. Diarization of a long
    meeting, the first download of a Whisper model or a single Claude call can take longer with
    nothing new to report, so a daemon thread rewrites the last state (with a fresh `updatedAt`)
    every `interval` seconds. Use it as a context manager: leaving the block stops the thread, so
    a final state written afterwards can never be overwritten by a late heartbeat.
    """

    def __init__(self, recording_dir: Path, interval: float = HEARTBEAT_SECONDS) -> None:
        self.recording_dir = recording_dir
        self.interval = interval
        self._lock = threading.Lock()
        self._last: tuple[State, str] | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def __call__(self, state: State, message: str) -> None:
        with self._lock:
            self._last = (state, message)
            write_status(self.recording_dir, state, message=message)

    def __enter__(self) -> Self:
        self._stop.clear()
        self._thread = threading.Thread(
            target=self._heartbeat, name="status-heartbeat", daemon=True
        )
        self._thread.start()
        return self

    def __exit__(self, *exc_info: object) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join()
            self._thread = None

    def _heartbeat(self) -> None:
        while not self._stop.wait(self.interval):
            with self._lock:
                if self._last is None:
                    continue
                state, message = self._last
                try:
                    write_status(self.recording_dir, state, message=message)
                except OSError as exc:
                    # The folder is being deleted: the run is about to be stopped anyway.
                    log.debug("Heartbeat could not write status.json: %s", exc)
