# ai-limits

Widget do paska menu macOS (SwiftBar), który pokazuje **wykorzystanie limitów i zużycie
tokenów** w Claude Code i Codeksie — razem, w jednym miejscu.

```
ClaudeCode 60M · 14%→4h30m · 65%→3d7h ┃ Codex 19M · 28%→4h29m · 23%→6d6h
```

Liczba tokenów to zużycie od północy, potem kolejno okna limitów: procent i czas do resetu.
Kliknięcie rozwija szczegóły (rozbicie na wejście/wyjście/cache, wątki dnia), a pozycja
„Pełny dashboard" generuje stronę HTML z wykresami 24 h i tabelą wątków.

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

## Instalacja

1. `brew install --cask swiftbar`
2. Katalog wtyczek ustaw na `~/Library/Application Support/SwiftBar/Plugins`
3. Skopiuj tam `plugin/ailimits.2m.py` (interwał odświeżania siedzi w nazwie pliku)
4. Repo trzymaj w `~/Projects/ai-limits` albo popraw ścieżkę w pierwszej linii wtyczki

Wymaga tylko systemowego Pythona 3.9 z macOS — zero zależności.

## Użycie z terminala

```bash
python3 -m ailimits.cli menu        # to, co widzi SwiftBar
python3 -m ailimits.cli ingest      # samo wczytanie nowych logów
python3 -m ailimits.cli dashboard   # generuje HTML i wypisuje ścieżkę
```
