"""Claude steps: clean the transcript (names, misrecognized terms) and write the note content.

Both results are cached in the recording folder (cleaned.json, summary.json), so a re-run after a
usage limit or a fix does not ask Claude again for finished steps.
"""

import json
import logging
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta
from pathlib import Path
from string import Template
from typing import Any

from meeting_pipeline.claude import ClaudeRunner
from meeting_pipeline.config import Config
from meeting_pipeline.recording import Recording
from meeting_pipeline.transcript import USER_SPEAKER, Segment
from meeting_pipeline.vocabulary import Term

log = logging.getLogger(__name__)

PROMPTS_DIR = Path(__file__).resolve().parents[2] / "prompts"
CLEANED_FILE = "cleaned.json"
SUMMARY_FILE = "summary.json"
SOURCE_NAMES = {"teams": "Teams", "meet": "Google Meet", "discord": "Discord"}


@dataclass(frozen=True)
class Line:
    """One transcript line with the speaker's display name and the wall-clock time."""

    id: int
    time: str  # "14:03:12"
    speaker: str  # "Petr Novák", "Petr Novák (?)" or the user's name
    language: str
    text: str


CLEAN_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": ["speakers", "corrections", "drop_ids"],
    "properties": {
        "speakers": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["label", "name", "confident"],
                "properties": {
                    "label": {"type": "string"},
                    "name": {"type": "string"},
                    "confident": {"type": "boolean"},
                },
            },
        },
        "corrections": {
            "type": "array",
            "items": {
                "type": "object",
                "additionalProperties": False,
                "required": ["id", "text"],
                "properties": {"id": {"type": "integer"}, "text": {"type": "string"}},
            },
        },
        "drop_ids": {"type": "array", "items": {"type": "integer"}},
    },
}

_TIME = {"type": "string", "description": "HH:MM"}
_STRINGS = {"type": "array", "items": {"type": "string"}}


def _objects(properties: dict[str, Any], required: list[str]) -> dict[str, Any]:
    return {
        "type": "array",
        "items": {
            "type": "object",
            "additionalProperties": False,
            "required": required,
            "properties": properties,
        },
    }


SUMMARY_SCHEMA: dict[str, Any] = {
    "type": "object",
    "additionalProperties": False,
    "required": [
        "summary",
        "key_points",
        "decisions",
        "my_tasks",
        "others_tasks",
        "open_questions",
        "name_mentions",
        "shared_content",
        "timeline",
    ],  # fmt: skip
    "properties": {
        "summary": {"type": "string"},
        "key_points": _STRINGS,
        "decisions": _STRINGS,
        "my_tasks": _objects(
            {"task": {"type": "string"}, "due": {"type": ["string", "null"]}}, ["task", "due"]
        ),
        "others_tasks": _objects(
            {
                "person": {"type": "string"},
                "task": {"type": "string"},
                "due": {"type": ["string", "null"]},
            },
            ["person", "task", "due"],
        ),
        "open_questions": _STRINGS,
        "name_mentions": _objects(
            {"time": _TIME, "context": {"type": "string"}}, ["time", "context"]
        ),
        "shared_content": _objects(
            {
                "frame": {"type": "string"},
                "time": _TIME,
                "title": {"type": "string"},
                "description": {"type": "string"},
            },
            ["frame", "time", "title", "description"],
        ),
        "timeline": _objects({"time": _TIME, "topic": {"type": "string"}}, ["time", "topic"]),
    },
}


def started_at(recording: Recording) -> datetime:
    return datetime.fromisoformat(recording.meta["startedAt"])


def clock(recording: Recording, seconds: float) -> str:
    return (started_at(recording) + timedelta(seconds=seconds)).strftime("%H:%M:%S")


def plain_lines(segments: list[Segment], recording: Recording, config: Config) -> list[Line]:
    """Lines without Claude: diarization labels, the user's name for the microphone."""
    return [
        Line(
            id=index,
            time=clock(recording, segment.start),
            speaker=config.user_name if segment.speaker == USER_SPEAKER else segment.speaker,
            language=segment.language,
            text=segment.text,
        )
        for index, segment in enumerate(segments)
    ]


