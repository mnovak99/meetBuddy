---
name: obsidian-note
description: Use when generating, changing or testing the Obsidian meeting note: its folder layout, file naming, frontmatter, sections, attachments and the shared task list.
---

# Obsidian meeting note

## Location and naming
- Vault path from `config.json` (`obsidianVaultPath`).
- Note: `Meetings/YYYY/MM/YYYY-MM-DD HHmm <Title>.md`. Title = calendar event title, otherwise empty (just date and time). Strip characters invalid in file names.
- Attachments: `Meetings/YYYY/MM/attachments/YYYY-MM-DD HHmm/<HHmmss>.jpg` (only key frames chosen by the summary).
- Never overwrite a note the user may have edited: on re-run write `… (2).md` unless frontmatter `status` is still `processing` or `needs_summary` (unfinished notes written by the pipeline).

## Template
```markdown
---
date: 2026-10-13
start: "14:00"
end: "15:05"
app: Teams
title: Sprint planning
participants: [Petr Novák, Jana K.]
languages: [cs, sk]
tags: [meeting]
status: done
---
# Sprint planning

> [!summary] Shrnutí
> 3–5 vět: o čem meeting byl a co z něj vyplynulo.

## Klíčové body
## Rozhodnutí
## Moje úkoly
- [ ] Úkol (termín, pokud zazněl)
## Úkoly ostatních
- [ ] **Jméno**: úkol
## Otevřené otázky
## Kde padlo moje jméno
- [14:23] kontext
## Sdílený obsah
### 14:12 – co bylo na obrazovce
![[attachments/2026-10-13 1400/141210.jpg]]
Krátký popis, proč je to důležité.
## Časová osa
- 14:00 téma
## Přepis
> [!note]- Plný přepis
> **[14:00:12] Petr:** …
```

## Rules
- Note text in Czech; transcript in the original language.
- Nothing invented: if unsure, leave the section out or mark it „(?)“. Empty sections are omitted.
- The user's own voice is in `mic.m4a` (speaker = `userName` in config). „Moje úkoly“ = tasks assigned to him by name, clearly addressed to him, or that he took on himself.
- Also append his tasks to `Meetings/Moje úkoly.md` as `- [ ] úkol ([[YYYY-MM-DD HHmm Title]])`, never duplicating existing lines.
- No Obsidian plugins required; only core Markdown, callouts and wiki-links.
