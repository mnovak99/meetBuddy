"""Command line entry point: `meeting-pipeline [--force] [--verbose] <recording-dir>`.

Exit codes: 0 = done or needs_summary, 1 = failed (status.json has the error), 2 = usage,
143 = stopped by SIGTERM (the app quits or deletes the recording). On SIGTERM no final status is
written: the folder stays "in progress" and the app resumes it at the next launch, where every
finished stage is reused from its cache.
"""

import argparse
import logging
import signal
import sys
import threading
from collections.abc import Sequence
from pathlib import Path
from types import FrameType
from typing import Any

from meeting_pipeline import claude, stages
from meeting_pipeline.audio import AudioError
from meeting_pipeline.config import Config, load_config
from meeting_pipeline.models import ModelError
from meeting_pipeline.note import NoteError, finish_note
from meeting_pipeline.recording import InvalidRecordingError, Recording, load_recording
from meeting_pipeline.status import State, StatusReporter, write_status

log = logging.getLogger("meeting_pipeline")

EXIT_OK = 0
EXIT_FAILED = 1
EXIT_USAGE = 2
EXIT_TERMINATED = 128 + signal.SIGTERM  # 143, like a process killed by SIGTERM


def _write_failed(recording_dir: Path, error: str) -> None:
    """Final status after a failure; the folder may be gone (deleted in the app meanwhile)."""
    try:
        write_status(recording_dir, State.FAILED, error=error)
    except OSError as exc:
        log.error("Cannot write the final status: %s", exc)


def main(argv: Sequence[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="meeting-pipeline",
        description="Process a Meeting Assistant recording folder into an Obsidian note.",
    )
    parser.add_argument("recording_dir", type=Path, help="recordings/<YYYY-MM-DD_HHmm>_<slug>/")
    parser.add_argument(
        "--force", action="store_true", help="start over: forget all finished stages"
    )
    parser.add_argument(
        "--verbose", action="store_true", help="debug logging (also with debugLogging in config)"
    )
    args = parser.parse_args(argv)
    configure_logging(verbose=args.verbose)

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
    if config.debug_logging:
        configure_logging(verbose=True)
    if not config.obsidian_vault_path:
        # Fail before the long transcription, not after it.
        write_status(
            recording_dir, State.FAILED, error="obsidianVaultPath is not set in config.json"
        )
        return EXIT_FAILED

    previous_handler = _install_sigterm_handler()
    try:
        return process(recording, config, force=args.force)
    finally:
        if previous_handler is not None:
            signal.signal(signal.SIGTERM, previous_handler)


def configure_logging(*, verbose: bool) -> None:
    """INFO by default; DEBUG with --verbose or debugLogging. Never logs transcript content."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")
    logging.getLogger().setLevel(logging.DEBUG if verbose else logging.INFO)


def process(recording: Recording, config: Config, *, force: bool) -> int:
    """All stages for one recording; the result is in status.json and the exit code."""
    recording_dir = recording.folder
    reporter = StatusReporter(recording_dir)
    try:
        # Leaving the block stops the heartbeat before any final status below is written.
        with reporter:
            reporter(State.TRANSCRIBING, "Začínám")
            if force:
                stages.clear_caches(recording_dir)
            components = stages.default_components(config)
            segments, warning = stages.run_transcription(
                recording, components, config, force=force, report=reporter
            )
            note, claude_error = stages.run_note(
                recording, segments, components, config, report=reporter
            )
    except (AudioError, ModelError, NoteError) as exc:
        log.error("Processing of %s failed: %s", recording_dir.name, exc)
        _write_failed(recording_dir, str(exc))
        return EXIT_FAILED
    except PermissionError as exc:
        # macOS protects ~/Documents: the app must be allowed to access it (System Settings).
        log.error("No permission: %s", exc)
        _write_failed(
            recording_dir,
            f"Chybí oprávnění k souboru {exc.filename}: povol Meeting Buddy přístup "
            "ke složce Dokumenty (Nastavení systému → Soukromí a zabezpečení → Soubory a složky).",
        )
        return EXIT_FAILED
    except Exception as exc:
        # Anything else (a damaged file, a library error): the app must see a failure instead of
        # a run that looks stuck. SystemExit from the SIGTERM handler is not an Exception and
        # passes through, leaving the in-progress status behind on purpose.
        log.exception("Processing of %s failed", recording_dir.name)
        _write_failed(recording_dir, f"{type(exc).__name__}: {exc}")
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
    # The note was written as "processing"; now that status.json is final, so is the note.
    try:
        finish_note(note)
    except OSError as exc:
        log.error("Cannot set the final status of the note: %s", exc)
    log.info("Recording %s processed (%s)", recording_dir.name, note.status)
    return EXIT_OK


def handle_sigterm(signum: int, frame: FrameType | None) -> None:
    """The app stops the run (it quits, or the recording is being deleted).

    A running `claude` is stopped too, so it is not left orphaned. SystemExit unwinds through
    the stages (stopping the heartbeat, removing temporary files) without a final status.json:
    the next launch of the app resumes the folder.
    """
    log.warning("Stopped by SIGTERM; the next launch continues from the finished stages")
    claude.terminate_child()
    raise SystemExit(EXIT_TERMINATED)


def _install_sigterm_handler() -> Any:
    """Returns the previous handler, to restore it (tests call main() more than once)."""
    if threading.current_thread() is not threading.main_thread():
        return None  # signal handlers can only be set from the main thread
    return signal.signal(signal.SIGTERM, handle_sigterm)


if __name__ == "__main__":
    sys.exit(main())
