import Foundation

/// Reads Claude Code transcripts into the store.
///
/// Every rule here was derived from real logs; getting any of them wrong
/// silently corrupts every number in the UI.
struct ClaudeIngest {
    let store: Store

    static var globs: [String] {
        let home = NSHomeDirectory()
        return [
            "\(home)/.claude/projects/*/*.jsonl",
            // Subagent transcripts. They repeat the parent's sessionId, and the
            // same assistant messages also appear in the parent file — the
            // (message.id, requestId) key is what stops double counting.
            "\(home)/.claude/projects/*/*/subagents/*.jsonl",
        ]
    }

    /// Returns the number of files that had new bytes.
    @discardableResult
    func run(maxBytes: Int? = nil) throws -> Int {
        var bytesRead = 0
        var filesTouched = 0

        for path in Glob.newestFirst(Self.globs) {
            if let maxBytes, bytesRead >= maxBytes { break }
            guard let cursor = store.cursor(for: path, app: .claude) else { continue }

            var events: [UsageEvent] = []
            var sessions = SessionAccumulator()
            var lastPosition = cursor.offset

            try LineReader.forEachLine(path: path, from: cursor.offset) { line, position in
                lastPosition = position
                bytesRead += line.count + 1

                guard line.contains(ascii: Marker.usage) || line.contains(ascii: Marker.aiTitle)
                else { return }
                guard let root = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject
                else { return }

                let kind = root.string("type")
                guard let sessionID = root.string("sessionId") else { return }

                if kind == "ai-title" {
                    sessions.note(app: .claude, sessionID: sessionID, title: root.string("aiTitle"))
                    return
                }
                guard kind == "assistant",
                      let message = root.object("message"),
                      let usage = message.object("usage"), !usage.isEmpty,
                      let timestamp = Timestamps.parse(root.string("timestamp"))
                else { return }

                let identifier = message.string("id") ?? root.string("uuid") ?? ""
                let event = UsageEvent(
                    app: .claude,
                    uniq: "\(identifier):\(root.string("requestId") ?? "")",
                    sessionID: sessionID,
                    ts: timestamp,
                    model: message.string("model"),
                    input: usage.int("input_tokens") ?? 0,
                    output: usage.int("output_tokens") ?? 0,
                    cacheRead: usage.int("cache_read_input_tokens") ?? 0,
                    cacheWrite: usage.int("cache_creation_input_tokens") ?? 0,
                    reasoning: usage.object("output_tokens_details")?.int("thinking_tokens") ?? 0,
                    sidechain: root.bool("isSidechain"))
                events.append(event)
                sessions.note(app: .claude, sessionID: sessionID,
                              cwd: root.string("cwd"), origin: "cli", ts: timestamp)

                if events.count >= 2_000 {
                    try store.add(events: events)
                    events.removeAll(keepingCapacity: true)
                }
            }

            try store.add(events: events)
            try sessions.flush(into: store)
            try store.saveCursor(path: path, app: .claude,
                                 cursor: FileCursor(offset: lastPosition,
                                                    size: cursor.size,
                                                    mtime: cursor.mtime))
            filesTouched += 1
        }
        return filesTouched
    }
}
