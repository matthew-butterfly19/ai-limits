# Feature Plan: AILimits — native macOS menu bar app

**Status:** Draft
**Created:** 2026-08-26
**Goal:** Replace the SwiftBar plugin with a self-contained native macOS menu bar app that shows live limit usage and token consumption for Claude Code and Codex, broken down by thread and model, with a graphical popover and a native charts window.

---

## Context

A working Python prototype exists in `~/Projects/ai-limits`:

- `ailimits/store.py` — SQLite schema at `~/Library/Application Support/AILimits/stats.db`, byte-offset cursors per log file, `INSERT OR IGNORE` on a dedup primary key.
- `ailimits/ingest.py` — incremental parsers for `~/.claude/projects/**/*.jsonl` (including `subagents/`) and `~/.codex/sessions|archived_sessions/**/*.jsonl`.
- `ailimits/limits.py` — live limits: Anthropic OAuth usage endpoint (token read from Keychain) and `codex app-server` JSON-RPC `account/rateLimits/read`.
- `ailimits/menu.py`, `ailimits/dashboard.py`, `ailimits/charts.py` — SwiftBar text menu and a generated HTML dashboard.

Current database: 40 913 usage events (Claude from 2026-07-01, Codex from 2026-03-06), 199 sessions, 4 635 limit samples. Parsing was validated against Claude Code's own `stats-cache.json`: for 2026-08-21 the undeduplicated sum matches Claude's number **exactly** (17 366 772), which confirms field selection and local-day bucketing; the deduplicated figure (7 262 287) is lower because Claude Code writes one API response across several JSONL lines, repeating the same `usage` block in each.

The prototype works but is a text menu driven by SwiftBar, and depends on the system Python 3.9 that Apple has deprecated.

---

## Decisions Made

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Headline token number | Two numbers side by side: `total / total-minus-cache-reads` (e.g. `62M/1.1M`) | Total is the literal answer and is comparable across both apps; the second number strips cache reads, which dominate ~97% of volume and are not proportional to limit burn |
| Menu bar content | Full line, no shortening: both apps, both numbers, all limit windows with time-to-reset | User explicitly rejected every abbreviated variant |
| Token accounting period in the title | Current 5-hour limit window, computed as `resets_at − 300 min` | Token count and limit percentage then describe the exact same interval |
| Attribution | Thread (session) × model | Directly answers "which model burned how much in which thread"; per-model weekly windows are metered separately by the API |
| Statistics in the UI | Burn rate + ETA, thread×model matrix, limit share per project, hour map + comparison to 7-day average, cache efficiency, reasoning-token share | All four analytical items accepted; API-price estimation rejected |
| UI technology | Native Swift menu bar app (SwiftUI `MenuBarExtra`), SwiftBar dropped | Full graphical control over the popover; removes the SwiftBar dependency |
| Collector language | Rewrite in Swift | System Python 3.9 is deprecated by Apple and will be removed; a single binary with no runtime dependency is required for any form of distribution |
| Detail view | Native Swift Charts | Consistent with the app, works offline in-window, no second UI language |
| Transition | Run in parallel; retire the SwiftBar plugin only at parity | Never leaves the user without a working widget |
| Distribution | Open source on GitHub, no sandbox, ad-hoc signed builds | Keeps every feature, costs nothing, and removes the licensing question that selling access to another product's endpoint would raise |

### Why not the App Store (recorded so the decision is not revisited blindly)

App Store distribution requires the App Sandbox, which was measured against what this app actually needs:

| Capability | Unsandboxed build | Sandboxed build |
|---|---|---|
| Read `~/.claude`, `~/.codex` | Direct filesystem access | Possible via user-selected folders + security-scoped bookmarks |
| Codex limit percentages | Live via `codex app-server` | Still possible — Codex writes `rate_limits` snapshots into its own session logs |
| Read Claude Code's Keychain item | Works (item ACL permits it) | **Blocked** — the item belongs to another application's access group |
| Spawn `codex app-server` | Works | **Blocked** — sandboxed apps cannot launch arbitrary executables |
| Claude limit percentages | Full | **Unavailable** — verified: nothing under `~/.claude` records limit state locally, and there is no public API for subscription windows |

