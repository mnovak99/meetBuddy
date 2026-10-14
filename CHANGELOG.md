# Changelog

Všechny podstatné změny Meeting Buddyho. Formát podle [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/), verze podle [SemVer](https://semver.org/lang/cs/).
Sekci `[Unreleased]` doplňuj průběžně; `scripts/release.sh` z ní při vydání bere poznámky k verzi.

## [Unreleased]

### Přidáno
- Licence MIT, zdrojáky jsou veřejné.
- Volba „Nahrávat můj mikrofon“ (jde vypnout).
- Varování v menu, když není vybraný Obsidian vault.

### Změněno
- Výchozí nastavení bez osobních hodnot: jméno z účtu na Macu, mikrofon = výchozí vstup systému, `uv` a pipeline se najdou samy (pipeline ve složce, ze které byla appka sestavená). Stávající `config.json` zůstává beze změny.
- Vydání jen z Terminálu (`scripts/release.sh`).

### Odstraněno
- Tlačítko pro vydání na GitHubu a self-hosted runner: u veřejného repa by cizí kód mohl běžet na Macu.

## [0.4.1] – 2026-10-14

### Přidáno
- Vydání tlačítkem na GitHubu (Actions → Release → Run workflow) přes runner na Macu mini; volba patch / minor / major, koncept nebo zkouška.
- Poznámky k vydání z commitů, když v CHANGELOGu nic není.

### Opraveno
- Testy nahrávání zvuku už při běhu nepípají.
- Přepis se zasekával na kouscích zvuku kratších než sekunda (Whisper v nich halucinoval minuty): takové kousky se přeskočí a délka přepisu je omezená podle délky úseku.
- Když se zpracování 30 minut nehne, appka ho ukončí a nahlásí místo nekonečného čekání.

## [0.4.0] – 2026-10-14

### Přidáno
- Okno Meeting Buddy (z menu baru, ⌘,): Slovník, Přehled, Nastavení, Úložiště.
- Slovník podle konvence custom vocabulary: správný tvar, typ, chybné tvary, význam, „Do promptu“ Whisperu a automatická oprava; návrhy nových pojmů po každém meetingu (Přijmout / Upravit / Zamítnout), import a export CSV, počet výskytů v přepisech.
- Přehled nahrávek: otevření poznámky, zpracování znovu, přepis od začátku, smazání do Koše.
- Nastavení: všechny volby `config.json`, start po přihlášení, přehled oprávnění, Hugging Face token.
- Úložiště: zaplnění vůči limitu, mazání starého audia, archivace starých poznámek do `Meetings/Archiv`.
- Ikona: duch se sluchátky, v menu baru se stavovou tečkou.

### Změněno
- Appka se jmenuje Meeting Buddy (`MeetingBuddy.app`); data, oprávnění i logy zůstávají.
- Prompt Whisperu je česká věta-glosář s rozpočtem tokenů; chybné tvary ze slovníku se opraví hned po přepisu.

## [0.3.0] – 2026-10-14

### Přidáno
- Tvůj mikrofon (Arctis) jako samostatná stopa `mic.m4a`, časově sladěná se zvukem meetingu.
- Pipeline: rozlišení mluvčích (pyannote), přepis po úsecích s detekcí jazyka (Whisper large-v3-turbo), čištění a shrnutí přes Claude, poznámka v Obsidianu, `Moje úkoly.md`.
- Spouštění pipeline po nahrávce na pozadí, stav v menu, notifikace „Poznámka je hotová“.
- Bez modelu pro diarizaci vznikne poznámka bez rozlišení mluvčích, bez Clauda poznámka jen s přepisem.

## [0.2.0] – 2026-10-14

### Přidáno
- Nahrávání zvuku jen meeting appky (Core Audio tap podle bundle ID) do AAC odolného vůči pádu.
- Klíčové snímky okna meetingu jen při ustálené změně obsahu.
- `meta.json` s kalendářní událostí (název, účastníci).
- Ruční nahrávání z menu, výběr okna pro snímky, nabídka zahození krátkých nahrávek.

## [0.1.0] – 2026-10-14

### Přidáno
- Menu bar appka s detekcí meetingů v Teams, Google Meet (Brave) a Discordu.
- Notifikace „Nahrávat?“ a „Meeting pravděpodobně skončil“, ošetřená oprávnění.
- `config.json` se schématem, kostra Python pipeline.

[Unreleased]: https://github.com/mnovak99/meetBuddy/compare/v0.4.1...HEAD
[0.4.1]: https://github.com/mnovak99/meetBuddy/releases/tag/v0.4.1
[0.4.0]: https://github.com/mnovak99/meetBuddy/releases/tag/v0.4.0
[0.3.0]: https://github.com/mnovak99/meetBuddy/releases/tag/v0.3.0
[0.2.0]: https://github.com/mnovak99/meetBuddy/releases/tag/v0.2.0
[0.1.0]: https://github.com/mnovak99/meetBuddy/releases/tag/v0.1.0
