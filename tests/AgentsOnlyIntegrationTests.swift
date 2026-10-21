import AppKit
import Foundation

// Contracts use the shipping sources but keep diagnostic writes out of the
// installed app's log directory. Service/audio boundaries below are injected.
func appendAppLog(_ fileName: String, _ message: String, timestampFormat: String = "yyyy-MM-dd HH:mm:ss") {}
func escapedForLog(_ text: String) -> String { text }

@MainActor
final class ContractGate {
    var arrivals = 0
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        arrivals += 1
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { opened = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}

@MainActor
final class RefreshScenario {
    let gates = (0..<8).map { _ in ContractGate() }
    var calls = 0
    func read() async -> Int {
        let index = calls; calls += 1
        precondition(index < gates.count, "Duplicate refresh task")
        await gates[index].wait() // Deliberately ignores cancellation: old callbacks can arrive late.
        return index + 1
    }
}

final class ContractURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var stream: ContractURLProtocol?
    nonisolated(unsafe) private static var unexpected = 0
    static var unexpectedRequests: Int { lock.withLock { unexpected } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "coucou-chat.invalid" else {
            Self.lock.withLock { Self.unexpected += 1 }
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lock.withLock { Self.stream = self }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "text/event-stream"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data("data: {\"choices\":[{\"delta\":{\"content\":\"first token\"}}]}\n\n".utf8))
    }
    override func stopLoading() {}
    static func finishStream() {
        guard let stream = lock.withLock({ stream }) else { preconditionFailure("No mock stream") }
        stream.client?.urlProtocolDidFinishLoading(stream)
    }
}

@main
struct AgentsOnlyIntegrationTests {
    @MainActor static func eventually(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<400 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure(message)
    }

    @MainActor static func main() async {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let domain = Bundle.main.bundleIdentifier!
        precondition(domain.hasPrefix("local.coucou.contracts."))
        defer { UserDefaults.standard.removePersistentDomain(forName: domain) }
        URLProtocol.registerClass(ContractURLProtocol.self)
        defer { URLProtocol.unregisterClass(ContractURLProtocol.self) }
        let state = AppState.shared
        await testChat(state)
        testClick(state)
        testLiveTasks(state)
        testPhoneSync(state)
        await testRefreshes(state)
        #if !APPSTORE
        await testTrustWaiter(state)
        await testFinalization(state)
        await testPromptDictation(state)
        await testMusicRestoration(state)
        #endif
        precondition(ContractURLProtocol.unexpectedRequests == 0, "A test tried to contact a real service")
        print("Native mode integration contracts passed")
    }

    @MainActor static func testChat(_ state: AppState) async {
        state.chatProvider = .ollama
        state.ollamaServerURL = "https://coucou-chat.invalid"
        state.ollamaChatModel = "fixture"
        let request = Task { await ClaudeService.shared.chat(query: "fixture", context: nil, state: state) }
        await eventually("Mock stream did not deliver its first visible token") {
            state.chatHistory.last?.content == "first token"
        }
        precondition(state.stateOverride == nil)
        precondition(state.optionalWork.busy && !state.setAgentsOnly(true), "First token must not release a streaming request")
        ContractURLProtocol.finishStream()
        await request.value
        precondition(!state.optionalWork.busy && state.setAgentsOnly(true))
        precondition(state.setAgentsOnly(false))
        print("PASS actual ClaudeService stream and AppState gate (including first token)")
    }

    @MainActor static func testClick(_ state: AppState) {
        precondition(state.setAgentsOnly(true))
        state.mode = .compact
        let controller = IslandWindowController(window: nil) // No monitors, panel or application delegate.
        controller.fsm.openOnHover = false
        controller.fsm.mouseEntered()
        precondition(controller.fsm.state == .petit)
        controller.beginIslandClick(inIsland: true, onBot: true, position: .zero)
        controller.endIslandClick()
        precondition(controller.fsm.state == .home, "Focus mode must preserve the default click-to-open path")
        precondition(state.setAgentsOnly(false))
        print("PASS actual island click handlers with hover disabled")
    }

    @MainActor static func testLiveTasks(_ state: AppState) {
        for id in ["agent_cursor", "agent_codex"] {
            state.observedAgent(id)
            state.tasks.removeAll { $0.id == id }
            state.addTask(AgentTask(id: id, name: "Live project", color: "#123456", state: .working,
                                   steps: ["Read", "Edit"], source: .agent, isIntegration: true))
        }
        let live = state.tasks.filter { ["agent_cursor", "agent_codex"].contains($0.id) }
        state.refreshAgentConnections() // Settings disappear / section changes.
        precondition(state.setAgentsOnly(true))
        precondition(state.setAgentsOnly(false))
        for task in live { precondition(state.tasks.contains(task), "Catalog reconciliation erased live session activity") }
        state.tasks.append(AgentTask(id: "ai_anthropic", name: "Placeholder", color: "#123456", state: .idle,
                                     steps: [], source: .agent, isIntegration: true, isPlaceholder: true))
        state.activeIntegrations.remove("ai_anthropic")
        state.refreshAgentConnections()
        precondition(!state.tasks.contains { $0.id == "ai_anthropic" }, "Unselected placeholders should still be reconciled")
        print("PASS AppState reconciliation preserves live Cursor/Codex steps and state")
    }

