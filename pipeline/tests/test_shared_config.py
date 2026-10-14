"""The example config, the JSON schema and their defaults must stay in sync.

The Swift app has its own defaults (AppConfig.swift) and checks them against the same example.
"""

import json
from pathlib import Path

SHARED = Path(__file__).resolve().parents[2] / "shared"


def load(name: str) -> dict:
    return json.loads((SHARED / name).read_text(encoding="utf-8"))


def test_example_has_exactly_the_schema_keys() -> None:
    schema = load("config.schema.json")
    example = load("config.example.json")

    assert set(example) == set(schema["properties"])


def test_example_values_equal_schema_defaults() -> None:
    schema = load("config.schema.json")
    example = load("config.example.json")

    for key, spec in schema["properties"].items():
        assert example[key] == spec["default"], key
