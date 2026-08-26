import Foundation

/// Codex limits via `codex app-server`, JSON-RPC over stdio.
///
/// This is a live backend request (measured at ~500 ms, and repeated calls do
/// not return a cached figure), so it also reflects usage from the ChatGPT
/// desktop app and `codex cloud` — not just this machine's CLI.
struct CodexLiveLimits: LimitsProvider {
    let app = AppKind.codex
    var timeout: TimeInterval = 20

    func fetch() async throws -> LimitsSnapshot {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do { continuation.resume(returning: try Self.read(timeout: timeout)) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    /// Where the CLI usually lives. `Process` needs an absolute path, so PATH
    /// lookup is done here rather than by the shell.
    static func executable() -> URL? {
        let candidates = [
            "\(NSHomeDirectory())/.local/bin/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    private static func read(timeout: TimeInterval) throws -> LimitsSnapshot {
        guard let executable = executable() else {
            throw LimitsError.processFailed("nie znaleziono binarki codex")
        }

        let process = Process()
        process.executableURL = executable
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        // Every exit path — success, throw, timeout — must reap the process.
        // A leaked app-server per refresh cycle is the failure mode here.
        defer {
            output.fileHandleForReading.readabilityHandler = nil
            if process.isRunning {
                process.terminate()
                let deadline = Date().addingTimeInterval(5)
                while process.isRunning, Date() < deadline { usleep(50_000) }
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            }
            try? input.fileHandleForWriting.close()
            try? output.fileHandleForReading.close()
        }

        let box = ResultBox()
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty { return }
            box.append(chunk)
        }

        do { try process.run() } catch {
            throw LimitsError.processFailed("nie udało się uruchomić codex app-server")
        }

        func send(_ message: JSONObject) throws {
            let data = try JSONSerialization.data(withJSONObject: message)
            input.fileHandleForWriting.write(data + Data("\n".utf8))
        }

        try send(["jsonrpc": "2.0", "id": 1, "method": "initialize",
                  "params": ["clientInfo": ["name": "ai-limits", "title": "AI limits",
                                            "version": "1.0.0"]]])
        try send(["jsonrpc": "2.0", "method": "initialized", "params": [:]])
        try send(["jsonrpc": "2.0", "id": 2, "method": "account/rateLimits/read", "params": [:]])

        guard let result = box.waitForResponse(id: 2, timeout: timeout) else {
            throw LimitsError.timedOut("codex app-server")
        }

        let rateLimits = result.object("rateLimits") ?? [:]
        var windows: [LimitWindow] = []
        for key in ["primary", "secondary"] {
            guard let node = rateLimits.object(key),
                  let minutes = node.int("windowDurationMins") else { continue }
            let resets = node.double("resetsAt").map { Date(timeIntervalSince1970: $0) }
            windows.append(LimitWindow(minutes: minutes,
                                       pct: node.double("usedPercent") ?? 0,
                                       resetsAt: resets))
        }
        guard !windows.isEmpty else {
            throw LimitsError.emptyResponse("app-server nie zwrócił okien")
        }
        windows.sort { $0.minutes < $1.minutes }

        return LimitsSnapshot(app: .codex, takenAt: Date(), windows: windows,
                              planName: rateLimits.string("planType"))
    }
}

/// Collects stdout across reads and hands back the first JSON-RPC response with
/// the id we are waiting for.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private let semaphore = DispatchSemaphore(value: 0)
    private var buffer = Data()
    private var response: JSONObject?
    private var wantedID = 2

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            let line = buffer[start..<newline]
            start = buffer.index(after: newline)
            if let message = (try? JSONSerialization.jsonObject(with: Data(line))) as? JSONObject,
               message.int("id") == wantedID, response == nil {
                response = message.object("result") ?? [:]
                buffer = Data()
                lock.unlock()
                semaphore.signal()
                return
            }
        }
        buffer = Data(buffer[start...])
        lock.unlock()
    }

    func waitForResponse(id: Int, timeout: TimeInterval) -> JSONObject? {
        lock.lock(); wantedID = id; lock.unlock()
        guard semaphore.wait(timeout: .now() + timeout) == .success else { return nil }
        lock.lock(); defer { lock.unlock() }
        return response
    }
}
