"""Command line entry point: `meeting-pipeline <recording-dir>`."""

import argparse
import logging
import sys
from collections.abc import Sequence
from pathlib import Path

from meeting_pipeline import stages
from meeting_pipeline.audio import AudioError
from meeting_pipeline.config import load_config
from meeting_pipeline.models import ModelError
from meeting_pipeline.note import NoteError
from meeting_pipeline.recording import InvalidRecordingError, load_recording
from meeting_pipeline.status import State, write_status

log = logging.getLogger("meeting_pipeline")

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="meeting-pipeline",
        description="Process a Meeting Assistant recording folder into an Obsidian note.",
    )
    parser.add_argument("recording_dir", type=Path, help="recordings/<YYYY-MM-DD_HHmm>_<slug>/")
    parser.add_argument("--force", action="store_true", help="redo finished stages (transcription)")
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    recording_dir: Path = args.recording_dir.expanduser().resolve()
    try:
        recording = load_recording(recording_dir)
    except NotADirectoryError as exc:
        # No folder means no place for status.json; report on stderr only.
        log.error("%s", exc)
        return EXIT_USAGE
    except InvalidRecordingError as exc:
        log.error("Invalid recording %s: %s", recording_dir.name, exc)
        write_status(recording_dir, State.FAILED, error=str(exc))
        return EXIT_FAILED

    config = load_config()
    if not config.obsidian_vault_path:
        # Fail before the long transcription, not after it.
        write_status(
            recording_dir, State.FAILED, error="obsidianVaultPath is not set in config.json"
        )
        return EXIT_FAILED

    state = State.TRANSCRIBING

    def report(message: str) -> None:
        write_status(recording_dir, state, message=message)

    report("Začínám")
    components = stages.default_components()
    try:
        segments, warning = stages.run_transcription(
            recording, components, force=args.force, report=report
        )
        state = State.SUMMARIZING
        note, claude_error = stages.run_note(recording, segments, components, config, report=report)
    except (AudioError, ModelError, NoteError) as exc:
        log.error("Processing of %s failed: %s", recording_dir.name, exc)
        write_status(recording_dir, State.FAILED, error=str(exc))
        return EXIT_FAILED
    except PermissionError as exc:
        # macOS protects ~/Documents: the app must be allowed to access it (System Settings).
        log.error("No permission: %s", exc)
        write_status(
            recording_dir, State.FAILED,
            error=f"Chybí oprávnění k souboru {exc.filename}: povol Meeting Assistant přístup "
            "ke složce Dokumenty (Nastavení systému → Soukromí a zabezpečení → Soubory a složky).",
        )  # fmt: skip
        return EXIT_FAILED

    if claude_error:
        write_status(
            recording_dir, State.NEEDS_SUMMARY,
            message=f"Poznámka jen s přepisem: {note.path.name}", error=claude_error,
        )  # fmt: skip
    else:
        # A warning (e.g. no speaker diarization) is reported in `error` of a done status.
        write_status(
            recording_dir, State.DONE, message=f"Poznámka: {note.path.name}", error=warning
        )
    log.info("Recording %s processed (%s)", recording_dir.name, note.status)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
