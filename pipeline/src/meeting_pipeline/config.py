"""Shared settings in ~/Library/Application Support/MeetingAssistant/ (written by the Swift app).

Schema: shared/config.schema.json. Only the keys the pipeline needs are read here.
"""

import json
from dataclasses import dataclass
from pathlib import Path

SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "MeetingAssistant"


@dataclass(frozen=True)
class Config:
    user_name: str = "Matej"
    obsidian_vault_path: str = ""


def load_config(path: Path = SUPPORT_DIR / "config.json") -> Config:
    """Missing file or keys fall back to the defaults (same rule as the Swift app)."""
    if not path.is_file():
        return Config()
    data = json.loads(path.read_text(encoding="utf-8"))
    defaults = Config()
    return Config(
        user_name=data.get("userName", defaults.user_name),
        obsidian_vault_path=data.get("obsidianVaultPath", defaults.obsidian_vault_path),
    )
