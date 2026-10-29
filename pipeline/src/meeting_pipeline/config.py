"""Shared settings in ~/Library/Application Support/MeetingAssistant/ (written by the Swift app).

Schema: shared/config.schema.json. Only the keys the pipeline needs are read here; every key is
optional and falls back to the same default as the Swift app.
"""

import getpass
import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path

SUPPORT_DIR = Path.home() / "Library" / "Application Support" / "MeetingAssistant"
DEFAULT_WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
DEFAULT_LANGUAGES = ("cs", "sk", "en")
SUPPORTED_LANGUAGES = ("cs", "sk", "en", "de", "pl")


@dataclass(frozen=True)
class Config:
    user_name: str = ""
    obsidian_vault_path: str = ""
    # Languages Whisper may detect; a chunk in another language is redone in the first one.
    transcript_languages: tuple[str, ...] = DEFAULT_LANGUAGES
    whisper_model: str = DEFAULT_WHISPER_MODEL
    # Alias for `claude --model`; empty = Claude Code's default.
    claude_model: str = ""
    note_include_transcript: bool = True
    append_tasks_to_list: bool = True
    notes_folder: str = "Meetings"
    pipeline_threads: int = 4
    debug_logging: bool = False
    extra: dict = field(default_factory=dict, compare=False, repr=False)


def macos_first_name() -> str:
    """First name of the macOS account (`id -F` prints the full name), else the login name."""
    result = subprocess.run(["/usr/bin/id", "-F"], capture_output=True, text=True, check=False)
    name = result.stdout.strip().split(" ")[0] if result.returncode == 0 else ""
    return name or getpass.getuser()


def _languages(value: object) -> tuple[str, ...]:
    if not isinstance(value, list):
        return DEFAULT_LANGUAGES
    chosen: list[str] = []
    for item in value:
        code = str(item).lower()
        if code in SUPPORTED_LANGUAGES and code not in chosen:
            chosen.append(code)
    return tuple(chosen) or DEFAULT_LANGUAGES


def _folder(value: object) -> str:
    name = str(value or "").strip().replace("/", "-")
    return name or "Meetings"


def _threads(value: object) -> int:
    try:
        return min(max(int(value), 1), 32)  # type: ignore[arg-type]
    except (TypeError, ValueError):
        return 4


def load_config(path: Path = SUPPORT_DIR / "config.json") -> Config:
    """Missing file or keys fall back to the defaults (same rules as the Swift app);
    an empty userName means the first name of the macOS account."""
    data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    if not isinstance(data, dict):
        data = {}
    return Config(
        user_name=data.get("userName") or macos_first_name(),
        obsidian_vault_path=str(data.get("obsidianVaultPath") or ""),
        transcript_languages=_languages(data.get("transcriptLanguages")),
        whisper_model=str(data.get("whisperModel") or "").strip() or DEFAULT_WHISPER_MODEL,
        claude_model=str(data.get("claudeModel") or "").strip(),
        note_include_transcript=bool(data.get("noteIncludeTranscript", True)),
        append_tasks_to_list=bool(data.get("appendTasksToList", True)),
        notes_folder=_folder(data.get("notesFolder", "Meetings")),
        pipeline_threads=_threads(data.get("pipelineThreads", 4)),
        debug_logging=bool(data.get("debugLogging", False)),
        extra=data,
    )
