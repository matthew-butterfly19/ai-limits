import AppKit

/// Picks the longest version of the menu bar line that the bar actually has
/// room for.
///
/// macOS does not truncate a status item that does not fit — it hides the whole
/// item. The item keeps its slot in the layout (visible in
/// `CGWindowListCopyWindowInfo(.optionAll)`, absent from `.optionOnScreenOnly`),
/// and every item further left is evicted along with it. Measured on the
/// machine this was written on: the full three-app line was 818 pt wide, the
/// space between the notch and the fixed Control Centre cluster was 276 pt, and
/// the result was no AI Limits in the menu bar at all — plus iStat Menus'
/// icons gone with it. That is the failure this class exists to prevent.
///
/// Three mechanisms, deliberately:
///
/// * **Budget** — `slot.maxX − edge` is how much room the line has, so the
///   right rung can be picked in one step. Needs a left edge, which comes from
///   the notch or from what the bar has already refused.
/// * **Feedback** — after the title is set, `isRendered` asks the window server
///   whether the item is actually on screen and steps down a rung if it is not.
///   No geometry assumptions at all, so this is what keeps an external monitor
///   honest, and what corrects any error in the budget.
/// * **Probing** — where no edge can be computed, one longer rung is tried
///   after each success until one is refused. Without it a line that had to
///   shrink on the cramped built-in bar would keep that length after moving to
///   a bar with room to spare.
///
/// All three are per menu bar, not per app: see `statusWindows`.
@MainActor
final class MenuBarFit {
    /// `MenuBarExtra`'s button pads the label by this much in total — measured
    /// against the real status window once it had settled: a 97 pt line sat in
    /// a 132 pt slot, so 35, rounded up. Up is the safe direction: over-stating
    /// the width can only pick a rung shorter than necessary, under-stating it
    /// picks one that vanishes. Not re-derived at runtime from a title that may
    /// have been measured mid-render; `diagnostics` prints the live delta, so a
    /// future macOS changing this shows up in the trace.
    private static let padding: CGFloat = StatusItem.margin
    /// Only climb back to a longer rung when it fits with room to spare, so a
    /// percentage ticking between 9 % and 10 % cannot flip the line every tick.
    private static let slack: CGFloat = 16
    /// Ile musi minąć od skrócenia linii, zanim wolno jej znowu próbować się
    /// wydłużyć.
    ///
    /// Skracanie jest natychmiastowe — bo alternatywą jest zniknięty element
    /// albo zepchnięta cudza ikona. Wydłużanie nie ma takiego usprawiedliwienia:
    /// zysk jest kosmetyczny, a koszt to przesunięcie całego paska. Bez tego
    /// progu belka, na której nasza szerokość wypada dokładnie na granicy,
    /// wydłużała się i skracała w kółko co kilka sekund: wydłuż się, zepchnij
    /// ikonę, skróć się, ikona wraca, wydłuż się. Pierwsza wspinaczka po starcie
    /// nie jest tym objęta — nic jeszcze nie skróciło linii, więc nie ma czego
    /// wyciszać.
    private static let growCooldown: TimeInterval = 300
    /// Long enough for the status item to have been laid out and drawn after a
    /// title change, short enough that walking the whole ladder is invisible.
    private static let settleDelay: TimeInterval = 0.25

    private static let font = StatusItem.font

    /// Step-by-step record of a fitting pass, under `AILIMITS_TRACE` — the only
    /// way to see why a line ended up on the rung it did, since every decision
    /// happens between two frames nobody is watching.
    private static let tracing = ProcessInfo.processInfo.environment["AILIMITS_TRACE"] != nil
    private func trace(_ line: @autoclosure () -> String) {
        guard Self.tracing else { return }
        FileHandle.standardError.write(Data("  fit: \(line())\n".utf8))
    }

    /// How long a "that position was hidden" observation is trusted before the
    /// fitter probes upwards again. The drawable edge is not a constant on a
    /// screen without a notch — it moves with the frontmost app's menus — so
    /// the lesson has to expire, or the line would stay short for the rest of
    /// the session because one menu-heavy app was in front once.
    private static let lessonLifetime: TimeInterval = 30 * 60

