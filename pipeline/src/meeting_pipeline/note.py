"""Writes the Obsidian note (format: skill `obsidian-note`).

<notesFolder>/YYYY/MM/YYYY-MM-DD HHmm <Title>.md, chosen frames in
<notesFolder>/YYYY/MM/attachments/YYYY-MM-DD HHmm/, the user's tasks appended to
<notesFolder>/Moje úkoly.md (`notesFolder` in config.json, "Meetings" by default).
Only core Markdown, callouts and wiki-links: no Obsidian plugins needed.

The note is first written with `status: processing`; `finish_note` sets the final status once
status.json says the run is over. A run stopped in between leaves a note that the next run
replaces, instead of a second copy "… (2).md" next to it.
"""

import json
import logging
import re
import shutil
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Any

from meeting_pipeline.config import Config
from meeting_pipeline.files import write_json, write_text
from meeting_pipeline.recording import Recording
from meeting_pipeline.summarize import SOURCE_NAMES, Line, started_at

log = logging.getLogger(__name__)

NOTE_RESULT_FILE = "note.json"
TASKS_NOTE = "Moje úkoly.md"
PROCESSING_STATUS = "processing"
# A note with one of these statuses was written by the pipeline and not finished: safe to replace.
REPLACEABLE_STATUSES = (PROCESSING_STATUS, "needs_summary")
INVALID_FILE_CHARS = re.compile(r'[\\/:*?"<>|#^\[\]]')
# "- [ ] task (due) ([[note name]])"; the link is missing on lines the user wrote by hand.
TASK_LINE = re.compile(r"^- \[[ xX]\] (?P<task>.*?)(?: \(\[\[(?P<note>[^\]]+)\]\]\))?$")
COPY_SUFFIX = re.compile(r" \(\d+\)$")


class NoteError(Exception):
    pass


@dataclass(frozen=True)
class NoteResult:
    path: Path
    selected_frames: list[str]
    # The final status (done / needs_summary); the note on disk says `processing` until
    # finish_note() is called.
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

    notes = vault / config.notes_folder
    start = started_at(recording)
    stamp = f"{start:%Y-%m-%d %H%M}"
    title = clean_title((recording.meta.get("calendar") or {}).get("title") or "")
    folder = notes / f"{start:%Y}" / f"{start:%m}"
    folder.mkdir(parents=True, exist_ok=True)
    note_path = _free_path(folder / f"{stamp}{' ' + title if title else ''}.md")

    status = "done" if summary else "needs_summary"
    if summary:
        summary = _with_existing_frames(recording, summary)
    frames = _copy_frames(recording, summary, folder / "attachments" / stamp) if summary else []
    write_text(
        note_path, render(recording, lines, summary, config, title, stamp, PROCESSING_STATUS)
    )
    if summary and config.append_tasks_to_list:
        append_tasks(notes / TASKS_NOTE, summary["my_tasks"], note_path.stem)

    result = NoteResult(path=note_path, selected_frames=frames, status=status)
    write_json(
        recording.folder / NOTE_RESULT_FILE,
        {"notePath": str(note_path), "selectedFrames": frames, "status": status},
    )
    return result


def finish_note(note: NoteResult) -> None:
    """Replace `status: processing` in the frontmatter with the final status of the note."""
    text = note.path.read_text(encoding="utf-8")
    final = re.sub(
        rf"^status: {PROCESSING_STATUS}$",
        f"status: {note.status}",
        text,
        count=1,
        flags=re.MULTILINE,
    )
    if final != text:
        write_text(note.path, final)


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

    if config.note_include_transcript:
        out += ["## Přepis", "> [!note]- Plný přepis"]
        for index, line in enumerate(lines):
            if index:
                out.append(">")
            out.append(f"> **[{line.time}] {line.speaker}:** {line.text}")
    while out and out[-1] == "":
        out.pop()
    return "\n".join(out) + "\n"


def append_tasks(tasks_note: Path, tasks: list[dict[str, Any]], note_name: str) -> None:
    """Add the user's tasks to the shared task list, never twice: the same task from the same
    meeting is skipped even when the note was written again as "… (2)"."""
    existing = (
        tasks_note.read_text(encoding="utf-8") if tasks_note.is_file() else "# Moje úkoly\n\n"
    )
    known = {_task_key(line) for line in existing.splitlines()}
    new = [f"- [ ] {_task(task['task'], task['due'])} ([[{note_name}]])" for task in tasks]
    new = [line for line in new if _task_key(line) not in known]
    if new:
        separator = "" if existing.endswith("\n") else "\n"
        write_text(tasks_note, existing + separator + "\n".join(new) + "\n")


def _task_key(line: str) -> tuple[str, str]:
    """The same task from the same meeting, done or not: "- [x] Foo ([[A (2)]])" equals
    "- [ ] Foo ([[A]])"."""
    match = TASK_LINE.match(line.strip())
    if not match:
        return (line.strip(), "")
    return (match["task"], COPY_SUFFIX.sub("", match["note"] or ""))


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


def _with_existing_frames(recording: Recording, summary: dict[str, Any]) -> dict[str, Any]:
    """Only chosen frames still on disk: summary.json may be older than the frames folder (the app
    trashes unselected frames after `done`, the user may delete more by hand)."""
    chosen = summary.get("shared_content") or []
    kept = [item for item in chosen if (recording.folder / item["frame"]).is_file()]
    if len(kept) < len(chosen):
        log.warning(
            "%d chosen frames are missing from the recording folder", len(chosen) - len(kept)
        )
    return {**summary, "shared_content": kept}


def _copy_frames(recording: Recording, summary: dict[str, Any] | None, target: Path) -> list[str]:
    frames = [item["frame"] for item in (summary or {}).get("shared_content", [])]
    if frames:
        target.mkdir(parents=True, exist_ok=True)
    for frame in frames:
        shutil.copy2(recording.folder / frame, target / Path(frame).name)
    return frames