So the sandbox would remove exactly the feature that makes the tool worth having, in a niche where free tools reading the same logs already exist. Distribution outside the store keeps everything and costs nothing.

The limit-provider protocol from Step 4 stays regardless — it is what makes the cached/stale path and unit testing clean.

---

## Implementation Plan

### Step 1: SwiftPM project skeleton and .app bundle

**File(s):** `Package.swift`, `Sources/AILimits/`, `scripts/bundle.sh`, `Resources/Info.plist`, `Resources/AILimits.entitlements`
**Type:** New files
**What:** SwiftPM executable target. Because Xcode is not installed (only Command Line Tools, Swift 6.1.2), the `.app` is assembled by a script: build the binary, lay out `Contents/MacOS`, `Contents/Resources`, `Info.plist` with `LSUIElement=true`, then ad-hoc sign with `codesign -s -`.
**Why:** Menu-bar-only app with no Dock icon; buildable today without Xcode.

```swift
// Package.swift
let package = Package(
    name: "AILimits",
    platforms: [.macOS(.v14)],
    targets: [.executableTarget(name: "AILimits", resources: [.process("Resources")])]
)
```

**Risks / Notes:** Xcode is required later for notarization and App Store submission; the bundle script keeps the local loop working until then. Ad-hoc signing means Gatekeeper will warn on any other machine — acceptable for a personal build.

---

### Step 2: Storage layer in Swift

**File(s):** `Sources/AILimits/Store/Database.swift`, `Store/Schema.swift`, `Store/Queries.swift`
**Type:** New files
**What:** Thin wrapper over system `libsqlite3` (no third-party dependency). Reuses the existing schema and the existing database file, so no migration and no data loss.
**Why:** The Python collector already populated 40 913 events; the Swift app must adopt them, not start from zero.

```swift
struct UsageEvent {
    let app: AppKind, uniq: String, sessionID: String
    let ts: Date, model: String?
    let input, output, cacheRead, cacheWrite, reasoning: Int
    let sidechain: Bool
}
// PRIMARY KEY (app, uniq) + INSERT OR IGNORE — re-reading any file stays idempotent.
```

**Risks / Notes:** WAL mode is already on; the Swift app and any leftover Python run must not fight over the write lock. Keep a single writer at a time (the app), with Python demoted to read-only once parity lands.

---

### Step 3: Log ingest in Swift

**File(s):** `Sources/AILimits/Ingest/ClaudeIngest.swift`, `Ingest/CodexIngest.swift`, `Ingest/LineReader.swift`
**Type:** New files
**What:** Port of `ingest.py`, preserving every rule that was empirically established:

- Byte-offset cursor per file; a file shorter than its stored offset is re-read from zero.
- A trailing line without `\n` is not consumed (the log is being written concurrently).
- Claude dedup key `(message.id, requestId)`; Codex dedup key `(session_id, ordinal)`.
- Claude subagent transcripts under `<project>/<session>/subagents/*.jsonl` are ingested and attributed to the parent session via `isSidechain`.
- Codex `input_tokens` includes `cached_input_tokens`; normalise to `input = input − cached`.
- Codex thread titles resolve in order: `thread_goal_updated.goal.objective` → `Title:` line from the display-title bootstrap message → first human user message with context blocks stripped → none.
- Codex `rate_limits` snapshots inside `token_count` events backfill limit history.

**Why:** These are not cosmetic details — each one was derived from inspecting real logs, and getting any of them wrong silently corrupts every number in the UI.

**Risks / Notes:** Cheap substring pre-filtering before JSON decoding is what keeps a full pass over ~860 MB at a few seconds. Keep that; do not decode every line.

