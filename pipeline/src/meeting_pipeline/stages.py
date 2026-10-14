"""Pipeline stages. Each stage keeps its result in the recording folder, so a re-run (after a
crash, a Claude usage limit or a fix) skips work that is already done."""

import json
import logging
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from pathlib import Path

import numpy as np

from meeting_pipeline import models
from meeting_pipeline.audio import load_audio, speech_regions
from meeting_pipeline.claude import ClaudeError, ClaudeRunner, run_claude
from meeting_pipeline.config import Config
from meeting_pipeline.keychain import hf_token
from meeting_pipeline.models import ModelError, Turn
from meeting_pipeline.note import NoteResult, write_note
from meeting_pipeline.recording import Recording
from meeting_pipeline.summarize import clean, plain_lines, summarize
from meeting_pipeline.transcript import (
    TRANSCRIPT_FILE,
    Segment,
    Transcriber,
    build_transcript,
    load_transcript,
    save_transcript,
)
from meeting_pipeline.vocabulary import Term, initial_prompt, load_vocabulary

log = logging.getLogger(__name__)

DIARIZATION_FILE = "diarization.json"


@dataclass
class Components:
    """The heavy parts, replaceable in tests."""

    diarize: Callable[[np.ndarray], list[Turn]]
    transcribe: Transcriber
    vocabulary: list[Term] = field(default_factory=list)
    claude: ClaudeRunner = run_claude


def default_components() -> Components:
    token = hf_token()
    return Components(
        diarize=lambda samples: models.diarize(samples, token),
        transcribe=models.transcribe,
        vocabulary=load_vocabulary(),
    )


def run_transcription(
    recording: Recording,
    components: Components,
    *,
    force: bool = False,
    report: Callable[[str], None] = lambda _: None,
) -> tuple[list[Segment], str | None]:
    """Diarize and transcribe; returns the transcript (from transcript.json if already done) and a
    warning when the speakers could not be told apart."""
    folder = recording.folder
    if (folder / TRANSCRIPT_FILE).is_file() and not force:
        log.info("Using existing %s", TRANSCRIPT_FILE)
        return load_transcript(folder), _transcript_warning(folder)

    report("Převádím zvuk")
    app = load_audio(recording.audio)
    mic = load_audio(recording.microphone) if recording.microphone else None

    warning: str | None = None
    turns = _cached_turns(folder) if not force else None
    if turns is None:
        report("Rozpoznávám mluvčí")
        try:
            turns = components.diarize(app)
            _save_turns(folder, turns)
        except ModelError as exc:
            # Better a note without speaker names than no note: transcribe the speech as one
            # speaker; Claude still tells people apart from the content where it can.
            warning = f"Bez rozlišení mluvčích: {exc}"
            log.warning("Diarization not available, continuing without it: %s", exc)
            turns = [Turn(start, end, "SPEAKER_00") for start, end in speech_regions(app)]
    speakers = len({turn.speaker for turn in turns})
    log.info("Diarization: %d turns, %d speakers", len(turns), speakers)

    def progress(done: int, total: int) -> None:
        report(f"Přepisuji {done}/{total}")

    prompt = initial_prompt(components.vocabulary)
    segments = build_transcript(app, mic, turns, components.transcribe, prompt, progress)
    save_transcript(
        folder,
        segments,
        {"asr": models.WHISPER_MODEL, "diarization": None if warning else models.DIARIZATION_MODEL},
        warning=warning,
    )
    log.info("Transcript: %d segments", len(segments))  # counts only, never the content
    return segments, warning


def _transcript_warning(folder: Path) -> str | None:
    data = json.loads((folder / TRANSCRIPT_FILE).read_text(encoding="utf-8"))
    return data.get("warning")


def run_note(
    recording: Recording,
    segments: list[Segment],
    components: Components,
    config: Config,
    *,
    report: Callable[[str], None] = lambda _: None,
) -> tuple[NoteResult, str | None]:
    """Clean, summarize and write the note. Returns the note and the Claude error, if any.

    Without Claude (usage limit, not logged in …) the note gets the transcript only and its status
    is needs_summary; running the pipeline again later adds the summary.
    """
    claude_error: str | None = None
    try:
        report("Čistím přepis a přiřazuji jména")
        lines = clean(segments, recording, config, components.vocabulary, components.claude)
        report("Píšu shrnutí")
        summary = summarize(lines, recording, config, components.claude)
    except ClaudeError as exc:
        log.warning("Claude not available: %s", exc)
        claude_error = str(exc)
        lines, summary = plain_lines(segments, recording, config), None
    report("Zapisuji poznámku do Obsidianu")
    return write_note(recording, lines, summary, config), claude_error


def _cached_turns(folder: Path) -> list[Turn] | None:
    path = folder / DIARIZATION_FILE
    if not path.is_file():
        return None
    return [Turn(**item) for item in json.loads(path.read_text(encoding="utf-8"))]


def _save_turns(folder: Path, turns: list[Turn]) -> None:
    (folder / DIARIZATION_FILE).write_text(
        json.dumps([asdict(turn) for turn in turns], indent=1) + "\n", encoding="utf-8"
    )
