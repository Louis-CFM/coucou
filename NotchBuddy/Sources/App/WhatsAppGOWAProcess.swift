#if !APPSTORE
import Foundation

// GitHub build only (#if !APPSTORE): the App Store build is sandboxed and may not run
// another program. Starts the GOWA binary the user picked as a child of Coucou, on the
// address set in Settings, and stops it when Coucou quits.

/// GOWA launched by Coucou ("Start GOWA automatically" in Settings).
@MainActor
final class WhatsAppGOWAProcess {
    static let shared = WhatsAppGOWAProcess()

    private var process: Process?
    private var lastStart: Date = .distantPast

    static var autoStart: Bool {
        get { UserDefaults.standard.bool(forKey: "whatsappAutoStartGOWA") }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappAutoStartGOWA") }
    }

    /// The binary's path (not a secret: UserDefaults).
    static var binaryPath: String {
        get { UserDefaults.standard.string(forKey: "whatsappGOWAPath") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "whatsappGOWAPath") }
    }

    var isRunning: Bool { process?.isRunning == true }

    /// Where GOWA keeps its own WhatsApp session (its database, not Coucou's): one folder in
    /// Application Support, so the link survives restarts.
    nonisolated static var workingDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Coucou/GOWA", isDirectory: true)
    }

    /// What the running GOWA was started with: changed, it is restarted; same, left alone.
    private var launchedWith: String?

    /// Brings GOWA in line with Settings: started when "Start GOWA automatically" is on (and
    /// the gateway is GOWA on this Mac), restarted only when its binary, address or password
    /// changed, stopped when the option is off. A GOWA that keeps dying is started again once
    /// a minute at most. Returns false when it can't run.
    @discardableResult
    func sync() -> Bool {
        guard Self.autoStart, WhatsAppSettings.gateway == .gowa else { stopNow(); return false }
        let path = (Self.binaryPath as NSString).expandingTildeInPath
        guard !path.isEmpty, FileManager.default.isExecutableFile(atPath: path),
              let url = URL(string: WhatsAppSettings.url) else {
            appendAppLog("nb.log", "[WhatsApp] GOWA binary missing or not executable")
            stopNow()
            return false
        }
        // Only ever on this Mac: an address elsewhere is someone else's gateway.
        guard ["127.0.0.1", "localhost", "::1"].contains(url.host ?? "") else { stopNow(); return false }
        let credential = KeychainStore.shared.get(WhatsAppSettings.credentialKey) ?? ""
        let signature = [path, url.absoluteString, credential].joined(separator: "\u{1F}")
        if isRunning {
            if launchedWith == signature { return true }
            stopNow()   // waits for it to let go of the port and its database
        } else if launchedWith == signature, Date().timeIntervalSince(lastStart) < 60 {
            return true
        }
        try? FileManager.default.createDirectory(at: Self.workingDirectory, withIntermediateDirectories: true)

        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = WAGOWA.launchArguments(for: url)
        p.currentDirectoryURL = Self.workingDirectory
        var env = ProcessInfo.processInfo.environment
        // The credential goes through the environment, not the command line (`ps` shows that).
        if credential.contains(":") { env["APP_BASIC_AUTH"] = credential }
        // GOWA's own web dashboard is not needed (Coucou is the interface): it would fetch
        // itself from GitHub at each start.
        env["APP_UI_ENABLED"] = "false"
        p.environment = env
        // GOWA's own output may name contacts or quote messages: it goes nowhere.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        p.terminationHandler = { proc in
            let status = proc.terminationStatus
            Task { @MainActor in
                appendAppLog("nb.log", "[WhatsApp] GOWA exited (\(status))")
            }
        }
        do {
            try p.run()
            process = p
            lastStart = Date()
            launchedWith = signature
            appendAppLog("nb.log", "[WhatsApp] GOWA started (pid \(p.processIdentifier))")
            return true
        } catch {
            appendAppLog("nb.log", "[WhatsApp] GOWA could not start: \(error.localizedDescription)")
            return false
        }
    }

    /// Stops GOWA if Coucou started it, waiting a second at most for it to go (at quit, or
    /// before starting it again so two never share its database).
    func stopNow() {
        launchedWith = nil
        guard let p = process else { return }
        guard p.isRunning else { process = nil; return }
        p.terminate()
        let deadline = Date().addingTimeInterval(1)
        while p.isRunning && Date() < deadline { usleep(50_000) }
        if p.isRunning { kill(p.processIdentifier, SIGKILL) }
        process = nil
    }
}
#endif
