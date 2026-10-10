import Foundation

// MARK: - TimelyPoller
// Today's entries and the running timer, every minute while the Timely pill is
// in the notch. OAuth tokens live in the Keychain; a 401 refreshes them once.

@MainActor
final class TimelyPoller {
    static let shared = TimelyPoller()

    enum Key {
        static let clientId     = "timely-client-id"
        static let clientSecret = "timely-client-secret"
        static let access       = "timely-access-token"
        static let refresh      = "timely-refresh-token"
    }

    static let pillId = "integration_timely"
    private static let interval: TimeInterval = 60

    private var timer: DispatchSourceTimer?
    private var inFlight = false
    // Looked up once per token: neither changes while the same user is connected.
    private var accountId: Int?
    private var userId: Int?
    private var capacity: (day: String, hours: Double?)?

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 9, repeating: Self.interval, leeway: .seconds(5))
        t.setEventHandler { Task { @MainActor in await TimelyPoller.shared.poll() } }
        t.resume()
        timer = t
    }

    func pollNow() { Task { await poll() } }

    private var isWanted: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    // MARK: - Connect

    /// Exchanges the code Timely showed for tokens. Returns false when Timely refused it.
    func connect(code: String) async -> Bool {
        guard let id = KeychainStore.shared.get(Key.clientId),
              let secret = KeychainStore.shared.get(Key.clientSecret) else { return false }
        let body = TimelyAPI.codeBody(clientId: id, clientSecret: secret, code: code)
        guard let tokens = await requestTokens(body, keeping: nil) else { return false }
        store(tokens)
        forgetUser()
        AppState.shared.timelyError = nil
        pollNow()
        return true
    }

    func disconnect() {
        KeychainStore.shared.remove(Key.access)
        KeychainStore.shared.remove(Key.refresh)
        forgetUser()
        AppState.shared.timelyDay = nil
        AppState.shared.timelyLoaded = false
        AppState.shared.timelyError = nil
    }

    private func forgetUser() {
        accountId = nil
        userId = nil
        capacity = nil
    }

    private func store(_ tokens: TimelyTokens) {
        KeychainStore.shared.set(Key.access, value: tokens.access)
        if let refresh = tokens.refresh { KeychainStore.shared.set(Key.refresh, value: refresh) }
    }

    // MARK: - Poll

    private func poll() async {
        guard !DemoEngine.isPollerPaused, isWanted, !inFlight else { return }
        guard KeychainStore.shared.get(Key.access) != nil else { return }
        inFlight = true
        defer { inFlight = false }

        guard let (account, user) = await resolveUser() else { return }
        let today = TimelyFormat.day(Date())
        if capacity?.day != today {
            let (status, data) = await get("/\(account)/users/\(user)/capacities")
            capacity = (today, status == TimelyAPI.httpOK ? data.flatMap(TimelyParse.dailyCapacity) : nil)
        }

        let (status, data) = await get("/\(account)/users/\(user)/events?since=\(today)&upto=\(today)")
        guard status == TimelyAPI.httpOK, let data, let entries = TimelyParse.entries(data) else {
            report(status)
            return
        }
        let state = AppState.shared
        state.setIfChanged(\.timelyError, nil)
        state.setIfChanged(\.timelyDay, TimelyDay(entries: entries, capacityHours: capacity?.hours))
        state.setIfChanged(\.timelyLoaded, true)
    }

    private func resolveUser() async -> (Int, Int)? {
        if let accountId, let userId { return (accountId, userId) }
        let (accountStatus, accounts) = await get("/accounts")
        guard let account = accounts.flatMap(TimelyParse.firstAccountId) else {
            report(accountStatus)
            return nil
        }
        let (userStatus, me) = await get("/\(account)/users/current")
        guard let user = me.flatMap(TimelyParse.userId) else {
            report(userStatus)
            return nil
        }
        accountId = account
        userId = user
        return (account, user)
    }

    private func report(_ status: Int) {
        let message: String
        switch status {
        case TimelyAPI.httpUnauthorized: message = "Invalid API key (401)"
        case 0:                          message = "No connection"
        default:                         message = "API error \(status)"
        }
        AppState.shared.setIfChanged(\.timelyError, message)
    }

    // MARK: - HTTP

    private func get(_ path: String) async -> (status: Int, data: Data?) {
        guard let access = KeychainStore.shared.get(Key.access),
              let url = URL(string: TimelyAPI.base + path) else { return (TimelyAPI.httpUnauthorized, nil) }
        return await TimelyAPI.withRefresh(
            access: access,
            send: { token in await Self.send(url, token: token) },
            refresh: { await self.refreshTokens() })
    }

    private nonisolated static func send(_ url: URL, token: String) async -> (status: Int, data: Data?) {
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await URLSession.shared.data(for: req) else { return (0, nil) }
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    private func refreshTokens() async -> String? {
        guard let id = KeychainStore.shared.get(Key.clientId),
              let secret = KeychainStore.shared.get(Key.clientSecret),
              let refresh = KeychainStore.shared.get(Key.refresh) else { return nil }
        let body = TimelyAPI.refreshBody(clientId: id, clientSecret: secret, refreshToken: refresh)
        guard let tokens = await requestTokens(body, keeping: refresh) else { return nil }
        store(tokens)
        return tokens.access
    }

    private func requestTokens(_ body: [String: String], keeping oldRefresh: String?) async -> TimelyTokens? {
        var req = URLRequest(url: TimelyAPI.tokenURL, timeoutInterval: 10)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              (response as? HTTPURLResponse)?.statusCode == TimelyAPI.httpOK else { return nil }
        return TimelyTokens.parse(data, keeping: oldRefresh)
    }
}
