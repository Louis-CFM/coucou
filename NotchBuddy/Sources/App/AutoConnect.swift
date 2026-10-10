import Foundation

/// Finds the AI tools and servers already on this Mac and connects them to the chat, so there is
/// no key to paste. Runs at launch and when Settings → Chat opens; the Scan button forces it.
/// Everything it asks stays on this Mac: the tools' own commands and 127.0.0.1.
@MainActor
enum AutoConnect {

    /// Automatic runs closer together than this are skipped (opening Settings twice is cheap).
    private static let minimumGap: TimeInterval = 30
    private static var lastRun = Date.distantPast

    /// `force` is the Scan button: it also reconnects what the user removed earlier.
    static func scan(force: Bool) async {
        let state = AppState.shared
        guard !state.isScanningConnections else { return }
        if !force, Date().timeIntervalSince(lastRun) < minimumGap { return }
        state.isScanningConnections = true
        defer { state.isScanningConnections = false; lastRun = Date() }

        var items: [ConnectedItem] = []
        var found: [CustomProvider] = []

        #if !APPSTORE
        // Every tool is asked at once: each check can take a few seconds.
        let statuses = await withTaskGroup(of: (CLIChatTool, CLIAuthStatus?).self) { group in
            for tool in CLIChatTools.all { group.addTask { (tool, await CLIChatRunner.authStatus(tool)) } }
            var results: [String: (CLIChatTool, CLIAuthStatus?)] = [:]
            for await (tool, status) in group { results[tool.id] = (tool, status) }
            return results
        }
        for tool in CLIChatTools.all {
            let status = statuses[tool.id]?.1
            appendAppLog("autoconnect.log", "\(tool.id): \(status.map { $0.isSignedIn ? "signed in" : "signed out" } ?? "not installed or no answer")")
            guard let status else { continue }
            items.append(CLIChatTools.connectedItem(for: tool, status: status))
            if status.isSignedIn { found.append(CLIChatTools.provider(for: tool)) }
        }
        #endif

        for server in await CustomProviderClient.scanThisMac() {
            let candidate = server.candidate
            let detail = server.models.isEmpty
                ? String(localized: "Running · no models yet")
                : String(format: String(localized: "Running · %lld models"), Int64(server.models.count))
            items.append(ConnectedItem(id: candidate.baseURL, name: candidate.name, detail: detail, status: .connected))
            switch candidate.builtInID {
            case "ollama":
                connectBuiltIn(id: "ollama", url: candidate.baseURL, current: \.ollamaServerURL, force: force)
            case "lmstudio":
                connectBuiltIn(id: "lmstudio", url: candidate.baseURL, current: \.lmstudioServerURL, force: force)
            default:
                guard let first = server.models.first else { continue }
                let id = CustomProviders.slug(from: candidate.name, existing: state.customProviders.map(\.id))
                found.append(CustomProvider(id: id, name: candidate.name, baseURL: candidate.baseURL, requiresKey: false,
                                            model: first, colorHex: CustomProviders.color(forID: id)))
            }
        }

        for provider in CustomProviders.providersToConnect(found: found, connected: state.customProviders,
                                                           dismissed: state.autoConnectDismissed, force: force) {
            state.addCustomProvider(provider, apiKey: "")
        }
        state.connectedItems = items
    }

    /// Ollama and LM Studio keep their own URL field in Settings → Chat → Local models.
    private static func connectBuiltIn(id: String, url: String, current: ReferenceWritableKeyPath<AppState, String>, force: Bool) {
        let state = AppState.shared
        guard CustomProviders.shouldConnectBuiltIn(id: id, currentURL: state[keyPath: current],
                                                   dismissed: state.autoConnectDismissed, force: force) else { return }
        state[keyPath: current] = LocalChat.normaliseURL(url)
    }
}
