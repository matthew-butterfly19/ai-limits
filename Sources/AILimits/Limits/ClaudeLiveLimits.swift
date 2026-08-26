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
        let credentials = try Self.readCredentials()

        var request = URLRequest(url: Self.endpoint)
        request.timeoutInterval = 12
        request.setValue("Bearer \(credentials.accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            if http.statusCode == 401 { throw LimitsError.tokenExpired }
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
    }

    /// Uses `/usr/bin/security` rather than the Keychain API on purpose: the
    /// item belongs to Claude Code's access group, and the command line tool is
    /// the path macOS grants after the one-time user approval.
    static func readCredentials() throws -> Credentials {
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

        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? JSONObject,
              let oauth = root.object("claudeAiOauth"),
              let token = oauth.string("accessToken")
        else { throw LimitsError.keychainDenied }

        return Credentials(accessToken: token,
                           subscriptionType: oauth.string("subscriptionType"))
    }
}
