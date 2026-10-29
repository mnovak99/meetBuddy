import json
from pathlib import Path

import pytest
from conftest import fake_claude

from meeting_pipeline.claude import ClaudeError
from meeting_pipeline.config import Config
from meeting_pipeline.note import NoteResult, clean_title, finish_note, write_note
from meeting_pipeline.recording import Recording
from meeting_pipeline.stages import Components, run_note
from meeting_pipeline.status import State
from meeting_pipeline.transcript import Segment
from meeting_pipeline.vocabulary import Term


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


def components(claude=fake_claude, **overrides) -> Components:
    return Components(diarize=lambda s: [], transcribe=None, claude=claude, **overrides)  # type: ignore[arg-type]


def config(vault: Path, **overrides) -> Config:
    return Config(**{"user_name": "Matej", "obsidian_vault_path": str(vault), **overrides})


def process(recording: Recording, parts: Components, cfg: Config) -> tuple[NoteResult, str | None]:
    """What the CLI does: the Claude steps and the note, then the final status of the note once
    status.json is final."""
    note, error = run_note(recording, SEGMENTS, parts, cfg)
    finish_note(note)
    return note, error


def test_full_note(recording: Recording, vault: Path) -> None:
    note, error = process(recording, components(), config(vault))

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


def test_note_is_processing_until_finished(recording: Recording, vault: Path) -> None:
    note, _ = run_note(recording, SEGMENTS, components(), config(vault))

    assert note.status == "done"
    assert "status: processing" in note.path.read_text(encoding="utf-8")
    assert (
        json.loads((recording.folder / "note.json").read_text(encoding="utf-8"))["status"] == "done"
    )

    finish_note(note)

    assert "status: done" in note.path.read_text(encoding="utf-8")
    assert not list(note.path.parent.glob(".*.tmp"))


def test_summarizing_and_writing_are_reported(recording: Recording, vault: Path) -> None:
    states: list[State] = []
    run_note(
        recording, SEGMENTS, components(), config(vault),
        report=lambda state, message: states.append(state),
    )  # fmt: skip
    assert states == [State.SUMMARIZING, State.SUMMARIZING, State.WRITING]


def test_chosen_frames_are_copied(recording: Recording, vault: Path) -> None:
    note, _ = process(recording, components(), config(vault))

    attachments = vault / "Meetings/2026/10/attachments/2026-10-14 1400"
    assert [p.name for p in attachments.iterdir()] == ["140005.jpg"]
    result = json.loads((recording.folder / "note.json").read_text(encoding="utf-8"))
    assert result["selectedFrames"] == ["frames/140005.jpg"]
    assert result["notePath"] == str(note.path)


def test_frames_missing_from_disk_are_left_out(recording: Recording, vault: Path) -> None:
    prompts: list[str] = []

    def watching(prompt, schema, *, cwd, allowed_tools=()):
        prompts.append(prompt)
        return fake_claude(prompt, schema, cwd=cwd, allowed_tools=allowed_tools)

    # Trashed by the app after an earlier run; meta.json still lists it.
    (recording.folder / "frames" / "140005.jpg").unlink()

    note, error = process(recording, components(watching), config(vault))

    assert error is None
    assert "frames/140010.jpg" in prompts[1] and "frames/140005.jpg" not in prompts[1]
    assert note.selected_frames == []
    assert "![[" not in note.path.read_text(encoding="utf-8")


def test_cached_summary_naming_a_trashed_frame_does_not_crash(
    recording: Recording, vault: Path
) -> None:
    first, _ = process(recording, components(), config(vault))
    (recording.folder / "frames" / "140005.jpg").unlink()  # summary.json still names it

    second, error = process(recording, components(), config(vault))

    assert error is None
    assert first.selected_frames == ["frames/140005.jpg"] and second.selected_frames == []


def test_tasks_are_not_duplicated_by_a_second_copy_of_the_note(
    recording: Recording, vault: Path
) -> None:
    first, _ = process(recording, components(), config(vault))
    # The user edited the note, so a re-run writes "… (2).md" with the same tasks.
    first.path.write_text(first.path.read_text() + "\nMoje poznámka.\n", encoding="utf-8")

    second, _ = process(recording, components(), config(vault))

    assert second.path.name == "2026-10-14 1400 Sprint planning Q4 (2).md"
    tasks = (vault / "Meetings/Moje úkoly.md").read_text(encoding="utf-8")
    assert tasks.count("Připravit odhad (do pátku)") == 1
    assert "([[2026-10-14 1400 Sprint planning Q4]])" in tasks


def test_the_same_task_from_another_meeting_is_added(recording: Recording, vault: Path) -> None:
    process(recording, components(), config(vault))
    tasks_note = vault / "Meetings/Moje úkoly.md"
    done = tasks_note.read_text(encoding="utf-8").replace("- [ ] Připravit", "- [x] Připravit")
    tasks_note.write_text(done, encoding="utf-8")
    summary = json.loads((recording.folder / "summary.json").read_text(encoding="utf-8"))

    write_note(recording, [], summary, config(vault))  # the same meeting again: nothing new
    recording.meta["startedAt"] = "2026-10-15T09:00:00+02:00"
    write_note(recording, [], summary, config(vault))  # another meeting: a new line

    tasks = tasks_note.read_text(encoding="utf-8")
    assert tasks.count("Připravit odhad (do pátku)") == 2
    assert "- [x] Připravit odhad (do pátku) ([[2026-10-14 1400 Sprint planning Q4]])" in tasks
    assert "- [ ] Připravit odhad (do pátku) ([[2026-10-15 0900 Sprint planning Q4]])" in tasks


