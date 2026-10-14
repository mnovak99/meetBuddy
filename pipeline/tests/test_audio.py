from pathlib import Path

import numpy as np
from conftest import RATE, silence, tone, write_m4a

from meeting_pipeline.audio import load_audio, speech_regions


def test_speech_region_is_found() -> None:
    samples = np.concatenate([silence(1), tone(2), silence(2)])

    regions = speech_regions(samples, padding=0)

    assert len(regions) == 1
    start, end = regions[0]
    assert abs(start - 1.0) < 0.05
    assert abs(end - 3.0) < 0.05


def test_clicks_are_ignored_and_short_pauses_bridged() -> None:
    samples = np.concatenate(
        [
            silence(1),
            tone(0.1),
            silence(2),  # a click
            tone(1),
            silence(0.5),
            tone(1),
            silence(1),  # one utterance with a short pause
        ]
    )

    regions = speech_regions(samples, padding=0)

    assert len(regions) == 1
    assert abs(regions[0][0] - 3.1) < 0.05
    assert abs(regions[0][1] - 5.6) < 0.05


def test_silence_has_no_regions() -> None:
    assert speech_regions(silence(5)) == []


def test_m4a_is_decoded_to_16_khz(tmp_path: Path) -> None:
    path = tmp_path / "tone.m4a"
    write_m4a(tone(1.0), path)

    samples = load_audio(path)

    assert abs(len(samples) - RATE) < 0.1 * RATE  # AAC adds a little padding
    assert samples.dtype == np.float32
    assert 0.2 < np.abs(samples).max() <= 1.0
