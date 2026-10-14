"""Writes the Obsidian note (format: skill `obsidian-note`).

Meetings/YYYY/MM/YYYY-MM-DD HHmm <Title>.md, chosen frames in
Meetings/YYYY/MM/attachments/YYYY-MM-DD HHmm/, the user's tasks appended to Meetings/Moje úkoly.md.
Only core Markdown, callouts and wiki-links: no Obsidian plugins needed.
"""

import json
import re
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from meeting_pipeline.config import Config
from meeting_pipeline.recording import Recording
from meeting_pipeline.summarize import SOURCE_NAMES, Line, started_at

NOTE_RESULT_FILE = "note.json"
TASKS_NOTE = "Moje úkoly.md"
# A note with one of these statuses was written by the pipeline and not finished: safe to replace.
REPLACEABLE_STATUSES = ("processing", "needs_summary")
INVALID_FILE_CHARS = re.compile(r'[\\/:*?"<>|#^\[\]]')


class NoteError(Exception):
    pass


@dataclass(frozen=True)
class NoteResult:
    path: Path
    selected_frames: list[str]
    status: str


def write_note(
    recording: Recording, lines: list[Line], summary: dict[str, Any] | None, config: Config
) -> NoteResult:
    """`summary=None`: Claude was not available, the note has the transcript only."""
    if not config.obsidian_vault_path:
        raise NoteError("obsidianVaultPath is not set in config.json")
    vault = Path(config.obsidian_vault_path).expanduser()
    if not vault.is_dir():
        raise NoteError(f"Obsidian vault not found: {vault}")

    start = started_at(recording)
    stamp = f"{start:%Y-%m-%d %H%M}"
    title = clean_title((recording.meta.get("calendar") or {}).get("title") or "")
    folder = vault / "Meetings" / f"{start:%Y}" / f"{start:%m}"
    folder.mkdir(parents=True, exist_ok=True)
    note_path = _free_path(folder / f"{stamp}{' ' + title if title else ''}.md")

    status = "done" if summary else "needs_summary"
    frames = _copy_frames(recording, summary, folder / "attachments" / stamp) if summary else []
    note_path.write_text(
        render(recording, lines, summary, config, title, stamp, status), encoding="utf-8"
    )
    if summary:
        append_tasks(vault / "Meetings" / TASKS_NOTE, summary["my_tasks"], note_path.stem)

    result = NoteResult(path=note_path, selected_frames=frames, status=status)
    (recording.folder / NOTE_RESULT_FILE).write_text(
        json.dumps(
            {"notePath": str(note_path), "selectedFrames": frames, "status": status},
            ensure_ascii=False,
            indent=1,
        )
        + "\n",
        encoding="utf-8",
    )
    return result


def clean_title(title: str) -> str:
    """Strip characters invalid in file names or special in Obsidian links."""
    return re.sub(r"\s+", " ", INVALID_FILE_CHARS.sub(" ", title)).strip(" .")


