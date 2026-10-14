Ahoj, začínáme nový projekt. Nejdřív si přečti CLAUDE.md a skills v .claude/skills/.

Děláme krok 1 z roadmapy: kostru appky bez nahrávání.

Rozsah kroku 1:
1. Struktura repa podle CLAUDE.md, .gitignore (včetně *.xcodeproj, build/, .venv, nahrávek).
2. `app/project.yml` pro XcodeGen: menu bar appka (LSUIElement, MenuBarExtra), podpis certifikátem „MeetingAssistant Dev“, bez sandboxu, macOS 15+.
3. Ikona v menu baru se stavem: čekám / meeting detekován / (připraveno pro) nahrávám.
4. `MeetingDetector`: polling každé ~3 s, rozpozná Teams desktop, Google Meet v Brave a Discord desktop podle CLAUDE.md. Výstup: stav + zdroj + název okna. Logovat přes os.Logger.
5. Notifikace „Detekován meeting v <appka> – nahrávat?“ s akcemi Ano / Ne (zatím jen zaloguje volbu) a notifikace při pravděpodobném konci meetingu.
6. Načítání `config.json` s výchozími hodnotami + `shared/config.schema.json`.
7. `pipeline/`: uv projekt, CLI `meeting-pipeline <dir>`, který zatím jen zvaliduje složku a zapíše `status.json`, plus pytest test.

Postup:
- Nejdřív zkontroluj prostředí (verze Xcode, xcodegen, uv, `security find-identity -v -p codesigning`) a řekni mi, co chybí.
- Ověř v Apple dokumentaci API, která použiješ (titulky oken a jejich oprávnění, Core Audio process objects, UserNotifications s akcemi).
- Pak navrhni plán a počkej, než ho schválím. Do té doby nepiš kód.
- Po implementaci postav appku přes XcodeBuildMCP a oprav chyby.
- Na konci mi napiš přesný postup ručního testu: jaká oprávnění povolit, co spustit (Teams call, Meet v Brave, Discord) a co mám vidět v menu baru, v notifikacích a v logu.
