# AI Limits

Widget paska menu macOS, który odpowiada na jedno pytanie: **czy limit wystarczy mi do
resetu** — dla Claude Code i Codeksa naraz, plus zużycie tokenów DeepSeek Harness (dsh),
który rozlicza się inaczej i nie ma własnego okna limitu.

![Pasek menu](docs/menubar.png)

Procent zużycia, czas do resetu i prognoza na koniec okna. Kiedy okno ma wyschnąć przed
resetem, zamiast prognozy pojawia się alarm z godziną, o której skończą się tokeny.

## Panel

![Panel](docs/panel.png)

Kliknięcie rozwija panel z licznikami obu okien, werdyktem („starczy" / „na styk" /
„zabraknie za…") i listą sesji **wycenionych w procentach limitu**, a nie w tokenach —
procent jest walutą, w której się płaci. Na dole porównanie z tym samym momentem tydzień
wcześniej.

Przycisk *Szczegóły…* otwiera okno z wykresami: tokeny w godzinach, tydzień do tygodnia,
przebieg wykorzystania limitów, tabela modeli i rozwijana lista wątków.

Ikona zębatki obok niego chowa dwa ustawienia: co ma prowadzić w pasku menu (okna, tokeny
albo oba) i które aplikacje w ogóle dostają tam segment — przydatne, gdy jedna z nich milczy
tygodniami i tylko zajmuje miejsce.

Ostatnia sekcja, **AI Review Platform**, nie liczy kosztu, tylko wydaje werdykt o kluczu
OpenRoutera, którym płaci platforma recenzji: *klucz działa* / *limit na wyczerpaniu* /
*limit wyczerpany*, *wyłączony*, *wygasł* — plus pasek tygodniowego limitu i ile z niego
zostało. Powód jest konkretny: wyczerpany limit nie zatrzymuje platformy, tylko po cichu
wyłącza skautów, a recenzja i tak się publikuje — pusta, nie do odróżnienia od „nic nie
znaleziono”. Sekcja pojawia się po wskazaniu klucza w *OpenRouter…* (przy jednym kluczu z
„review” w nazwie wskazuje się sam) i korzysta z tego samego management key co Harness.
W pasku menu ten sam klucz to segment `Review 12,1$/d` na końcu linii — jak koszt Harnessa,
wyłączany pod zębatką. Na drabinie skracania odpada przed pierwszą aplikacją, ale martwy
klucz zostawia `Review ⚠`, którego skracanie nie zdejmuje.

## Kiedy w pasku brakuje miejsca

macOS nie skraca elementu paska menu, który się nie mieści — **chowa go w całości**, razem z
ikonami sąsiadów po lewej. Pełna linia dla trzech aplikacji ma ok. 800 pt, a między notchem
a blokiem Centrum sterowania bywa 270 pt, więc na MacBooku z kilkoma innymi ikonami znika
cała linia i nic tego nie sygnalizuje.

Dlatego linia zwija się sama (checkbox *Skracaj przy braku miejsca* pod zębatką, domyślnie
włączony). Kolejność jest stała i idzie od najtańszej straty do najdroższej: odstępy wokół
separatora, prognoza `≈88%`, tokeny, okno 7 d, czas do resetu, potem odpadają całe aplikacje
— najpierw Harness, bo nie ma okna limitu, więc nigdy nie jest tą aplikacją, której limit
zaraz się skończy — a na dwóch ostatnich szczeblach znikają też nazwy i zostaje `21% ⚠`.
Alarm `⚠` i znacznik cache `↻` zostają zawsze; `…` na końcu linii znaczy „to nie jest już
pełny obraz”. Panel po kliknięciu pokazuje komplet.

Najniżej drabina przestaje skracać, a zaczyna po prostu być: `47%` bez `…` (61 pt), a pod tym
sam znak `◆` — albo `⚠`, jeśli któreś okno kończy się przed resetem (47 pt, z czego 37 to
nieusuwalny margines przycisku, więc węziej się nie da). Ten ostatni szczebel nie niesie już
liczby, ale jest czymś, w co da się kliknąć.

Przy dwóch ekranach macOS trzyma **osobną kopię elementu na każdej belce**, w różnych
miejscach, a tytuł jest wspólny — więc o długość linii gra ta belka, która jest najciaśniejsza
spośród tych, które w ogóle mogą element narysować. Belka bez miejsca nie zabiera informacji
z tej, na której miejsce jest: i tak niczego tam nie widać.

Gdzie przebiega granica rysowalnego paska, aplikacja **uczy się z obserwacji**, a nie zakłada:
`auxiliaryTopRightArea` (prawy brzeg notcha) potrafi się mylić o kilkadziesiąt punktów, a na
monitorze bez notcha nie ma żadnego API, które by tę granicę podawało. Po każdej zmianie linii
aplikacja pyta window servera, czy element faktycznie został narysowany, i zapamiętuje
najdalszą pozycję, na której go odrzucono. Lekcja wygasa po pół godziny, bo na ekranie bez
notcha granica zależy od menu aktywnej aplikacji. Tam, gdzie granicy nie da się policzyć,
aplikacja po prostu próbuje: po każdym udanym wyświetleniu sięga o jeden szczebel wyżej, aż
któryś zostanie odrzucony. `AILIMITS_TRACE=1` pokazuje cały ten przebieg krok po kroku.

`AILimits --menubar` wypisuje całą drabinę z szerokościami w punktach; uruchomiona aplikacja
z `AILIMITS_TRACE=1` dopisuje do tego, gdzie leży jej slot w pasku i czy macOS ją rysuje.

Osobna sprawa to **miejsce w kolejce ikon**, bo nie naprawia go żadna długość. Zmierzone na
MacBooku z notchem: system stawiał element na 993…1026 pt, gdy rysowalna część paska zaczyna
się od 1010 — nie widać nic, a skracanie przesuwa tylko lewą krawędź slotu, bo prawa jest
przybita. `MenuBarExtra` ze SwiftUI nie daje na to żadnego uchwytu, dlatego aplikacja ma
własny `NSStatusItem` z `autosaveName`: pozycję zapisuje się w `UserDefaults`, przy pierwszym
uruchomieniu ustawiamy ją po prawej stronie paska i od tej pory element jest rysowany. Twoje
⌘-przeciągnięcie nadpisuje ten sam klucz, więc ręczny wybór wygrywa.

Skoro element rysuje się zawsze, pytanie o długość zmienia sens: nie „czy mnie widać”, tylko
„ile mogę zabrać, żeby nie wypchnąć z paska cudzej ikony”. Budżetem jest wolne miejsce przed
najbardziej lewą cudzą ikoną; jego miarę aplikacja bierze raz na pół godziny, schodząc na
najkrótszy szczebel i czekając, aż wypchnięte ikony wrócą. Gdy mimo to któraś zniknie, linia
schodzi o szczebel niżej. Bez tego element zjadał pasek do zegara — to jest ten sam objaw,
tylko przeniesiony na sąsiadów.

Na ciasnej belce laptopa może się okazać, że wolnego miejsca nie ma wcale — wtedy każdy punkt
linii kosztuje jedną cudzą ikonę. Wyboru za użytkownika nie da się tu zrobić: albo w pasku
jest procent, albo jest ta ikona.

Na ten jeden przypadek jest ostatnie zabezpieczenie: gdy pasek odrzuci nawet sam znak,
pojawia się **ikona w Docku** z procentem okna 5 h tej aplikacji, która jest najbliżej ściany,
a kliknięcie w nią otwiera okno szczegółów. Znika, gdy tylko pasek znowu cokolwiek rysuje.
Checkbox *Ikona w Docku, gdy pasek nic nie pokazuje* (pod zębatką) wyłącza ją na stałe.

## Instalacja

```bash
git clone https://github.com/matthew-butterfly19/ai-limits.git
cd ai-limits
./scripts/install.sh
```

Aplikacja ląduje w `/Applications` i startuje przy logowaniu. Odinstalowanie:
`./scripts/install.sh --uninstall` (baza statystyk zostaje nietknięta).

Wymaga macOS 14+ i Command Line Tools. Xcode nie jest potrzebny.

## Skąd biorą się dane

| Źródło | Co daje |
|---|---|
| `api.anthropic.com/api/oauth/usage` | limity Claude Code — okno 5 h, tygodniowe i osobne okna per model |
| `codex app-server` → `account/rateLimits/read` | limity Codeksa — okno 5 h i tygodniowe |
| `~/.claude/projects/**/*.jsonl` | tokeny per wątek, model, projekt, subagenci |
| `~/.codex/sessions/**/*.jsonl` | jw. plus historyczne próbki limitów z samych logów |
| `~/.dsh/sessions/**/session.jsonl.zstd` | tokeny per wątek i model dla dsh — bez limitu, bo dsh rozlicza się przez OpenRouter, nie przez subskrypcję z oknem |

Token OAuth Claude'a czytamy z Keychaina przy każdym odczycie i nigdzie go nie zapisujemy.
Management key do OpenRoutera leży w pliku `~/Library/Application Support/AILimits/openrouter-key`
z prawami `0600`, a nie w Keychainie: lista dostępu wpisu w keychainie jest przypięta do
konkretnego pliku binarnego, więc po każdej instalacji lokalnego builda system pytał o hasło do
keychaina od nowa i „Zawsze zezwalaj” tego nie kończyło. Klucz zapisany przez starszą wersję
aplikacja przenosi do pliku sama, przy pierwszym odczycie — to jedno, ostatnie pytanie o hasło.
Wszystko inne zostaje na dysku, w SQLite pod `~/Library/Application Support/AILimits/`.
Poza dwoma zapytaniami o limity — do Anthropica i OpenAI, czyli tam, gdzie te limity i tak
są liczone — nic nie wychodzi na zewnątrz. Szczegóły w [SECURITY.md](SECURITY.md).

## Jak liczona jest prognoza

Samo tempo („3,1 %/h") niczego nie rozstrzyga — przy czterech godzinach do resetu jest
wygodne, przy jednej zabójcze. Dlatego tempo jest zawsze zestawione z **budżetem**:

```
budżet  = (100 − zużyte) / godziny do resetu
koniec  = zużyte + tempo × godziny do resetu
```

Dla okna 5 h tempo bierzemy z ostatniej godziny. Dla tygodniowego — ze średniej od
otwarcia okna, bo tempo z popołudnia rozciągnięte na trzy doby ignoruje noce i przerwy.
Poniżej trzech próbek prognozy nie ma wcale; projekcja z dwóch punktów to zgadywanka
w przebraniu pomiaru.

## Czego te liczby nie mówią

**dsh nie ma prognozy ani werdyktu, tylko tokeny.** OpenRouter rozlicza per token, nie przez
subskrypcję z resetem, więc nie ma tu żadnego okna do wypełnienia — sekcja Harness w panelu
liczy wyłącznie zużycie, a w pasku menu pokazuje tokeny zawsze, niezależnie od trybu, bo to
jedyne, co ma do powiedzenia.

**Procent per sesja to udział w tokenach, nie zmierzony koszt.** Suma po sesjach zgadza się
z licznikiem okna co do procenta, ale podział między nie zakłada, że token kosztuje tyle
samo niezależnie od modelu. Dostawcy nie podają wag per model; żeby je oszacować, potrzeba
kilkunastu okien z próbkami — aplikacja zbiera je od pierwszego uruchomienia.

**Kompaktowanie kontekstu nie jest nigdzie policzone.** Wywołanie kompaktujące przeczytuje
całą rozmowę i kosztuje realne tokeny, ale Claude Code zapisuje rekord `compact_boundary`
bez bloku `usage`, a Codex — `token_count` z zerami. Limit to odczuwa, logi nie. Kompakty
trafiają więc do osobnej tabeli i są pokazywane obok sum, nigdy w nich (`--compactions`).

**Sumy są niższe niż `/stats` w Claude Code.** Claude zapisuje jedną odpowiedź modelu
w kilku liniach JSONL, powtarzając w każdej ten sam licznik zużycia. Deduplikujemy po
`(message.id, requestId)`; `/stats` liczy każdą linię osobno. Dla Codeksa kluczem jest
`(session_id, ordinal)`, dla dsh — `(session_id, seq)`, bo jego własny log już numeruje
każde zdarzenie.

## Z terminala

Ta sama binarka działa jako narzędzie wiersza poleceń:

```bash
AILimits=/Applications/AILimits.app/Contents/MacOS/AILimits

$AILimits --limits        # limity na żywo
$AILimits --totals        # sumy tokenów per aplikacja
$AILimits --threads       # najcięższe wątki
$AILimits --models        # co który model daje za to, co zużywa
$AILimits --compactions   # kompakty kontekstu i ich szacowany koszt
$AILimits --ingest        # wczytaj nowe linie logów
$AILimits --backfill      # przejdź logi od nowa (bezpieczne, nic się nie dubluje)
```

`--db PATH` wskazuje inną bazę — tak sprawdzamy zgodność kolektora bez ruszania tej właściwej.

## Budowanie

```bash
./scripts/build.sh          # debug
./scripts/build.sh release
```

Dwie osobliwości stockowych Command Line Tools, obie obsłużone w skrypcie i żadna nie
wymaga `sudo`:

- **Nie ma `Package.swift`.** Dostarczona `libPackageDescription.dylib` nie eksportuje
  inicjalizatora `Package`, do którego linkuje SwiftPM, więc każdy manifest pada na
  linkowaniu. Sam `swiftc` działa bez zarzutu, więc `.app` składa skrypt.
- **Duplikat mapy modułów.** Część instalacji CLT niesie dwie kopie mapy modułu
  `SwiftBridging`. Wtedy *każda* kompilacja Swifta pada na „redefinition of module" — nawet
  gołe `import Foundation`. Skrypt wykrywa to i przykrywa przestarzały plik nakładką VFS na
  czas kompilacji.

macOS nie ma systemowego zstd — sesje dsh są nim skompresowane, więc odczyt ładuje
Homebrew'owe `libzstd.dylib` przez `dlopen` w czasie działania (nie w czasie budowania,
więc `./scripts/build.sh` tego nie wymaga). Bez `brew install zstd` ingestia dsh po cichu
się pomija — reszta aplikacji działa normalnie.

## Licencja

MIT. Katalogi `ailimits/` i `plugin/` to prototyp w Pythonie na SwiftBarze, z którego
wyrosła ta aplikacja; nie jest już używany i zostaje jako niezależny punkt odniesienia
dla liczb.