---

### Step 4: Limit providers behind a protocol

**File(s):** `Sources/AILimits/Limits/LimitsProvider.swift`, `Limits/ClaudeLiveLimits.swift`, `Limits/CodexLiveLimits.swift`, `Limits/CachedLimits.swift`
**Type:** New files
**What:**

```swift
protocol LimitsProvider {
    func fetch() async throws -> LimitsSnapshot   // windows: [minutes: (pct, resetsAt)]
}
```

- `ClaudeLiveLimits` — read `Claude Code-credentials` from the Keychain, `GET https://api.anthropic.com/api/oauth/usage` with `anthropic-beta: oauth-2025-04-20`. HTTP 401 maps to a specific "token expired, run Claude Code" message rather than a raw error.
- `CodexLiveLimits` — spawn `codex app-server`, JSON-RPC `initialize` → `initialized` → `account/rateLimits/read`, then terminate the process. Measured at ~500 ms per call and confirmed to be a live backend request, so it also covers usage from the ChatGPT desktop app and `codex cloud`.
- `CachedLimits` — decorator that persists the last good snapshot and serves it with a staleness marker when the underlying provider fails; time-to-reset is always recomputed from `resetsAt`, never from a stored countdown.

**Why:** Failures, staleness and testing all live in one place instead of being smeared across the UI, and swapping in a fake provider is what makes the UI testable without network access.

**Risks / Notes:** Every `codex app-server` process must be terminated on every exit path, including cancellation. A leaked daemon per refresh cycle is the failure mode to guard against in tests.

---

### Step 5: Statistics engine

**File(s):** `Sources/AILimits/Stats/StatsEngine.swift`
**Type:** New file
**What:** Pure functions over the store, one per accepted statistic:

| Function | Output |
|---|---|
| `currentWindowTotals(resetsAt:)` | tokens since `resetsAt − window`, split four ways, per app |
| `burnRate(app:window:)` | %/hour from the slope of recent limit samples, plus projected exhaustion time |
| `threadModelMatrix(since:)` | rows of (thread, model) → tokens, turns, cache ratio, reasoning share |
| `projectLimitShare(window:)` | per-project share of tokens consumed inside the active limit window |
| `hourMap(days:)` | day × local-hour grid of token volume |
| `comparisonToAverage(days: 7)` | today vs 7-day mean, per app |

**Why:** Keeping this separate from the UI means the same numbers feed the popover, the charts window, and any future export, and it is the layer that unit tests can pin down.

**Risks / Notes:** Burn-rate ETA must degrade honestly when samples are sparse (fewer than ~3 samples in the last hour → show "brak danych", never a fabricated projection).

---

### Step 6: Menu bar title

**File(s):** `Sources/AILimits/UI/MenuBarTitle.swift`
**Type:** New file
**What:** Renders the agreed line, monospaced digits:

```
ClaudeCode 62M/1.1M · 15%→4h28m · 65%→3d6h ┃ Codex 22M/6.0M · 29%→4h27m · 23%→6d6h
```

Windows absent from the API response are omitted entirely (never rendered as a dash). Colour escalates at 70% and 90% per window.

**Why:** Matches the decisions above exactly; no shortening.

**Risks / Notes:** This is the longest variant yet (~85 characters). Needs a look on the real menu bar; if macOS truncates it, the agreed lever is font size, not content.

---

### Step 7: Graphical popover

**File(s):** `Sources/AILimits/UI/PopoverView.swift`, `UI/Components/`
**Type:** New files
**What:** SwiftUI popover replacing the text menu:

- Header per app: the two token numbers for the current 5-hour window, plan name.
- Limit meters: one bar per window, with percentage, time to reset, and burn-rate ETA underneath.
- Model breakdown: horizontal bars per model, coloured by the categorical palette, with the per-model weekly window shown where the API reports one.
- Thread list: top threads in the window, each showing project, title, model chip, and a proportional bar.
- Footer: last refresh, a stale-data warning when applicable, buttons for detail window and manual refresh.

