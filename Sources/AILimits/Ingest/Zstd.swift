import Foundation

/// Minimal libzstd binding, loaded via `dlopen`.
///
/// macOS ships no zstd of its own: there is no `libzstd` under `/usr/lib`, and
/// Apple's Compression framework — despite an enum that looks like it should
/// have one — never exposes `COMPRESSION_ZSTD`. dsh's session logs are zstd
/// compressed, so this loads Homebrew's dylib at runtime instead of linking
/// it. When the dylib is not on disk, `isAvailable` is false and the caller
/// skips dsh ingestion rather than the app failing to build or launch.
enum Zstd {
    private static let candidatePaths = [
        "/opt/homebrew/lib/libzstd.dylib",   // Homebrew, Apple silicon
        "/usr/local/lib/libzstd.dylib",      // Homebrew, Intel
        "/opt/local/lib/libzstd.dylib",      // MacPorts
    ]

    private struct InBuffer {
        var src: UnsafeRawPointer?
        var size: Int
        var pos: Int
    }
    private struct OutBuffer {
        var dst: UnsafeMutableRawPointer?
        var size: Int
        var pos: Int
    }

    private struct Symbols {
        let createDStream: @convention(c) () -> UnsafeMutableRawPointer?
        let freeDStream: @convention(c) (UnsafeMutableRawPointer?) -> Int
        let initDStream: @convention(c) (UnsafeMutableRawPointer?) -> Int
        let decompressStream:
            @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer,
                            UnsafeMutableRawPointer) -> Int
        let isError: @convention(c) (Int) -> UInt32
        let outSize: @convention(c) () -> Int
    }

    private static let symbols: Symbols? = {
        for path in candidatePaths {
            guard let handle = dlopen(path, RTLD_NOW) else { continue }
            func load<T>(_ name: String, as: T.Type) -> T? {
                dlsym(handle, name).map { unsafeBitCast($0, to: T.self) }
            }
            guard
                let createDStream = load("ZSTD_createDStream",
                    as: (@convention(c) () -> UnsafeMutableRawPointer?).self),
                let freeDStream = load("ZSTD_freeDStream",
                    as: (@convention(c) (UnsafeMutableRawPointer?) -> Int).self),
                let initDStream = load("ZSTD_initDStream",
                    as: (@convention(c) (UnsafeMutableRawPointer?) -> Int).self),
                let decompressStream = load("ZSTD_decompressStream",
                    as: (@convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer,
                                         UnsafeMutableRawPointer) -> Int).self),
                let isError = load("ZSTD_isError", as: (@convention(c) (Int) -> UInt32).self),
                let outSize = load("ZSTD_DStreamOutSize", as: (@convention(c) () -> Int).self)
            else { continue }
            return Symbols(createDStream: createDStream, freeDStream: freeDStream,
                           initDStream: initDStream, decompressStream: decompressStream,
                           isError: isError, outSize: outSize)
        }
        return nil
    }()

    static var isAvailable: Bool { symbols != nil }

    enum ZstdError: LocalizedError {
        case unavailable
        case decodeFailed(String)

        var errorDescription: String? {
            switch self {
            case .unavailable: return "libzstd nie znaleziony (brew install zstd)"
            case .decodeFailed(let s): return "błąd dekompresji zstd: \(s)"
            }
        }
    }

    static func decompress(_ data: Data) throws -> Data {
        guard let symbols else { throw ZstdError.unavailable }
        guard let stream = symbols.createDStream() else { throw ZstdError.decodeFailed("createDStream") }
        defer { _ = symbols.freeDStream(stream) }
        _ = symbols.initDStream(stream)

        var output = Data()
        output.reserveCapacity(data.count * 4)
        var outStorage = [UInt8](repeating: 0, count: symbols.outSize())

        try data.withUnsafeBytes { (rawInput: UnsafeRawBufferPointer) in
            guard let base = rawInput.baseAddress, rawInput.count > 0 else { return }
            var inBuffer = InBuffer(src: base, size: rawInput.count, pos: 0)

            while inBuffer.pos < inBuffer.size {
                var produced = 0
                var thrown: Error?
                outStorage.withUnsafeMutableBytes { (rawOutput: UnsafeMutableRawBufferPointer) in
                    var outBuffer = OutBuffer(dst: rawOutput.baseAddress, size: rawOutput.count, pos: 0)
                    let result = withUnsafeMutablePointer(to: &outBuffer) { outPtr -> Int in
                        withUnsafeMutablePointer(to: &inBuffer) { inPtr in
                            symbols.decompressStream(stream, UnsafeMutableRawPointer(outPtr),
                                                     UnsafeMutableRawPointer(inPtr))
                        }
                    }
                    guard symbols.isError(result) == 0 else {
                        thrown = ZstdError.decodeFailed("decompressStream code \(result)")
                        return
                    }
                    if outBuffer.pos > 0 {
                        output.append(rawOutput.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                     count: outBuffer.pos)
                    }
                    produced = outBuffer.pos
                }
                if let thrown { throw thrown }
                // No output and no more input taken: the frame is done.
                if produced == 0 && inBuffer.pos >= inBuffer.size { break }
            }
        }
        return output
    }
}
