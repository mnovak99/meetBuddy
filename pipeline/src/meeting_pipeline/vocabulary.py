"""vocabulary.json: names, abbreviations and terms that speech recognition gets wrong.

Three uses, as in commercial speech-to-text services:
- keyterm boosting: entries with `inPrompt` go into Whisper's `initial_prompt` as a short Czech
  glossary sentence (Whisper copies the prompt's style and spelling, it does not follow
  instructions; only the last 224 tokens count),
- custom spelling: entries with `autoReplace` replace their known misrecognitions (`aliases`)
  right after transcription,
- context for the Claude cleanup: the whole vocabulary including meanings and roles.

Edited in the app (Slovník). Schema: shared/vocabulary.schema.json.
"""

import json
import re
from collections.abc import Callable
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path
from typing import Any

from meeting_pipeline.config import SUPPORT_DIR

VOCABULARY_FILE = SUPPORT_DIR / "vocabulary.json"
SUGGESTIONS_FILE = SUPPORT_DIR / "vocabulary-suggestions.json"
CATEGORIES = ("abbreviation", "person", "product", "company", "term")
# Whisper keeps the last 224 prompt tokens; leave a margin.
PROMPT_MAX_TOKENS = 200
PROMPT_INTRO = "Na poradě padly pojmy a jména: "
MAX_SUGGESTIONS = 100


@dataclass(frozen=True)
class Term:
    term: str
    category: str = "term"
    aliases: list[str] = field(default_factory=list)
    description: str = ""
    in_prompt: bool = False
    auto_replace: bool = False


def load_vocabulary(path: Path = VOCABULARY_FILE) -> list[Term]:
    if not path.is_file():
        return []
    data = json.loads(path.read_text(encoding="utf-8"))
    terms = []
    for item in data.get("terms", []):
        if not item.get("term"):
            continue
        terms.append(
            Term(
                term=item["term"],
                category=item.get("category", "term"),
                aliases=[a for a in item.get("aliases", []) if a],
                description=item.get("description", ""),
                # Older files had "priority" (1 = most important) instead of "inPrompt".
                in_prompt=bool(item.get("inPrompt", item.get("priority") == 1)),
                auto_replace=bool(item.get("autoReplace", False)),
            )
        )
    return terms


def _estimate_tokens(text: str) -> int:
    """Czech text: about 2.3 characters per Whisper token (measured)."""
    return int(len(text) / 2.3) + 1


def whisper_token_counter() -> Callable[[str], int]:
    """Exact count with Whisper's tokenizer; the estimate if MLX cannot be loaded."""
    try:
        from mlx_whisper.tokenizer import get_tokenizer

        tokenizer = get_tokenizer(multilingual=True, num_languages=100)
        return lambda text: len(tokenizer.encode(" " + text.strip()))
    except Exception:
        return _estimate_tokens


def initial_prompt(
    terms: list[Term],
    max_tokens: int = PROMPT_MAX_TOKENS,
    count_tokens: Callable[[str], int] = _estimate_tokens,
) -> str | None:
    """A glossary sentence with the `inPrompt` terms that fit, in the order of the vocabulary."""
    selected: list[str] = []
    for term in terms:
        if not term.in_prompt:
            continue
        candidate = PROMPT_INTRO + ", ".join([*selected, term.term]) + "."
        if count_tokens(candidate) > max_tokens:
            break
        selected.append(term.term)
    return PROMPT_INTRO + ", ".join(selected) + "." if selected else None


def apply_spelling(text: str, terms: list[Term]) -> str:
    """Replace known misrecognitions (`aliases`) of `autoReplace` terms with the correct form.

    Whole words only, case-insensitive; longer aliases first ("pí ár ka" before "pí ár").
    """
    replacements = sorted(
        ((alias, term.term) for term in terms if term.auto_replace for alias in term.aliases),
        key=lambda pair: len(pair[0]),
        reverse=True,
    )
    for alias, correct in replacements:
        pattern = re.compile(rf"(?<!\w){re.escape(alias)}(?!\w)", re.IGNORECASE)
        text = pattern.sub(correct, text)
    return text


def merge_suggestions(
    path: Path, suggestions: list[dict[str, Any]], vocabulary: list[Term], source: str
) -> int:
    """Add Claude's vocabulary suggestions to the review queue shown in the app.

    Skips terms already in the vocabulary, already rejected by the user or already queued (then
    only the new misrecognitions are added). Returns the number of new suggestions.
    """
    data = json.loads(path.read_text(encoding="utf-8")) if path.is_file() else {}
    queued: list[dict[str, Any]] = data.get("suggestions", [])
    rejected = {term.casefold() for term in data.get("rejected", [])}
    known = {term.term.casefold() for term in vocabulary}
    by_term = {item["term"].casefold(): item for item in queued}
    added = 0
    for suggestion in suggestions:
        term = suggestion.get("term", "").strip()
        key = term.casefold()
        if not term or key in known or key in rejected:
            continue
        heard = [h for h in suggestion.get("heard_as", []) if h and h.casefold() != key]
        if key in by_term:
            existing = by_term[key]
            existing["heardAs"] = sorted(set(existing.get("heardAs", [])) | set(heard))
            continue
        item = {
            "term": term,
            "heardAs": sorted(set(heard)),
            "category": suggestion.get("category")
            if suggestion.get("category") in CATEGORIES
            else "term",
            "description": suggestion.get("description", ""),
            "source": source,
            "addedAt": datetime.now().astimezone().isoformat(timespec="seconds"),
        }
        queued.append(item)
        by_term[key] = item
        added += 1
    data = {
        "schemaVersion": 1,
        "suggestions": queued[-MAX_SUGGESTIONS:],
        "rejected": data.get("rejected", []),
    }
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    temporary.replace(path)
    return added
