import Foundation

/// Work admitted by a UI action must be claimed before its Task is scheduled.
/// The owner keeps the claim until final results and cleanup have completed.
@MainActor
final class OptionalWork {
    private var active: Set<UUID> = []
    var busy: Bool { !active.isEmpty }
    func begin() -> UUID { let id = UUID(); active.insert(id); return id }
    func end(_ id: UUID) { active.remove(id) }
}

/// A cancelled refresh cannot clear the ownership of its replacement request.
@MainActor
struct RefreshOwnership {
    private var current: UUID?
    var busy: Bool { current != nil }
    mutating func begin() -> UUID? {
        guard current == nil else { return nil }
        let id = UUID(); current = id; return id
    }
    func owns(_ id: UUID) -> Bool { current == id }
    mutating func finish(_ id: UUID) { if owns(id) { current = nil } }
    mutating func cancel() { current = nil }
}

struct AgentDisplayPolicy {
    let agentsOnly: Bool
    let connectedIDs: Set<String>

    static func isAgent(_ id: String) -> Bool {
        id == "integration_claude" || id.hasPrefix("agent_")
    }

    func allows(_ id: String) -> Bool {
        !agentsOnly || (Self.isAgent(id) && connectedIDs.contains(id))
    }

    func loadsCatalog(_ id: String, main: String, active: Set<String>) -> Bool {
        agentsOnly ? allows(id) : id == main || active.contains(id)
    }
}

/// The mode does not rewrite any individual feature preference.
final class AgentsOnlyPreference: @unchecked Sendable {
    static let shared = AgentsOnlyPreference(defaults: .standard)
    static let key = "agentsOnlyMode"
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var value: Bool

    init(defaults: UserDefaults) {
        self.defaults = defaults
        value = defaults.bool(forKey: Self.key)
    }

    var enabled: Bool { lock.withLock { value } }

    func set(_ enabled: Bool) {
        lock.withLock {
            value = enabled
            defaults.set(enabled, forKey: Self.key)
        }
    }
}

/// Owns only optional features. Agent transports remain outside this lifecycle.
@MainActor
final class OptionalFeatureRuntime {
    struct Feature {
        let start: () -> Void
        let stop: () -> Void
    }
    private let features: [Feature]
    private(set) var running = false

    init(features: [Feature]) { self.features = features }

    func apply(agentsOnly: Bool) {
        let wanted = !agentsOnly
        guard running != wanted else { return }
        running = wanted
        if wanted { features.forEach { $0.start() } }
        else { features.reversed().forEach { $0.stop() } }
    }
}

/// Ownership for optional async work, including tasks started by notifications.
@MainActor
final class FeatureTasks {
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var active = false
    var count: Int { tasks.count }

    func start() { active = true }

    func run(_ operation: @escaping @MainActor () async -> Void) {
        guard active else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            guard !Task.isCancelled else { return }
            await operation()
            self?.tasks.removeValue(forKey: id)
        }
    }

    func stop() {
        active = false
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
    }
}

/// Cancel the timer AND in-flight requests. Old completions cannot revive a
/// stopped service or publish data after a later restart.
final class ServiceActivity: @unchecked Sendable {
    struct Delivery: Sendable {
        fileprivate let owner: ServiceActivity
        fileprivate let generation: UUID
        var isCurrent: Bool { owner.isCurrent(generation) }

        func onMain(_ action: @escaping @MainActor @Sendable () -> Void) {
            DispatchQueue.main.async {
                guard isCurrent else { return }
                action()
            }
        }
    }
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var session: URLSession?
    private var generation = UUID()
    private let configuration: URLSessionConfiguration

    init(configuration: URLSessionConfiguration = .default) {
        self.configuration = configuration
    }

    var running: Bool { lock.withLock { session != nil } }

    private func isCurrent(_ token: UUID) -> Bool {
        lock.withLock { session != nil && generation == token }
    }

    @discardableResult
    func start(after delay: TimeInterval, every interval: TimeInterval, leeway: Int,
               poll: @escaping @Sendable () -> Void) -> Bool {
        lock.withLock {
            guard session == nil else { return false }
            generation = UUID()
            let token = generation
            session = URLSession(configuration: configuration)
            let source = DispatchSource.makeTimerSource(queue: .global(qos: .background))
            source.schedule(deadline: .now() + delay, repeating: interval, leeway: .seconds(leeway))
            source.setEventHandler { [weak self] in
                guard self?.isCurrent(token) == true else { return }
                poll()
            }
            timer = source
            source.resume()
            return true
        }
    }

    func stop() {
        let previous = lock.withLock { () -> (DispatchSourceTimer?, URLSession?) in
            let previous = (timer, session)
            timer = nil
            session = nil
            generation = UUID()
            return previous
        }
        previous.0?.cancel()
        previous.1?.invalidateAndCancel()
    }

    func dataTask(with request: URLRequest, from delivery: Delivery? = nil,
                  completionHandler: @escaping @Sendable (Data?, URLResponse?, Error?, Delivery) -> Void) -> URLSessionDataTask? {
        lock.withLock {
            guard let session else { return nil }
            if let delivery {
                guard delivery.owner === self, delivery.generation == generation else { return nil }
            }
            let token = generation
            return session.dataTask(with: request) { [weak self] data, response, error in
                guard let self, self.lock.withLock({ self.session != nil && self.generation == token }) else { return }
                completionHandler(data, response, error, Delivery(owner: self, generation: token))
            }
        }
    }

    deinit { timer?.cancel(); session?.invalidateAndCancel() }
}