    /// Where the drawable part of this bar starts, learned from what actually
    /// drew. `auxiliaryTopRightArea` is not that edge: an item whose slot began
    /// 10 pt to the right of it was still hidden, and on a screen without a
    /// notch there is no published edge at all. So both bounds come from
    /// observation — `hiddenAt` is the furthest right an item was refused,
    /// `shownAt` the furthest left one was drawn.
    private struct Lesson {
        var hiddenAt: CGFloat?
        var shownAt: CGFloat?
        /// Ta belka odmówiła nawet najkrótszej wersji. Nie da się na niej
        /// pokazać niczego, więc nie ma też prawa dyktować długości drugiej.
        var impossible = false
        /// The longest rung this bar was seen drawing (rungs are numbered from
        /// the longest down). Where no budget can be computed, this is what
        /// spares the user watching the line grow one rung at a time every time
        /// they come back to that display — it starts from what worked last.
        var bestIndex: Int?
        /// Ile punktów paska zajmują cudze ikony, gdy wszystkie się mieszczą.
        /// Maksimum z obserwacji: linia dłuższa od budżetu spycha sąsiadów za
        /// krawędź, więc bieżąca suma bywa zaniżona — a wtedy budżet rósłby
        /// sam z siebie i element zjadałby pasek do końca. Dokładnie to zrobił
        /// przy pierwszym podejściu: została nasza linia, zegar i Centrum
        /// sterowania.
        var neighbours: CGFloat?
        /// Ile cudzych ikon mieści się na tej belce, gdy nikt nie wypadł.
        /// Sama szerokość nie wystarcza jako kryterium: moduły iStata zmieniają
        /// szerokość razem z liczbami, więc suma faluje o kilkadziesiąt punktów
        /// i pomiar potrafi być zaniżony. Liczba ikon nie faluje wcale — jeśli
        /// spadła, to znaczy, że nasza linia kogoś zepchnęła.
        var items: Int?
        /// Najkrótszy szczebel, którego ta belka nie przyjęła bez szkody dla
        /// sąsiadów — czyli sufit dla sondowania w górę. W odróżnieniu od
        /// `bestIndex` nie obniża się po sukcesie i nie przedawnia: skoro raz
        /// zobaczyliśmy, że przy tej długości komuś ubyło ikony, nie ma powodu
        /// sprawdzać tego co pół godziny od nowa. To jest jedyna rzecz, która
        /// naprawdę kończy oddychanie paska.
        var ceiling: Int?
        /// Najwęższa linia, przy której belka odmówiła albo zepchnęła sąsiada.
        /// Na ekranie bez wcięcia to jedyny sposób, żeby w ogóle mieć budżet:
        /// krawędzi menu nie da się odczytać, ale „przy 690 pt ikony wypadły”
        /// jest twardą liczbą i wystarcza, żeby następnym razem wybrać szczebel
        /// od razu, zamiast wspinać się po jednym aż do awarii.
        var refusedWidth: CGFloat?
        /// Kiedy ta belka ostatnio kazała nam się skrócić. Per belka, bo
        /// globalnie znaczyło to, że ciasny pasek laptopa uciszał wydłużanie na
        /// monitorze, który ma pół belki wolnej — i po powrocie na monitor
        /// zostawał sam znak zamiast całej linii.
        var shrunkAt: Date?
        var stamp = Date()
    }
    /// Po jednej lekcji na belkę. Jedna wspólna znaczyła, że nauka na ekranie
    /// wbudowanym kasowała wszystko, czego aplikacja dowiedziała się o
    /// zewnętrznym — a przy dwóch ekranach obie belki żyją równolegle.
    private var lessons: [String: Lesson] = [:]
    /// Ekran, na którym była belka, gdy ostatnio o to pytano — patrz `barMoved`.
    private var lastActiveSignature: String?

    private func signature(_ screen: NSScreen) -> String {
        "\(Int(screen.frame.minX))x\(Int(screen.frame.width))"
    }

    /// Przedawnia się sama odmowa, nie cała lekcja.
    ///
    /// `hiddenAt` i `impossible` opisują krawędź, która zależy od menu
    /// aplikacji na wierzchu — te muszą wygasać. `neighbours`, `items` i
    /// `bestIndex` opisują cudze ikony na tej belce i tak się nie zmieniają.
    /// Kasowanie wszystkiego naraz miało widoczny skutek: po pół godziny
    /// znikał budżet, a bez budżetu przebieg zaczynał od najdłuższego
    /// szczebla i schodził w dół po jednym, co 0,25 s. Dokładnie to, co widać
    /// w pasku jako „rozwija się na pełno i kurczy w oczach”.
    private func lesson(for screen: NSScreen) -> Lesson? {
        guard var lesson = lessons[signature(screen)] else { return nil }
        if Date().timeIntervalSince(lesson.stamp) >= Self.lessonLifetime {
            lesson.hiddenAt = nil
            lesson.impossible = false
            lesson.refusedWidth = nil
        }
        return lesson
    }

    private var verification: Task<Void, Never>?
    /// Warianty, nad którymi pracuje trwający przebieg — patrz `verify`.
    private var running: [String]?
    /// Numer przebiegu. Po samej liście wariantów nie da się ich rozróżnić:
    /// przebieg, który przerzuca się na drugą belkę, woła `verify` z tą samą
    /// listą, więc porównanie przez równość kazałoby pierwszemu posprzątać po
    /// drugim — i zostałby przebieg, którego nikt już nie potrafi przerwać.
    private var generation = 0

    /// Przebieg się skończył (sam albo przerwany). Sprząta po sobie tylko
    /// wtedy, gdy w międzyczasie nikt nie zdążył zacząć nowego.
    private func finished(_ generation: Int) {
        guard self.generation == generation else { return }
        running = nil
        verification = nil
    }
    /// Which rung was last handed out — where the fitting pass starts.
    private var currentIndex = 0

    /// Zgłasza wynik przebiegu jednym faktem: czy pasek menu odmówił nawet
    /// najkrótszego szczebla. `true` znaczy, że przez pasek nie da się już
    /// dotrzeć do tych liczb ani nawet w niego kliknąć — wtedy aplikacja musi
    /// pokazać się gdzie indziej (patrz `AppModel.barIsHidden` i `DockIcon`).
    /// Wołane tylko wtedy, gdy odpowiedź jest pewna: „belka nic nie rysuje”
    /// (pełny ekran, wygaszony ekran) nic tu nie mówi i nic nie zgłasza.
    var onHidden: ((Bool) -> Void)?

    /// The line to show right now, plus a pass that corrects it once the bar
    /// has stopped moving.
    ///
    /// What it deliberately does not do is measure synchronously. This runs on
    /// every app switch, and at that instant the status item is often still
    /// being handed from one screen's bar to the other's: its frame describes
    /// where it just was. Deciding from that produced exactly the symptom this
    /// is meant to prevent — the line collapsing to `22% …` on switching apps
    /// and only recovering a tick later. So the rung already in use is kept,
    /// and every decision waits for the frame to hold still.
    func fit(_ variants: [String], apply: @escaping (String) -> Void) -> String {
        guard !variants.isEmpty else { return "" }
        // Szczebel, który ta belka narysowała ostatnio — od razu, jeszcze przed
        // jakimkolwiek pomiarem. Bez tego linia po przeniesieniu na ciaśniejszy
        // ekran pokazuje się na pełno i dopiero po chwili kurczy w oczach:
        // dokładnie ten objaw, o który poszło.
        if let screen = activeScreen() {
            var start = lesson(for: screen)?.bestIndex ?? currentIndex
            // …ale nigdy dłuższy, niż pozwala budżet tej belki. Sam pamiętany
            // szczebel bywa optymistyczny (pochodzi z chwili, gdy sąsiadów było
            // mniej), a wtedy każde odświeżenie zaczynało od zbyt długiej linii
            // i skracało ją w oczach.
            if let budget = budget(on: screen) {
                start = max(start, variants.firstIndex { width(of: $0) <= budget }
                                    ?? (variants.count - 1))
            }
            currentIndex = min(start, variants.count - 1)
        }
        let immediate = variants[min(currentIndex, variants.count - 1)]
        verify(variants, apply: apply)
        return immediate
    }