def render(
    recording: Recording,
    lines: list[Line],
    summary: dict[str, Any] | None,
    config: Config,
    title: str,
    stamp: str,
    status: str,
) -> str:
    meta = recording.meta
    start = started_at(recording)
    end = datetime.fromisoformat(meta["endedAt"]) if meta.get("endedAt") else None
    participants = list(dict.fromkeys([config.user_name] + [line.speaker for line in lines]))
    languages = sorted({line.language for line in lines})

    out: list[str] = [
        "---",
        f"date: {start:%Y-%m-%d}",
        f'start: "{start:%H:%M}"',
        f'end: "{end:%H:%M}"' if end else 'end: ""',
        f"app: {SOURCE_NAMES.get(meta.get('source', ''), meta.get('source', ''))}",
        f"title: {json.dumps(title, ensure_ascii=False)}",
        f"participants: {json.dumps(participants, ensure_ascii=False)}",
        f"languages: {json.dumps(languages)}",
        "tags: [meeting]",
        f"status: {status}",
        "---",
        f"# {title or f'Meeting {start:%-d. %-m. %Y %H:%M}'}",
        "",
    ]

    if summary:
        out += ["> [!summary] Shrnutí", *_quote(summary["summary"]), ""]
        _section(out, "Klíčové body", [f"- {point}" for point in summary["key_points"]])
        _section(out, "Rozhodnutí", [f"- {item}" for item in summary["decisions"]])
        _section(
            out, "Moje úkoly", [f"- [ ] {_task(t['task'], t['due'])}" for t in summary["my_tasks"]]
        )
        _section(
            out,
            "Úkoly ostatních",
            [
                f"- [ ] **{t['person']}**: {_task(t['task'], t['due'])}"
                for t in summary["others_tasks"]
            ],
        )
        _section(out, "Otevřené otázky", [f"- {q}" for q in summary["open_questions"]])
        _section(
            out,
            "Kde padlo moje jméno",
            [f"- [{m['time']}] {m['context']}" for m in summary["name_mentions"]],
        )
        shared: list[str] = []
        for item in summary["shared_content"]:
            image = f"attachments/{stamp}/{Path(item['frame']).name}"
            shared += [
                f"### {item['time']} – {item['title']}",
                f"![[{image}]]",
                item["description"],
                "",
            ]
        _section(out, "Sdílený obsah", shared[:-1] if shared else [])
        _section(out, "Časová osa", [f"- {t['time']} {t['topic']}" for t in summary["timeline"]])
    else:
        out += [
            "> [!warning] Shrnutí zatím chybí",
            "> Claude nebyl dostupný (limit nebo chyba). Zpracování se dá spustit znovu.",
            "",
        ]

    out += ["## Přepis", "> [!note]- Plný přepis"]
    for index, line in enumerate(lines):
        if index:
            out.append(">")
        out.append(f"> **[{line.time}] {line.speaker}:** {line.text}")
    return "\n".join(out) + "\n"


def append_tasks(tasks_note: Path, tasks: list[dict[str, Any]], note_name: str) -> None:
    """Add the user's tasks to the shared task list, never twice."""
    existing = (
        tasks_note.read_text(encoding="utf-8") if tasks_note.is_file() else "# Moje úkoly\n\n"
    )
    known = {_task_key(line) for line in existing.splitlines()}
    new = [f"- [ ] {_task(task['task'], task['due'])} ([[{note_name}]])" for task in tasks]
    new = [line for line in new if _task_key(line) not in known]
    if new:
        separator = "" if existing.endswith("\n") else "\n"
        tasks_note.write_text(existing + separator + "\n".join(new) + "\n", encoding="utf-8")


def _task_key(line: str) -> str:
    """The same task, done or not: "- [x] Foo" equals "- [ ] Foo"."""
    return re.sub(r"^- \[[ xX]\] ", "", line.strip())


def _task(task: str, due: str | None) -> str:
    return f"{task} ({due})" if due else task


def _quote(text: str) -> list[str]:
    return [f"> {line}" for line in text.strip().splitlines()]


def _section(out: list[str], heading: str, body: list[str]) -> None:
    """Empty sections are left out (skill rule)."""
    if body:
        out += [f"## {heading}", *body, ""]


def _free_path(path: Path) -> Path:
    """Never overwrite a note the user may have edited: use "… (2).md" unless the existing note is
    an unfinished one written by the pipeline."""
    if not path.exists() or _status(path) in REPLACEABLE_STATUSES:
        return path
    counter = 2
    while True:
        candidate = path.with_name(f"{path.stem} ({counter}).md")
        if not candidate.exists() or _status(candidate) in REPLACEABLE_STATUSES:
            return candidate
        counter += 1


def _status(note: Path) -> str | None:
    match = re.search(r"^status:\s*(\S+)\s*$", note.read_text(encoding="utf-8"), re.MULTILINE)
    return match.group(1) if match else None


def _copy_frames(recording: Recording, summary: dict[str, Any] | None, target: Path) -> list[str]:
    frames = [item["frame"] for item in (summary or {}).get("shared_content", [])]
    if frames:
        target.mkdir(parents=True, exist_ok=True)
    for frame in frames:
        shutil.copy2(recording.folder / frame, target / Path(frame).name)
    return frames
