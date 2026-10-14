"""Command line entry point: `meeting-pipeline <recording-dir>`."""

import argparse
import logging
import sys
from collections.abc import Sequence
from pathlib import Path

from meeting_pipeline.recording import InvalidRecordingError, load_meta
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
    args = parser.parse_args(argv)
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(name)s: %(message)s")

    recording_dir: Path = args.recording_dir.expanduser().resolve()
    try:
        load_meta(recording_dir)
    except NotADirectoryError as exc:
        # No folder means no place for status.json; report on stderr only.
        log.error("%s", exc)
        return EXIT_USAGE
    except InvalidRecordingError as exc:
        log.error("Invalid recording %s: %s", recording_dir.name, exc)
        write_status(recording_dir, State.FAILED, error=str(exc))
        return EXIT_FAILED

    # Step 1 skeleton: transcription, summary and the Obsidian note come in step 3.
    write_status(
        recording_dir,
        State.DONE,
        message="Skeleton pipeline: recording folder is valid, nothing was processed.",
    )
    log.info("Recording %s is valid (skeleton, nothing processed)", recording_dir.name)
    return EXIT_OK


if __name__ == "__main__":
    sys.exit(main())