**Why:** This is the "more graphical menu" that was asked for.

**Risks / Notes:** Palette is fixed and already validated (blue `#2a78d6`/`#3987e5` for ClaudeCode, orange `#eb6834`/`#d95926` for Codex; all six colour checks pass in both light and dark mode). Model colours must come from the same fixed slot order, never cycled.

---

### Step 8: Detail window with Swift Charts

**File(s):** `Sources/AILimits/UI/DetailWindow.swift`, `UI/Charts/`
**Type:** New files
**What:** A regular window with:

- Hourly token bars, last 24 h, stacked by app, local hours.
- Limit utilisation lines, last 24 h; colour = app, solid = 5 h window, dashed = weekly. Gaps longer than 30 minutes break the line instead of interpolating across them.
- Hour map (day × hour heat grid), single-hue sequential ramp.
- Thread × model table with expandable rows: four-way token split, turns, cache ratio, reasoning share, subagent share, active time range.
- Period switcher: current window / 24 h / 7 days / all time.

**Why:** The heavy analysis needs room that a popover does not have.

**Risks / Notes:** Never put two measures with different scales on one chart — tokens and percentages stay in separate charts.

---

### Step 9: Refresh scheduling

**File(s):** `Sources/AILimits/App/RefreshCoordinator.swift`
**Type:** New file
**What:** Async timer, 2-minute default, configurable. Each tick: incremental ingest → limit fetch → limit sample write → UI update. Ingest and limit fetch fail independently; a failure in either must never blank the other's numbers.
**Why:** The Python version had exactly this bug — a database failure took the whole widget down, including limit data that was available.
**Risks / Notes:** Skip the tick entirely when the popover is closed and the machine is on battery below a threshold? Deferred — noted in Open Questions.

---

### Step 10: Release engineering

**File(s):** `scripts/release.sh`, `.github/workflows/build.yml`
**Type:** New files
**What:** `swift build -c release`, bundle assembly, ad-hoc signature, zip named by version. A GitHub Actions workflow builds on push to verify the project compiles on a clean machine. Release notes state plainly that the binary is unsigned and give the one-line unblock (`xattr -dr com.apple.quarantine AILimits.app`).
**Why:** A dev tool distributed as source plus a downloadable build; no Apple account required to ship.
**Risks / Notes:** Notarization is a later, optional step (Developer ID, 99 USD/year) and requires Xcode, which is not installed. Nothing in the design blocks it — the entitlements file simply stays empty until then. A Homebrew tap is the natural next distribution channel once there is a tagged release.

---

### Step 11: Retire the SwiftBar plugin

**File(s):** `plugin/ailimits.2m.py`, `~/Library/Application Support/SwiftBar/Plugins/`
**Type:** Delete (only after parity)
**What:** Keep both running side by side; the Python plugin becomes read-only (no writes to the database) as soon as the Swift app starts writing. Remove it once the native app has run for a few days without gaps.
**Why:** Zero days without a working widget.

---

### Step 12: Repository hygiene for GitHub

**File(s):** `README.md`, `LICENSE`, `.gitignore`, `SECURITY.md`, `docs/`
**Type:** New / modify
**What:** Public repo with no secrets, no database, no logs, no transcript fragments in fixtures. README documents exactly which files are read, which two network requests are made and where the token comes from — that is the first question any reader will have about a tool touching AI credentials, and answering it up front is what makes the project trustworthy. `SECURITY.md` states the threat model in three lines: the app never writes credentials anywhere, never transmits log content, and the only outbound traffic goes to Anthropic and OpenAI. MIT licence.

---

## Files Modified