def meeting_text(recording: Recording) -> str:
    meta = recording.meta
    start = started_at(recording)
    end = datetime.fromisoformat(meta["endedAt"]) if meta.get("endedAt") else None
    title = (meta.get("calendar") or {}).get("title") or "(bez události v kalendáři)"
    span = f"{start:%d. %m. %Y %H:%M}" + (f"–{end:%H:%M}" if end else "")
    return f"{title}, {span}, {SOURCE_NAMES.get(meta.get('source', ''), meta.get('source', ''))}"


def participants_text(recording: Recording) -> str:
    attendees = (recording.meta.get("calendar") or {}).get("attendees") or []
    names = [a.get("name") or a.get("email") for a in attendees if a.get("name") or a.get("email")]
    return ", ".join(names) if names else "neznámí (meeting nemá událost v kalendáři)"


def vocabulary_text(terms: list[Term]) -> str:
    if not terms:
        return "(prázdný)"
    lines = []
    for term in terms:
        line = f"- {term.term}"
        if term.aliases:
            line += f" (aliasy: {', '.join(term.aliases)})"
        if term.description:
            line += f" – {term.description}"
        lines.append(line)
    return "\n".join(lines)


def clean(
    segments: list[Segment],
    recording: Recording,
    config: Config,
    terms: list[Term],
    runner: ClaudeRunner,
) -> list[Line]:
    """Speaker names, corrected terms and dropped hallucinations. Cached in cleaned.json."""
    cache = recording.folder / CLEANED_FILE
    if cache.is_file():
        return [Line(**item) for item in json.loads(cache.read_text(encoding="utf-8"))["lines"]]

    transcript = "\n".join(
        f"#{index} [{clock(recording, s.start)}] {s.speaker} ({s.language}): {s.text}"
        for index, s in enumerate(segments)
    )
    prompt = Template((PROMPTS_DIR / "clean.md").read_text(encoding="utf-8")).substitute(
        user_name=config.user_name,
        meeting=meeting_text(recording),
        participants=participants_text(recording),
        vocabulary=vocabulary_text(terms),
        transcript=transcript,
    )
    result = runner(prompt, CLEAN_SCHEMA, cwd=recording.folder, allowed_tools=())

    names = {
        item["label"]: item["name"] + ("" if item["confident"] else " (?)")
        for item in result["speakers"]
    }
    corrections = {item["id"]: item["text"] for item in result["corrections"]}
    dropped = set(result["drop_ids"])
    lines = [
        Line(
            id=line.id,
            time=line.time,
            speaker=names.get(segments[line.id].speaker, line.speaker),
            language=line.language,
            text=corrections.get(line.id, line.text),
        )
        for line in plain_lines(segments, recording, config)
        if line.id not in dropped
    ]
    log.info("Cleaned transcript: %d speakers named, %d corrections, %d dropped",
             len(names), len(corrections), len(dropped))  # fmt: skip
    cache.write_text(
        json.dumps({"speakers": result["speakers"], "lines": [asdict(line) for line in lines]},
                   ensure_ascii=False, indent=1) + "\n",
        encoding="utf-8",
    )  # fmt: skip
    return lines


def summarize(
    lines: list[Line], recording: Recording, config: Config, runner: ClaudeRunner
) -> dict[str, Any]:
    """Content of the note (summary, tasks, chosen frames …). Cached in summary.json."""
    cache = recording.folder / SUMMARY_FILE
    if cache.is_file():
        return json.loads(cache.read_text(encoding="utf-8"))

    frames = recording.meta.get("frames") or []
    frames_text = (
        "\n".join(
            f"- {frame['file']} ({clock(recording, frame['offsetSeconds'])})" for frame in frames
        )
        or "(žádné snímky)"
    )
    participants = sorted({line.speaker for line in lines})
    prompt = Template((PROMPTS_DIR / "summary.md").read_text(encoding="utf-8")).substitute(
        user_name=config.user_name,
        meeting=meeting_text(recording),
        participants=", ".join(participants) or participants_text(recording),
        frames=frames_text,
        transcript="\n".join(f"[{line.time}] {line.speaker}: {line.text}" for line in lines),
    )
    result = runner(prompt, SUMMARY_SCHEMA, cwd=recording.folder, allowed_tools=("Read",))

    # Only frames that really exist in this recording.
    known = {frame["file"] for frame in frames}
    result["shared_content"] = [item for item in result["shared_content"] if item["frame"] in known]
    log.info("Summary: %d tasks for the user, %d frames chosen",
             len(result["my_tasks"]), len(result["shared_content"]))  # fmt: skip
    cache.write_text(json.dumps(result, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    return result