    /// Waits for the bar to settle, picks the rung the budget allows, then
    /// checks it against what the window server actually drew and walks down
    /// until the item reappears. Cancels any pass still running, so a burst of
    /// refreshes leaves exactly one loop behind.
    func verify(_ variants: [String], apply: @escaping (String) -> Void, attempt: Int = 0) {
        guard variants.count > 1 else { return }
        // Ta sama lista co w trwającym przebiegu nie wnosi nic, a przerwanie
        // kosztuje: pomiar sąsiadów trwa kilka sekund i przy odświeżeniu co
        // 30 s, plus zdarzeniach z zewnątrz, nigdy nie dobiegał końca. Nie
        // dobiegał — więc `neighbours` zostawało puste, więc nie było budżetu,
        // więc następny przebieg znowu zaczynał od zera.
        //
        // Tylko dla wywołań z zewnątrz: przerzucenie się na drugą belkę
        // (`attempt: 1`) woła to z tą samą listą, w środku trwającego
        // przebiegu, i musi przejść — inaczej belka, która nie narysuje nic,
        // nigdy nie oddałaby głosu drugiej ani nie zapaliła ikony w Docku.
        if attempt == 0, let running, running == variants,
           let task = verification, !task.isCancelled {
            return
        }
        verification?.cancel()
        generation += 1
        let generation = self.generation
        running = variants
        verification = Task { @MainActor [weak self] in
            defer { self?.finished(generation) }
            // One copy of the item is chosen for the whole pass and never
            // re-resolved. Re-asking every sample let the choice alternate
            // between the two bars' copies, whose frames differ — so the frame
            // never looked settled, the pass gave up, and the line kept
            // whatever length it had.
            guard let self,
                  let window = self.governingWindow(
                    minimumWidth: self.width(of: variants[variants.count - 1]))
            else { return }
            guard var slot = await self.settledFrame(of: window) else {
                self.trace("ramka się nie ustabilizowała — przebieg porzucony")
                return
            }
            var index = self.currentIndex
            // Ile miejsca zajmują cudze ikony, gdy wszystkie się mieszczą. Da
            // się to zmierzyć tylko wtedy, gdy nasza linia niczego nie wypchnęła
            // — więc raz na lekcję schodzimy na najkrótszy szczebel, liczymy i
            // wracamy. Jedno mrugnięcie na pół godziny zamiast paska zjedzonego
            // do zegara.
            if self.neighbours(for: window) == nil {
                let shortest = variants.count - 1
                if index != shortest {
                    apply(variants[shortest])
                    self.currentIndex = shortest
                    index = shortest
                    guard let settled = await self.settledFrame(of: window) else { return }
                    slot = settled
                }
                if let measured = await self.settledNeighbourWidth(around: window) {
                    self.learnNeighbours(window: window, width: measured)
                    self.trace(String(format: "sąsiedzi: %.0f pt, %d ikon", measured,
                                      self.itemCount(around: window) ?? -1))
                }
            }
            self.trace(String(format: "start: szczebel %d, budżet %@, belka %@", index,
                              self.budget(for: window).map { String(format: "%.0f", $0) }
                                ?? "nieznany",
                              self.barScreen(for: window).map {
                                  String(format: "%.0fx%.0f", $0.frame.width, $0.frame.height)
                              } ?? "?"))

            // With a measurable edge the right rung can be picked outright.
            // This happens only once the frame has settled, never at the
            // moment of the call: on an app switch the item is often still
            // being handed from one screen's bar to the other's, and its frame
            // then describes where it just was.
            let wantedByBudget = self.budget(for: window).map { budget in
                variants.firstIndex { self.width(of: $0) <= budget } ?? (variants.count - 1)
            }
            // No budget to compute (a screen with no notch): start from the rung
            // this bar drew last time. Either way one step, not a crawl — the
            // user should not watch the line grow a rung at a time every time
            // they come back to a display, which is what starting from whatever
            // length the other display forced looked like.
            //
            // A gdy i tego nie ma — zostajemy na szczeblu, który jest teraz, i
            // niech go poprawi sondowanie. Skok na najdłuższy „na wszelki
            // wypadek” kosztował widoczne rozwinięcie i zwijanie linii przy
            // każdym przebiegu, a nie kupował nic: sondowanie w górę i tak
            // dochodzi tam, gdzie jest miejsce.
            // Podłoga: budżet policzony z ciasnoty (a nie z tego, że element
            // znika) nie ma prawa zbić linii do gołego znaku. Poniżej schodzi
            // się tylko wtedy, gdy pasek naprawdę nic nie narysował — to robi
            // gałąź „nie narysowany” niżej.
            let floorIndex = max(0, variants.count - 2)
            let wanted = min(wantedByBudget ?? self.rememberedIndex(for: window) ?? index,
                             floorIndex)
            if wanted != index {
                index = wanted
                self.currentIndex = index
                apply(variants[index])
                guard let settled = await self.settledFrame(of: window) else { return }
                slot = settled
            }

            // Belka, na której ten przebieg się zaczął. Gdy element w trakcie
            // przeniesie się na drugą (użytkownik przełączył ekran), wszystkie
            // pomiary z tej chwili opisują już co innego — a nauka z nich
            // trafiłaby do lekcji niewłaściwego ekranu.
            let barAtStart = self.barScreen(for: window).map(self.signature)

            /// The longest rung still allowed. A refused probe raises it, and
            /// that is what stops the pass from oscillating between a rung that
            /// draws and the next one up that does not. Zaczyna od tego, czego
            /// ta belka nauczyła się wcześniej — inaczej każdy przebieg
            /// sprawdzałby od nowa szczebel, o którym już wiadomo, że spycha
            /// komuś ikonę z paska.
            var ceiling = self.ceiling(for: window) ?? 0
            while !Task.isCancelled {
                guard self.barScreen(for: window).map(self.signature) == barAtStart else {
                    self.trace("element przeniósł się na inną belkę — przebieg porzucony")
                    return
                }
                guard let drawn = await self.isDrawn(window) else {
                    self.trace("szczebel \(index): pasek nic nie rysuje — nie oceniam")
                    return
                }
                var crowded = false
                if drawn { crowded = await self.settledCrowded(around: window) }
                self.trace(String(format: "szczebel %d slot %.0f…%.0f  rysowany=%@%@",
                                  index, slot.minX, slot.maxX, drawn ? "tak" : "nie",
                                  crowded ? "  (sąsiad wypadł)" : ""))
                if crowded {
                    // Nas widać, więc ikona w Docku jest niepotrzebna — ale
                    // linia zepchnęła z paska czyjąś ikonę, a to jest ta sama
                    // szkoda, przed którą ta klasa broni nas samych.
                    self.onHidden?(false)
                    ceiling = index + 1
                    // Ta sama podłoga, co przy wyborze z budżetu: cudza ikona
                    // kosztem procentu — tak; procent kosztem cudzej ikony —
                    // dopiero gdy element nie rysuje się w ogóle.
                    guard index < floorIndex else {
                        // Najkrótszy szczebel i nadal ciasno: krócej się nie da,
                        // a zniknięcie własnej linii niczego by nie naprawiło.
                        // Skoro przy najkrótszej wersji ikon jest mniej, to nie
                        // przez nas — więc to nowa prawda o tej belce, a nie
                        // powód do skracania. Bez tej korekty jedna ikona, która
                        // mignęła raz w pasku, zostawałaby w pamięci na zawsze i
                        // od tej chwili każdy pomiar wyglądałby na ciasnotę.
                        self.relearnItems(window: window)
                        self.learn(window: window, minX: slot.minX, rendered: true, index: index)
                        return
                    }
                    // Ta szerokość jest za duża — i to jest liczba, która robi
                    // z tej belki belkę z budżetem. Schodzimy od razu tam, gdzie
                    // budżet pozwala, zamiast po jednym szczeblu w dół: każdy
                    // krok to widoczny skok w pasku, a znamy już cel.
                    self.learnRefused(window: window, width: self.width(of: variants[index]),
                                      index: index)
                    let target = self.budget(for: window).map { budget in
                        variants.firstIndex { self.width(of: $0) <= budget } ?? floorIndex
                    } ?? (index + 1)
                    index = min(max(target, index + 1), floorIndex)
                } else if drawn {
                    self.learn(window: window, minX: slot.minX, rendered: true, index: index)
                    self.onHidden?(false)
                    if let measured = self.neighbourWidth(around: window) {
                        self.learnNeighbours(window: window, width: measured)
                    }
                    // On a screen with no notch there is no edge to compute a
                    // budget from, so the only way to find out whether a longer
                    // line would still be drawn is to try one. Without this the
                    // line would keep whatever length it had to take on the
                    // cramped built-in bar for as long as it stayed running.
                    // Wydłużać się wolno tylko na belce bez budżetu (nie ma jak
                    // policzyć miejsca inaczej niż spróbować), nie powyżej
                    // sufitu z tego przebiegu i nie częściej niż raz na
                    // `growCooldown`. Ten ostatni warunek jest tu po to, żeby
                    // pasek stał, a nie oddychał.
                    guard self.budget(for: window) == nil, index - 1 >= ceiling,
                          Date().timeIntervalSince(self.shrunkAt(for: window) ?? .distantPast)
                            >= Self.growCooldown
                    else { return }
                    index -= 1
                } else {
                    let shortest = index == variants.count - 1
                    self.learn(window: window, minX: slot.minX, rendered: false,
                               index: index, shortest: shortest)
                    if !shortest {
                        self.learnRefused(window: window, width: self.width(of: variants[index]),
                                          index: index)
                    }
                    ceiling = index + 1
                    guard !shortest else {
                        // Nothing fits on this bar at all. Now that this is
                        // known rather than estimated, the other bar gets the
                        // vote — otherwise a display that shows nothing keeps
                        // the one that could show everything cut to `30% …`.
                        self.trace("ta belka nie narysuje nic — próbuję drugiej")
                        if attempt == 0, self.statusWindows().count > 1 {
                            self.verify(variants, apply: apply, attempt: 1)
                        } else {
                            // Żadna belka nie narysuje nawet samego znaku.
                            // Pasek menu przestał być drogą do tych liczb —
                            // i, co ważniejsze, nie ma już w co kliknąć.
                            self.onHidden?(true)
                        }
                        return
                    }
                    index += 1
                }
                self.currentIndex = index
                apply(variants[index])
                guard let settled = await self.settledFrame(of: window) else { return }
                slot = settled
            }
        }
    }