| File | Change Type | Summary |
|------|-------------|---------|
| `Package.swift` | Create | SwiftPM executable target |
| `scripts/bundle.sh` | Create | Assemble and ad-hoc sign the `.app` without Xcode |
| `Sources/AILimits/Store/*` | Create | SQLite layer over the existing schema |
| `Sources/AILimits/Ingest/*` | Create | Swift port of the JSONL parsers |
| `Sources/AILimits/Limits/*` | Create | Limit providers behind a protocol |
| `Sources/AILimits/Stats/*` | Create | Statistics engine |
| `Sources/AILimits/UI/*` | Create | Menu bar title, popover, detail window, charts |
| `scripts/release.sh` | Create | Release build, bundle, zip |
| `.github/workflows/build.yml` | Create | Clean-machine build check |
| `LICENSE`, `SECURITY.md` | Create | MIT, stated threat model |
| `ailimits/*.py` | Keep, then delete | Runs in parallel until parity, then removed |
| `README.md` | Modify | Rewritten for the native app |

---

## What Does NOT Change

- The database file, its location, and its schema — the Swift app adopts the existing data.
- The dedup semantics. The deliberate difference from Claude Code's own `/stats` (which counts each JSONL line, including repeated `usage` blocks) stays, and stays documented.
- The colour palette and the "colour follows the entity" rule.
- Data collection scope: no new sources, no network calls beyond the two limit endpoints.
- The HTML dashboard is not extended further; it stays as-is until the native window replaces it, then is removed.

---

## Open Questions

1. **Menu bar width.** The title is now the longest variant yet (~85 characters). It has never been checked on the real menu bar. The agreed lever if it truncates is font size, not content — but it has to be looked at.
2. **Refresh behaviour on battery** — throttle when the popover is closed, or keep a constant 2-minute cadence.
3. **Notarization** — optional later step. Requires an Apple Developer account (99 USD/year) and Xcode, neither of which is present. Not a blocker for shipping source plus an unsigned build.
4. **Codex-only limits mode.** Because Codex writes `rate_limits` into its own session logs, a build with no Keychain access at all would still show Codex percentages. Not needed now, but it is the cheapest fallback if the Anthropic endpoint ever changes.
5. **Window-size learning.** Historical pairs of (tokens in window, reported %) could be fitted to infer the actual token budget behind each limit. Would turn "65% of the week" into "roughly 340M tokens left". Worth prototyping after parity, not before.

---

## Testing Plan

- [ ] **Parity:** Swift ingest into a fresh database reproduces the Python database exactly — same event count, same per-day per-model totals.
- [ ] **Ground truth:** for 2026-08-21, the undeduplicated sum equals Claude Code's own `dailyModelTokens` value (17 366 772) — proves field selection is still right after the port.
- [ ] **Idempotence:** running ingest twice changes no counts.
- [ ] **Partial line:** a log file whose last line lacks `\n` is not consumed and is picked up on the next pass.
- [ ] **Truncation:** a file shorter than its stored offset is re-read from zero without duplicating events.
- [ ] **Limit failure:** network down and expired token both fall back to cached values with a visible stale marker, and the countdown still ticks correctly.
- [ ] **Independence:** an unreadable database still renders limits; a failing limit fetch still renders tokens.
- [ ] **No leaks:** after 20 refresh cycles, `pgrep -f "codex app-server"` shows no process spawned by the app.
- [ ] **Menu bar width:** the full title is checked on the real menu bar at the actual font size.
- [ ] **Appearance:** popover and charts verified in both light and dark mode.
- [ ] **Clean machine:** the release zip unpacks and launches on a Mac that has never seen the project, after the documented quarantine removal.
- [ ] **Repo hygiene:** a fresh clone contains no database, no logs, no transcript fixtures, no credentials.

---

_Default review = chat-summary (Mode B). Reply in chat with adjustments — you do not need to read this document. If you want a careful review, open this file and add `// CHANGE: your comment` annotations where you want adjustments, then say "apply changes"._
