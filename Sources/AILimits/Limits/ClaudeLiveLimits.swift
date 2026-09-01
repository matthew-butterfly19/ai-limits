import Foundation

/// Claude Code's own OAuth usage endpoint.
///
/// The access token is read from the Keychain item Claude Code itself created,
/// kept in memory for the duration of one request, and never written to disk,
/// logged, or included in an error message.
struct ClaudeLiveLimits: LimitsProvider {
    let app = AppKind.claude
    var session: URLSession = .shared

    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    private static let keychainService = "Claude Code-credentials"

    func fetch() async throws -> LimitsSnapshot {
        let credentials = try await ClaudeCredentials.shared.current()

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 12
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 {
                // The cached token is the one that was just refused — drop it,
                // so the next attempt goes back to the Keychain instead of
                // failing the same way for the rest of the token's nominal
                // lifetime.
                await ClaudeCredentials.shared.invalidate()
                throw LimitsError.tokenExpired
            }
            // 429 here is throttling of the *usage* endpoint, not the account
            // limit being reached — the cached snapshot stays valid, so this
            // must never look like "limit wyczerpany".
            if http.statusCode == 429 {
                let retry = (http.value(forHTTPHeaderField: "retry-after")).flatMap(Double.init)
                throw LimitsError.throttled(retryAfter: retry)
            }
            throw LimitsError.processFailed("api.anthropic.com odpowiedziało \(http.statusCode)")
        }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject else {
            throw LimitsError.emptyResponse("nieczytelny JSON")
        }
        // Never let an empty payload overwrite a good cached snapshot.
        guard root["five_hour"] != nil || root["seven_day"] != nil else {
            throw LimitsError.emptyResponse("brak five_hour i seven_day")
        }

        var windows: [LimitWindow] = []
        if let window = Self.window(root.object("five_hour"), minutes: 300) { windows.append(window) }
        if let window = Self.window(root.object("seven_day"), minutes: 10_080) { windows.append(window) }

        var scoped: [ScopedLimit] = []
        for row in root.array("limits") ?? [] {
            guard let row = row as? JSONObject, row.string("kind") == "weekly_scoped",
                  let window = Self.window(row, minutes: 10_080) else { continue }
            let label = row.object("scope")?.object("model")?.string("display_name") ?? "model"
            scoped.append(ScopedLimit(label: label, window: window))
        }

        return LimitsSnapshot(app: .claude, takenAt: Date(), windows: windows,
                              planName: credentials.subscriptionType, scoped: scoped)
    }

    private static func window(_ node: JSONObject?, minutes: Int) -> LimitWindow? {
        guard let node else { return nil }
        guard let percent = node.double("utilization") ?? node.double("percent") else { return nil }
        return LimitWindow(minutes: minutes, pct: percent,
                           resetsAt: Timestamps.parse(node.string("resets_at")))
    }

    // MARK: - Keychain

    struct Credentials {
        var accessToken: String
        var subscriptionType: String?
        /// When Claude Code says the token stops working. Drives how long it
        /// may be held in memory — no guess, the vendor's own number.
        var expiresAt: Date?

        /// A minute of margin, so a token is never used in the second it dies.
        var isUsable: Bool {
            guard let expiresAt else { return false }
            return Date() < expiresAt.addingTimeInterval(-60)
        }
    }

    /// Claude Code also keeps the same JSON in `~/.claude/.credentials.json`
    /// on some setups. When that copy is current it is preferred over the
    /// Keychain for one reason only: reading it raises no password prompt.
    /// A stale copy (the usual case when the Keychain is the live store) is
    /// ignored rather than trusted.
    static func fileCredentials() -> Credentials? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".claude/.credentials.json")
        guard let data = try? Data(contentsOf: url),
              let credentials = parse(data), credentials.isUsable
        else { return nil }
        return credentials
    }

    /// Uses `/usr/bin/security` rather than the Keychain API on purpose: the
    /// item belongs to Claude Code's access group, and the command line tool is
    /// the path macOS grants after the one-time user approval.
    static func readCredentials() throws -> Credentials {
        if let fromFile = fileCredentials() { return fromFile }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", keychainService, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do { try process.run() } catch { throw LimitsError.keychainDenied }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LimitsError.keychainDenied }

        guard let credentials = parse(data) else { throw LimitsError.keychainDenied }
        return credentials
    }

    private static func parse(_ data: Data) -> Credentials? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let oauth = root.object("claudeAiOauth"),
              let token = oauth.string("accessToken")
        else { return nil }
        // Milliseconds since the epoch, the way Claude Code writes it.
        let expiry = oauth.double("expiresAt").map { Date(timeIntervalSince1970: $0 / 1000) }
        return Credentials(accessToken: token,
                           subscriptionType: oauth.string("subscriptionType"),
                           expiresAt: expiry)
    }
}

/// Holds Claude's access token in memory for as long as it is valid.
///
/// Not an optimisation — a fix. Every read went through
/// `/usr/bin/security find-generic-password`, and macOS asks for the Keychain
/// password whenever a program that is not on the item's access list reads it.
/// Claude Code rewrites that item every time it refreshes its token, and a
/// rewritten item comes back with its access list reset, so "Always Allow"
/// stops holding — which turned a read every five minutes into a password
/// prompt every five minutes. One read per token lifetime instead, in memory
/// only: never written to disk, never logged.
actor ClaudeCredentials {
    static let shared = ClaudeCredentials()

    private var cached: ClaudeLiveLimits.Credentials?

    func current() throws -> ClaudeLiveLimits.Credentials {
        if let cached, cached.isUsable { return cached }
        let fresh = try ClaudeLiveLimits.readCredentials()
        cached = fresh
        return fresh
    }

    func invalidate() { cached = nil }
}
