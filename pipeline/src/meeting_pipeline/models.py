"""The two local models: pyannote (who speaks when) and mlx-whisper (what is said).

Both run on this Mac; audio never leaves it. Heavy imports happen inside the functions, so the
rest of the pipeline (and its tests) work without loading PyTorch or MLX. Every failure of a
model (download, loading, inference) is raised as ModelError, so the CLI can report it in
status.json instead of dying with a traceback.
"""

import logging
import os
from dataclasses import dataclass

import numpy as np

from meeting_pipeline.audio import SAMPLE_RATE

log = logging.getLogger(__name__)

DIARIZATION_MODEL = "pyannote/speaker-diarization-community-1"
WHISPER_MODEL = "mlx-community/whisper-large-v3-turbo"
# Leave CPU for VS Code and Docker: the pipeline runs in the background anyway.
TORCH_THREADS = 4


class ModelError(Exception):
    pass


@dataclass(frozen=True)
class Turn:
    """One speaker turn from diarization, in seconds."""

    start: float
    end: float
    speaker: str

    @property
    def duration(self) -> float:
        return self.end - self.start


@dataclass(frozen=True)
class RawSegment:
    """A piece of Whisper output, relative to the start of the audio it was given."""

    start: float
    end: float
    text: str


def diarize(samples: np.ndarray, token: str | None, *, threads: int = TORCH_THREADS) -> list[Turn]:
    """Speaker turns without overlaps ("exclusive" diarization, meant for transcription).

    `threads` = CPU threads for PyTorch (`pipelineThreads` in config.json).
    """
    # Must be set before pyannote is imported: no usage statistics are sent anywhere.
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    try:
        import torch
        from pyannote.audio import Pipeline
    except ImportError as exc:
        raise ModelError(f"pyannote.audio is not installed: {exc}") from exc

    if not token:
        raise ModelError(
            "Hugging Face token missing: store it with "
            '`security add-generic-password -a "$USER" -s "MeetingAssistant HF token" -w`'
        )
    torch.set_num_threads(threads)
    try:
        pipeline = Pipeline.from_pretrained(DIARIZATION_MODEL, token=token)
    except Exception as exc:  # the hub raises various HTTP errors for gated models
        text = str(exc)
        if any(hint in text for hint in ("403", "gated", "restricted", "accept")):
            raise ModelError(
                f"Model {DIARIZATION_MODEL} není přístupný: potvrď jeho podmínky na "
                f"https://huggingface.co/{DIARIZATION_MODEL}"
            ) from exc
        raise ModelError(f"Cannot load {DIARIZATION_MODEL}: {text[:300]}") from exc
    if pipeline is None:
        raise ModelError(
            f"Cannot load {DIARIZATION_MODEL}: accept its conditions on huggingface.co "
            "with the account of the token"
        )
    if torch.backends.mps.is_available():
        pipeline.to(torch.device("mps"))

    waveform = torch.from_numpy(samples).unsqueeze(0)  # (channel, time)
    try:
        output = pipeline({"waveform": waveform, "sample_rate": SAMPLE_RATE})
    except Exception as exc:  # out of memory, a broken model file, an MPS error …
        raise ModelError(f"Diarization failed: {type(exc).__name__}: {str(exc)[:300]}") from exc
    annotation = getattr(output, "exclusive_speaker_diarization", output)
    return [
        Turn(start=float(segment.start), end=float(segment.end), speaker=str(label))
        for segment, _, label in annotation.itertracks(yield_label=True)
    ]


def transcribe(
    samples: np.ndarray,
    *,
    initial_prompt: str | None,
    language: str | None,
    model: str = WHISPER_MODEL,
) -> tuple[str, list[RawSegment]]:
    """Transcribe one chunk. `language=None` lets Whisper detect it from the first 30 s.

    `model` is a Hugging Face repo of an MLX Whisper model (`whisperModel` in config.json).
    """
    try:
        import mlx_whisper
    except ImportError as exc:
        raise ModelError(f"mlx-whisper is not installed: {exc}") from exc

    try:
        result = mlx_whisper.transcribe(
            samples,
            path_or_hf_repo=model,
            initial_prompt=initial_prompt,
            language=language,
            # Each chunk stands alone; carrying text over makes Whisper repeat itself in silence.
            condition_on_previous_text=False,
            verbose=None,
            sample_len=max_tokens(len(samples) / SAMPLE_RATE),
        )
    except Exception as exc:  # unknown repo, failed download, MLX error …
        raise ModelError(
            f"Whisper ({model}) failed: {type(exc).__name__}: {str(exc)[:300]}"
        ) from exc
    segments = [
        RawSegment(start=float(s["start"]), end=float(s["end"]), text=s["text"].strip())
        for s in result["segments"]
        if s["text"].strip()
    ]
    return str(result["language"]), segments


def max_tokens(seconds: float) -> int:
    """Upper bound of tokens Whisper may generate for a chunk (its own maximum is 224 per window).

    Speech has at most ~8 tokens per second. Without this bound, a hallucination on a nearly
    silent chunk runs to 224 tokens at every one of Whisper's six temperature retries, which on
    a busy GPU at background priority takes many minutes.
    """
    return min(224, int(seconds * 8) + 16)
