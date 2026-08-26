import Foundation

/// Streams newline-terminated lines out of a log file, starting at a byte offset.
///
/// The logs are appended to while we read them, so a trailing fragment without
/// a `\n` is deliberately **not** consumed — the cursor stops before it and the
/// next pass picks the line up whole.
enum LineReader {
    private static let chunkSize = 1 << 20   // 1 MiB

    /// Calls `body(line, offsetAfterLine)` for every complete line.
    /// `line` excludes the trailing newline.
    static func forEachLine(path: String,
                            from offset: Int,
                            _ body: (Data, Int) throws -> Void) throws {
        guard let handle = FileHandle(forReadingAtPath: path) else { return }
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(offset))

        var position = offset
        var pending = Data()

        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            pending.append(chunk)

            var searchStart = pending.startIndex
            while let newline = pending[searchStart...].firstIndex(of: 0x0A) {
                let line = pending[searchStart..<newline]
                position += line.count + 1
                try body(Data(line), position)
                searchStart = pending.index(after: newline)
            }
            // Keep only the incomplete tail for the next chunk.
            pending = Data(pending[searchStart...])
        }
        // Whatever is left has no newline: leave it for the next run.
    }
}

extension Data {
    /// Cheap substring test used to skip lines before paying for JSON decoding.
    /// A full pass over ~860 MB of logs only stays fast because most lines die here.
    func contains(ascii needle: [UInt8]) -> Bool {
        guard needle.count <= count, !needle.isEmpty else { return false }
        let first = needle[0]
        return withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else { return false }
            let limit = count - needle.count
            var index = 0
            while index <= limit {
                if base[index] == first {
                    var matched = 1
                    while matched < needle.count, base[index + matched] == needle[matched] {
                        matched += 1
                    }
                    if matched == needle.count { return true }
                }
                index += 1
            }
            return false
        }
    }
}

/// ASCII byte patterns for the pre-filter, spelled once.
enum Marker {
    static let usage      = Array(#""usage""#.utf8)
    static let aiTitle    = Array(#""ai-title""#.utf8)
    static let tokenCount = Array(#""token_count""#.utf8)
    static let sessionMeta = Array(#""session_meta""#.utf8)
    static let threadGoal = Array(#""thread_goal_updated""#.utf8)
    static let inputText  = Array(#""input_text""#.utf8)
}
