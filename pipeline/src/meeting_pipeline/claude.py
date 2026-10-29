"""Calls Claude Code headless (`claude -p`) with the user's subscription.

- No API key and no other backend: every `ANTHROPIC_*` and `CLAUDE_CODE_*` variable is removed
  from the environment, so usage goes through the logged-in Claude account, never through paid
  API access, a proxy, Bedrock or Vertex.
- Structured output: `--json-schema` makes Claude answer with JSON matching the schema; it comes
  back in the `structured_output` field of `--output-format json`.
- Only the Read tool is allowed, with the recording folder as working directory (to look at
  frames). `--strict-mcp-config` keeps the user's own MCP servers from starting for every call.
- The running child process is remembered, so the SIGTERM handler of the CLI can stop it
  (`terminate_child`) instead of leaving an orphaned `claude` behind.
"""

import json
import logging
import os
import shutil
import subprocess
import threading
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

TIMEOUT_SECONDS = 15 * 60
DISALLOWED_TOOLS = ("Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch")
STRIPPED_ENV_PREFIXES = ("ANTHROPIC_", "CLAUDE_CODE_")

# The `claude` process of the current call, for terminate_child(). RLock: the SIGTERM handler
# runs in the same thread and may interrupt a section that already holds the lock.
_child_lock = threading.RLock()
_child: subprocess.Popen[str] | None = None


class ClaudeError(Exception):
    """Claude is not available (not installed, not logged in, usage limit) or failed."""


def claude_path() -> str:
    path = shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")
    if not Path(path).exists():
        raise ClaudeError("claude CLI not found (expected in ~/.local/bin)")
    return path


def claude_env() -> dict[str, str]:
    """The environment for `claude`: without API keys and backend overrides."""
    return {
        key: value for key, value in os.environ.items() if not key.startswith(STRIPPED_ENV_PREFIXES)
    }


def run_claude(
    prompt: str,
    schema: dict[str, Any],
    *,
    cwd: Path,
    allowed_tools: Sequence[str] = ("Read",),
    attempts: int = 2,
    model: str | None = None,
) -> dict[str, Any]:
    """Run one prompt and return the structured output. Retries once on a failed answer.

    `model` is an alias for `claude --model` (sonnet, opus, haiku …); None = Claude Code's default.
    """
    command = [
        claude_path(),
        "-p",
        "--output-format", "json",
        "--json-schema", json.dumps(schema),
        "--no-session-persistence",
        "--strict-mcp-config",
        # Claude only reads: never runs commands, edits files or goes to the web.
        "--disallowedTools", ",".join(DISALLOWED_TOOLS),
    ]  # fmt: skip
    if allowed_tools:
        command += ["--allowedTools", ",".join(allowed_tools)]
    if model:
        command += ["--model", model]
    env = claude_env()
    log.debug("Claude command: %s", " ".join(command[1:]))
    last_error = "unknown error"
    for attempt in range(1, attempts + 1):
        try:
            stdout, stderr, returncode = _run(command, prompt, cwd, env)
        except subprocess.TimeoutExpired:
            last_error = f"timed out after {TIMEOUT_SECONDS} s"
            log.warning("Claude attempt %d: %s", attempt, last_error)
            continue
        try:
            output = json.loads(stdout)
        except json.JSONDecodeError:
            last_error = f"exit code {returncode}: {stderr.strip()[:300]}"
            log.warning("Claude attempt %d: no JSON output (%s)", attempt, last_error)
            continue
        if not isinstance(output, dict):
            last_error = f"unexpected output: {str(output)[:100]}"
            log.warning("Claude attempt %d: %s", attempt, last_error)
            continue
        structured = output.get("structured_output")
        if not output.get("is_error") and isinstance(structured, dict):
            return structured
        if output.get("is_error"):
            # An error message from the CLI (usage limit, not logged in): useful to show.
            last_error = f"{output.get('subtype')}: {str(output.get('result'))[:300]}"
        else:
            # The answer did not match the schema: never copy model output into status/log.
            last_error = f"{output.get('subtype')}: odpověď nebyla ve správném formátu"
        log.warning("Claude attempt %d failed: %s", attempt, output.get("subtype"))
    raise ClaudeError(last_error)


def _run(command: list[str], prompt: str, cwd: Path, env: dict[str, str]) -> tuple[str, str, int]:
    """Like `subprocess.run` with a timeout, but the child is remembered for terminate_child()."""
    global _child
    with _child_lock:
        process = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            cwd=cwd,
            env=env,
        )
        _child = process
    try:
        stdout, stderr = process.communicate(prompt, timeout=TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
        raise
    finally:
        with _child_lock:
            _child = None
    return stdout, stderr, process.returncode


def terminate_child() -> None:
    """Stop a running `claude`, if any (called from the SIGTERM handler of the CLI)."""
    with _child_lock:
        if _child is not None and _child.poll() is None:
            _child.terminate()


ClaudeRunner = Callable[..., dict[str, Any]]
