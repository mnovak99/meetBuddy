# Meeting Assistant

Osobní macOS appka (nikdy se nepublikuje). Běží v menu baru na Mac mini, detekuje online meetingy, po potvrzení nahraje zvuk meeting aplikace a klíčové snímky sdíleného obsahu a po meetingu vytvoří poznámku v Obsidianu (shrnutí + plný přepis).

## Prostředí a uživatel
- Mac mini M4 (2025), 16 GB RAM, macOS 26 Tahoe, disk 256 GB (volných ~84 GB).
- Vývoj: VS Code + Claude Code. Uživatel (Matej) zná Python a React, **Swift nezná**: Swift piš čitelně, nezřejmá API (ScreenCaptureKit, Core Audio, TCC, EventKit) okomentuj a rozhodnutí vysvětluj.
- Kód, identifikátory, komentáře a commit messages anglicky. Komunikace s uživatelem česky. UI appky česky.

## Architektura
Dvě části, komunikují přes soubory:
1. `app/` – Swift/SwiftUI menu bar appka (MenuBarExtra + okno s GUI). Detekce, nahrávání, notifikace, GUI, spouštění pipeline.
2. `pipeline/` – Python (uv). Přepis (mlx-whisper), diarizace (pyannote), čištění a shrnutí přes Claude Code headless (`claude -p`), zápis do Obsidianu.

Sdílený stav v `~/Library/Application Support/MeetingAssistant/`:
- `config.json` – nastavení (čte Swift i Python, schéma v `shared/config.schema.json`)
- `vocabulary.json` – slovník termínů, zkratek a jmen
- `recordings/<YYYY-MM-DD_HHmm>_<slug>/` – `meta.json`, `audio.m4a`, `frames/*.jpg`, `status.json`

Po skončení nahrávání Swift spustí `uv run --project <pipeline> meeting-pipeline <dir>` s nízkou prioritou (`taskpolicy -b`) a sleduje `status.json`.

```
app/        Swift (project.yml, Sources/, Resources/)
pipeline/   Python (pyproject.toml, src/meeting_pipeline/, prompts/, tests/)
shared/     config.schema.json, ukázkové JSON
scripts/    build/install pomocné skripty
docs/       rozhodnutí a poznámky
```

## Rozhodnutí z dotazníku (neměnit bez domluvy)

**Detekce**
- Teams desktop (`com.microsoft.teams2`), Google Meet v Brave (`com.brave.Browser`, okno s titulkem „Meet – …“), Discord desktop (`com.hnc.Discord`, pracovní, výjimečně).
- Signály: běžící appka + titulek okna + aktivní audio procesu (Core Audio process objects, macOS 14.4+). Meeting nemusí být v popředí, uživatel bývá ztlumený.
- Po detekci notifikace „Nahrávat?“ (Ano / Ne). **Nikdy nenahrávat bez potvrzení.**
- Pravděpodobný konec (okno zavřené, audio ticho N minut) → notifikace. Ukončení ručně nebo z notifikace.
- Záznamy kratší než `minDurationMinutes` (výchozí 5) zahodit.

**Zvuk**
- **Nahrávat jen zvuk meeting aplikace. Mikrofon nikdy.** Appka nesmí žádat o přístup k mikrofonu.
- Pokud to jde, jen audio procesu meeting appky (Core Audio process tap nebo SCK filtr na aplikaci), ne celý systém. Pozor na Brave: audio z jiných záložek.
- Formát: mono AAC `.m4a`, ~32 kbps.

**Obraz**
- Jen okno meetingu (`SCContentFilter(desktopIndependentWindow:)`). Funguje i zakryté, minimalizované ne → notifikace.
- Snímek každé 2–3 s, uložit jen při výrazné změně (perceptual hash), zmenšit na max 1600 px delší strana, JPEG.
- Zajímá nás sdílený obsah (kód, dashboardy, Confluence), ne kamery účastníků.

**Přepis a AI**
- Jazyky: čeština (kolegové), slovenština (zákazníci), ~10 % angličtina. Střídání mluvčích, hovorová řeč, anglicismy. Přepis v původním jazyce, poznámky česky.
- `mlx-whisper` s modelem large-v3-turbo, auto-detekce jazyka. Slovník: krátký výběr do `initial_prompt`, celý slovník do Claude čištění.
- Mluvčí: diarizace → Claude přiřadí jména podle účastníků z kalendáře a kontextu, nejistá označí „(?)“.
- LLM výhradně Claude Code headless přes Team předplatné uživatele. Žádný API klíč, žádné jiné cloudové služby. Pipeline z env pro volání `claude` odstraní `ANTHROPIC_API_KEY`.
- Zpracování hned po meetingu na pozadí. Musí nechat prostor pro VS Code + 1 Docker kontejner. Poznámka může být klidně až druhý den.

**Kalendář**: EventKit (Google i Outlook účty v macOS Kalendáři) → název meetingu a účastníci. Bez události: název = datum a čas.

**Obsidian**: viz skill `obsidian-note`.

**Úložiště**: audio 7 dní, nevybrané snímky smazat hned po zpracování, limit appky 10 GB, mazání vždy s potvrzením, staré poznámky do archivní složky (ručně z GUI).

**GUI** (SwiftUI okno): Přehled, Slovník, Nastavení, Úložiště. Ovládání ikonou v menu baru a notifikacemi. Start po přihlášení přes `SMAppService.mainApp`. Mac se po práci vypíná.

## Roadmapa (vždy jen jeden krok, pak se zastav a dej uživateli otestovat)
1. Kostra: XcodeGen projekt, menu bar, detekce meetingu, notifikace (bez nahrávání), config, Python skeleton.
2. Nahrávání: audio meeting appky + klíčové snímky okna, `meta.json`, ukončení.
3. Pipeline: přepis, diarizace, Claude čištění a shrnutí, zápis do Obsidianu, `status.json`.
4. GUI: Přehled, Slovník, Nastavení, Úložiště, start po přihlášení.
5. Ladění podle ostrého provozu.

## Build a běh (podrobně: skill `build-and-run`, `pipeline-dev`)
- Xcode projekt se generuje z `app/project.yml` (XcodeGen). `.xcodeproj` needitovat ručně, je v `.gitignore`.
- Build a spuštění přes XcodeBuildMCP, jinak `xcodebuild`.
- Podpis certifikátem „MeetingAssistant Dev“ z Klíčenky (stabilní identita = oprávnění přežijí rebuild). Nikdy ad-hoc.
- Bez App Sandboxu (subprocessy, zápis do vaultu). Bundle ID `dev.matej.MeetingAssistant`, minimum macOS 15.
- Logování přes `os.Logger(subsystem: "dev.matej.MeetingAssistant", category: …)`.
- Python: `cd pipeline && uv run pytest && uv run ruff check`.

## Pravidla práce
- Na začátku kroku navrhni plán a počkej na schválení.
- Nové závislosti (SPM, PyPI, Homebrew) jen po odsouhlasení, preferuj systémové frameworky.
- Apple API ověřuj v dokumentaci (Xcode MCP `DocumentationSearch`), neodhaduj z paměti. ScreenCaptureKit a Core Audio taps se mezi verzemi macOS mění.
- Každé oprávnění (Screen Recording, Notifikace, Kalendář) má ošetřený stav „nepovoleno“ a UI říká, co má uživatel udělat.
- Nahrávky, přepisy a poznámky nikdy necommitovat a obsah přepisů nelogovat.
- Krok je hotový, až když build i testy projdou a uživatel dostal přesný postup ručního testu.