def test_without_claude_the_note_has_the_transcript_only(recording: Recording, vault: Path) -> None:
    def unavailable(*args, **kwargs):
        raise ClaudeError("usage limit")

    note, error = process(recording, components(unavailable), config(vault))

    assert error == "usage limit"
    assert note.status == "needs_summary"
    text = note.path.read_text(encoding="utf-8")
    assert "status: needs_summary" in text
    assert "> [!warning] Shrnutí zatím chybí" in text
    assert "> **[14:00:01] SPEAKER_00:** Ahoj, jak to vypadá s odhadem?" in text
    assert not (vault / "Meetings/Moje úkoly.md").exists()


def test_cleaned_lines_are_kept_when_only_the_summary_fails(
    recording: Recording, vault: Path
) -> None:
    def summary_unavailable(prompt, schema, *, cwd, allowed_tools=()):
        if "drop_ids" in schema["properties"]:
            return fake_claude(prompt, schema, cwd=cwd, allowed_tools=allowed_tools)
        raise ClaudeError("usage limit")

    note, error = process(recording, components(summary_unavailable), config(vault))

    assert error == "usage limit"
    assert note.status == "needs_summary"
    text = note.path.read_text(encoding="utf-8")
    assert "> **[14:00:01] Petr Novák:** Opravený text" in text  # names and corrections kept
    assert (recording.folder / "cleaned.json").is_file()
    assert not (recording.folder / "summary.json").exists()


def test_rerun_after_usage_limit_replaces_the_unfinished_note(
    recording: Recording, vault: Path
) -> None:
    def unavailable(*args, **kwargs):
        raise ClaudeError("usage limit")

    first, _ = process(recording, components(unavailable), config(vault))
    second, _ = process(recording, components(), config(vault))

    assert second.path == first.path
    assert "status: done" in second.path.read_text(encoding="utf-8")


def test_edited_note_is_never_overwritten(recording: Recording, vault: Path) -> None:
    first, _ = process(recording, components(), config(vault))
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


def test_notes_folder_comes_from_the_config(recording: Recording, vault: Path) -> None:
    note, _ = process(recording, components(), config(vault, notes_folder="Porady"))

    assert note.path == vault / "Porady/2026/10/2026-10-14 1400 Sprint planning Q4.md"
    assert (vault / "Porady/2026/10/attachments/2026-10-14 1400/140005.jpg").is_file()
    assert (vault / "Porady/Moje úkoly.md").is_file()
    assert not (vault / "Meetings").exists()


def test_transcript_can_be_left_out(recording: Recording, vault: Path) -> None:
    note, _ = process(recording, components(), config(vault, note_include_transcript=False))

    text = note.path.read_text(encoding="utf-8")
    assert "## Přepis" not in text
    assert "Pošlu ho do pátku" not in text
    assert "> [!summary] Shrnutí" in text
    assert text.endswith("- 14:00 Plán sprintu\n")


def test_tasks_are_not_appended_when_turned_off(recording: Recording, vault: Path) -> None:
    note, _ = process(recording, components(), config(vault, append_tasks_to_list=False))

    assert "- [ ] Připravit odhad (do pátku)" in note.path.read_text(encoding="utf-8")
    assert not (vault / "Meetings/Moje úkoly.md").exists()


def test_odd_speaker_names_from_claude_are_ignored(recording: Recording, vault: Path) -> None:
    def odd(prompt, schema, *, cwd, allowed_tools=()):
        result = fake_claude(prompt, schema, cwd=cwd, allowed_tools=allowed_tools)
        if "drop_ids" in schema["properties"]:
            result["speakers"] = [
                {"label": "USER", "name": "Někdo jiný", "confident": True},
                {"label": "SPEAKER_00", "name": "   ", "confident": True},
                {"label": "SPEAKER_01", "name": "Jana", "confident": False},
            ]
        return result

    note, _ = process(recording, components(odd), config(vault))

    text = note.path.read_text(encoding="utf-8")
    assert "> **[14:00:04] Matej:** Pošlu ho do pátku." in text  # the microphone stays the user
    assert "> **[14:00:01] SPEAKER_00:** Opravený text" in text  # a blank name keeps the label
    assert "> **[14:00:07] Jana (?):** Dobre, ďakujem." in text


def test_cleanup_is_redone_after_the_vocabulary_or_name_changes(
    recording: Recording, vault: Path
) -> None:
    calls = {"clean": 0, "summary": 0}

    def counting(prompt, schema, *, cwd, allowed_tools=()):
        calls["clean" if "drop_ids" in schema["properties"] else "summary"] += 1
        return fake_claude(prompt, schema, cwd=cwd, allowed_tools=allowed_tools)

    process(recording, components(counting), config(vault))
    process(recording, components(counting), config(vault))
    assert calls == {"clean": 1, "summary": 1}  # both cached

    process(recording, components(counting, vocabulary=[Term("Grafana")]), config(vault))
    assert calls == {"clean": 2, "summary": 2}  # a new vocabulary: both redone

    process(recording, components(counting), config(vault, user_name="Jiný"))
    assert calls == {"clean": 3, "summary": 3}


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
    parts = components(suggestions_path=queue)

    run_note(recording, SEGMENTS, parts, config(vault))

    suggestions = json.loads(queue.read_text(encoding="utf-8"))["suggestions"]
    assert [(s["term"], s["heardAs"], s["source"]) for s in suggestions] == [
        ("Grafana", ["grafána"], "recording")
    ]
