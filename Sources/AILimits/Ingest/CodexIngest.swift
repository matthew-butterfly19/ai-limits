import Foundation

/// Reads Codex rollout logs into the store.
struct CodexIngest {
    let store: Store

    static var globs: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.codex/sessions/*/*/*/*.jsonl",
            "\(home)/.codex/archived_sessions/*.jsonl",
            "\(home)/.codex/archived_sessions/*/*/*/*.jsonl",
        ]
    }

    private static let uuidPattern = try! NSRegularExpression(
        pattern: "([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})")

    /// Context blocks Codex injects ahead of the user's actual first prompt —
    /// a thread titled with one of these would be titled with boilerplate.
    private static let contextMarkers = [
        "# AGENTS.md", "AGENTS.md instructions", "<user_instructions>",
        "<environment_context>", "<recommended_plugins>", "<plugin",
    ]

    private static let tagPattern = try! NSRegularExpression(pattern: "<[^>]{1,60}>")

    @discardableResult
    func run(maxBytes: Int? = nil) throws -> Int {
        var bytesRead = 0
        var filesTouched = 0
        var titled = try store.codexTitledSessions()

        for path in Glob.newestFirst(Self.globs) {
            if let maxBytes, bytesRead >= maxBytes { break }
            guard let cursor = store.cursor(for: path, app: .codex) else { continue }

            // The session header only appears once, at the top of the file. When
            // we resume mid-file it is already behind the cursor, so the id has
            // to come from the filename.
            var sessionID = Self.sessionID(fromFilename: path)

            var events: [UsageEvent] = []
            var compactions: [Compaction] = []
            var sessions = SessionAccumulator()
            // Codex does not report how big the context was when it compacted,
            // so the last request's input size stands in for it. Stays 0 when
            // the scan resumes past that record.
            var lastContextTokens = 0
            var lastPosition = cursor.offset

            try LineReader.forEachLine(path: path, from: cursor.offset) { line, position in
                lastPosition = position
                bytesRead += line.count + 1

                let needTitle = sessionID.map { !titled.contains($0) } ?? true
                guard line.contains(ascii: Marker.tokenCount)
                        || line.contains(ascii: Marker.sessionMeta)
                        || line.contains(ascii: Marker.threadGoal)
                        || line.contains(ascii: Marker.compacted)
                        || (needTitle && line.contains(ascii: Marker.inputText))
                else { return }
                guard let root = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject
                else { return }

                let payload = root.object("payload") ?? [:]
                let payloadType = payload.string("type")

                // The `token_count` Codex emits beside a compaction reads
                // literally zero, so the call's own cost is invisible here too.
                if root.string("type") == "compacted", let sessionID,
                   let timestamp = Timestamps.parse(root.string("timestamp")) {
                    compactions.append(Compaction(
                        app: .codex, sessionID: sessionID, ts: timestamp,
                        trigger: nil, preTokens: lastContextTokens,
                        postTokens: 0, dropped: max(lastContextTokens, 0), durationMs: 0))
                    lastContextTokens = 0
                    return
                }

                if root.string("type") == "session_meta" {
                    sessionID = payload.string("session_id") ?? payload.string("id") ?? sessionID
                    if let sessionID {
                        sessions.note(app: .codex, sessionID: sessionID,
                                      cwd: payload.string("cwd"),
                                      origin: payload.string("originator") ?? payload.string("source"),
                                      ts: Timestamps.parse(payload.string("timestamp")
                                                           ?? root.string("timestamp")))
                    }
                    return
                }

                if payload.string("role") == "user", needTitle, let sessionID {
                    for chunk in payload.array("content") ?? [] {
                        guard let chunk = chunk as? JSONObject,
                              let title = Self.title(fromText: chunk.string("text")) else { continue }
                        sessions.note(app: .codex, sessionID: sessionID, title: title)
                        titled.insert(sessionID)
                        break
                    }
                    return
                }

                if payloadType == "thread_goal_updated", let sessionID {
                    if let objective = payload.object("goal")?.string("objective"),
                       !objective.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        sessions.note(app: .codex, sessionID: sessionID,
                                      title: String(objective.trimmingCharacters(in: .whitespacesAndNewlines)
                                                    .prefix(200)))
                        titled.insert(sessionID)
                    }
                    return
                }

                guard payloadType == "token_count", let sessionID,
                      let info = payload.object("info"),
                      let last = info.object("last_token_usage"), !last.isEmpty,
                      let timestamp = Timestamps.parse(root.string("timestamp"))
                else { return }

                // Codex reports cached tokens *inside* input_tokens; Claude does
                // not. Normalise so the two apps' columns mean the same thing.
                let cached = last.int("cached_input_tokens") ?? 0
                let input = last.int("input_tokens") ?? 0
                if input > 0 { lastContextTokens = input }

                events.append(UsageEvent(
                    app: .codex,
                    uniq: "\(sessionID):\(root.int("ordinal").map(String.init) ?? "None")",
                    sessionID: sessionID,
                    ts: timestamp,
                    model: info.string("model") ?? payload.string("model"),
                    input: max(input - cached, 0),
                    output: last.int("output_tokens") ?? 0,
                    cacheRead: cached,
                    cacheWrite: last.int("cache_write_input_tokens") ?? 0,
                    reasoning: last.int("reasoning_output_tokens") ?? 0,
                    sidechain: false))

                // Limit history straight out of the log, so the chart has a past
                // going back further than the day this app was installed.
                if let rateLimits = payload.object("rate_limits") {
                    for key in ["primary", "secondary"] {
                        guard let node = rateLimits.object(key),
                              let minutes = node.int("window_minutes") else { continue }
                        let resets = node.double("resets_at").map {
                            Date(timeIntervalSince1970: $0)
                        } ?? Timestamps.parse(node.string("resets_at"))
                        try store.add(limitSample: LimitSample(
                            ts: timestamp, app: .codex, windowMinutes: minutes,
                            pct: node.double("used_percent") ?? 0, resetsAt: resets))
                    }
                }

                if events.count >= 2_000 {
                    try store.add(events: events)
                    events.removeAll(keepingCapacity: true)
                }
            }

            try store.add(events: events)
            try store.add(compactions: compactions)
            try sessions.flush(into: store)
            try store.saveCursor(path: path, app: .codex,
                                 cursor: FileCursor(offset: lastPosition,
                                                    size: cursor.size,
                                                    mtime: cursor.mtime))
            filesTouched += 1
        }
        return filesTouched
    }

    // MARK: - helpers

    static func sessionID(fromFilename path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        let range = NSRange(name.startIndex..., in: name)
        guard let match = uuidPattern.firstMatch(in: name, range: range),
              let matched = Range(match.range(at: 1), in: name) else { return nil }
        return String(name[matched])
    }

    /// Thread title from a user message, or nil when the message is only the
    /// injected context preamble.
    static func title(fromText text: String?) -> String? {
        let text = (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        // The bootstrap message that names the thread in the desktop app:
        // "... Title: <name>".
        for line in text.split(separator: "\n", omittingEmptySubsequences: false)
        where line.hasPrefix("Title:") {
            let name = line.dropFirst("Title:".count).trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { return String(name.prefix(200)) }
        }

        let head = String(text.prefix(400))
        if contextMarkers.contains(where: { head.contains($0) }) { return nil }

        let stripped = tagPattern.stringByReplacingMatches(
            in: text, range: NSRange(text.startIndex..., in: text), withTemplate: " ")
        let clean = stripped.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return clean.count > 4 ? String(clean.prefix(200)) : nil
    }
}
