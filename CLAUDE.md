# Meeting Assistant

Osobní macOS appka **Meeting Buddy** (nikdy se nepublikuje; `MeetingBuddy.app`, ikona: duch se sluchátky). Bundle ID, složka dat a logy zůstávají `dev.matej.MeetingAssistant` / `MeetingAssistant`. Běží v menu baru na Mac mini, detekuje online meetingy, po potvrzení nahraje zvuk meeting aplikace, mikrofon uživatele a klíčové snímky sdíleného obsahu a po meetingu vytvoří poznámku v Obsidianu (shrnutí + plný přepis).

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
- `recordings/<YYYY-MM-DD_HHmm>_<slug>/` – `meta.json`, `audio.m4a` (ostatní), `mic.m4a` (uživatel), `frames/*.jpg`, `status.json`

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
- Záznamy kratší než `minDurationMinutes` (výchozí 5) nabídnout k zahození notifikací (Zahodit / Ponechat). Bez odpovědi ponechat, zahozené jdou do Koše.
- Ruční start nahrávání z menu (výslovná volba uživatele, např. když detekce selže).

**Zvuk**
- Dvě oddělené stopy sladěné v čase (jedno agregované zařízení): `audio.m4a` = zvuk meeting aplikace (ostatní účastníci), `mic.m4a` = mikrofon uživatele, pevně Arctis Nova 7 (`microphoneName` v configu). Bez povolení nebo bez připojeného mikrofonu se nahraje jen `audio.m4a`.
- Ztlumení si uživatel řeší tlačítkem na mikrofonu, appka stav ztlumení v meetingu neřeší.
- Jen audio procesů meeting appky přes Core Audio process tap podle bundle ID (macOS 26+, `processRestoreEnabled`), ne celý systém. Brave: tap zachytí i jiné záložky, jednu záložku oddělit nejde.
- Formát: mono AAC `.m4a`, ~32 kbps, obě stopy.

**Obraz**
- Jen okno meetingu (`SCContentFilter(desktopIndependentWindow:)`). Funguje i zakryté, minimalizované ne → notifikace.
- Snímek každé 2–3 s, uložit jen při výrazné změně (perceptual hash), zmenšit na max 1600 px delší strana, JPEG.
- Zajímá nás sdílený obsah (kód, dashboardy, Confluence), ne kamery účastníků.

**Přepis a AI**
- Jazyky: čeština (kolegové), slovenština (zákazníci), ~10 % angličtina. Střídání mluvčích, hovorová řeč, anglicismy. Přepis v původním jazyce, poznámky česky.
- `mlx-whisper` s modelem large-v3-turbo, auto-detekce jazyka. Slovník: krátký výběr do `initial_prompt`, celý slovník do Claude čištění.
- Mluvčí: `mic.m4a` je vždy uživatel (`userName`). Diarizace jen na `audio.m4a` → Claude přiřadí jména podle účastníků z kalendáře a kontextu, nejistá označí „(?)“.
- LLM výhradně Claude Code headless přes Team předplatné uživatele. Žádný API klíč, žádné jiné cloudové služby. Pipeline z env pro volání `claude` odstraní `ANTHROPIC_API_KEY`.
- Zpracování hned po meetingu na pozadí. Musí nechat prostor pro VS Code + 1 Docker kontejner. Poznámka může být klidně až druhý den.

**Kalendář**: EventKit (Google i Outlook účty v macOS Kalendáři) → název meetingu a účastníci. Bez události: název = datum a čas.

**Obsidian**: viz skill `obsidian-note`.

**Úložiště**: audio 7 dní, nevybrané snímky smazat hned po zpracování, limit appky 10 GB, mazání vždy s potvrzením, staré poznámky do archivní složky (ručně z GUI).

**GUI** (SwiftUI okno): Slovník, Přehled, Nastavení, Úložiště. Slovník podle konvence custom vocabulary: správný tvar, typ, chybné tvary (custom spelling), význam (jen pro Claude), „Do promptu“ (keyterms do Whisperu, ~200 tokenů), „Automaticky opravovat“; návrhy z Claudova čištění, import/export CSV. Ovládání ikonou v menu baru a notifikacemi. Start po přihlášení přes `SMAppService.mainApp`. Mac se po práci vypíná.

## Roadmapa (vždy jen jeden krok, pak se zastav a dej uživateli otestovat)
1. Kostra: XcodeGen projekt, menu bar, detekce meetingu, notifikace (bez nahrávání), config, Python skeleton.
2. Nahrávání: audio meeting appky + klíčové snímky okna, kalendář, `meta.json`, ukončení.
3. Pipeline: přepis, diarizace, Claude čištění a shrnutí, zápis do Obsidianu, `status.json`.
4. GUI: Přehled, Slovník, Nastavení, Úložiště, start po přihlášení.
5. Ladění podle ostrého provozu.

## Build a běh (podrobně: skill `build-and-run`, `pipeline-dev`)
- Xcode projekt se generuje z `app/project.yml` (XcodeGen). `.xcodeproj` needitovat ručně, je v `.gitignore`.
- Build a spuštění přes XcodeBuildMCP, jinak `xcodebuild`.
- Podpis certifikátem „MeetingAssistant Dev“ z Klíčenky (stabilní identita = oprávnění přežijí rebuild). Nikdy ad-hoc.
- Bez App Sandboxu (subprocessy, zápis do vaultu). Bundle ID `dev.matej.MeetingAssistant`, minimum macOS 26 (Core Audio tap podle bundle ID).
- Logování přes `os.Logger(subsystem: "dev.matej.MeetingAssistant", category: …)`.
- Python: `cd pipeline && uv run pytest && uv run ruff check`.
- Popis pro lidi: `README.md` (česky). Změny průběžně do `CHANGELOG.md` pod `[Unreleased]`; vydání tlačítkem na GitHubu (Actions → Release, self-hosted runner `mac-mini` v `~/actions-runner`) nebo `scripts/release.sh --bump patch|minor|major`.

## Pravidla práce
- Na začátku kroku navrhni plán a počkej na schválení.
- Nové závislosti (SPM, PyPI, Homebrew) jen po odsouhlasení, preferuj systémové frameworky.
- Apple API ověřuj v dokumentaci (Xcode MCP `DocumentationSearch`), neodhaduj z paměti. ScreenCaptureKit a Core Audio taps se mezi verzemi macOS mění.
- Každé oprávnění (Nahrávání obrazovky a systémového zvuku, Mikrofon, Notifikace, Kalendář) má ošetřený stav „nepovoleno“ a UI říká, co má uživatel udělat.
- Nahrávky, přepisy a poznámky nikdy necommitovat a obsah přepisů nelogovat.
- Krok je hotový, až když build i testy projdou a uživatel dostal přesný postup ručního testu.