    @MainActor static func testPhoneSync(_ state: AppState) {
        var listeners = 0, cleanups = 0
        let runtime = OptionalFeatureRuntime(features: [
            .init(start: { listeners += 1 }, stop: { listeners -= 1; cleanups += 1 }),
            .init(start: { listeners += 1 }, stop: { listeners -= 1; cleanups += 1 })
        ])
        runtime.apply(agentsOnly: false)
        // No ping task is created; call the actual CloudProbe mode path for an
        // already-started sync lifecycle, using local service collaborators.
        let probe = CloudProbe(started: true, startServices: { runtime.apply(agentsOnly: false) },
                               stopServices: { runtime.apply(agentsOnly: true) })
        for _ in 0..<3 {
            precondition(state.setAgentsOnly(true))
            probe.updateServiceMode()
            precondition(listeners == 0)
            precondition(state.setAgentsOnly(false))
            probe.updateServiceMode()
            probe.updateServiceMode()
            precondition(listeners == 2)
        }
        precondition(cleanups == 6)
        runtime.apply(agentsOnly: true)
        print("PASS actual CloudProbe sync-on/ping-off stop, cleanup and restart")
    }

    @MainActor static func refreshContract(_ name: String, pill: String, state: AppState, scenario: RefreshScenario,
                                            refresh: () -> Void, stop: () -> Void, value: () -> Int) async {
        state.activeIntegrations.insert(pill)
        refresh()
        await eventually("First \(name) request did not start") { scenario.calls == 1 }
        state.activeIntegrations.remove(pill)
        scenario.gates[0].release()
        await eventually("Inactive \(name) completion did not unwind") { scenario.gates[0].arrivals > 0 }
        // Give the completed first request a turn to run its production defer.
        await Task.yield()
        state.activeIntegrations.insert(pill)
        await eventually("\(name) stayed wedged after disable/complete/re-enable") {
            refresh(); return scenario.calls == 2
        }
        scenario.gates[1].release()
        await eventually("\(name) replacement did not publish") { value() == 2 }
        refresh()
        await eventually("Third \(name) request did not start") { scenario.calls == 3 }
        stop()
        refresh()
        await eventually("Fourth \(name) request did not start") { scenario.calls == 4 }
        scenario.gates[2].release()
        // Wait until the stale closure has returned to its owning task.
        for _ in 0..<10 { await Task.yield() }
        refresh()
        precondition(scenario.calls == 4, "Stale \(name) completion released replacement ownership")
        scenario.gates[3].release()
        await eventually("Final \(name) request did not publish") { value() == 4 }
        stop()
        state.activeIntegrations.remove(pill)
        print("PASS actual \(name): disable/complete/re-enable and stale completion")
    }

    @MainActor static func testRefreshes(_ state: AppState) async {
        let cryptoScenario = RefreshScenario()
        UserDefaults.standard.set("BTC", forKey: CryptoSettings.coinsKey)
        let crypto = CryptoController(fetchQuote: { _, _, _, _ in
            CryptoQuote(symbol: "BTC", price: Double(await cryptoScenario.read()), open24h: 1)
        })
        await refreshContract("CryptoController", pill: CryptoController.pillId, state: state, scenario: cryptoScenario,
                              refresh: crypto.refresh, stop: crypto.stop, value: { Int(crypto.quotes.first?.price ?? 0) })
        let portfolioScenario = RefreshScenario()
        let fixture = PortfolioAccount(source: .exchange(.binance))
        let portfolio = PortfolioController(configuredAccounts: { [fixture] }, readAccount: { account in
            var result = account; result.fetchError = String(await portfolioScenario.read()); return result
        }, readPrices: { _ in [:] })
        await refreshContract("PortfolioController", pill: PortfolioController.pillId, state: state, scenario: portfolioScenario,
                              refresh: portfolio.refresh, stop: portfolio.stop, value: { Int(portfolio.accounts.first?.fetchError ?? "0") ?? 0 })
        #if !APPSTORE
        let mailScenario = RefreshScenario()
        let mail = MailController(mailAvailable: { true }, executeScript: { _ in .success([String(await mailScenario.read())]) })
        await refreshContract("MailController", pill: MailController.pillId, state: state, scenario: mailScenario,
                              refresh: mail.refresh, stop: mail.stop, value: { mail.unreadCount ?? 0 })
        #endif
    }

