"""Shared settings in ~/Library/Application Support/MeetingAssistant/ (written by the Swift app).

Schema: shared/config.schema.json. Only the keys the pipeline needs are read here.
"""

import getpass
import json
import subprocess
from dataclasses import dataclass
from pathlib import Path

SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "MeetingAssistant"


@dataclass(frozen=True)
class Config:
    user_name: str = ""
    obsidian_vault_path: str = ""


def macos_first_name() -> str:
    """First name of the macOS account (`id -F` prints the full name), else the login name."""
    result = subprocess.run(["/usr/bin/id", "-F"], capture_output=True, text=True, check=False)
    name = result.stdout.strip().split(" ")[0] if result.returncode == 0 else ""
    return name or getpass.getuser()


def load_config(path: Path = SUPPORT_DIR / "config.json") -> Config:
    """Missing file or keys fall back to the defaults (same rules as the Swift app);
    an empty userName means the first name of the macOS account."""
    data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    return Config(
        user_name=data.get("userName") or macos_first_name(),
        obsidian_vault_path=data.get("obsidianVaultPath", ""),
    )
