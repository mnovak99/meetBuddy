"""Small files the pipeline writes: status.json, the cache files, note.json and the note itself.

Every write goes to a temporary file in the same folder that is then renamed over the target.
A rename is atomic on one volume, so a reader (the app, Obsidian) never sees a half-written file,
and a run stopped in the middle of a write (SIGTERM, shutdown) leaves the previous file behind
instead of a truncated one. Reads of cache files are tolerant: a damaged file is logged and
treated as absent, so its stage is simply redone on the next run.
"""

import json
import logging
import os
import tempfile
from pathlib import Path
from typing import Any

log = logging.getLogger(__name__)


def write_text(path: Path, text: str) -> None:
    """Replace `path` with `text` atomically (temporary file in the same folder + rename)."""
    fd, tmp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as tmp:
            tmp.write(text)
        os.replace(tmp_name, path)
    except BaseException:
        Path(tmp_name).unlink(missing_ok=True)
        raise


def write_json(path: Path, payload: Any, *, indent: int = 1) -> None:
    write_text(path, json.dumps(payload, ensure_ascii=False, indent=indent) + "\n")


def read_json(path: Path) -> Any | None:
    """The parsed file, or None when it does not exist or is not valid JSON (logged)."""
    if not path.is_file():
        return None
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        log.warning("Ignoring damaged %s (%s); it will be rebuilt", path.name, exc)
        return None
