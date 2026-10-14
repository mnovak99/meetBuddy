"""vocabulary.json: terms, abbreviations and names that speech recognition tends to get wrong.

A short selection goes into Whisper's `initial_prompt`; the full list goes to the Claude cleanup.
Example: shared/vocabulary.example.json.
"""

import json
from dataclasses import dataclass, field
from pathlib import Path

from meeting_pipeline.config import SUPPORT_DIR

# Whisper's prompt holds about 224 tokens; ~600 characters of Czech text stays safely below.
PROMPT_MAX_CHARS = 600


@dataclass(frozen=True)
class Term:
    term: str
    aliases: list[str] = field(default_factory=list)
    description: str = ""
    # 1 = most important (always in the Whisper prompt), higher = less important.
    priority: int = 2


def load_vocabulary(path: Path = SUPPORT_DIR / "vocabulary.json") -> list[Term]:
    if not path.is_file():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    return [
        Term(
            term=item["term"],
            aliases=list(item.get("aliases", [])),
            description=item.get("description", ""),
            priority=int(item.get("priority", 2)),
        )
        for item in data.get("terms", [])
        if item.get("term")
    ]


def initial_prompt(terms: list[Term], max_chars: int = PROMPT_MAX_CHARS) -> str | None:
    """The most important terms as a comma-separated list that fits Whisper's prompt."""
    selected: list[str] = []
    length = 0
    for term in sorted(terms, key=lambda t: (t.priority, t.term.lower())):
        addition = len(term.term) + (2 if selected else 0)
        if length + addition > max_chars:
            break
        selected.append(term.term)
        length += addition
    return ", ".join(selected) or None
