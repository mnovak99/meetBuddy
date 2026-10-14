# Příprava před prvním promptem

Projdi kroky v tomto pořadí. Celé to zabere zhruba hodinu, nejdéle trvá stažení Xcode.

## 1. Xcode
- Nainstaluj Xcode z App Store (26.3 nebo novější, kvůli MCP bridge). Jednou ho otevři a nech doinstalovat komponenty.
- V terminálu: `sudo xcode-select -s /Applications/Xcode.app` a `sudo xcodebuild -license accept`.
- Xcode → Settings → Intelligence → Model Context Protocol → zapni **Xcode Tools**. Tento MCP funguje jen tehdy, když Xcode běží.

## 2. Homebrew a nástroje
```
brew install xcodegen xcode-build-server uv node ffmpeg gh
npm install -g pyright
```
Ověř, že `which sourcekit-lsp` něco vrátí (přichází s Xcode).

## 3. Podpisový certifikát
Bez něj by macOS po každém buildu zapomněl udělená oprávnění.
1. Otevři Klíčenka (Keychain Access) → menu Klíčenka → Asistent pro certifikáty → Vytvořit certifikát.
2. Název `MeetingAssistant Dev`, typ identity „Self-signed root“, typ certifikátu **Code Signing**.
3. Ověř: `security find-identity -v -p codesigning` musí certifikát vypsat.

## 4. Claude Code
- Nainstaluj Claude Code a rozšíření Claude Code do VS Code (postup: https://docs.claude.com/en/docs/claude-code/overview).
- Přihlas se firemním Team účtem (`claude` → `/login`).
- Ověř, že nemáš nastavenou proměnnou `ANTHROPIC_API_KEY` (`echo $ANTHROPIC_API_KEY` musí být prázdné), jinak by se používání účtovalo přes API.
- VS Code rozšíření: Claude Code, Swift (swiftlang), Python.

## 5. Repo
```
mkdir -p ~/Developer/meeting-assistant && cd ~/Developer/meeting-assistant
git init
```
Nakopíruj do něj obsah tohoto balíčku (`CLAUDE.md`, `.mcp.json`, `.claude/`). `SETUP.md` a `KICKOFF_PROMPT.md` můžeš dát do `docs/`.
Volitelně privátní repo na GitHubu: `gh repo create meeting-assistant --private --source . --push`.

## 6. Pluginy (v Claude Code)
Jsou předvyplněné v `.claude/settings.json`, při prvním spuštění je stačí potvrdit, případně ručně:
```
/plugin install swift-lsp@claude-plugins-official
/plugin install pyright-lsp@claude-plugins-official
/plugin install commit-commands@claude-plugins-official
```
- **swift-lsp, pyright-lsp**: Claude po každé úpravě vidí chyby typů a importů bez spuštění buildu.
- **commit-commands**: `/commit-commands:commit` udělá commit s rozumnou zprávou.
- Volitelně `github@claude-plugins-official`, pokud budeš mít repo na GitHubu.

## 7. MCP servery
Jsou v `.mcp.json`, Claude Code se při prvním spuštění zeptá, jestli jim důvěřuješ.
- **XcodeBuildMCP**: build, spuštění a logy macOS appky bez otevírání Xcode; vrací jen podstatné chyby místo tisíců řádků logu. Pokud nebude nabízet macOS nástroje, povol je podle README projektu (getsentry/XcodeBuildMCP).
- **xcode** (`xcrun mcpbridge`): oficiální MCP z Xcode. Hlavně `DocumentationSearch` pro aktuální dokumentaci ScreenCaptureKit, Core Audio a EventKit. Vyžaduje běžící Xcode s otevřeným projektem.
- **context7**: aktuální dokumentace Python knihoven (mlx-whisper, pyannote).
- Kontrola: `claude mcp list`.

## 8. Skills (projektové, v `.claude/skills/`)
- **build-and-run**: generování projektu, build, podpis, instalace do /Applications, reset oprávnění, logy.
- **pipeline-dev**: Python pipeline, syntetické testovací nahrávky přes `say`, volání `claude -p`.
- **obsidian-note**: přesný formát poznámky, pojmenování, přílohy, „Moje úkoly“.
Claude je načte sám, když na danou oblast narazí. Uprav je, kdykoliv se něco změní.

## 9. Obsidian
- Nainstaluj Obsidian a vytvoř vault, třeba `~/Obsidian/Work`. Raději mimo iCloud.
- Cestu k vaultu později zadáš v nastavení appky.

## 10. Kalendář
- Přidej Google i Outlook (firemní) účet do macOS Kalendáře (Nastavení systému → Internetové účty). Appka z něj přečte název meetingu a účastníky.
- Pokud firma Outlook v Kalendáři nepovolí, poznámky se pojmenují datem a časem.

## 11. Až ke kroku 3 (pipeline)
- Účet na Hugging Face, přístupový token a odsouhlasené podmínky modelu pyannote pro diarizaci.
- ~3–4 GB místa na modely.

## Jak začít
1. Otevři repo ve VS Code a spusť Claude Code.
2. Přepni do Plan mode (Shift+Tab).
3. Vlož obsah `KICKOFF_PROMPT.md`.
4. Po každém kroku appku vyzkoušej, commitni a teprve pak pokračuj dalším krokem roadmapy (stačí napsat „pokračujeme krokem 2“).
