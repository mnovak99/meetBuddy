import json
from pathlib import Path

from meeting_pipeline.vocabulary import Term, initial_prompt, load_vocabulary

SHARED = Path(__file__).resolve().parents[2] / "shared"


def test_most_important_terms_come_first() -> None:
    terms = [Term("Zeta", priority=2), Term("Kubernetes", priority=1), Term("Alfa", priority=2)]
    assert initial_prompt(terms) == "Kubernetes, Alfa, Zeta"


def test_prompt_respects_length_limit() -> None:
    terms = [Term(f"term{i:03d}") for i in range(500)]
    prompt = initial_prompt(terms, max_chars=100)
    assert prompt is not None
    assert len(prompt) <= 100


def test_no_terms_no_prompt() -> None:
    assert initial_prompt([]) is None


def test_missing_file_is_empty(tmp_path: Path) -> None:
    assert load_vocabulary(tmp_path / "vocabulary.json") == []


def test_shared_example_loads(tmp_path: Path) -> None:
    terms = load_vocabulary(SHARED / "vocabulary.example.json")
    assert terms
    assert all(term.term for term in terms)
    assert (
        json.loads((SHARED / "vocabulary.example.json").read_text(encoding="utf-8"))[
            "schemaVersion"
        ]
        == 1
    )
