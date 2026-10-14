---
name: pipeline-dev
description: Use when working on the Python pipeline in pipeline/ (transcription, diarization, Claude summarization, Obsidian output), its prompts, tests or fixtures.
---

# Python pipeline

## Basics
- Managed by uv: `cd pipeline && uv sync`, `uv run pytest`, `uv run ruff check --fix`.
- Entry point: `uv run meeting-pipeline <recording-dir>`. It reads `meta.json`, `audio.m4a` and `frames/`, and writes `status.json` (`queued` → `transcribing` → `summarizing` → `writing` → `done` | `failed` + `error`).
- The pipeline must be safe to re-run on the same folder (idempotent; reuse finished intermediate results like `transcript.json`).

## Fixtures
- Never use or commit real recordings. Generate synthetic ones with macOS voices:
  `say -v Zuzana -o cz.aiff "..."` (Czech), `say -v Laura -o sk.aiff "..."` (Slovak), then `afconvert -f m4af -d aac cz.aiff cz.m4a` and merge them.
- Keep fixtures in `pipeline/tests/fixtures/`.

## Transcription
- `mlx-whisper`, model large-v3-turbo, language auto-detect. The model is downloaded on first run (a few GB) into the Hugging Face cache.
- `initial_prompt` gets a short selection from `vocabulary.json` (most important terms and names, fits Whisper's prompt limit).
- Run under low priority (the Swift app starts the pipeline via `taskpolicy -b`). Do not parallelize heavy steps.

## Diarization
- pyannote.audio; needs `HF_TOKEN` (read from the macOS Keychain or env, never from repo files) and accepted model terms on Hugging Face.
- Output: anonymous speakers. Names are assigned later by Claude.

## Claude step
- Call: `claude -p "<prompt>" --output-format json --allowedTools "Read"`, working directory = the recording folder (so Claude can Read `frames/*.jpg`).
- Remove `ANTHROPIC_API_KEY` from the subprocess env, so usage goes through the user's subscription.
- Prompts live in `pipeline/prompts/*.md` with placeholders. Inputs: transcript with timestamps and speakers, calendar participants, full vocabulary, list of key frames with timestamps.
- Ask for strict JSON output, validate it, retry once on invalid JSON.
- If `claude` fails or hits a usage limit: write the note with the transcript only and set `status.json` to `needs_summary`, so it can be re-run later.
