"""The `claude -p` call without a real `claude`: command line, environment, answer handling."""

import json
import os
from pathlib import Path

import pytest

from meeting_pipeline import claude
from meeting_pipeline.claude import ClaudeError, run_claude


class FakeProcess:
    def __init__(self, stdout: str) -> None:
        self.stdout = stdout
        self.returncode = 0

    def communicate(self, input=None, timeout=None):
        return self.stdout, "stderr text"

    def poll(self):
        return self.returncode

    def kill(self) -> None:
        pass

    def wait(self, timeout=None):
        return self.returncode


@pytest.fixture
def popen(monkeypatch: pytest.MonkeyPatch):
    """Replaces subprocess.Popen in claude.py; returns the recorded calls and the answers to give
    (one per call, in order)."""
    calls: list[tuple[list[str], dict]] = []
    answers: list[str] = []

    def fake_popen(command, **kwargs):
        calls.append((command, kwargs))
        return FakeProcess(answers.pop(0))

    monkeypatch.setattr(claude.subprocess, "Popen", fake_popen)
    monkeypatch.setattr(claude, "claude_path", lambda: "/opt/claude")
    return calls, answers


def answer(structured: dict) -> str:
    return json.dumps({"is_error": False, "subtype": "success", "structured_output": structured})


def test_command_uses_the_model_and_strict_mcp_config(popen, tmp_path: Path) -> None:
    calls, answers = popen
    answers.append(answer({"ok": True}))

    result = run_claude("prompt", {"type": "object"}, cwd=tmp_path, model="sonnet")

    assert result == {"ok": True}
    command, kwargs = calls[0]
    assert command[:2] == ["/opt/claude", "-p"]
    assert command[command.index("--model") + 1] == "sonnet"
    assert "--strict-mcp-config" in command
    assert "--no-session-persistence" in command
    assert command[command.index("--allowedTools") + 1] == "Read"
    assert kwargs["cwd"] == tmp_path


def test_no_model_flag_without_a_model(popen, tmp_path: Path) -> None:
    calls, answers = popen
    answers.append(answer({}))

    run_claude("prompt", {}, cwd=tmp_path, allowed_tools=())

    command = calls[0][0]
    assert "--model" not in command
    assert "--allowedTools" not in command


def test_api_keys_and_backends_are_stripped_from_the_environment(
    popen, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    monkeypatch.setenv("ANTHROPIC_API_KEY", "secret")
    monkeypatch.setenv("ANTHROPIC_BASE_URL", "http://proxy")
    monkeypatch.setenv("CLAUDE_CODE_USE_BEDROCK", "1")
    monkeypatch.setenv("HF_TOKEN", "keep")
    calls, answers = popen
    answers.append(answer({}))

    run_claude("prompt", {}, cwd=tmp_path)

    env = calls[0][1]["env"]
    assert not [key for key in env if key.startswith(("ANTHROPIC_", "CLAUDE_CODE_"))]
    assert env["HF_TOKEN"] == "keep"
    assert env["PATH"] == os.environ["PATH"]


def test_non_object_answers_are_retried_then_reported(popen, tmp_path: Path) -> None:
    calls, answers = popen
    answers += [
        "[1, 2]",
        json.dumps({"is_error": True, "subtype": "error_max_turns", "result": "x"}),
    ]

    with pytest.raises(ClaudeError, match="error_max_turns"):
        run_claude("prompt", {}, cwd=tmp_path)

    assert len(calls) == 2


def test_the_child_is_forgotten_after_the_call(popen, tmp_path: Path) -> None:
    _, answers = popen
    answers.append(answer({}))

    run_claude("prompt", {}, cwd=tmp_path)

    assert claude._child is None
