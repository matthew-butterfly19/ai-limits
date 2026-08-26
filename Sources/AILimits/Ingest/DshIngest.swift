import Foundation

/// Reads DeepSeek Harness (`dsh`) session logs into the store.
///
/// dsh sessions are zstd-compressed, and there is no incremental byte offset
/// to resume from once a file is compressed — each changed file is
/// decompressed and reprocessed whole. That is safe because every write below
/// is already idempotent (`add(events:)` is a dedup'd upsert, `touch(session:)`
/// widens rather than overwrites), so `saveCursor` is called with `offset`
/// pinned to the compressed file's own size: the next pass sees "unchanged"
/// and skips the file entirely until it actually grows.
struct DshIngest {
    let store: Store

    static var globs: [String] {
        let home = NSHomeDirectory()
        return ["\(home)/.dsh/sessions/*/*/session.jsonl.zstd"]
    }

    @discardableResult
    func run() throws -> Int {
        // No libzstd on disk — skip quietly rather than let every tick fail.
        guard Zstd.isAvailable else { return 0 }

        var filesTouched = 0
        for path in Glob.newestFirst(Self.globs) {
            guard let cursor = store.cursor(for: path, app: .dsh) else { continue }
            guard let raw = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let decompressed = try? Zstd.decompress(raw),
                  let text = String(data: decompressed, encoding: .utf8)
            else { continue }

            try ingest(text: text, path: path)
            try store.saveCursor(path: path, app: .dsh,
                                 cursor: FileCursor(offset: cursor.size,
                                                    size: cursor.size,
                                                    mtime: cursor.mtime))
            filesTouched += 1
        }
        return filesTouched
    }

    private func ingest(text: String, path: String) throws {
        var sessionID = Self.sessionID(fromDirectory: path)
        var sidechain = false
        var events: [UsageEvent] = []
        var compactions: [Compaction] = []
        var sessions = SessionAccumulator()
        // The model lives on each `assistant/message`'s own `source`, but that
        // is occasionally absent (a retried step) — `request/header` is the
        // fallback, exactly as Codex's `turn_context` stands in for its own
        // usage records that carry no model.
        var currentModel: String?
        // Full context size just before the most recent compaction request —
        // neither `compaction/start` nor `.../end` says how big the context
        // was, so the last message's own size stands in, same estimate
        // Codex's ingest already makes for the same missing number.
        var lastContextTokens = 0
        var pendingCompactions: [String: (time: Double, context: Int)] = [:]

        for rawLine in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = Data(rawLine.utf8)
            guard line.contains(ascii: Marker.dshAssistantMessage)
                    || line.contains(ascii: Marker.dshSessionHeader)
                    || line.contains(ascii: Marker.dshSessionTitle)
                    || line.contains(ascii: Marker.dshCompactionStart)
                    || line.contains(ascii: Marker.dshCompactionEnd)
                    || line.contains(ascii: Marker.dshRequestHeader)
            else { continue }
            guard let root = (try? JSONSerialization.jsonObject(with: line)) as? JSONObject,
                  let type = root.string("type")
            else { continue }
            let data = root.object("data") ?? [:]
            let timeMs = root.double("time") ?? 0
            let ts = Date(timeIntervalSince1970: timeMs / 1_000)

            switch type {
            case "session":
                // The one record that carries its fields at the top level,
                // not under `data` — it is the file's own header, not an
                // event inside the stream.
                sessionID = root.string("id") ?? sessionID
                sidechain = (root.int("delegationDepth") ?? 0) > 0
                if let sessionID {
                    sessions.note(app: .dsh, sessionID: sessionID,
                                 cwd: root.string("cwd"), origin: root.string("agentPreset"),
                                 ts: ts)
                }

            case "session/title":
                if let sessionID, let title = data.string("title") {
                    sessions.note(app: .dsh, sessionID: sessionID, title: title)
                }

            case "request/header":
                let config = data.object("header")?.object("config")
                currentModel = config?.string("model") ?? currentModel

            case "assistant/message":
                guard let sessionID else { continue }
                let seq = root.int("seq") ?? 0
                let usage = data.object("usage") ?? [:]
                let model = data.object("message")?.object("source")?.string("model")
                            ?? currentModel
                let input = usage.int("inputTokens") ?? 0
                let cacheRead = usage.int("cacheReadTokens") ?? 0
                lastContextTokens = input + cacheRead

                events.append(UsageEvent(
                    app: .dsh,
                    uniq: "\(sessionID):\(seq)",
                    sessionID: sessionID,
                    ts: ts,
                    model: model,
                    input: input,
                    output: usage.int("outputTokens") ?? 0,
                    cacheRead: cacheRead,
                    cacheWrite: 0,
                    reasoning: usage.int("reasoningTokens") ?? 0,
                    sidechain: sidechain))

                if events.count >= 2_000 {
                    try store.add(events: events)
                    events.removeAll(keepingCapacity: true)
                }

            case "compaction/start":
                if let id = data.string("compactionId") {
                    pendingCompactions[id] = (time: timeMs, context: lastContextTokens)
                }

            case "compaction/end":
                guard let sessionID, let id = data.string("compactionId"),
                      let start = pendingCompactions.removeValue(forKey: id)
                else { continue }
                compactions.append(Compaction(
                    app: .dsh, sessionID: sessionID, ts: ts, trigger: nil,
                    preTokens: start.context, postTokens: 0,
                    dropped: max(start.context, 0),
                    durationMs: max(0, Int(timeMs - start.time))))

            default:
                continue
            }
        }

        try store.add(events: events)
        try store.add(compactions: compactions)
        try sessions.flush(into: store)
    }

    /// Falls back to the containing directory's own name — which is already
    /// the session id, prefix and all — when a file somehow has no `session`
    /// header of its own. In practice that header is always the first line
    /// ever written, so this only guards against a truncated file.
    static func sessionID(fromDirectory path: String) -> String? {
        let dir = (path as NSString).deletingLastPathComponent
        let name = (dir as NSString).lastPathComponent
        return name.isEmpty ? nil : name
    }
}
