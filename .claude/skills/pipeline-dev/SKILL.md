---
name: pipeline-dev
description: Use when working on the Python pipeline in pipeline/ (transcription, diarization, Claude summarization, Obsidian output), its prompts, tests or fixtures.
---

# Python pipeline

## Basics
- Managed by uv: `cd pipeline && uv sync`, `uv run pytest`, `uv run ruff check --fix`.
- Entry point: `uv run meeting-pipeline [--force] [--verbose] <recording-dir>`. It reads `meta.json`, `audio.m4a` (the other participants), `mic.m4a` (the user, may be missing: see `meta.json` → `microphone`) and `frames/`, and writes `status.json` (`queued` → `transcribing` → `summarizing` → `writing` → `done` | `needs_summary` | `failed` + `error`). While a stage runs, a heartbeat thread rewrites `status.json` every 60 s (the app kills a run with no change for 30 min). `--verbose` (or `debugLogging` in config) = DEBUG logs; transcript content is never logged.
- Settings honoured from `config.json`: `transcriptLanguages` (first = fallback for misdetected chunks), `whisperModel`, `claudeModel`, `pipelineThreads` (torch threads; the app also sets `OMP_NUM_THREADS`), `notesFolder`, `noteIncludeTranscript`, `appendTasksToList`, `debugLogging`.
- The pipeline must be safe to re-run on the same folder (idempotent; reuse finished intermediate results like `transcript.json`). Cache files are written atomically (`files.py`); a damaged one is logged and rebuilt. `cleaned.json` remembers `userName` and a hash of the vocabulary: when they change, the cleanup and the summary are redone.
- SIGTERM (the app quits or deletes the recording): the handler stops a running `claude`, exits with 143 and leaves the in-progress `status.json`, so the app resumes the folder at the next launch. Any other unexpected exception ends as `failed` with `Type: message` (traceback in `pipeline.log`).

## Fixtures
- Never use or commit real recordings. Generate synthetic ones with macOS voices:
  `say -v Zuzana -o cz.aiff "..."` (Czech), `say -v Laura -o sk.aiff "..."` (Slovak), then `afconvert -f m4af -d aac cz.aiff cz.m4a` and merge them.
- Keep fixtures in `pipeline/tests/fixtures/`.

## Transcription
- `mlx-whisper`, model large-v3-turbo (`whisperModel` in config), language auto-detect limited to `transcriptLanguages`. The model is downloaded on first run (a few GB) into the Hugging Face cache.
- `initial_prompt` gets a short selection from `vocabulary.json` (most important terms and names, fits Whisper's prompt limit).
- Run under low priority (the Swift app starts the pipeline via `taskpolicy -b`). Do not parallelize heavy steps.

## Diarization
- pyannote.audio; needs `HF_TOKEN` (read from the macOS Keychain or env, never from repo files) and accepted model terms on Hugging Face.
- Diarize only `audio.m4a`. `mic.m4a` is always the user; both files share one timeline (same start, same clock).
- If the user listened on speakers, `mic.m4a` also contains the others (echo): prefer `audio.m4a` for their speech.
- Output: anonymous speakers. Names are assigned later by Claude.

## Claude step
- Call: `claude -p --output-format json --json-schema … --no-session-persistence --strict-mcp-config --allowedTools Read [--model <claudeModel>]`, prompt on stdin, working directory = the recording folder (so Claude can Read `frames/*.jpg`). `--strict-mcp-config` keeps the user's MCP servers from starting for every call.
- Remove every `ANTHROPIC_*` and `CLAUDE_CODE_*` variable from the subprocess env, so usage goes through the user's subscription (no API key, proxy, Bedrock or Vertex).
- Check the answers: a name for the label `USER` or a blank name is ignored, only frames that exist on disk are offered to Claude and kept in the note.
- Prompts live in `pipeline/prompts/*.md` with placeholders. Inputs: transcript with timestamps and speakers, calendar participants, full vocabulary, list of key frames with timestamps.
- Ask for strict JSON output, validate it, retry once on invalid JSON.
- If `claude` fails or hits a usage limit: write the note with the transcript only (with the cleaned names and corrections when only the summary failed) and set `status.json` to `needs_summary`, so it can be re-run later.
