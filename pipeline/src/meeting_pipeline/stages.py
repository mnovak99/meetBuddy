"""Pipeline stages. Each stage keeps its result in the recording folder, so a re-run (after a
crash, a Claude usage limit or a fix) skips work that is already done. Cache files are written
atomically and a damaged one is rebuilt instead of crashing the run (see files.py)."""

import logging
from collections.abc import Callable
from dataclasses import asdict, dataclass, field
from functools import partial
from pathlib import Path

import numpy as np

from meeting_pipeline import models
from meeting_pipeline.audio import load_audio, speech_regions
from meeting_pipeline.claude import ClaudeError, ClaudeRunner, run_claude
from meeting_pipeline.config import Config
from meeting_pipeline.files import read_json, write_json
from meeting_pipeline.keychain import hf_token
from meeting_pipeline.models import ModelError, Turn
from meeting_pipeline.note import NoteResult, write_note
from meeting_pipeline.recording import Recording
from meeting_pipeline.status import Reporter, State
from meeting_pipeline.summarize import Line, clean, plain_lines, summarize
from meeting_pipeline.transcript import (
    TRANSCRIPT_FILE,
    Segment,
    Transcriber,
    build_transcript,
    load_transcript,
    save_transcript,
)
from meeting_pipeline.vocabulary import (
    SUGGESTIONS_FILE,
    Term,
    initial_prompt,
    load_vocabulary,
    whisper_token_counter,
)

log = logging.getLogger(__name__)

DIARIZATION_FILE = "diarization.json"


def _no_report(_state: State, _message: str) -> None:
    pass


@dataclass
class Components:
    """The heavy parts, replaceable in tests."""

    diarize: Callable[[np.ndarray], list[Turn]]
    transcribe: Transcriber
    vocabulary: list[Term] = field(default_factory=list)
    claude: ClaudeRunner = run_claude
    # Where Claude's vocabulary suggestions go (None in tests: not written).
    suggestions_path: Path | None = None
    count_tokens: Callable[[str], int] | None = None


def default_components(config: Config) -> Components:
    """The real models and Claude, set up from config.json (model names, threads)."""
    token = hf_token()
    return Components(
        diarize=partial(models.diarize, token=token, threads=config.pipeline_threads),
        transcribe=partial(models.transcribe, model=config.whisper_model),
        vocabulary=load_vocabulary(),
        claude=partial(run_claude, model=config.claude_model or None),
        suggestions_path=SUGGESTIONS_FILE,
        count_tokens=whisper_token_counter(),
    )


CACHE_FILES = (DIARIZATION_FILE, TRANSCRIPT_FILE, "transcript.txt", "cleaned.json", "summary.json")


def clear_caches(folder: Path) -> None:
    """For a fresh run ("Přepsat znovu od začátku"): forget all intermediate results."""
    for name in CACHE_FILES:
        (folder / name).unlink(missing_ok=True)


def run_transcription(
    recording: Recording,
    components: Components,
    config: Config,
    *,
    force: bool = False,
    report: Reporter = _no_report,
) -> tuple[list[Segment], str | None]:
    """Diarize and transcribe; returns the transcript (from transcript.json if already done) and a
    warning when the speakers could not be told apart."""
    folder = recording.folder
    if not force and (cached := load_transcript(folder)) is not None:
        log.info("Using existing %s", TRANSCRIPT_FILE)
        return cached

    report(State.TRANSCRIBING, "Převádím zvuk")
    app = load_audio(recording.audio)
    mic = load_audio(recording.microphone) if recording.microphone else None

    warning: str | None = None
    turns = _cached_turns(folder) if not force else None
    if turns is None:
        report(State.TRANSCRIBING, "Rozpoznávám mluvčí")
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
        report(State.TRANSCRIBING, f"Přepisuji {done}/{total}")

    if components.count_tokens:
        prompt = initial_prompt(components.vocabulary, count_tokens=components.count_tokens)
    else:
        prompt = initial_prompt(components.vocabulary)
    segments = build_transcript(
        app, mic, turns, components.transcribe, prompt, progress,
        languages=config.transcript_languages,
    )  # fmt: skip
    save_transcript(
        folder,
        segments,
        {"asr": config.whisper_model, "diarization": None if warning else models.DIARIZATION_MODEL},
        warning=warning,
    )
    log.info("Transcript: %d segments", len(segments))  # counts only, never the content
    return segments, warning


def run_note(
    recording: Recording,
    segments: list[Segment],
    components: Components,
    config: Config,
    *,
    report: Reporter = _no_report,
) -> tuple[NoteResult, str | None]:
    """Clean, summarize and write the note. Returns the note and the Claude error, if any.

    Without Claude (usage limit, not logged in …) the note gets the transcript only and its status
    is needs_summary; running the pipeline again later adds the summary. When only the summary
    fails, the cleaned lines (names, corrections) are still used for the note.

    The note on disk says `status: processing` until note.finish_note() is called (after the
    final status.json), see note.py.
    """
    lines, summary, claude_error = run_summary(
        recording, segments, components, config, report=report
    )
    report(State.WRITING, "Zapisuji poznámku do Obsidianu")
    return write_note(recording, lines, summary, config), claude_error


def run_summary(
    recording: Recording,
    segments: list[Segment],
    components: Components,
    config: Config,
    *,
    report: Reporter = _no_report,
) -> tuple[list[Line], dict | None, str | None]:
    """The two Claude steps. Returns the lines, the summary (None without Claude) and the error."""
    report(State.SUMMARIZING, "Čistím přepis a přiřazuji jména")
    try:
        lines = clean(
            segments, recording, config, components.vocabulary, components.claude,
            components.suggestions_path,
        )  # fmt: skip
    except ClaudeError as exc:
        log.warning("Claude not available for the cleanup: %s", exc)
        return plain_lines(segments, recording, config, components.vocabulary), None, str(exc)
    report(State.SUMMARIZING, "Píšu shrnutí")
    try:
        summary = summarize(lines, recording, config, components.claude)
    except ClaudeError as exc:
        log.warning("Claude not available for the summary: %s", exc)
        return lines, None, str(exc)
    return lines, summary, None


def _cached_turns(folder: Path) -> list[Turn] | None:
    data = read_json(folder / DIARIZATION_FILE)
    if data is None:
        return None
    try:
        return [Turn(**item) for item in data]
    except (TypeError, ValueError) as exc:
        log.warning("Ignoring damaged %s (%s); diarizing again", DIARIZATION_FILE, exc)
        return None


def _save_turns(folder: Path, turns: list[Turn]) -> None:
    write_json(folder / DIARIZATION_FILE, [asdict(turn) for turn in turns])
