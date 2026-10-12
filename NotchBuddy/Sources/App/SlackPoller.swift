import AppKit
import Foundation

// MARK: - SlackPoller
// Unread direct messages and recent mentions, with the user's own Slack user token.
// Polls once a minute, only while the Slack pill is declared. Calls and rate limits:
// docs/INTEGRATIONS.md, section Slack.

@MainActor
final class SlackPoller {
    static let shared = SlackPoller()

    private static let pillId = "integration_slack"
    private static let tokenKey = "slack-token"
    private static let interval: Duration = .seconds(60)
    private static let imListMaxAge: TimeInterval = 600
    private static let imsPerPoll = 15

    private var loop: Task<Void, Never>?
    private var polling = false
    private var token: String?
    private var identity: SlackIdentity?
    private var ims: [SlackIM] = []
    private var imsFetchedAt: Date = .distantPast
    private var unreadIms: Set<String> = []
    private var names: [String: String] = [:]
    /// Newest message already announced; nil until the first poll fills the card.
    private var lastAnnouncedTs: String?
    /// Set from a 429's Retry-After: no request before then.
    private var quietUntil: Date = .distantPast

    private init() {}

    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            while !Task.isCancelled {
                await self?.poll()
                try? await Task.sleep(for: SlackPoller.interval)
            }
        }
    }

    func pollNow() {
        Task { await poll() }
    }

    // MARK: - Poll

    private func poll() async {
        guard !polling, !DemoEngine.isPollerPaused, Date() >= quietUntil else { return }
        let state = AppState.shared
        guard state.activeIntegrations.contains(Self.pillId) else { return }
        guard let current = KeychainStore.shared.get(Self.tokenKey) else {
            if token != nil { reset() }
            return
        }
        polling = true
        defer { polling = false }
        if current != token { reset(); token = current }

        do {
            let me = try await currentIdentity()
            let dms = try await unreadDirectMessages(me: me)
            let mentions = try await recentMentions(me: me)
            try await resolveNames(for: dms.map(\.userId) + mentions.map(\.userId) + [me.userId])

            let named = (dms + mentions).map { m -> SlackMessage in
                var m = m
                if m.kind == .dm { m.author = names[m.userId] ?? m.author }
                m.text = SlackParsing.snippet(m.text, names: names)
                return m
            }
            let messages = SlackParsing.merged(dms: named.filter { $0.kind == .dm },
                                               mentions: named.filter { $0.kind == .mention })
            state.setIfChanged(\.slackError, nil)
            state.slackTeamId = me.teamId
            state.slackWorkspaceURL = me.url
            state.slackMessages = messages
            state.slackUnreadDMs = dms.reduce(0) { $0 + $1.unread }
            state.slackMentionCount = mentions.count
            state.setIfChanged(\.slackLoaded, true)
            announce(messages)
        } catch let error as SlackError {
            state.setIfChanged(\.slackError, error.message)
        } catch {
            state.setIfChanged(\.slackError, error.localizedDescription)
        }
    }

    private func reset() {
        token = nil
        identity = nil
        ims = []
        imsFetchedAt = .distantPast
        unreadIms = []
        names = [:]
        lastAnnouncedTs = nil
        let state = AppState.shared
        state.slackMessages = []
        state.slackLoaded = false
        state.slackError = nil
    }

    private func currentIdentity() async throws -> SlackIdentity {
        if let identity { return identity }
        let json = try await call("auth.test")
        guard let me = SlackParsing.identity(json) else { throw SlackError(message: "Slack error: auth.test") }
        identity = me
        return me
    }

    private func unreadDirectMessages(me: SlackIdentity) async throws -> [SlackMessage] {
        if Date().timeIntervalSince(imsFetchedAt) > Self.imListMaxAge {
            let json = try await call("conversations.list", ["types": "im", "exclude_archived": "true", "limit": "200"])
            ims = SlackParsing.ims(json)
            imsFetchedAt = Date()
        }
        var found: [SlackMessage] = []
        var gone: Set<String> = []
        for im in SlackParsing.imsToCheck(ims, unread: unreadIms, limit: Self.imsPerPoll) {
            guard let json = try await callItem("conversations.info", ["channel": im.channelId]) else {
                gone.insert(im.channelId)
                continue
            }
            if let dm = SlackParsing.unreadDM(json, me: me.userId) { found.append(dm) }
        }
        ims.removeAll { gone.contains($0.channelId) }
        unreadIms = Set(found.map(\.channelId))
        return found
    }

    private func recentMentions(me: SlackIdentity) async throws -> [SlackMessage] {
        let json = try await call("search.messages", ["query": "<@\(me.userId)>", "sort": "timestamp",
                                                      "sort_dir": "desc", "count": "20"])
        return SlackParsing.mentions(json, me: me.userId)
    }

    private func resolveNames(for ids: [String]) async throws {
        for id in Set(ids) where names[id] == nil && !id.isEmpty {
            let json = try await callItem("users.info", ["user": id])
            names[id] = json.flatMap(SlackParsing.userName) ?? id
        }
    }

    // MARK: - Alert

    private func announce(_ messages: [SlackMessage]) {
        guard let newest = SlackParsing.newest(messages) else { return }
        defer { lastAnnouncedTs = newest.ts }
        guard let last = lastAnnouncedTs, SlackParsing.tsLess(last, newest.ts) else { return }

        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        state.tasks[idx].state = .finished
        state.tasks[idx].steps = [newest.author]
        if state.focusId != Self.pillId { state.tasks[idx].pillBadge = .finished }
        SoundEngine.shared.play("finish")
        NotificationCenter.default.post(name: .hookReveal, object: nil)

        // Same 60 s auto-clear as the other services; the messages stay on the card.
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) {
            guard let i = state.tasks.firstIndex(where: { $0.id == Self.pillId }),
                  state.tasks[i].state == .finished else { return }
            state.tasks[i].state = .idle
            state.tasks[i].steps = []
            state.tasks[i].pillBadge = nil
        }
    }

    // MARK: - Opening

    static func open(_ message: SlackMessage) {
        let team = AppState.shared.slackTeamId
        if let app = SlackLinks.app(team: team, channel: message.channelId),
           NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
            return
        }
        if let web = SlackLinks.web(team: team, channel: message.channelId, permalink: message.permalink) {
            NSWorkspace.shared.open(web)
        }
    }

    /// The ↗ button: the Slack app, else the workspace in a browser.
    static func openWorkspace() {
        let state = AppState.shared
        if let app = URL(string: "slack://open"), NSWorkspace.shared.urlForApplication(toOpen: app) != nil {
            NSWorkspace.shared.open(app)
        } else if let url = safeWebURL(state.slackWorkspaceURL) ?? URL(string: "https://app.slack.com") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - HTTP

    private struct SlackError: Error {
        let message: String
    }

    private func call(_ method: String, _ params: [String: String] = [:]) async throws -> [String: Any] {
        let json = try await send(method, params)
        if let error = SlackParsing.error(json) { throw SlackError(message: error) }
        return json
    }

    /// A call about one conversation or person: nil when Slack no longer finds it.
    private func callItem(_ method: String, _ params: [String: String]) async throws -> [String: Any]? {
        let json = try await send(method, params)
        if SlackParsing.isMissing(json) { return nil }
        if let error = SlackParsing.error(json) { throw SlackError(message: error) }
        return json
    }

    private func send(_ method: String, _ params: [String: String]) async throws -> [String: Any] {
        guard let token else { throw SlackError(message: "Invalid token") }
        var components = URLComponents(string: "https://slack.com/api/\(method)")!
        if !params.isEmpty {
            components.queryItems = params.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        }
        var req = URLRequest(url: components.url!, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: req)
        let http = response as? HTTPURLResponse
        if http?.statusCode == 429 {
            quietUntil = Date().addingTimeInterval(SlackParsing.retryAfter(http?.value(forHTTPHeaderField: "Retry-After")))
            throw SlackError(message: "Slack error: ratelimited")
        }
        guard http?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError(message: "API error \(http?.statusCode ?? 0)")
        }
        return json
    }
}
