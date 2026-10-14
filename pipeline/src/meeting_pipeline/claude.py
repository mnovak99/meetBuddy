"""Calls Claude Code headless (`claude -p`) with the user's subscription.

- No API key: ANTHROPIC_API_KEY is removed from the environment, so usage goes through the
  logged-in Claude account, never through paid API access.
- Structured output: `--json-schema` makes Claude answer with JSON matching the schema; it comes
  back in the `structured_output` field of `--output-format json`.
- Only the Read tool is allowed, with the recording folder as working directory (to look at frames).
"""

import json
import logging
import os
import shutil
import subprocess
from collections.abc import Callable, Sequence
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)

TIMEOUT_SECONDS = 15 * 60
DISALLOWED_TOOLS = ("Bash", "Edit", "Write", "NotebookEdit", "WebFetch", "WebSearch")


class ClaudeError(Exception):
    """Claude is not available (not installed, not logged in, usage limit) or failed."""


def claude_path() -> str:
    path = shutil.which("claude") or str(Path.home() / ".local" / "bin" / "claude")
    if not Path(path).exists():
        raise ClaudeError("claude CLI not found (expected in ~/.local/bin)")
    return path


def run_claude(
    prompt: str,
    schema: dict[str, Any],
    *,
    cwd: Path,
    allowed_tools: Sequence[str] = ("Read",),
    attempts: int = 2,
) -> dict[str, Any]:
    """Run one prompt and return the structured output. Retries once on a failed answer."""
    env = {key: value for key, value in os.environ.items() if key != "ANTHROPIC_API_KEY"}
    command = [
        claude_path(),
        "-p",
        "--output-format", "json",
        "--json-schema", json.dumps(schema),
        "--no-session-persistence",
        # Claude only reads: never runs commands, edits files or goes to the web.
        "--disallowedTools", ",".join(DISALLOWED_TOOLS),
    ]  # fmt: skip
    if allowed_tools:
        command += ["--allowedTools", ",".join(allowed_tools)]
    last_error = "unknown error"
    for attempt in range(1, attempts + 1):
        try:
            result = subprocess.run(
                command, input=prompt, capture_output=True, text=True, cwd=cwd, env=env,
                timeout=TIMEOUT_SECONDS, check=False,
            )  # fmt: skip
        except subprocess.TimeoutExpired:
            last_error = f"timed out after {TIMEOUT_SECONDS} s"
            continue
        try:
            output = json.loads(result.stdout)
        except json.JSONDecodeError:
            last_error = f"exit code {result.returncode}: {result.stderr.strip()[:300]}"
            log.warning("Claude attempt %d: no JSON output (%s)", attempt, last_error)
            continue
        structured = output.get("structured_output")
        if not output.get("is_error") and isinstance(structured, dict):
            return structured
        last_error = f"{output.get('subtype')}: {str(output.get('result'))[:300]}"
        log.warning("Claude attempt %d failed: %s", attempt, output.get("subtype"))
    raise ClaudeError(last_error)


ClaudeRunner = Callable[..., dict[str, Any]]
