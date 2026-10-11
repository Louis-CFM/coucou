import AppKit
import Foundation

// MARK: - GcalPoller
// Google Calendar, the network side of GoogleCalendar.swift.
//
// There is no Coucou server, so there is no shared "Sign in with Google": the
// user creates a Desktop OAuth client in their own Google Cloud project and
// pastes its ID and secret in Settings. Connecting then runs the installed-app
// flow Google documents for desktop apps — PKCE, a one-shot listener on
// 127.0.0.1, the browser for consent — and keeps only the refresh token, in the
// Keychain. Access tokens live in memory for their hour.
//
// Polled every minute so a five-minute reminder can't be skipped over.

final class GcalPoller: @unchecked Sendable {
    static let shared = GcalPoller()

    private var timer: DispatchSourceTimer?
    private let lock = NSLock()

    /// Bumped by every Connect and Cancel click, so a newer attempt (or a cancel)
    /// retires an older listener still waiting on a browser tab the user closed.
    /// Google's own error pages — "access blocked" for an app in Testing whose user
    /// isn't on the test list — never redirect back, so without this the wait could
    /// only end at the timeout.
    private var attempt = 0
    private var access: (token: String, until: Date)?
    /// The calendar list barely changes: fetched every ten minutes, not every poll.
    private var calendars: (list: [GcalCalendar], at: Date)?
    private var reminders = GcalReminders()
    private var polling = false
    /// A poll asked for while one was out (Connect finishing during a timer poll):
    /// run once more when it's done, so the new sign-in is never left unread.
    private var pollAgain = false

