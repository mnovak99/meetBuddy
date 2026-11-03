# Changelog

Všechny podstatné změny Meeting Buddyho. Formát podle [Keep a Changelog](https://keepachangelog.com/cs/1.1.0/), verze podle [SemVer](https://semver.org/lang/cs/).
Sekci `[Unreleased]` doplňuj průběžně; `scripts/release.sh` z ní při vydání bere poznámky k verzi.

## [Unreleased]

### Přidáno
- Licence MIT, zdrojáky jsou veřejné.
- Volba „Nahrávat můj mikrofon“ (jde vypnout).
- Nová nastavení (`config.json`, Nastavení → záložky):
  - **Detekce:** prohlížeč pro Google Meet (Brave, Chrome, Edge, Arc, Vivaldi, Opera nebo vlastní bundle ID), interval kontroly, konec bez jakéhokoli signálu (`endGraceSeconds`), automatické ukončení nahrávání, když po pravděpodobném konci nikdo neodpoví (`autoStopMinutes`, výchozí vypnuto).
  - **Notifikace:** zvuk a jednotlivé druhy notifikací (konec meetingu, hotová poznámka, úložiště, problémy při nahrávání); „Nahrávat?“ a chyby se zobrazují vždy.
  - **AI a pipeline:** jazyky přepisu, model Whisperu, model Clauda, přepis do poznámky, zápis do „Moje úkoly.md“, název složky poznámek, počet vláken CPU, nezpracovávat během nahrávání (výchozí zapnuto), zpracovat až když Mac N minut nepoužíváš.
  - **Vzhled a diagnostika:** ikona v menu baru (duch / symbol), podrobné logování.
- Checklist připravenosti (oprávnění, vault, token, Claude, uv a pipeline, start po přihlášení) s tlačítky, které rovnou vyžádají oprávnění nebo otevřou správné místo.
- Varování v panelu a v checklistu, když není vybraný Obsidian vault.
- Pipeline respektuje nová nastavení: jazyky přepisu, model Whisperu, model Clauda, počet vláken, složka poznámek, přepis v poznámce, zápis úkolů do seznamu a podrobné logování (`--verbose`).

### Změněno
- Výchozí nastavení bez osobních hodnot: jméno z účtu na Macu, mikrofon = výchozí vstup systému, `uv` a pipeline se najdou samy (pipeline ve složce, ze které byla appka sestavená). Stávající `config.json` zůstává beze změny.
- Vydání jen z Terminálu (`scripts/release.sh`).
- Ovládání z menu baru je panel místo rozbalovacího menu; Nastavení je samostatné okno se záložkami (⌘,), změny se ukládají hned.
- Pipeline čeká, dokud běží nahrávání (jde vypnout), a volitelně na nečinnost Macu.
- Pipeline dostává z appky `--verbose` při podrobném logování a počet vláken z nastavení; z prostředí se odstraňují všechny proměnné `ANTHROPIC_*` a `CLAUDE_CODE_*`.

### Opraveno
- Appka padala (zamrzla a pak ji systém ukončil) hned po „Nahrávat“, když byl zapnutý čas nahrávání v menu baru: měnící se ikona vyvolávala nekonečné překreslování. Čas vedle ikony je odstraněný (délku nahrávání ukazuje panel), obrázek ducha se kreslí jen jednou.
- `audio.m4a` byl zrychlený a měl jen třetinu skutečné délky, když mikrofon (např. sluchátka Arctis v režimu headset) přepnul zvukové zařízení na 16 kHz. Obě stopy se teď značí skutečnou frekvencí zařízení. Týká se i starších nahrávek.
- Fronta pipeline se zasekla, když se zpracování nepodařilo spustit (chybějící složka pipeline, smazaná nahrávka).
- „Přepsat znovu od začátku“ u právě zpracovávané nahrávky přepisovalo její `status.json`; teď se provede po skončení běžícího zpracování.
- Smazání nahrávky ve frontě nebo ve zpracování ji nejdřív z fronty odstraní a zpracování zastaví.
- Zapnutí mikrofonu v Nastavení si hned vyžádá oprávnění (dřív až po restartu); nevyžádaná oprávnění se nabízejí k povolení místo odkazu do Nastavení systému.
- Ukončení appky těsně po vypínání Macu už nepřeruší dokončování nahrávky; druhá nahrávka nemůže přepsat rozpracovanou.
- Víc krátkých nahrávek čekajících na „Zahodit / Ponechat“ najednou; bez odpovědi se zpracují po příštím spuštění.
- Ukončení appky během zpracování už nehlásí falešné selhání.
- Hodnoty mimo rozsah schématu (`audioRetentionDays`, `storageLimitGB`, `minDurationMinutes`) se ořezávají.
- Text o oprávnění systémového zvuku odkazoval na „Meeting Assistant“.
- Zpracování dlouhých meetingů už appka neukončí jako zaseklé: pipeline během dlouhých kroků (rozpoznávání mluvčích, stahování modelu, Claude) průběžně obnovuje `status.json`.
- Při ukončení appky pipeline zastaví i běžícího `claude` a při dalším spuštění pokračuje od hotových kroků.
- Nečekaná chyba (poškozený soubor, chyba modelu) skončí jako `failed` s popisem místo věčného „transcribing“; poškozené mezivýsledky se přepočítají.
- Opakované zpracování nevytváří duplicitní úkoly v `Moje úkoly.md` ani nepadá na snímcích přesunutých do Koše.
- Když selže jen shrnutí, poznámka si nechá jména mluvčích a opravy z čištění.
- Volání `claude` ignoruje všechny proměnné `ANTHROPIC_*` a `CLAUDE_CODE_*` a nespouští MCP servery uživatele.
- Slovníkový pojem s obráceným lomítkem už neshodí automatickou opravu.
- Odmítnutý nebo nezodpovězený meeting už neblokuje detekci dalšího hovoru (nový hovor po pauze ve zvuku nebo nové okno Meet se nabídne k nahrávání).
- Nahrávání mikrofonu: stopa je vždy mono, vícekanálové mikrofony se nesmíchají se zvukem meetingu; když mikrofon nejde od zvuku meetingu rozlišit, nahraje se jen zvuk meetingu a appka to řekne. Výpadky při ukládání zvuku se hlásí v panelu i v Přehledu.
- Přidání pojmu, který ve slovníku už je (i s jinou velikostí písmen), ho sloučí místo zdvojení; počítání výskytů v přepisech už neblokuje okno.
- Ukončení pipeline zastaví i její podprocesy (uv, Python, claude) a po 5 s dorazí SIGKILL tomu, co SIGTERM ignoruje.
- Smazání právě zpracovávané nahrávky už nehlásí falešné selhání a nenabízí „Zkusit znovu“ na smazané složce.
- „Zpracovat znovu“ se u hotové poznámky nenabízí (vznikala by kopie „(2)“); pro změnu slovníku je „Přepsat znovu od začátku“.
- Když Claude selže při opakovaném čištění po změně jména nebo slovníku, zůstane předchozí čištění i shrnutí místo poznámky jen s přepisem.
- Google Meet: přejmenování záložky v téže schůzce (připojení, sdílení) už nevyvolá novou otázku „Nahrávat?“; nová schůzka = jiné okno nebo jiný kód schůzky. Teams a Discord: krátký výpadek zvuku plus nové okno chatu už není nový hovor.
- Zvuk meetingu se ukládá ve formátu, který skutečně dodává virtuální zařízení (při mikrofonu s jinou vzorkovací frekvencí byl dřív špatně rychlý). Výpadky se počítají zvlášť pro zvuk meetingu a mikrofon.
- Kliknutí na „Nahrávat“ během dokončování předchozí nahrávky se neztratí, provede se hned potom. Oprávnění k mikrofonu se při prvním spuštění nežádá dvakrát.
- Seznam nahrávek se načítá na pozadí, okno při stovkách nahrávek nezamrzá. Export diagnostiky vynechává účastníky z kalendáře; chybová hláška Clauda už neobsahuje text jeho odpovědi.
- Poznámky čekající na shrnutí se po startu zkoušejí znovu jen tehdy, když je nainstalovaný `claude`.

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
