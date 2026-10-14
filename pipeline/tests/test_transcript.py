import numpy as np
from conftest import FakeTranscriber, silence, tone

from meeting_pipeline.models import Turn
from meeting_pipeline.transcript import (
    USER_SPEAKER,
    Segment,
    build_transcript,
    speaker_chunks,
    transcript_text,
)


def test_turns_of_one_speaker_are_merged() -> None:
    turns = [Turn(0, 2, "A"), Turn(2.5, 4, "A"), Turn(4.2, 6, "B"), Turn(9, 10, "B")]

    chunks = speaker_chunks(turns)

    assert chunks == [Turn(0, 4, "A"), Turn(4.2, 6, "B"), Turn(9, 10, "B")]


def test_tiny_turns_are_dropped() -> None:
    assert speaker_chunks([Turn(0, 0.2, "A"), Turn(1, 3, "B")]) == [Turn(1, 3, "B")]


def test_long_chunks_are_split_at_max_duration() -> None:
    turns = [Turn(i, i + 1, "A") for i in range(0, 100, 1)]
    chunks = speaker_chunks(turns, max_duration=60)
    assert all(chunk.duration <= 60 for chunk in chunks)
    assert len(chunks) == 2


def test_short_chunks_take_the_language_of_their_speaker() -> None:
    samples = silence(40)
    turns = [Turn(0, 10, "A"), Turn(12, 13, "A"), Turn(20, 30, "B"), Turn(33, 34, "B")]
    transcriber = FakeTranscriber(languages=["cs", "sk"])  # detected for A, then B

    segments = build_transcript(samples, None, turns, transcriber, None)

    by_speaker = {(s.speaker, s.language) for s in segments}
    assert by_speaker == {("A", "cs"), ("B", "sk")}
    # Long chunks: detected (None), short chunks: the speaker's language.
    assert [language for _, language in transcriber.calls] == [None, None, "cs", "sk"]


def test_unexpected_language_is_redone_in_czech() -> None:
    transcriber = FakeTranscriber(languages=["ja"])

    segments = build_transcript(silence(10), None, [Turn(0, 8, "A")], transcriber, None)

    assert [language for _, language in transcriber.calls] == [None, "cs"]
    assert segments[0].language == "cs"


def test_microphone_speech_is_the_user() -> None:
    mic = np.concatenate([silence(2), tone(4, amplitude=0.2), silence(2)])
    transcriber = FakeTranscriber(languages=["cs"])

    segments = build_transcript(silence(8), mic, [], transcriber, None)

    assert len(segments) == 1
    assert segments[0].speaker == USER_SPEAKER
    assert segments[0].track == "mic"
    assert 1.5 < segments[0].start < 2.0


def test_segments_are_sorted_by_time() -> None:
    mic = np.concatenate([silence(1), tone(4, amplitude=0.2), silence(10)])
    transcriber = FakeTranscriber()

    segments = build_transcript(silence(15), mic, [Turn(6, 12, "A")], transcriber, None)

    assert [s.speaker for s in segments] == [USER_SPEAKER, "A"]


def test_readable_text() -> None:
    text = transcript_text([Segment(3725.4, 3727, "SPEAKER_00", "app", "sk", "Dobrý deň")])
    assert text == "[01:02:05] SPEAKER_00 (sk): Dobrý deň\n"


def test_pieces_shorter_than_a_second_are_not_transcribed() -> None:
    transcriber = FakeTranscriber(languages=["cs"])
    turns = [Turn(0, 5, "A"), Turn(8, 8.6, "B"), Turn(10, 10.4, "A")]

    segments = build_transcript(silence(12), None, turns, transcriber, None)

    assert [s.speaker for s in segments] == ["A"]
    assert len(transcriber.calls) == 1


def test_token_budget_follows_the_chunk_length() -> None:
    from meeting_pipeline.models import max_tokens

    assert max_tokens(1.0) == 24
    assert max_tokens(60.0) == 224  # Whisper's own maximum per 30 s window
