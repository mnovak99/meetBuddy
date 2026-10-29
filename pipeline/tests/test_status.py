import json
import time
from collections.abc import Callable
from pathlib import Path

from meeting_pipeline.status import State, StatusReporter


def wait_for(condition: Callable[[], bool], timeout: float = 2.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.01)
    return condition()


def test_heartbeat_rewrites_the_last_status(tmp_path: Path) -> None:
    status = tmp_path / "status.json"
    with StatusReporter(tmp_path, interval=0.05) as report:
        report(State.TRANSCRIBING, "Rozpoznávám mluvčí")
        status.unlink()

        assert wait_for(status.is_file)

        data = json.loads(status.read_text(encoding="utf-8"))
    assert data["state"] == "transcribing"
    assert data["message"] == "Rozpoznávám mluvčí"

    # After the block nothing writes any more, so a final status is safe.
    status.unlink()
    time.sleep(0.2)
    assert not status.exists()


def test_no_heartbeat_before_the_first_report(tmp_path: Path) -> None:
    with StatusReporter(tmp_path, interval=0.02):
        time.sleep(0.1)
    assert not (tmp_path / "status.json").exists()
