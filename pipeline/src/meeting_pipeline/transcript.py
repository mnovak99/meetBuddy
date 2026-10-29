"""Transcript of a meeting: who said what and when, built from both audio tracks.

- audio.m4a (the other participants): diarization splits it into speaker turns, each chunk of
  consecutive turns of one speaker is transcribed separately, so Czech and Slovak speakers get
  their own language.
- mic.m4a (the user): loud parts are transcribed as speaker "USER".

Language detection needs a few seconds of speech. Chunks shorter than SHORT_CHUNK_SECONDS take
the language detected for the same speaker in longer chunks (or the meeting's main language).
A chunk detected as a language outside `languages` (`transcriptLanguages` in config.json) is
redone in the first one: short or noisy chunks are misdetected now and then.
"""

import logging
from collections import Counter
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import datetime
from pathlib import Path
from typing import Protocol

import numpy as np

from meeting_pipeline.audio import cut, speech_regions
from meeting_pipeline.files import read_json, write_json, write_text
from meeting_pipeline.models import RawSegment, Turn

log = logging.getLogger(__name__)

USER_SPEAKER = "USER"
ALLOWED_LANGUAGES = ("cs", "sk", "en")
DEFAULT_LANGUAGE = ALLOWED_LANGUAGES[0]
SHORT_CHUNK_SECONDS = 3.0
# Shorter pieces ("mhm", a cough) carry no words worth having; Whisper only invents text in them.
MIN_CHUNK_SECONDS = 1.0
# A little audio around each chunk, so Whisper does not cut words at the edges.
CHUNK_PADDING = 0.2
TRANSCRIPT_FILE = "transcript.json"
TRANSCRIPT_TEXT_FILE = "transcript.txt"
SCHEMA_VERSION = 1


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    speaker: str
    track: str  # "app" or "mic"
    language: str
    text: str


class Transcriber(Protocol):
    def __call__(
        self, samples: np.ndarray, *, initial_prompt: str | None, language: str | None
    ) -> tuple[str, list[RawSegment]]: ...


Progress = Callable[[int, int], None]


@dataclass(frozen=True)
class _Job:
    chunk: Turn
    track: str
    samples: np.ndarray


def speaker_chunks(
    turns: list[Turn],
    *,
    merge_gap: float = 1.0,
    max_duration: float = 60.0,
    min_duration: float = 0.4,
) -> list[Turn]:
    """Merge consecutive turns of the same speaker (short pauses, up to `max_duration`) and drop
    turns too short to contain a word."""
    chunks: list[Turn] = []
    for turn in sorted(turns, key=lambda t: t.start):
        last = chunks[-1] if chunks else None
        if (
            last
            and last.speaker == turn.speaker
            and turn.start - last.end <= merge_gap
            and turn.end - last.start <= max_duration
        ):
            chunks[-1] = Turn(last.start, max(last.end, turn.end), last.speaker)
        else:
            chunks.append(turn)
    return [chunk for chunk in chunks if chunk.duration >= min_duration]


def build_transcript(
    app_samples: np.ndarray,
    mic_samples: np.ndarray | None,
    turns: list[Turn],
    transcriber: Transcriber,
    initial_prompt: str | None,
    progress: Progress | None = None,
    *,
    languages: Sequence[str] = ALLOWED_LANGUAGES,
    default_language: str | None = None,
) -> list[Segment]:
    """`languages`: what Whisper may detect; anything else is redone in `default_language`
    (the first of `languages` unless given)."""
    fallback = default_language or (languages[0] if languages else DEFAULT_LANGUAGE)
    jobs = [
        _Job(chunk, "app", app_samples)
        for chunk in speaker_chunks(turns, min_duration=MIN_CHUNK_SECONDS)
    ]
    if mic_samples is not None:
        jobs += [
            _Job(Turn(start, end, USER_SPEAKER), "mic", mic_samples)
            for start, end in speech_regions(mic_samples)
            if end - start >= MIN_CHUNK_SECONDS
        ]
    total = len(jobs)
    done = 0

    def run(job: _Job, language: str | None) -> tuple[str, list[Segment]]:
        nonlocal done
        start = max(0.0, job.chunk.start - CHUNK_PADDING)
        end = job.chunk.end + CHUNK_PADDING
        detected, raw = transcriber(
            cut(job.samples, start, end), initial_prompt=initial_prompt, language=language
        )
        if language is None and detected not in languages:
            # Misdetection on a short or noisy chunk: redo it in the meeting's usual language.
            detected, raw = transcriber(
                cut(job.samples, start, end), initial_prompt=initial_prompt, language=fallback
            )
        done += 1
        if progress:
            progress(done, total)
        segments = [
            Segment(
                start=round(start + piece.start, 2),
                end=round(min(start + piece.end, end), 2),
                speaker=job.chunk.speaker,
                track=job.track,
                language=detected,
                text=piece.text,
            )
            for piece in raw
        ]
        return detected, segments

    # Pass 1: chunks long enough to detect their language.
    segments: list[Segment] = []
    found_languages: dict[str, Counter[str]] = {}
    for job in jobs:
        if job.chunk.duration >= SHORT_CHUNK_SECONDS:
            detected, found = run(job, None)
            found_languages.setdefault(job.chunk.speaker, Counter())[detected] += 1
            segments += found

    # Pass 2: short chunks ("jo", "ok") reuse the speaker's or the meeting's language.
    overall = sum(found_languages.values(), Counter())
    meeting_language = overall.most_common(1)[0][0] if overall else fallback
    for job in jobs:
        if job.chunk.duration < SHORT_CHUNK_SECONDS:
            counter = found_languages.get(job.chunk.speaker)
            language = counter.most_common(1)[0][0] if counter else meeting_language
            segments += run(job, language)[1]

    return sorted(segments, key=lambda s: (s.start, s.track))


def save_transcript(
    folder: Path,
    segments: list[Segment],
    models: dict[str, str | None],
    warning: str | None = None,
) -> None:
    """transcript.json (the cache, with the models that made it) and transcript.txt to read."""
    payload = {
        "schemaVersion": SCHEMA_VERSION,
        "createdAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        "models": models,
        "warning": warning,
        "segments": [asdict(segment) for segment in segments],
    }
    write_json(folder / TRANSCRIPT_FILE, payload)
    write_text(folder / TRANSCRIPT_TEXT_FILE, transcript_text(segments))


def load_transcript(folder: Path) -> tuple[list[Segment], str | None] | None:
    """The cached segments and the warning of transcript.json; None when it is missing or
    damaged (then the transcription is redone)."""
    data = read_json(folder / TRANSCRIPT_FILE)
    if data is None:
        return None
    try:
        return [Segment(**item) for item in data["segments"]], data.get("warning")
    except (KeyError, TypeError) as exc:
        log.warning("Ignoring damaged %s (%s); transcribing again", TRANSCRIPT_FILE, exc)
        return None


def transcript_text(segments: list[Segment]) -> str:
    """Readable form for checking the transcription: "[00:12:34] SPEAKER_00 (sk): text"."""
    lines = []
    for segment in segments:
        seconds = int(segment.start)
        stamp = f"{seconds // 3600:02d}:{seconds % 3600 // 60:02d}:{seconds % 60:02d}"
        lines.append(f"[{stamp}] {segment.speaker} ({segment.language}): {segment.text}")
    return "\n".join(lines) + "\n"
