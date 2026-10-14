"""The two local models: pyannote (who speaks when) and mlx-whisper (what is said).

Both run on this Mac; audio never leaves it. Heavy imports happen inside the functions, so the
rest of the pipeline (and its tests) work without loading PyTorch or MLX.
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


def diarize(samples: np.ndarray, token: str | None) -> list[Turn]:
    """Speaker turns without overlaps ("exclusive" diarization, meant for transcription)."""
    # Must be set before pyannote is imported: no usage statistics are sent anywhere.
    os.environ["PYANNOTE_METRICS_ENABLED"] = "0"
    import torch
    from pyannote.audio import Pipeline

    if not token:
        raise ModelError(
            "Hugging Face token missing: store it with "
            '`security add-generic-password -a "$USER" -s "MeetingAssistant HF token" -w`'
        )
    torch.set_num_threads(TORCH_THREADS)
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
    output = pipeline({"waveform": waveform, "sample_rate": SAMPLE_RATE})
    annotation = getattr(output, "exclusive_speaker_diarization", output)
    return [
        Turn(start=float(segment.start), end=float(segment.end), speaker=str(label))
        for segment, _, label in annotation.itertracks(yield_label=True)
    ]


def transcribe(
    samples: np.ndarray, *, initial_prompt: str | None, language: str | None
) -> tuple[str, list[RawSegment]]:
    """Transcribe one chunk. `language=None` lets Whisper detect it from the first 30 s."""
    import mlx_whisper

    result = mlx_whisper.transcribe(
        samples,
        path_or_hf_repo=WHISPER_MODEL,
        initial_prompt=initial_prompt,
        language=language,
        # Each chunk stands alone; carrying text over makes Whisper repeat itself in silence.
        condition_on_previous_text=False,
        verbose=None,
    )
    segments = [
        RawSegment(start=float(s["start"]), end=float(s["end"]), text=s["text"].strip())
        for s in result["segments"]
        if s["text"].strip()
    ]
    return str(result["language"]), segments
