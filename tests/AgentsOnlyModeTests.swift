import Foundation

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func add(_ n: Int = 1) { lock.withLock { count += n } }
}

final class DeliveryStore: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServiceActivity.Delivery?
    var value: ServiceActivity.Delivery? { lock.withLock { stored } }
    func set(_ delivery: ServiceActivity.Delivery) { lock.withLock { stored = delivery } }
}

final class FocusURLProtocol: URLProtocol, @unchecked Sendable {
    static let starts = Counter()
    static let stops = Counter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.starts.add()
        if request.url?.path == "/respond" {
            client?.urlProtocol(self, didReceive: URLResponse(url: request.url!, mimeType: "text/plain", expectedContentLength: 2, textEncodingName: nil), cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("ok".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { Self.stops.add() }
}

@main
struct AgentsOnlyModeTests {
    static func check(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
    }

    static func wait(for predicate: @escaping @Sendable () -> Bool) async {
        for _ in 0..<100 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        preconditionFailure("Timed out waiting for lifecycle event")
    }

    @MainActor static func main() async {
        let suite = "coucou-focus-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: "unrelatedFeatureEnabled")
        let preference = AgentsOnlyPreference(defaults: defaults)
        check(!preference.enabled, "Full mode remains the default")
        preference.set(true)
        check(AgentsOnlyPreference(defaults: defaults).enabled, "Focus mode persists")
        preference.set(false)
        check(!AgentsOnlyPreference(defaults: defaults).enabled, "Returning to full mode persists")
        check(defaults.bool(forKey: "unrelatedFeatureEnabled"), "Feature preferences are preserved")

        let ids = ["integration_claude", "agent_pi", "integration_spotify", "ai_openai"]
        let empty = AgentDisplayPolicy(agentsOnly: true, connectedIDs: [])
        check(ids.filter(empty.allows).isEmpty, "No connected agents produces an empty state")
        let focus = AgentDisplayPolicy(agentsOnly: true, connectedIDs: ["agent_pi", "integration_spotify"])
        check(ids.filter(focus.allows) == ["agent_pi"], "Focus exposes connected agents only, even with a stale service id")
        check(!focus.loadsCatalog("integration_claude", main: "integration_claude", active: []), "An unconnected main workspace is omitted")
        let full = AgentDisplayPolicy(agentsOnly: false, connectedIDs: [])
        check(ids.filter(full.allows) == ids, "Full mode preserves visibility")
        check(full.loadsCatalog("integration_spotify", main: "integration_claude", active: ["integration_spotify"]), "Full mode restores selected services")

        let starts = Counter(), stops = Counter(), listeners = Counter()
        let center = NotificationCenter()
        let notification = Notification.Name("optional-feature-test")
        let deliveriesReceived = Counter()
        var tokens: [NSObjectProtocol] = []
        let feature = OptionalFeatureRuntime.Feature(start: {
            starts.add(); listeners.add()
            tokens.append(center.addObserver(forName: notification, object: nil, queue: nil) { _ in deliveriesReceived.add() })
        }, stop: {
            center.removeObserver(tokens.removeLast())
            stops.add(); listeners.add(-1)
        })
        let runtime = OptionalFeatureRuntime(features: [
            feature, feature,
        ])
        runtime.apply(agentsOnly: true)
        check(starts.value == 0, "Focus startup never starts unrelated features")
        for _ in 0..<50 {
            runtime.apply(agentsOnly: false)
            runtime.apply(agentsOnly: false)
            check(listeners.value == 2, "No duplicate subscriptions on full mode")
            let received = deliveriesReceived.value
            center.post(name: notification, object: nil)
            check(deliveriesReceived.value == received + 2, "Each live listener receives once")
            runtime.apply(agentsOnly: true)
            runtime.apply(agentsOnly: true)
            check(listeners.value == 0, "No listeners remain in focus mode")
            center.post(name: notification, object: nil)
            check(deliveriesReceived.value == received + 2, "Stopped listeners receive no notifications")
        }
        check(starts.value == 100 && stops.value == 100, "Every resource starts and stops exactly once per transition")

        let jobs = FeatureTasks()
        let finishedJobs = Counter()
        let startedJobs = Counter()
        jobs.run { finishedJobs.add() }
        check(jobs.count == 0, "Optional tasks cannot start while suspended")
        jobs.start()
        jobs.run {
            startedJobs.add()
            try? await Task.sleep(for: .seconds(10))
            if !Task.isCancelled { finishedJobs.add() }
        }
        check(jobs.count == 1, "Async work is owned")
        jobs.stop()
        await Task.yield()
        check(jobs.count == 0 && finishedJobs.value == 0, "Suspension cancels optional async work")
        check(startedJobs.value == 0, "A job cancelled before scheduling cannot begin work")
        jobs.start()
        jobs.run { finishedJobs.add() }
        for _ in 0..<10 where finishedJobs.value == 0 { await Task.yield() }
        check(finishedJobs.value == 1, "Optional async work resumes once")
        jobs.stop()

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FocusURLProtocol.self]
        let service = ServiceActivity(configuration: config)
        let ticks = Counter(), callbacks = Counter()
        check(service.start(after: 0, every: 0.02, leeway: 0, poll: { ticks.add() }), "A service starts")
        check(!service.start(after: 0, every: 0.02, leeway: 0, poll: { ticks.add() }), "A second timer is refused")
        service.dataTask(with: URLRequest(url: URL(string: "https://example.invalid/stall")!)) { _, _, _, _ in callbacks.add() }?.resume()
        await wait { FocusURLProtocol.starts.value == 1 && ticks.value > 0 }
        service.stop()
        await wait { FocusURLProtocol.stops.value == 1 }
        try? await Task.sleep(for: .milliseconds(50))
        let stoppedTicks = ticks.value
        try? await Task.sleep(for: .milliseconds(100))
        check(ticks.value == stoppedTicks, "Stopped services do not poll")
        check(callbacks.value == 0, "Cancelled requests do not publish stale completions")
        check(service.dataTask(with: URLRequest(url: URL(string: "https://example.invalid/never")!)) { _, _, _, _ in callbacks.add() } == nil, "Suspended services cannot start requests")
        check(service.start(after: 10, every: 60, leeway: 0, poll: {}), "A service can resume")
        let deliveries = DeliveryStore()
        service.dataTask(with: URLRequest(url: URL(string: "https://example.invalid/respond")!)) { data, _, _, delivery in
            if data == Data("ok".utf8) { deliveries.set(delivery); callbacks.add() }
        }?.resume()
        await wait { callbacks.value == 1 }
        let previous = deliveries.value!
        let publications = Counter()
        previous.onMain { publications.add() }
        service.stop()
        _ = service.start(after: 10, every: 60, leeway: 0, poll: {})
        try? await Task.sleep(for: .milliseconds(50))
        check(publications.value == 0, "A queued UI completion cannot cross a stop/restart boundary")
        check(!previous.isCurrent, "Old delivery generations are invalid after restart")
        check(service.dataTask(with: URLRequest(url: URL(string: "https://example.invalid/never")!), from: previous) { _, _, _, _ in callbacks.add() } == nil,
              "An old fallback chain cannot create a request after restart")
        service.stop()
        check(!service.running, "Service state is inactive after a second stop")
        print("Agents only mode: preference, 50 round trips, listener balance, timer and request cancellation, and restart passed")
    }
}