    /// The item's frame once its width has stopped changing — that is, once
    /// the line just applied has been laid out.
    ///
    /// Width, not the whole frame. Waiting for the position to hold still too
    /// never finished on this machine: iStat Menus rewrites its own numbers
    /// every second, every rewrite re-packs the bar, and our slot slides a few
    /// points sideways with it. The pass then gave up before judging anything
    /// and the line kept whatever length it had. The sideways drift is
    /// harmless — the window server's copy moves with it, and both are read at
    /// the same moment.
    private func settledFrame(of window: NSWindow, attempts: Int = 16) async -> NSRect? {
        var last = NSRect.null
        for _ in 0..<attempts {
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return nil }
            let frame = window.frame
            if frame.width == last.width { return frame }
            last = frame
        }
        return nil
    }

    /// Whether the settled item is on screen. A single "no" is confirmed once
    /// more — the window server can lag one sample behind — and `nil` means the
    /// bar itself is not drawing, which says nothing either way.
    private func isDrawn(_ window: NSWindow) async -> Bool? {
        guard let first = isOnScreen(window) else { return nil }
        if first { return true }
        try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
        guard !Task.isCancelled else { return nil }
        return isOnScreen(window)
    }

    /// Forgets what it learned about the current bar — used when the user
    /// switches auto-shortening off and on, or the screen setup changes.
    func reset() {
        verification?.cancel()
        verification = nil
        running = nil
        lessons.removeAll()
        currentIndex = 0
        // Zmiana ekranów unieważnia też werdykt „nic się nie zmieści”:
        // dopóki nowy przebieg nie powie inaczej, zakładamy, że pasek działa.
        onHidden?(false)
    }

    /// Records what the bar did with the item at this position. Two bounds,
    /// never mixed: a refusal moves the edge right, a success caps how far
    /// right it can be claimed to be.
    private func learn(window: NSWindow, minX: CGFloat, rendered: Bool, index: Int,
                       shortest: Bool = false) {
        guard let screen = barScreen(for: window) else { return }
        var updated = lesson(for: screen) ?? Lesson()
        if rendered {
            updated.shownAt = min(updated.shownAt ?? minX, minX)
            updated.bestIndex = min(updated.bestIndex ?? index, index)
            updated.impossible = false
        } else {
            updated.hiddenAt = max(updated.hiddenAt ?? minX, minX)
            // Refused here, so nothing longer than the next rung down can be
            // the starting guess any more.
            updated.bestIndex = max(updated.bestIndex ?? (index + 1), index + 1)
            // Refused even at the shortest rung: this bar cannot draw the item
            // at any length, and a budget estimate saying otherwise has just
            // been proven wrong by the bar itself.
            if shortest { updated.impossible = true }
            updated.stamp = Date()
        }
        lessons[signature(screen)] = updated
    }

    /// To samo pytanie, ale zadane dopiero wtedy, gdy pasek przestał się
    /// przestawiać.
    ///
    /// Ikony wypchnięte przez dłuższą linię znikają z opóźnieniem, a wracają
    /// jeszcze wolniej — do dwóch sekund. Pytanie zadane od razu po zmianie
    /// szczebla opisuje więc szczebel poprzedni, nie ten. Dokładnie stąd brała
    /// się wspinaczka, która przechodziła przez punkt spychania ikon i orientowała
    /// się dopiero na samej górze, po czym zjeżdżała do najkrótszej wersji i
    /// zaczynała od nowa — pasek skakał w kółko co kilka sekund.
    private func settledCrowded(around window: NSWindow) async -> Bool {
        guard let screen = barScreen(for: window),
              let remembered = lesson(for: screen)?.items else { return false }
        var last: Int?
        var quiet = 0
        for _ in 0..<12 {
            if let now = itemCount(around: window) {
                quiet = (now == last) ? quiet + 1 : 0
                last = now
                if quiet >= 3 { return now < remembered }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { break }
        }
        return (last ?? remembered) < remembered
    }

    /// Czy na belce jest teraz mniej ikon, niż potrafiła pomieścić.
    private func crowded(around window: NSWindow) -> Bool {
        guard let screen = barScreen(for: window),
              let remembered = lesson(for: screen)?.items,
              let now = itemCount(around: window) else { return false }
        return now < remembered
    }

    /// Ile elementów rysuje ta belka w tej chwili — z naszym włącznie.
    private func itemCount(around window: NSWindow) -> Int? {
        guard let screen = barScreen(for: window) else { return nil }
        let items = barItems(on: screen)
        return items.isEmpty ? nil : items.count
    }

    /// Zapamiętane miejsce zajmowane przez cudze ikony na tej belce.
    private func neighbours(for window: NSWindow) -> CGFloat? {
        guard let screen = barScreen(for: window) else { return nil }
        return lesson(for: screen)?.neighbours
    }

    /// Ta szerokość okazała się za duża — albo element się nie narysował, albo
    /// zepchnął z paska cudzą ikonę. Minimum z obserwacji, i to jest odmowa,
    /// więc odświeża znacznik czasu i przedawnia się jak każda inna.
    private func learnRefused(window: NSWindow, width: CGFloat, index: Int) {
        guard let screen = barScreen(for: window) else { return }
        var updated = lesson(for: screen) ?? Lesson()
        updated.refusedWidth = min(updated.refusedWidth ?? width, width)
        updated.bestIndex = max(updated.bestIndex ?? (index + 1), index + 1)
        updated.ceiling = max(updated.ceiling ?? (index + 1), index + 1)
        updated.shrunkAt = Date()
        updated.stamp = Date()
        lessons[signature(screen)] = updated
    }

    /// Przyjmuje bieżącą liczbę ikon jako nową prawdę o belce — wołane tylko
    /// wtedy, gdy nasza linia jest najkrótsza z możliwych, więc na pewno nie
    /// jest przyczyną tego, że komuś ubyło.
    private func relearnItems(window: NSWindow) {
        guard let screen = barScreen(for: window), let count = itemCount(around: window) else {
            return
        }
        var updated = lesson(for: screen) ?? Lesson()
        updated.items = count
        lessons[signature(screen)] = updated
    }

    /// Maksimum z obserwacji — patrz komentarz przy `Lesson.neighbours`.
    private func learnNeighbours(window: NSWindow, width: CGFloat) {
        guard let screen = barScreen(for: window) else { return }
        var updated = lesson(for: screen) ?? Lesson()
        updated.neighbours = max(updated.neighbours ?? width, width)
        if let count = itemCount(around: window) {
            updated.items = max(updated.items ?? count, count)
        }
        lessons[signature(screen)] = updated
    }

    /// Kiedy ta belka ostatnio kazała nam się skrócić — patrz `growCooldown`.
    private func shrunkAt(for window: NSWindow) -> Date? {
        guard let screen = barScreen(for: window) else { return nil }
        return lesson(for: screen)?.shrunkAt
    }

    /// Najdłuższy szczebel, jaki wolno na tej belce próbować — patrz
    /// `Lesson.ceiling`.
    private func ceiling(for window: NSWindow) -> Int? {
        guard let screen = barScreen(for: window) else { return nil }
        return lesson(for: screen)?.ceiling
    }

    /// The rung this bar last managed to draw, if it is still worth trusting.
    private func rememberedIndex(for window: NSWindow) -> Int? {
        guard let screen = barScreen(for: window) else { return nil }
        return lesson(for: screen)?.bestIndex
    }

    /// Whether this bar has proven it cannot draw the item at any length.
    private func isImpossible(_ window: NSWindow) -> Bool {
        guard let screen = barScreen(for: window) else { return false }
        return lesson(for: screen)?.impossible == true
    }

    // MARK: - Measurement

    func width(of title: String) -> CGFloat {
        (title as NSString).size(withAttributes: [.font: Self.font]).width + Self.padding
    }

    /// Room for the line, in points, or nil when the left edge is unknowable
    /// (any screen without a notch — the frontmost app's menus end wherever
    /// they end, and there is no API that says where).
    func budget() -> CGFloat? {
        guard let window = statusWindow() else { return nil }
        return budget(for: window)
    }

    /// The same question for one particular copy of the item — the bar a
    /// fitting pass has committed to.
    ///
    /// Odkąd element ma zapisaną pozycję (patrz `StatusItem`), nie stoi już na
    /// skrajnie lewym miejscu w grupie, tylko między ikonami innych aplikacji.
    /// To zmienia pytanie: nie „czy zmieszczę się między krawędzią a sobą”,
    /// tylko „ile mogę zabrać, żeby sąsiedzi z lewej nie wypadli z paska”.
    /// Każdy punkt naszej szerokości spycha ich w lewo o tyle samo, więc
    /// budżetem jest wolne miejsce przed najbardziej lewą cudzą ikoną plus to,
    /// co sami w tej chwili zajmujemy.
    ///
    /// Bez tego element rysowałby się zawsze — kosztem ikon iStata, które
    /// znikałyby po kolei. To był pierwotny objaw, od którego zaczęła się cała
    /// ta klasa, tyle że przeniesiony na sąsiadów.
    func budget(for window: NSWindow) -> CGFloat? {
        guard let screen = barScreen(for: window) else { return nil }
        return budget(on: screen)
    }

    /// Dwa niezależne ograniczenia, bierzemy ciaśniejsze:
    ///
    /// * z geometrii — od krawędzi rysowania do miejsca zajętego przez cudze
    ///   ikony. Wymaga wcięcia w ekranie, więc na monitorze zewnętrznym nie ma
    ///   go wcale;
    /// * z obserwacji — najwęższa linia, przy której coś już wypadło z paska.
    ///   To działa na każdym ekranie i jest tym, czego brakowało: bez budżetu
    ///   jedynym sposobem sprawdzenia „czy zmieszczę się dłuższy” było wydłużyć
    ///   się i zobaczyć, a to znaczyło wypychać ikony iStata w kółko.
    ///
    /// `slack` nie jest ostrożnością na wszelki wypadek: moduły iStata zmieniają
    /// szerokość razem z liczbami w środku (samo „8 KB/s” kontra „1,0 MB/s” to
    /// kilkanaście punktów). Bez zapasu linia dobrana co do punktu spycha
    /// sąsiada z paska przy pierwszej takiej zmianie.
    func budget(on screen: NSScreen) -> CGFloat? {
        let lesson = lesson(for: screen)
        var limits: [CGFloat] = []
        if let edge = drawableEdge(screen: screen), let neighbours = lesson?.neighbours {
            limits.append(screen.frame.maxX - edge - neighbours - Self.slack)
        }
        if let refused = lesson?.refusedWidth {
            limits.append(refused - Self.slack)
        }
        return limits.min()
    }

    /// To samo, ale z kilku próbek. Dwa powody, oba zmierzone: po zmianie
    /// naszej szerokości sąsiedzi przesuwają się z opóźnieniem, a ikony iStata
    /// same zmieniają szerokość co sekundę, gdy zmienia się liczba w środku.
    /// Zaniżony pomiar to zawyżony budżet, a zawyżony budżet to zepchnięte z
    /// paska cudze ikony — czyli dokładnie to, czego ta klasa ma nie robić.
    private func settledNeighbourWidth(around window: NSWindow) async -> CGFloat? {
        var best: CGFloat?
        var quiet = 0
        // Cierpliwość mierzona, nie zgadnięta: ikona zepchnięta z paska przez
        // pełną linię wracała tu nawet po dwóch sekundach, a pomiar zrobiony
        // wcześniej zaniżał budżet o całą jej szerokość i cały mechanizm
        // „nikogo nie spychamy” przestawał działać. Sześć sekund raz na pół
        // godziny, w tle, przy najkrótszym szczeblu.
        for _ in 0..<24 {
            if let sample = neighbourWidth(around: window) {
                let grown = sample > (best ?? 0)
                best = max(best ?? sample, sample)
                quiet = grown ? 0 : quiet + 1
                // Ikony wypchnięte przez zbyt długą linię wracają dopiero po
                // chwili, więc suma przez pierwszą sekundę tylko rośnie.
                // Kończymy, gdy przestała.
                if quiet >= 8 { return best }
            }
            try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
            guard !Task.isCancelled else { return best }
        }
        return best
    }

    /// Suma szerokości cudzych ikon w tej belce, teraz. Nasza własna wypada z
    /// sumy po pozycji slotu.
    private func neighbourWidth(around window: NSWindow) -> CGFloat? {
        guard let screen = barScreen(for: window) else { return nil }
        let items = barItems(on: screen)
        guard !items.isEmpty else { return nil }
        let slot = window.frame
        return items.filter { abs($0.minX - slot.minX) >= 2 }.reduce(0) { $0 + $1.width }
    }

    /// Prostokąty wszystkich elementów paska na tym ekranie, tak jak widzi je
    /// window server — nasz włącznie, o ile jest rysowany.
    private func barItems(on screen: NSScreen) -> [CGRect] {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first else { return [] }
        // Core Graphics liczy y w dół od góry ekranu z AppKitowym (0, 0),
        // AppKit w górę od jego dołu.
        let barY = primary.frame.maxY - screen.frame.maxY
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        return list.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 24, layer < 100,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"],
                  abs(y - barY) < 4,
                  // Tło samego paska ciągnie się przez cały ekran i nie jest
                  // elementem; żaden element nie zbliża się do tej szerokości.
                  width < screen.frame.width - 1 else { return nil }
            return CGRect(x: x, y: y, width: width, height: 1)
        }
    }

    /// The leftmost x an item's slot may start at and still be drawn.
    ///
    /// The notch is the published starting point and the floor for the guess;
    /// a refusal seen further right overrides it, and a position that was drawn
    /// caps it, because the edge cannot be right of somewhere the item drew.
    /// With no notch and nothing learned yet there is nothing to say — `nil`,
    /// and the feedback pass does all the work.
    func drawableEdge(screen: NSScreen) -> CGFloat? {
        let notch = screen.auxiliaryTopRightArea?.minX
        var edge = notch
        if let lesson = lesson(for: screen) {
            if let hidden = lesson.hiddenAt {
                edge = max(edge ?? hidden, hidden + 1)
            }
            // `shownAt` is deliberately *not* used to pull the edge left. It
            // would sit exactly at the current line's own left end, making the
            // budget equal to the width already in use — the line could then
            // never try a longer rung again, which is precisely the "it stays
            // short even though there is room" complaint. It is recorded for
            // the trace, and as the proof that a refusal further right was a
            // fluke worth expiring.
        }
        return edge
    }

    /// The screen the user is working on — the one holding the frontmost app's
    /// largest window. Reads window bounds only, so it needs no screen
    /// recording or accessibility permission.
    func activeScreen() -> NSScreen? {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
        else { return pointerScreen() }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let windows = list.compactMap { info -> CGRect? in
            guard info[kCGWindowOwnerPID as String] as? pid_t == pid,
                  (info[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"],
                  let width = bounds["Width"], let height = bounds["Height"],
                  width > 100, height > 100
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        guard let biggest = windows.max(by: { $0.width * $0.height < $1.width * $1.height })
        else { return pointerScreen() }
        // Core Graphics measures y downwards from the top of the primary
        // screen; AppKit upwards from its bottom.
        let centre = NSPoint(x: biggest.midX, y: primary.frame.maxY - biggest.midY)
        return NSScreen.screens.first { $0.frame.contains(centre) } ?? pointerScreen()
    }

    /// Czy od ostatniego pytania pasek menu przeniósł się na inny ekran.
    ///
    /// Przełączenie aplikacji w obrębie jednego ekranu nie zmienia dla
    /// dopasowania nic, a wywołane wtedy przeliczenie przerywało trwający
    /// pomiar. Przy otwieraniu okien terminala takich przełączeń jest kilka
    /// pod rząd i to wystarczało, żeby linia nigdy nie doszła do końca.
    func barMoved() -> Bool {
        let now = activeScreen().map(signature)
        defer { lastActiveSignature = now }
        return now != lastActiveSignature
    }

    private func pointerScreen() -> NSScreen? {
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
    }

    /// The screen whose menu bar the item is sitting in. Not `window.screen`,
    /// which is nil for an item macOS has hidden, and not `NSScreen.main`,
    /// which follows the key window — in a menu bar app that is regularly a
    /// different display than the one holding the bar. The top edge is what
    /// identifies it: a status item is always flush with it.
    func barScreen(for window: NSWindow) -> NSScreen? {
        NSScreen.screens.first { abs(window.frame.maxY - $0.frame.maxY) < 2 }
            ?? window.screen ?? NSScreen.main
    }

    /// The status item's windows — **one per menu bar**, which is the fact this
    /// whole class had to be rebuilt around.
    ///
    /// With two displays AppKit keeps a separate `NSStatusBarWindow` on each
    /// bar, at different positions, and only the bar the user is on draws its
    /// copy. Taking whichever came first meant measuring the built-in bar (no
    /// room, so every rung read as "hidden") while the item was in fact drawn
    /// on the external one — the line then walked down to `24% …` and stayed
    /// there no matter how much room the bar it was actually on had.
    ///
    /// `MenuBarExtra` gives no handle on any of them, so they are identified by
    /// what only they look like: status-bar level, flush with the top of a
    /// screen. The popover `MenuBarExtra` opens sits at the same level but not
    /// at the top edge.
    func statusWindows() -> [NSWindow] {
        // `NSApp` is nil in the command line tool — there is no status item to
        // measure there, only the ladder itself.
        guard let app = NSApp else { return [] }
        return app.windows.filter { window in
            guard window.level.rawValue == NSWindow.Level.statusBar.rawValue,
                  window.frame.height < 60 else { return false }
            return NSScreen.screens.contains { abs(window.frame.maxY - $0.frame.maxY) < 2 }
        }
    }

    /// The copy worth reporting on: the one on the bar the user is looking at.
    /// `NSScreen.main` names that screen, and when it cannot (no key window in
    /// this process, which is the normal state for a menu bar app) the copy
    /// that is actually drawn answers the same question.
    func statusWindow() -> NSWindow? {
        let candidates = statusWindows()
        guard candidates.count > 1 else { return candidates.first }
        if let main = NSScreen.main,
           let onMain = candidates.first(where: { abs($0.frame.maxY - main.frame.maxY) < 2 }) {
            return onMain
        }
        return candidates.first { isOnScreen($0) == true } ?? candidates.first
    }

    /// The copy a fitting pass has to satisfy. One title serves every bar, so
    /// with two displays one of them decides the length.
    ///
    /// The bar the user is looking at decides, and nothing else — the built-in
    /// bar here has about sixty points between the notch and the next icon, and
    /// letting it set the length meant `27% …` on a 1920-point external display
    /// with half its bar empty. The display nobody is looking at does not get
    /// to dictate what the display in use shows.
    ///
    /// Which display that is comes from the frontmost app's own window. Not
    /// `NSScreen.main` — "main" is the screen holding *this* process's key
    /// window, and a menu bar app never has one, so it answered "built-in" no
    /// matter where the user actually was. Not the pointer either: it can sit
    /// parked on the laptop screen for an hour while all the work happens on
    /// the external one.
    ///
    /// The active bar only gets the vote if it can draw the item at all. When
    /// it cannot — the built-in bar here is so crowded that its slot ends left
    /// of the notch, where nothing is ever drawn — it shows nothing whatever
    /// the line says, so letting it shorten the line would cost the other
    /// display its numbers and buy nothing.
    ///
    /// Falling back further: the tightest bar that can still draw the item, and
    /// only if none can, the roomiest one.
    func governingWindow(minimumWidth: CGFloat) -> NSWindow? {
        let candidates = statusWindows()
        guard candidates.count > 1 else { return candidates.first }
        // An unknown budget (a screen with no notch and nothing learned yet)
        // counts as roomy; probing corrects it if it is not.
        let unlimited = CGFloat.greatestFiniteMagnitude
        let scored = candidates.map { ($0, budget(for: $0) ?? unlimited) }
        if let active = activeScreen(),
           let onActive = scored.first(where: {
               abs($0.0.frame.maxY - active.frame.maxY) < 2
                   && $0.1 >= minimumWidth && !isImpossible($0.0)
           }) {
            return onActive.0
        }
        if let tightest = scored.filter({ $0.1 >= minimumWidth && !isImpossible($0.0) })
            .min(by: { $0.1 < $1.1 }) {
            return tightest.0
        }
        return scored.max(by: { $0.1 < $1.1 })?.0
    }

    /// Whether the item is on screen right now, or nil when there is nothing to
    /// ask about yet (no status window — too early in launch).
    ///
    /// The window server is the only honest answer here: `NSWindow.isVisible`
    /// stays `true` for an item macOS has hidden. Matching is by frame, not by
    /// window id — status items are reported as owned by Control Centre, and
    /// the id correspondence is undocumented, while the x/width of the slot
    /// agrees exactly with `NSWindow.frame`. Only bounds and layer are read, so
    /// this needs no screen-recording permission.
    func isRendered() -> Bool? {
        guard let window = statusWindow() else { return nil }
        return isOnScreen(window)
    }

    /// Whether this particular copy of the item is on screen right now, or nil
    /// when the bar it lives on is not drawing at all — hidden under a
    /// full-screen app, say — which says nothing either way.
    private func isOnScreen(_ window: NSWindow) -> Bool? {
        guard let screen = barScreen(for: window) else { return nil }
        let items = barItems(on: screen)
        // A bar drawing nothing at all says nothing about whether this item
        // fits, and must not be read as "you are too wide".
        guard !items.isEmpty else { return nil }
        let slot = window.frame
        return items.contains { abs($0.minX - slot.minX) < 2 && abs($0.width - slot.width) < 2 }
    }

    /// Every candidate window and every menu bar rect the window server knows
    /// about, for when the two disagree — which is how the per-bar duplication
    /// was found in the first place. Printed only under `AILIMITS_TRACE=2`; it
    /// is a page of output per refresh.
    func windowDump() -> String {
        var lines: [String] = []
        for window in NSApp?.windows ?? [] where window.level.rawValue >= 24 {
            lines.append(String(format: "  okno #%d level=%d %@ %@", window.windowNumber,
                                window.level.rawValue, NSStringFromRect(window.frame),
                                String(describing: type(of: window))))
        }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        for info in list {
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 24, layer < 100,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let number = info[kCGWindowNumber as String] as? Int else { continue }
            lines.append(String(format: "  CG #%d layer=%d x=%.0f y=%.0f w=%.0f", number, layer,
                                bounds["X"] ?? -1, bounds["Y"] ?? -1, bounds["Width"] ?? -1))
        }
        return lines.joined(separator: "\n")
    }

    /// One line describing what the fitter can see — for `AILIMITS_TRACE` and
    /// the `--menubar` diagnostic. `title` is the line currently in the bar; it
    /// only serves to print how far `padding` is off, which is the one constant
    /// here that a macOS update could invalidate.
    func diagnostics(title: String = "") -> String {
        guard let window = statusWindow() else { return "brak okna paska menu (jeszcze?)" }
        let screen = barScreen(for: window)
        let edge = screen.flatMap { drawableEdge(screen: $0) }
        let rendered = isRendered().map { $0 ? "tak" : "NIE — macOS chowa element" } ?? "?"
        let measured = title.isEmpty ? "" : String(format: "  zmierzone %.0f/%.0f pt",
                                                   width(of: title), window.frame.width)
        let learned = screen.flatMap { lesson(for: $0) }.map {
            String(format: "  lekcja: schowany≤%@ pokazany≥%@ szczebel≥%@%@",
                   $0.hiddenAt.map { String(format: "%.0f", $0) } ?? "—",
                   $0.shownAt.map { String(format: "%.0f", $0) } ?? "—",
                   $0.bestIndex.map(String.init) ?? "—",
                   $0.impossible ? " NIC SIĘ NIE ZMIEŚCI" : "")
        } ?? ""
        return String(format: "slot %.0f…%.0f  krawędź→%@  budżet %@  widoczny: %@%@%@",
                      window.frame.minX, window.frame.maxX,
                      edge.map { String(format: "%.0f", $0) } ?? "nieznana",
                      budget().map { String(format: "%.0f pt", $0) } ?? "nieznany",
                      rendered, measured, learned)
    }
}
