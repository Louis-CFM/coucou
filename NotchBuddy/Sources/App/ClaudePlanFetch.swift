#if !APPSTORE
import Foundation

// MARK: - Claude plan usage from the account (GitHub build)

/// The status line only reports limits while a Claude Code session is open in a terminal, so
/// the gauge froze for people who mostly use the Claude desktop app or claude.ai. This reads the
/// same numbers from the account, with the token Claude Code already stores in the Keychain.
/// Nothing is written: no token refresh, no change to Claude Code's credentials.
enum ClaudePlanFetch {

    private static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// nil if Claude Code was never signed in on this Mac, its token expired, or the call failed.
    static func fetch() async -> PlanUsage? {
        guard let token = await Task.detached(operation: { readAccessToken() }).value else { return nil }
        var req = URLRequest(url: usageURL, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return ClaudePlanGauge.parseAccountUsage(json)
    }

    /// Claude Code keeps its credentials in the login Keychain ("Claude Code-credentials"),
    /// created through /usr/bin/security, so reading them the same way does not prompt.
    /// Older installs keep them in ~/.claude/.credentials.json.
    private static func readAccessToken() -> String? {
        if let data = runSecurity(), let t = ClaudePlanGauge.accessToken(fromCredentials: data) { return t }
        let file = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/.credentials.json")
        if let data = try? Data(contentsOf: file) { return ClaudePlanGauge.accessToken(fromCredentials: data) }
        return nil
    }

    private static func runSecurity() -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0, !data.isEmpty else { return nil }
        return data
    }
}
#endif
