"""Audio loading and simple speech detection.

Both models get the audio as a 16 kHz mono float32 NumPy array. Decoding uses macOS' built-in
`afconvert` (m4a → WAV), so no extra decoder is needed on our side.
"""

import subprocess
import tempfile
import wave
from pathlib import Path

import numpy as np

SAMPLE_RATE = 16_000


class AudioError(Exception):
    pass


def load_audio(path: Path) -> np.ndarray:
    """Decode any file afconvert understands to 16 kHz mono float32 samples in [-1, 1]."""
    with tempfile.TemporaryDirectory(prefix="meeting-pipeline-") as tmp:
        wav = Path(tmp) / "audio.wav"
        result = subprocess.run(
            [
                "/usr/bin/afconvert",
                "-f",
                "WAVE",
                "-d",
                f"LEI16@{SAMPLE_RATE}",
                "-c",
                "1",
                str(path),
                str(wav),
            ],
            capture_output=True,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise AudioError(f"afconvert failed for {path.name}: {result.stderr.strip()}")
        with wave.open(str(wav), "rb") as reader:
            frames = reader.readframes(reader.getnframes())
    return np.frombuffer(frames, dtype="<i2").astype(np.float32) / 32768.0


def speech_regions(
    samples: np.ndarray,
    sample_rate: int = SAMPLE_RATE,
    *,
    threshold_db: float = -45.0,
    frame_seconds: float = 0.03,
    min_speech: float = 0.3,
    merge_gap: float = 1.0,
    padding: float = 0.2,
) -> list[tuple[float, float]]:
    """(start, end) seconds of loud parts, e.g. the user speaking into the microphone.

    Energy-based: good enough for a close headset microphone; when the user is muted, the track is
    digital silence. Short clicks are dropped, pauses shorter than `merge_gap` are bridged.
    """
    frame = max(1, int(frame_seconds * sample_rate))
    count = len(samples) // frame
    if count == 0:
        return []
    frames = samples[: count * frame].reshape(count, frame)
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))
    loud = 20 * np.log10(np.maximum(rms, 1e-10)) > threshold_db

    regions: list[tuple[float, float]] = []
    start: int | None = None
    for index, is_loud in enumerate(loud):
        if is_loud and start is None:
            start = index
        elif not is_loud and start is not None:
            regions.append((start * frame_seconds, index * frame_seconds))
            start = None
    if start is not None:
        regions.append((start * frame_seconds, count * frame_seconds))

    merged: list[tuple[float, float]] = []
    for begin, end in regions:
        if merged and begin - merged[-1][1] <= merge_gap:
            merged[-1] = (merged[-1][0], end)
        else:
            merged.append((begin, end))

    duration = len(samples) / sample_rate
    return [
        (max(0.0, begin - padding), min(duration, end + padding))
        for begin, end in merged
        if end - begin >= min_speech
    ]


def cut(
    samples: np.ndarray, start: float, end: float, sample_rate: int = SAMPLE_RATE
) -> np.ndarray:
    return samples[int(start * sample_rate) : int(end * sample_rate)]
