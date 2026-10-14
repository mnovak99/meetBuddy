import json
from pathlib import Path

from meeting_pipeline.config import load_config, macos_first_name


def test_empty_name_comes_from_the_mac_account(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"userName": "", "obsidianVaultPath": "/vault"}), encoding="utf-8")

    config = load_config(path)

    assert config.user_name == macos_first_name()
    assert config.user_name
    assert config.obsidian_vault_path == "/vault"


def test_configured_name_wins(tmp_path: Path) -> None:
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"userName": "Matej"}), encoding="utf-8")
    assert load_config(path).user_name == "Matej"


def test_missing_file_uses_defaults(tmp_path: Path) -> None:
    config = load_config(tmp_path / "missing.json")
    assert config.user_name == macos_first_name()
    assert config.obsidian_vault_path == ""
