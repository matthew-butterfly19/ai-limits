# ai-limits

Aplikacja paska menu macOS, która pokazuje **wykorzystanie limitów i zużycie tokenów**
w Claude Code i Codeksie — razem, w jednym miejscu.

```
ClaudeCode 175M/2.5M · 42%→2h21m · 68%→3d4h  ┃  Codex 107M/2.1M · 60%→2h20m · 28%→6d4h
```

Dwie liczby to tokeny w bieżącym oknie 5 h: łącznie i bez odczytów z cache (te potrafią być
97 % surowego wolumenu i nie przekładają się wprost na zużycie limitu). Dalej kolejne okna
limitów: procent i czas do resetu. Kliknięcie otwiera panel z licznikami, rozbiciem na
modele i najcięższymi wątkami; „Szczegóły…" — okno z wykresami, udziałem projektów
i rozwijaną tabelą wątek × model.

## Skąd biorą się dane

| Źródło | Co daje | Jak |
|---|---|---|
| `api.anthropic.com/api/oauth/usage` | limity Claude Code (5 h, tydzień, okno per model) | token OAuth czytany z Keychaina przy każdym odświeżeniu, nigdzie nie zapisywany |
| `codex app-server` → `account/rateLimits/read` | limity Codeksa (5 h, tydzień) | proces uruchamiany i ubijany przy każdym odczycie |
| `~/.claude/projects/**/*.jsonl` | tokeny per wątek, model, projekt, subagenci | czytane przyrostowo (kursor bajtowy na plik) |
| `~/.codex/sessions/**/*.jsonl` | tokeny per wątek + historyczne próbki limitów | jw. |

Wszystko ląduje w SQLite w `~/Library/Application Support/AILimits/stats.db`.
Nic nie wychodzi na zewnątrz poza dwoma zapytaniami o limity — do Anthropica i OpenAI,
czyli tam, gdzie te limity i tak są liczone.

## Liczenie tokenów

Claude Code zapisuje jedną odpowiedź modelu w kilku liniach JSONL (osobno blok myślenia,
osobno każde wywołanie narzędzia), **powtarzając w każdej ten sam licznik zużycia**.
Deduplikujemy po `(message.id, requestId)`, więc wynik jest niższy niż to, co pokazuje
`/stats` w samym Claude Code — tam każda linia liczy się osobno. Dla Codeksa kluczem jest
`(session_id, ordinal)`, a sumujemy `last_token_usage` z każdego turnu.

Klucz jest `PRIMARY KEY`, a zapis idzie przez `INSERT OR IGNORE` — ponowne wczytanie
dowolnego pliku niczego nie podwaja.

## Budowanie

```bash
./scripts/build.sh            # debug → .build/AILimits.app
./scripts/build.sh release
open .build/AILimits.app
```

Wymaga Command Line Tools (Swift 6.1+). Xcode nie jest potrzebny.

**Dlaczego nie ma `Package.swift`.** Na czystych Command Line Tools dostarczona
`libPackageDescription.dylib` nie eksportuje inicjalizatora `Package`, do którego linkuje
SwiftPM, więc każdy manifest wywala się na etapie linkowania. Sam `swiftc` działa
bez zarzutu, więc `.app` składa skrypt.

**Duplikat mapy modułów.** Niektóre instalacje CLT niosą dwie kopie mapy modułu
`SwiftBridging` (`bridging.modulemap` i przestarzały `module.modulemap`, identyczne poza
rokiem w nagłówku). Wtedy *każda* kompilacja Swifta pada na „redefinition of module
'SwiftBridging'" — nawet gołe `import Foundation`. Skrypt budujący wykrywa to i przykrywa
przestarzały plik nakładką VFS na czas kompilacji. Nie wymaga `sudo` i nie zmienia niczego
w systemie.

## Użycie z terminala

Ta sama binarka działa jako narzędzie CLI:

```bash
.build/AILimits.app/Contents/MacOS/AILimits --ingest    # wczytaj nowe linie logów
.build/AILimits.app/Contents/MacOS/AILimits --totals    # sumy tokenów per aplikacja
.build/AILimits.app/Contents/MacOS/AILimits --threads   # najcięższe wątki
.build/AILimits.app/Contents/MacOS/AILimits --limits    # limity na żywo
```

`--db PATH` wskazuje inną bazę — tak sprawdzamy zgodność kolektora bez ruszania tej właściwej.

## Prototyp w Pythonie

Katalog `ailimits/` i `plugin/ailimits.2m.py` to działający prototyp na SwiftBarze, z którego
wyrosła ta aplikacja. Zostaje w repo do czasu, aż natywna wersja przejmie wszystko —
i jako niezależny punkt odniesienia dla liczb.

```bash
python3 -m ailimits.cli menu
python3 -m ailimits.cli ingest
python3 -m ailimits.cli dashboard
```
