import json
from pathlib import Path

from meeting_pipeline.vocabulary import (
    PROMPT_INTRO,
    Term,
    apply_spelling,
    initial_prompt,
    load_vocabulary,
    merge_suggestions,
)

SHARED = Path(__file__).resolve().parents[2] / "shared"


def test_shared_example_loads() -> None:
    terms = load_vocabulary(SHARED / "vocabulary.example.json")
    assert [t.term for t in terms] == ["Kubernetes", "PR", "Mária Kováčová"]
    assert terms[0].in_prompt and terms[0].auto_replace
    assert terms[2].category == "person" and not terms[2].auto_replace


def test_example_keys_match_schema() -> None:
    schema = json.loads((SHARED / "vocabulary.schema.json").read_text(encoding="utf-8"))
    example = json.loads((SHARED / "vocabulary.example.json").read_text(encoding="utf-8"))
    allowed = set(schema["properties"]["terms"]["items"]["properties"])
    for item in example["terms"]:
        assert set(item) <= allowed


def test_legacy_priority_means_in_prompt(tmp_path: Path) -> None:
    path = tmp_path / "vocabulary.json"
    path.write_text('{"terms": [{"term": "A", "priority": 1}, {"term": "B", "priority": 2}]}')
    assert [t.in_prompt for t in load_vocabulary(path)] == [True, False]


def test_missing_file_is_empty(tmp_path: Path) -> None:
    assert load_vocabulary(tmp_path / "vocabulary.json") == []


def test_prompt_is_a_glossary_sentence_of_prompt_terms() -> None:
    terms = [
        Term("Kubernetes", in_prompt=True),
        Term("běžné", in_prompt=False),
        Term("Jira", in_prompt=True),
    ]
    assert initial_prompt(terms) == f"{PROMPT_INTRO}Kubernetes, Jira."


def test_prompt_stops_at_the_token_budget() -> None:
    terms = [Term(f"Pojem{i}", in_prompt=True) for i in range(200)]
    prompt = initial_prompt(terms, max_tokens=20, count_tokens=lambda text: len(text.split()))
    assert prompt is not None
    assert len(prompt.split()) <= 20
    assert prompt.endswith(".")


def test_no_prompt_terms_no_prompt() -> None:
    assert initial_prompt([Term("A")]) is None


def test_spelling_replaces_whole_words_case_insensitively() -> None:
    terms = [
        Term("Kubernetes", aliases=["kubernetis"], auto_replace=True),
        Term("PR", aliases=["pí ár"], auto_replace=True),
    ]
    text = "Nasadíme to do Kubernetis a pošlu pí ár, ne kubernetisový."
    assert apply_spelling(text, terms) == "Nasadíme to do Kubernetes a pošlu PR, ne kubernetisový."


def test_spelling_only_for_auto_replace_terms() -> None:
    terms = [Term("Mária", aliases=["Marie"], auto_replace=False)]
    assert apply_spelling("Marie řekla", terms) == "Marie řekla"


def test_longer_alias_wins() -> None:
    terms = [
        Term("PR", aliases=["pí ár"], auto_replace=True),
        Term("PRK", aliases=["pí ár ka"], auto_replace=True),
    ]
    assert apply_spelling("to je pí ár ka", terms) == "to je PRK"


def test_term_with_a_backslash_is_inserted_literally() -> None:
    terms = [Term(r"C:\share", aliases=["cé šér"], auto_replace=True)]
    assert apply_spelling("je to na cé šér", terms) == r"je to na C:\share"


def test_damaged_queue_is_replaced(tmp_path: Path) -> None:
    path = tmp_path / "vocabulary-suggestions.json"
    path.write_text("{broken", encoding="utf-8")
    suggestion = {"term": "Grafana", "heard_as": [], "category": "product", "description": ""}

    assert merge_suggestions(path, [suggestion], [], "x") == 1

    assert [s["term"] for s in json.loads(path.read_text(encoding="utf-8"))["suggestions"]] == [
        "Grafana"
    ]
    assert (tmp_path / "vocabulary-suggestions.json.lock").exists()


def test_suggestions_are_queued_without_duplicates(tmp_path: Path) -> None:
    path = tmp_path / "vocabulary-suggestions.json"
    vocabulary = [Term("Kubernetes")]
    first = [
        {
            "term": "Grafana",
            "heard_as": ["grafána"],
            "category": "product",
            "description": "Dashboardy",
        },
        {
            "term": "kubernetes",
            "heard_as": ["kubernetis"],
            "category": "product",
            "description": "",
        },
    ]
    assert merge_suggestions(path, first, vocabulary, "2026-10-14_1400_sprint") == 1

    second = [
        {"term": "Grafana", "heard_as": ["grafanu"], "category": "product", "description": ""}
    ]
    assert merge_suggestions(path, second, vocabulary, "2026-10-15_0900_daily") == 0

    data = json.loads(path.read_text(encoding="utf-8"))
    assert [s["term"] for s in data["suggestions"]] == ["Grafana"]
    assert data["suggestions"][0]["heardAs"] == ["grafanu", "grafána"]
    assert data["suggestions"][0]["source"] == "2026-10-14_1400_sprint"


def test_rejected_suggestions_do_not_come_back(tmp_path: Path) -> None:
    path = tmp_path / "vocabulary-suggestions.json"
    path.write_text(json.dumps({"schemaVersion": 1, "suggestions": [], "rejected": ["Grafana"]}))

    added = merge_suggestions(
        path,
        [{"term": "grafana", "heard_as": [], "category": "product", "description": ""}],
        [],
        "x",
    )

    assert added == 0
    assert json.loads(path.read_text())["rejected"] == ["Grafana"]
