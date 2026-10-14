"""Secrets come from the environment or the macOS Keychain, never from files in the repo."""

import os
import subprocess

HF_TOKEN_SERVICE = "MeetingAssistant HF token"


def hf_token() -> str | None:
    """Hugging Face token for the pyannote model download (never logged).

    Stored once with: security add-generic-password -a "$USER" -s "MeetingAssistant HF token" -w
    """
    if token := os.environ.get("HF_TOKEN"):
        return token
    result = subprocess.run(
        ["/usr/bin/security", "find-generic-password", "-s", HF_TOKEN_SERVICE, "-w"],
        capture_output=True,
        text=True,
        check=False,
    )
    token = result.stdout.strip()
    return token or None
