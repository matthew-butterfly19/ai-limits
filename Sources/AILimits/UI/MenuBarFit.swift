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
    private static let padding: CGFloat = 37
    /// Only climb back to a longer rung when it fits with room to spare, so a
    /// percentage ticking between 9 % and 10 % cannot flip the line every tick.
    private static let slack: CGFloat = 16
    /// Long enough for the status item to have been laid out and drawn after a
    /// title change, short enough that walking the whole ladder is invisible.
    private static let settleDelay: TimeInterval = 0.25

    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

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
        var screen: String
        var hiddenAt: CGFloat?
        var shownAt: CGFloat?
        /// The longest rung this bar was seen drawing (rungs are numbered from
        /// the longest down). Where no budget can be computed, this is what
        /// spares the user watching the line grow one rung at a time every time
        /// they come back to that display — it starts from what worked last.
        var bestIndex: Int?
        var stamp = Date()
    }
    private var lesson: Lesson?

    private var verification: Task<Void, Never>?
    /// Which rung was last handed out — where the fitting pass starts.
    private var currentIndex = 0

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
        let immediate = variants[min(currentIndex, variants.count - 1)]
        verify(variants, apply: apply)
        return immediate
    }

    /// Waits for the bar to settle, picks the rung the budget allows, then
    /// checks it against what the window server actually drew and walks down
    /// until the item reappears. Cancels any pass still running, so a burst of
    /// refreshes leaves exactly one loop behind.
    func verify(_ variants: [String], apply: @escaping (String) -> Void) {
        verification?.cancel()
        guard variants.count > 1 else { return }
        verification = Task { @MainActor [weak self] in
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
            // this bar drew last time, or from the full line if it has not been
            // seen yet. Either way one step, not a crawl — the user should not
            // watch the line grow a rung at a time every time they come back to
            // a display, which is what starting from whatever length the other
            // display forced looked like.
            let wanted = min(wantedByBudget ?? self.rememberedIndex(for: window) ?? 0,
                             variants.count - 1)
            if wanted != index {
                index = wanted
                self.currentIndex = index
                apply(variants[index])
                guard let settled = await self.settledFrame(of: window) else { return }
                slot = settled
            }

            /// The longest rung still allowed. A refused probe raises it, and
            /// that is what stops the pass from oscillating between a rung that
            /// draws and the next one up that does not.
            var ceiling = 0
            while !Task.isCancelled {
                guard let drawn = await self.isDrawn(window) else {
                    self.trace("szczebel \(index): pasek nic nie rysuje — nie oceniam")
                    return
                }
                self.trace(String(format: "szczebel %d slot %.0f…%.0f  rysowany=%@",
                                  index, slot.minX, slot.maxX, drawn ? "tak" : "nie"))
                if drawn {
                    self.learn(window: window, minX: slot.minX, rendered: true, index: index)
                    // On a screen with no notch there is no edge to compute a
                    // budget from, so the only way to find out whether a longer
                    // line would still be drawn is to try one. Without this the
                    // line would keep whatever length it had to take on the
                    // cramped built-in bar for as long as it stayed running.
                    guard self.budget(for: window) == nil, index - 1 >= ceiling else { return }
                    index -= 1
                } else {
                    self.learn(window: window, minX: slot.minX, rendered: false, index: index)
                    ceiling = index + 1
                    guard index + 1 < variants.count else { return }
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
        lesson = nil
        currentIndex = 0
    }

    /// Records what the bar did with the item at this position. Two bounds,
    /// never mixed: a refusal moves the edge right, a success caps how far
    /// right it can be claimed to be.
    private func learn(window: NSWindow, minX: CGFloat, rendered: Bool, index: Int) {
        guard let screen = barScreen(for: window) else { return }
        let signature = "\(Int(screen.frame.minX))x\(Int(screen.frame.width))"
        var updated = lesson?.screen == signature ? lesson! : Lesson(screen: signature)
        if rendered {
            updated.shownAt = min(updated.shownAt ?? minX, minX)
            updated.bestIndex = min(updated.bestIndex ?? index, index)
        } else {
            updated.hiddenAt = max(updated.hiddenAt ?? minX, minX)
            // Refused here, so nothing longer than the next rung down can be
            // the starting guess any more.
            updated.bestIndex = max(updated.bestIndex ?? (index + 1), index + 1)
            updated.stamp = Date()
        }
        lesson = updated
    }

    /// The rung this bar last managed to draw, if it is still worth trusting.
    private func rememberedIndex(for window: NSWindow) -> Int? {
        guard let screen = barScreen(for: window), let lesson,
              lesson.screen == "\(Int(screen.frame.minX))x\(Int(screen.frame.width))"
        else { return nil }
        return lesson.bestIndex
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
    func budget(for window: NSWindow) -> CGFloat? {
        guard let screen = barScreen(for: window),
              let edge = drawableEdge(screen: screen)
        else { return nil }
        return window.frame.maxX - edge - Self.slack
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
        if let lesson, lesson.screen == "\(Int(screen.frame.minX))x\(Int(screen.frame.width))" {
            if let hidden = lesson.hiddenAt,
               Date().timeIntervalSince(lesson.stamp) < Self.lessonLifetime {
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
               abs($0.0.frame.maxY - active.frame.maxY) < 2 && $0.1 >= minimumWidth
           }) {
            return onActive.0
        }
        if let tightest = scored.filter({ $0.1 >= minimumWidth }).min(by: { $0.1 < $1.1 }) {
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
        guard let screen = barScreen(for: window),
              let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero })
                ?? NSScreen.screens.first
        else { return nil }
        // Core Graphics counts y downwards from the top of the screen whose
        // AppKit origin is (0, 0), AppKit upwards from its bottom — this is
        // where our bar's items are in the first coordinate space.
        let barY = primary.frame.maxY - screen.frame.maxY
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        let list = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] ?? []
        let items = list.compactMap { info -> CGRect? in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer >= 24, layer < 100,
                  let bounds = info[kCGWindowBounds as String] as? [String: CGFloat],
                  let x = bounds["X"], let y = bounds["Y"], let width = bounds["Width"],
                  abs(y - barY) < 4,
                  // The bar's own backdrop spans the whole screen and is not
                  // an item; a status item never comes close to that width.
                  width < screen.frame.width - 1 else { return nil }
            return CGRect(x: x, y: y, width: width, height: 1)
        }
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
        let learned = lesson.map {
            String(format: "  lekcja[%@]: schowany≤%@ pokazany≥%@", $0.screen,
                   $0.hiddenAt.map { String(format: "%.0f", $0) } ?? "—",
                   $0.shownAt.map { String(format: "%.0f", $0) } ?? "—")
        } ?? ""
        return String(format: "slot %.0f…%.0f  krawędź→%@  budżet %@  widoczny: %@%@%@",
                      window.frame.minX, window.frame.maxX,
                      edge.map { String(format: "%.0f", $0) } ?? "nieznana",
                      budget().map { String(format: "%.0f pt", $0) } ?? "nieznany",
                      rendered, measured, learned)
    }
}
