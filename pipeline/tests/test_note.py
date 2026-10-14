import json
from pathlib import Path

import pytest
from conftest import fake_claude

from meeting_pipeline.claude import ClaudeError
from meeting_pipeline.config import Config
from meeting_pipeline.note import clean_title, write_note
from meeting_pipeline.recording import Recording
from meeting_pipeline.stages import Components, run_note
from meeting_pipeline.transcript import Segment


@pytest.fixture
def recording(tmp_path: Path) -> Recording:
    folder = tmp_path / "recording"
    (folder / "frames").mkdir(parents=True)
    (folder / "frames" / "140005.jpg").write_bytes(b"\xff\xd8 fake jpeg")
    (folder / "frames" / "140010.jpg").write_bytes(b"\xff\xd8 fake jpeg")
    meta = {
        "source": "teams",
        "startedAt": "2026-10-14T14:00:00+02:00",
        "endedAt": "2026-10-14T15:05:00+02:00",
        "calendar": {"title": "Sprint: planning / Q4", "attendees": [{"name": "Petr Novák"}]},
        "frames": [
            {"file": "frames/140005.jpg", "offsetSeconds": 5},
            {"file": "frames/140010.jpg", "offsetSeconds": 10},
        ],
    }
    (folder / "meta.json").write_text(json.dumps(meta), encoding="utf-8")
    return Recording(folder=folder, meta=meta)


SEGMENTS = [
    Segment(1.0, 3.0, "SPEAKER_00", "app", "cs", "Ahoj, jak to vypadá s odhadem?"),
    Segment(4.0, 6.0, "USER", "mic", "cs", "Pošlu ho do pátku."),
    Segment(7.0, 9.0, "SPEAKER_01", "app", "sk", "Dobre, ďakujem."),
]


def components(claude=fake_claude) -> Components:
    return Components(diarize=lambda s: [], transcribe=None, claude=claude)  # type: ignore[arg-type]


def config(vault: Path) -> Config:
    return Config(user_name="Matej", obsidian_vault_path=str(vault))


def test_full_note(recording: Recording, vault: Path) -> None:
    note, error = run_note(recording, SEGMENTS, components(), config(vault))

    assert error is None
    assert note.path == vault / "Meetings/2026/10/2026-10-14 1400 Sprint planning Q4.md"
    text = note.path.read_text(encoding="utf-8")
    assert text.startswith('---\ndate: 2026-10-14\nstart: "14:00"\nend: "15:05"\napp: Teams\n')
    assert 'participants: ["Matej", "Petr Novák", "Jana (?)"]' in text
    assert "status: done" in text
    assert "> [!summary] Shrnutí\n> Probírali jsme plán sprintu." in text
    assert "- [ ] Připravit odhad (do pátku)" in text
    assert "- [ ] **Petr Novák**: Poslat specifikaci" in text
    assert "## Rozhodnutí" not in text  # empty sections are left out
    assert "![[attachments/2026-10-14 1400/140005.jpg]]" in text
    assert "> **[14:00:01] Petr Novák:** Opravený text" in text  # correction from Claude
    assert "> **[14:00:04] Matej:** Pošlu ho do pátku." in text


def test_chosen_frames_are_copied(recording: Recording, vault: Path) -> None:
    note, _ = run_note(recording, SEGMENTS, components(), config(vault))

    attachments = vault / "Meetings/2026/10/attachments/2026-10-14 1400"
    assert [p.name for p in attachments.iterdir()] == ["140005.jpg"]
    result = json.loads((recording.folder / "note.json").read_text(encoding="utf-8"))
    assert result["selectedFrames"] == ["frames/140005.jpg"]
    assert result["notePath"] == str(note.path)


def test_tasks_are_appended_once(recording: Recording, vault: Path) -> None:
    run_note(recording, SEGMENTS, components(), config(vault))
    # A second meeting with the same task text links to another note; the same note never twice.
    write_note(
        recording, [], json.loads((recording.folder / "summary.json").read_text()), config(vault)
    )

    tasks = (vault / "Meetings/Moje úkoly.md").read_text(encoding="utf-8")
    assert tasks.count("Připravit odhad (do pátku) ([[2026-10-14 1400 Sprint planning Q4]])") == 1
    assert "([[2026-10-14 1400 Sprint planning Q4 (2)]])" in tasks


def test_without_claude_the_note_has_the_transcript_only(recording: Recording, vault: Path) -> None:
    def unavailable(*args, **kwargs):
        raise ClaudeError("usage limit")

    note, error = run_note(recording, SEGMENTS, components(unavailable), config(vault))

    assert error == "usage limit"
    assert note.status == "needs_summary"
    text = note.path.read_text(encoding="utf-8")
    assert "status: needs_summary" in text
    assert "> [!warning] Shrnutí zatím chybí" in text
    assert "> **[14:00:01] SPEAKER_00:** Ahoj, jak to vypadá s odhadem?" in text
    assert not (vault / "Meetings/Moje úkoly.md").exists()


def test_rerun_after_usage_limit_replaces_the_unfinished_note(
    recording: Recording, vault: Path
) -> None:
    def unavailable(*args, **kwargs):
        raise ClaudeError("usage limit")

    first, _ = run_note(recording, SEGMENTS, components(unavailable), config(vault))
    second, _ = run_note(recording, SEGMENTS, components(), config(vault))

    assert second.path == first.path
    assert "status: done" in second.path.read_text(encoding="utf-8")


def test_edited_note_is_never_overwritten(recording: Recording, vault: Path) -> None:
    first, _ = run_note(recording, SEGMENTS, components(), config(vault))
    first.path.write_text(first.path.read_text() + "\nMoje poznámka.\n", encoding="utf-8")

    second = write_note(recording, [], None, config(vault))

    assert second.path.name == "2026-10-14 1400 Sprint planning Q4 (2).md"
    assert "Moje poznámka." in first.path.read_text(encoding="utf-8")


def test_note_without_calendar_is_named_by_date(recording: Recording, vault: Path) -> None:
    recording.meta.pop("calendar")
    note = write_note(recording, [], None, config(vault))
    assert note.path.name == "2026-10-14 1400.md"
    assert "# Meeting 14. 10. 2026 14:00" in note.path.read_text(encoding="utf-8")


def test_missing_vault_is_an_error(recording: Recording, tmp_path: Path) -> None:
    from meeting_pipeline.note import NoteError

    with pytest.raises(NoteError):
        write_note(recording, [], None, config(tmp_path / "nonexistent"))


@pytest.mark.parametrize(
    ("title", "expected"),
    [
        ("Sprint: planning / Q4", "Sprint planning Q4"),
        ("[ACME] #standup?", "ACME standup"),
        ("", ""),
    ],
)
def test_clean_title(title: str, expected: str) -> None:
    assert clean_title(title) == expected


def test_vocabulary_suggestions_reach_the_queue(
    recording: Recording, vault: Path, tmp_path: Path
) -> None:
    queue = tmp_path / "vocabulary-suggestions.json"
    parts = Components(
        diarize=lambda s: [], transcribe=None, claude=fake_claude, suggestions_path=queue
    )  # type: ignore[arg-type]

    run_note(recording, SEGMENTS, parts, config(vault))

    suggestions = json.loads(queue.read_text(encoding="utf-8"))["suggestions"]
    assert [(s["term"], s["heardAs"], s["source"]) for s in suggestions] == [
        ("Grafana", ["grafána"], "recording")
    ]