    private static let calendarsTTL: TimeInterval = 10 * 60
    /// How long the browser has to come back with a code.
    private static let connectTimeout: TimeInterval = 5 * 60

    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 4, repeating: 60)
        t.setEventHandler {
            Task {
                // A pill the user switched off makes no network calls at all.
                guard await MainActor.run(body: { AppState.shared.activeIntegrations.contains("integration_gcal") })
                else { return }
                await GcalPoller.shared.poll()
            }
        }
        t.resume()
        timer = t
    }

    // MARK: - Connecting

    /// Settings → Cancel: stops waiting for Google within a second.
    func cancel() {
        lock.withLock { attempt += 1 }
    }

    private func isCurrent(_ mine: Int) -> Bool {
        lock.withLock { attempt == mine }
    }

    /// Opens Google's consent page and returns once the refresh token is stored.
    /// Throws a message to show: cancelled, timed out, wrong client…
    func connect() async throws {
        guard let clientId = KeychainStore.shared.get("gcal-client-id"),
              let clientSecret = KeychainStore.shared.get("gcal-client-secret") else {
            throw GcalProblem.shown("Save the client ID and client secret first.")
        }
        let mine = lock.withLock { () -> Int in attempt += 1; return attempt }

        let listener = try LoopbackListener()
        defer { listener.close() }
        let redirect = "http://127.0.0.1:\(listener.port)"

        let verifier = GcalOAuth.b64url(try GcalOAuth.randomBytes(32))
        let challenge = GcalOAuth.b64url(GcalOAuth.sha256(Array(verifier.utf8)))
        let state = GcalOAuth.b64url(try GcalOAuth.randomBytes(16))

        let query = GcalOAuth.form([
            ("client_id", clientId),
            ("redirect_uri", redirect),
            ("response_type", "code"),
            ("scope", Gcal.scope),
            ("code_challenge", challenge),
            ("code_challenge_method", "S256"),
            ("state", state),
            // A refresh token, every time — Google only hands one out on consent.
            ("access_type", "offline"),
            ("prompt", "consent"),
        ])
        guard let url = URL(string: "\(Gcal.authURL)?\(query)") else {
            throw GcalProblem.shown("Could not build the Google sign-in link.")
        }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
        log("gcal: waiting for the browser")

        let code = try await waitForCode(listener, state: state, attempt: mine)

        let (status, body) = try await post(Gcal.tokenURL, GcalOAuth.form([
            ("code", code),
            ("client_id", clientId),
            ("client_secret", clientSecret),
            ("redirect_uri", redirect),
            ("grant_type", "authorization_code"),
            ("code_verifier", verifier),
        ]))
        guard (200..<300).contains(status) else {
            throw GcalProblem.shown(GcalOAuth.googleError(body) ?? "Google answered \(status)")
        }
        guard let refresh = body["refresh_token"] as? String else {
            throw GcalProblem.shown("Google didn't return a refresh token.")
        }
        KeychainStore.shared.set("gcal-refresh-token", value: refresh)
        lock.withLock {
            remember(body)
            reminders.clear()
            calendars = nil
        }
        log("gcal: connected")

        await poll()
    }

    /// Waits on a background thread for the browser to come back (LoopbackListener.waitForCode).
    private func waitForCode(_ listener: LoopbackListener, state: String, attempt mine: Int) async throws -> String {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let result = listener.waitForCode(
                    state: state,
                    deadline: Date().addingTimeInterval(Self.connectTimeout),
                    stillWanted: { self.isCurrent(mine) }
                )
                cont.resume(with: result.mapError { $0 as Error })
            }
        }
    }

    /// Revokes the grant at Google (best effort) and forgets the token.
    func disconnect() async {
        cancel()
        if let refresh = KeychainStore.shared.get("gcal-refresh-token") {
            _ = try? await post(Gcal.revokeURL, GcalOAuth.form([("token", refresh)]))
        }
        KeychainStore.shared.remove("gcal-refresh-token")
        lock.withLock {
            access = nil
            reminders.clear()
            calendars = nil
        }
        await MainActor.run {
            AppState.shared.gcalEvents = nil
            AppState.shared.gcalError = nil
        }
    }

    // MARK: - Access tokens

    /// Call with `lock` held.
    private func remember(_ body: [String: Any]) {
        guard let token = body["access_token"] as? String else { return }
        let ttl = jsonInt(body["expires_in"]) ?? 3600
        // A minute early, so a token never expires between check and use.
        access = (token, Date().addingTimeInterval(TimeInterval(max(0, ttl - 60))))
    }

    private func accessToken(_ refresh: String) async throws -> String {
        if let cached = lock.withLock({ access }), Date() < cached.until { return cached.token }
        guard let clientId = KeychainStore.shared.get("gcal-client-id"),
              let clientSecret = KeychainStore.shared.get("gcal-client-secret") else {
            throw GcalProblem.shown("Client ID or secret missing")
        }
        let (status, body) = try await post(Gcal.tokenURL, GcalOAuth.form([
            ("client_id", clientId),
            ("client_secret", clientSecret),
            ("refresh_token", refresh),
            ("grant_type", "refresh_token"),
        ]))
        guard (200..<300).contains(status) else {
            // invalid_grant: revoked, or the 7-day expiry of an OAuth app left in
            // "Testing" — either way only a new sign-in fixes it.
            if body["error"] as? String == "invalid_grant" { throw GcalProblem.shown(Gcal.expired) }
            throw GcalProblem.shown(GcalOAuth.googleError(body) ?? "Google answered \(status)")
        }
        lock.withLock { remember(body) }
        guard let token = body["access_token"] as? String else { throw GcalProblem.shown("No access token") }
        return token
    }

    // MARK: - HTTP

    private func post(_ url: String, _ form: String) async throws -> (Int, [String: Any]) {
        guard let u = URL(string: url) else { throw GcalProblem.offline }
        var req = URLRequest(url: u, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.utf8)
        return try await send(req)
    }

    private func send(_ req: URLRequest) async throws -> (Int, [String: Any]) {
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse else { throw GcalProblem.offline }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
        return (http.statusCode, json)
    }

    /// GET with the cached access token, retrying once with a fresh one when it
    /// turns out to have been revoked.
    private func getJSON(_ refresh: String, _ url: String) async throws -> (Int, [String: Any]) {
        for _ in 0..<2 {
            let token = try await accessToken(refresh)
            guard let u = URL(string: url) else { throw GcalProblem.offline }
            var req = URLRequest(url: u, timeoutInterval: 15)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (status, json) = try await send(req)
            if status == 401 {
                lock.withLock { access = nil }
                continue
            }
            return (status, json)
        }
        throw GcalProblem.shown(Gcal.expired)
    }

    // MARK: - Polling

    /// Every calendar shown in Google Calendar — your own, shared and subscribed
    /// ones alike — not just the primary one, which is often the emptiest.
    private func calendarList(_ refresh: String) async throws -> [GcalCalendar] {
        if let cached = lock.withLock({ calendars }), Date().timeIntervalSince(cached.at) < Self.calendarsTTL {
            return cached.list
        }
        let url = "https://www.googleapis.com/calendar/v3/users/me/calendarList?minAccessRole=reader&maxResults=50"
        let (status, json) = try await getJSON(refresh, url)
        let list: [GcalCalendar]
        if status == 403 {
            // A token from before Coucou asked for the calendar list: the primary
            // calendar is all it may read until the next Connect.
            log("gcal: no calendar-list access, reading the primary calendar only")
            list = [GcalCalendar(id: "primary", name: "", color: nil, primary: true)]
        } else if !(200..<300).contains(status) {
            throw GcalProblem.shown(GcalOAuth.googleError(json) ?? "API error \(status)")
        } else {
            list = GcalCalendar.parseList(json)
        }
        lock.withLock { calendars = (list, Date()) }
        return list
    }

    func pollNow() {
        Task { await poll() }
    }

    func poll() async {
        guard KeychainStore.shared.get("gcal-refresh-token") != nil else { return }
        guard lock.withLock({ () -> Bool in
            if polling { pollAgain = true; return false }
            polling = true
            return true
        }) else { return }
        repeat {
            await pollOnce()
        } while lock.withLock({ () -> Bool in
            let again = pollAgain
            pollAgain = false
            if !again { polling = false }
            return again
        })
    }

    private func pollOnce() async {
        guard let refresh = KeychainStore.shared.get("gcal-refresh-token") else { return }
        do {
            let list = try await calendarList(refresh)

            let now = RFC3339.now()
            let query = GcalOAuth.form([
                // Events ending after now: what's on right now counts.
                ("timeMin", RFC3339.utc(now)),
                ("timeMax", RFC3339.utc(now + 7 * 86_400)),
                ("singleEvents", "true"),
                ("orderBy", "startTime"),
                ("maxResults", "10"),
            ])

            var events: [GcalEvent] = []
            var readAny = false
            var firstError: String?
            // Your main calendar's default reminders; the last resort is Gcal.fallbackLead.
            var primaryDefaults: [Int] = []
            for var cal in list {
                let url = "https://www.googleapis.com/calendar/v3/calendars/\(GcalOAuth.pct(cal.id))/events?\(query)"
                let (status, json) = try await getJSON(refresh, url)
                guard (200..<300).contains(status) else {
                    // One unreadable calendar (an import gone stale) shouldn't hide
                    // the others. Typically "Google Calendar API has not been used…".
                    log("gcal: calendar HTTP \(status)")
                    if firstError == nil { firstError = GcalOAuth.googleError(json) ?? "API error \(status)" }
                    continue
                }
                readAny = true
                var defaults = reminderMinutes(json["defaultReminders"])
                if cal.primary { primaryDefaults = defaults }
                if defaults.isEmpty { defaults = primaryDefaults.isEmpty ? [Gcal.fallbackLead] : primaryDefaults }
                // The events response knows the calendar's real name even when
                // the list was a fallback.
                if cal.name.isEmpty { cal.name = json["summary"] as? String ?? "" }
                events += (json["items"] as? [Any] ?? []).compactMap {
                    GcalEvent.parse($0, calendar: cal, defaults: defaults)
                }
            }
            if !readAny, let firstError { throw GcalProblem.shown(firstError) }

            let merged = GcalEvent.merge(events)
            let reminder = lock.withLock { reminders.next(merged, now: now) }
            let shown = Array(merged.prefix(8))
            await MainActor.run {
                let state = AppState.shared
                // Disconnected while this poll was out: don't bring the card back.
                guard KeychainStore.shared.get("gcal-refresh-token") != nil else { return }
                state.gcalError = nil
                state.gcalEvents = shown
                if let reminder {
                    state.announce(reminder.news, for: "integration_gcal", reminder: reminder.event)
                }
            }
        } catch GcalProblem.shown(let message) {
            await MainActor.run {
                guard KeychainStore.shared.get("gcal-refresh-token") != nil else { return }
                AppState.shared.gcalError = message
            }
        } catch {
            // Offline: say nothing, try again next poll.
        }
    }

    private func log(_ message: String) {
        appendAppLog("integrations.log", message)
    }
}