    #if !APPSTORE
    @MainActor static func testTrustWaiter(_ state: AppState) async {
        UserDefaults.standard.set(true, forKey: FlowDictation.enabledKey)
        FlowStore.shared.engine = .apple
        let permission = ContractGate()
        var trusted = false, installs = 0, removals = 0
        var eventHandler: FlowInputAccess.Handler?
        let flow = FlowDictation(inputAccess: .init(trusted: { trusted }, wait: { await permission.wait() },
            install: { handler in installs += 1; eventHandler = handler; return [NSObject()] }, remove: { _ in removals += 1 }))
        flow.start()
        await eventually("Trust waiter did not start") { permission.arrivals > 0 }
        precondition(installs == 1)
        trusted = true
        precondition(state.setAgentsOnly(true))
        flow.stop()
        permission.release() // Cancelled waiter resumes after permission became granted.
        for _ in 0..<10 { await Task.yield() }
        eventHandler?(.flagsChanged, flow.key.keyCode, .option, nil)
        precondition(installs == 1 && removals == 1 && !flow.busy, "A cancelled permission waiter revived keyboard/microphone work")
        precondition(state.setAgentsOnly(false))
        flow.start()
        precondition(installs == 2)
        flow.stop()
        UserDefaults.standard.set(false, forKey: FlowDictation.enabledKey)
        print("PASS actual FlowDictation permission grant / focus race and keyboard boundary")
    }

    @MainActor static func testFinalization(_ state: AppState) async {
        let taker = NoteTaker(loadStoredNotes: false)
        let close = ContractGate(), process = ContractGate()
        let task = taker.finalizeRecording(UUID(), close: { await close.wait() }, process: { await process.wait() })
        precondition(taker.busy && !state.setAgentsOnly(true), "Finalization must be claimed synchronously")
        await eventually("Recorder close did not start") { close.arrivals == 1 }
        precondition(taker.working.isEmpty && taker.busy && !state.setAgentsOnly(true))
        close.release()
        await eventually("Processing did not start") { process.arrivals == 1 }
        precondition(taker.busy && !state.setAgentsOnly(true))
        process.release(); await task.value
        precondition(!taker.busy && state.setAgentsOnly(true))
        precondition(state.setAgentsOnly(false))
        print("PASS actual Notetaker finalization ownership through close and processing")
    }

    @MainActor static func testPromptDictation(_ state: AppState) async {
        let permission = ContractGate()
        let dictation = MacDictation(authorization: { await permission.wait(); return true })
        state.promptDraft = "unsent draft"
        let operation = state.optionalWork.begin() // PromptView claims before scheduling start/finish.
        let task = Task { await dictation.start(from: state.promptDraft) }
        await eventually("Prompt mic permission did not start") { dictation.isStarting }
        precondition(!state.setAgentsOnly(true))
        dictation.stop()
        state.optionalWork.end(operation)
        precondition(state.setAgentsOnly(true))
        permission.release(); await task.value
        precondition(!dictation.isStarting && !dictation.isRecording, "A removed prompt cannot start a microphone after late permission")
        precondition(state.promptDraft == "unsent draft")
        precondition(state.setAgentsOnly(false) && state.promptDraft == "unsent draft")
        print("PASS actual MacDictation late permission and shared draft preservation")
    }

    @MainActor static func testMusicRestoration(_ state: AppState) async {
        let writes = RefreshScenario()
        var musicCommands: [String] = [], spotifyCommands: [String] = []
        let music = MusicController(executeScript: { source in musicCommands.append(source); _ = await writes.read(); return .success([]) })
        let spotify = SpotifyController(running: { true }, executeScript: { source in spotifyCommands.append(source); _ = await writes.read(); return .success([]) })
        let voice = VoiceEngine(musicAccess: .init(spotifyPlaying: { true }, spotifyVolume: { 63 },
            setSpotifyVolume: spotify.setVolume, musicPlaying: { true }, musicVolume: { 77 }, setMusicVolume: music.setVolume))
        voice.duckMusic()
        await eventually("Ducking did not write both volumes") { musicCommands.count == 1 && spotifyCommands.count == 1 }
        precondition(!state.setAgentsOnly(true))
        voice.restoreMusic()
        precondition(!state.setAgentsOnly(true), "Scheduled restoration must finish before the mode gate closes")
        writes.gates.forEach { $0.release() }
        await eventually("Volume restoration did not finish") { !state.optionalWork.busy }
        precondition(musicCommands.last?.hasSuffix("77") == true && spotifyCommands.last?.hasSuffix("63") == true)
        precondition(state.setAgentsOnly(true))
        precondition(state.setAgentsOnly(false))
        let lateRead = ContractGate()
        let previousCommands = musicCommands.count
        let ending = VoiceEngine(musicAccess: .init(spotifyPlaying: { false }, spotifyVolume: { 0 },
            setSpotifyVolume: spotify.setVolume, musicPlaying: { true },
            musicVolume: { await lateRead.wait(); return 77 }, setMusicVolume: music.setVolume))
        ending.duckMusic()
        await eventually("Delayed volume read did not start") { lateRead.arrivals == 1 }
        ending.restoreMusic()
        precondition(!state.setAgentsOnly(true), "Pending volume reads must retain ownership")
        lateRead.release()
        await eventually("Delayed volume read did not unwind") { !state.optionalWork.busy }
        precondition(musicCommands.count == previousCommands, "A late volume read must not duck after restoration")
        precondition(state.setAgentsOnly(true))
        precondition(state.setAgentsOnly(false))
        print("PASS actual VoiceEngine + Music/Spotify restore saved volumes before focus")
    }
    #endif
}
