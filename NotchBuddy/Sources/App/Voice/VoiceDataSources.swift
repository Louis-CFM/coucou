#if !APPSTORE
import AppKit
import Contacts

// MARK: - LiveVoiceInfo
//
// Mac side of VoiceQuery: reads what the pollers already keep in AppState and turns it
// into a VoiceSnapshot for VoiceAnswer. Network only to services the user configured:
//   • Stripe (their key) for today's total, only when asked;
//   • Open-Meteo for the weather, only when the user turned it on and set a city.
// Mail: opens a compose window (mailto: or Mail's share sheet). It never sends — the
// user clicks Send (CLAUDE.md).

@MainActor
final class LiveVoiceInfo: VoiceInfoProviding {
    static let shared = LiveVoiceInfo()

    // MARK: Questions

    func answer(_ topic: VoiceTopic, locale: Locale?) async -> String {
        let fr = Self.isFrench(locale)
        let snap = await snapshot(for: topic, french: fr)
        return VoiceAnswer.text(topic, snap, french: fr)
    }

    static func isFrench(_ locale: Locale?) -> Bool {
        (locale ?? Locale.current).language.languageCode?.identifier == "fr"
    }

    private func snapshot(for topic: VoiceTopic, french fr: Bool) async -> VoiceSnapshot {
        let app = AppState.shared
        var s = VoiceSnapshot()
        func key(_ k: String) -> Bool { KeychainStore.shared.get(k) != nil }

        switch topic {
        case .stripe:
            guard key("stripe-api-key") else { s.configured = false; break }
            let cur = app.stripeCurrency
            var st = VoiceSnapshot.Stripe(balance: Self.money(app.stripeBalance, cur, fr: fr))
            st.last = app.stripePayments.prefix(3).map {
                .init(amount: Self.money($0.amount, $0.currency, fr: fr), description: $0.description,
                      ago: Self.ago($0.createdAt, fr: fr), succeeded: $0.isSuccess)
            }
            if let today = await StripeToday.fetch() {
                st.today = Self.money(today.cents, today.currency ?? cur, fr: fr)
                st.todayCount = today.count
            }
            s.stripe = st

        case .github:
            guard key("github-token") else { s.configured = false; break }
            var g = VoiceSnapshot.GitHub(stars: app.githubStats?.totalStars, repos: app.githubStats?.totalRepos)
            if let p = app.githubPulse {
                g.myPRs = p.myPRs.map { .init(title: $0.title, repo: $0.repo,
                                              ci: String(describing: $0.ci), review: String(describing: $0.review)) }
                g.toReview = p.toReview.count
                g.failingRepos = p.mainCI.filter { $0.ci == .failure }.map(\.repo)
            }
            s.github = g

        case .vercel:
            guard key("vercel-token") else { s.configured = false; break }
            s.deploys = app.vercelDeployments.map {
                .init(project: $0.projectName, state: $0.state, ago: Self.ago($0.createdAt, fr: fr), commit: $0.commitMessage)
            }

        case .resend:
            guard key("resend-api-key") else { s.configured = false; break }
            s.emailsTotal = app.resendTotal
            s.emails = app.resendEmails.map { (to: $0.recipientShort, subject: $0.subject, state: $0.lastEvent) }

        case .n8n:
            guard key("n8n-api-key") else { s.configured = false; break }
            s.runs = app.n8nRuns.map { (workflow: $0.workflow, ok: $0.success, ago: Self.ago($0.date, fr: fr)) }

        case .notion:
            guard key("notion-api-key") else { s.configured = false; break }
            s.pages = app.notionPages.map { (title: $0.title, ago: Self.ago($0.lastEditedAt, fr: fr)) }

        case .calcom:
            guard key("calcom-api-key") else { s.configured = false; break }
            let now = Date()
            s.bookings = app.calcomBookings
                .filter { $0.isActive && $0.endTime > now }
                .sorted { $0.startTime < $1.startTime }
                .map { .init(title: $0.title, when: Self.when($0.startTime, fr: fr), with: $0.attendeeName) }

        case .agents:
            s.approvalPending = app.pendingApproval?.tool
            s.sessions = app.tasks
                .filter { $0.source == .claudeCode || $0.source == .agent }
                .map { t in
                    var detail: String? = t.steps.indices.contains(t.stepIndex) ? t.steps[t.stepIndex] : t.finalLine
                    if let d = detail, d.count > 90 { detail = String(d.prefix(90)) + "…" }
                    return .init(name: t.name, state: t.state.rawValue, detail: detail)
                }

        case .claudePlan:
            s.plan = Self.plan(app.claudePlanUsage, fr: fr)

        case .codexPlan:
            s.plan = Self.plan(app.codexPlanUsage?.planUsage, fr: fr)

        case .music:
            if app.musicPlaying, let title = MusicController.shared.trackTitle {
                s.nowPlaying = (title: title, artist: MusicController.shared.artist)
            } else if SpotifyController.shared.isPlaying, let t = SpotifyController.shared.track {
                s.nowPlaying = (title: t.title, artist: Optional(t.artist))
            }

        case .pills:
            s.mainPill = PillCatalog.definition(for: app.mainPillId)?.name
            s.activePills = app.activeIntegrations.compactMap { PillCatalog.definition(for: $0)?.name }.sorted()

        case .weatherToday, .weatherTomorrow:
            guard VoiceSettings.weatherEnabled else { s.weatherOff = true; break }
            let city = VoiceSettings.weatherCity.trimmingCharacters(in: .whitespaces)
            guard !city.isEmpty else { s.weatherNoCity = true; break }
            s.weather = await WeatherSource.shared.forecast(city: city, tomorrow: topic == .weatherTomorrow, french: fr)
        }
        return s
    }

    // MARK: Formatting

    static func money(_ cents: Int, _ currency: String, fr: Bool) -> String {
        let f = NumberFormatter()
        f.numberStyle  = .currency
        f.currencyCode = currency.uppercased()
        f.locale       = Locale(identifier: fr ? "fr_FR" : "en_US")
        return f.string(from: NSNumber(value: Double(cents) / 100)) ?? "\(cents / 100) \(currency.uppercased())"
    }

    static func ago(_ date: Date, fr: Bool) -> String {
        let secs = max(60, Date().timeIntervalSince(date))
        return duration(secs, fr: fr, units: 1)
    }

    static func duration(_ secs: TimeInterval, fr: Bool, units: Int) -> String {
        let f = DateComponentsFormatter()
        f.unitsStyle = .full
        f.maximumUnitCount = units
        f.allowedUnits = [.day, .hour, .minute]
        var cal = Calendar.current
        cal.locale = Locale(identifier: fr ? "fr_FR" : "en_US")
        f.calendar = cal
        return f.string(from: secs) ?? ""
    }

    static func when(_ date: Date, fr: Bool) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: fr ? "fr_FR" : "en_US")
        f.doesRelativeDateFormatting = true
        f.dateStyle = .medium
        f.timeStyle = .short
        return f.string(from: date)
    }

    static func plan(_ u: PlanUsage?, fr: Bool) -> VoiceSnapshot.Plan? {
        guard let u else { return nil }
        let reset = [u.fiveHour?.resetsAt, u.sevenDay?.resetsAt].compactMap { $0 }.filter { $0 > Date() }.min()
        return .init(fiveHourPct: u.fiveHour.map { Int($0.usedPct.rounded()) },
                     sevenDayPct: u.sevenDay.map { Int($0.usedPct.rounded()) },
                     resetsIn: reset.map { duration($0.timeIntervalSinceNow, fr: fr, units: 2) })
    }

    // MARK: Guided email — the island's mail card, sent only on the user's click

    func resolveEmail(_ recipient: String) async -> String? {
        if let e = VoiceQuery.spokenEmail(recipient) { return e }
        return await ContactLookup.email(for: recipient)
    }

    func findFile(_ name: String, folder: VoiceQuery.MailRequest.Folder?) -> URL? {
        FileLookup.find(name, in: folder)
    }

    func draftBody(to recipient: String, about instruction: String) async -> String? {
        await VoiceBrain.draftMail(to: recipient, about: instruction)
    }

    func showMailCard(to address: String, subject: String, body: String, file: URL?) {
        let app = AppState.shared
        app.voiceMailDraft = VoiceMailDraft(to: address, subject: subject, body: body)
        app.droppedFile = file.map { DroppedFile(url: $0, name: $0.lastPathComponent) }
        NotificationCenter.default.post(name: .voiceShowMailCard, object: nil)
    }

    // MARK: Web search (opt-in, the user's Anthropic key)

    var webSearchEnabled: Bool { VoiceSettings.webSearchEnabled }
    var hasWebKey: Bool { !(ClaudeService.shared.apiKey ?? "").isEmpty }

    func webAnswer(_ question: String, history: [VoiceWebTurn], french: Bool) async -> String? {
        await ClaudeService.shared.voiceAnswer(question, history: history, french: french)
    }

    // MARK: Apps

    func openApp(_ name: String, locale: Locale?) -> VoiceActionResult {
        let fr = Self.isFrench(locale)
        guard let url = AppLookup.find(name) else {
            return .init(outcome: .failure,
                         message: fr ? "Je ne trouve pas l'app \(name)." : "I can't find the app \(name).")
        }
        NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        let shown = url.deletingPathExtension().lastPathComponent
        return .init(outcome: .success, message: fr ? "J'ouvre \(shown)." : "Opening \(shown).")
    }
}

// MARK: - Stripe: today's total (asked on demand, same key as StripePoller)

enum StripeToday {
    struct Total { var cents: Int; var count: Int; var currency: String? }

    static func fetch() async -> Total? {
        guard let key = KeychainStore.shared.get("stripe-api-key") else { return nil }
        let midnight = Calendar.current.startOfDay(for: Date())
        var comps = URLComponents(string: "https://api.stripe.com/v1/charges")!
        comps.queryItems = [URLQueryItem(name: "created[gte]", value: String(Int(midnight.timeIntervalSince1970))),
                            URLQueryItem(name: "limit", value: "100")]
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 6)
        req.setValue("Basic \(Data("\(key):".utf8).base64EncodedString())", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = json["data"] as? [[String: Any]] else { return nil }
        var total = Total(cents: 0, count: 0, currency: nil)
        for c in items where (c["status"] as? String) == "succeeded" && (c["paid"] as? Bool ?? true) {
            let amount   = c["amount"] as? Int ?? 0
            let refunded = c["amount_refunded"] as? Int ?? 0
            total.cents += amount - refunded
            total.count += 1
            if total.currency == nil { total.currency = c["currency"] as? String }
        }
        return total
    }
}

// MARK: - Weather (Open-Meteo, opt-in, 15 min cache)

@MainActor
final class WeatherSource {
    static let shared = WeatherSource()
    private var place: (query: String, name: String, lat: Double, lon: Double)?
    private var cache: (key: String, at: Date, json: [String: Any])?

    func forecast(city: String, tomorrow: Bool, french fr: Bool) async -> VoiceSnapshot.Weather? {
        guard let p = await geocode(city, fr: fr) else { return nil }
        let key = "\(p.lat),\(p.lon)"
        var json: [String: Any]
        if let c = cache, c.key == key, Date().timeIntervalSince(c.at) < 900 {
            json = c.json
        } else {
            var comps = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
            comps.queryItems = [
                .init(name: "latitude", value: String(p.lat)), .init(name: "longitude", value: String(p.lon)),
                .init(name: "current", value: "temperature_2m,weather_code,wind_speed_10m"),
                .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
                .init(name: "timezone", value: "auto"), .init(name: "forecast_days", value: "2"),
            ]
            guard let url = comps.url,
                  let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
                  let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            json = j
            cache = (key, Date(), j)
        }
        guard let daily = json["daily"] as? [String: Any] else { return nil }
        let i = tomorrow ? 1 : 0
        func num(_ k: String) -> Double? {
            guard let arr = daily[k] as? [Any], arr.indices.contains(i) else { return nil }
            if let d = arr[i] as? Double { return d }
            if let n = arr[i] as? Int { return Double(n) }
            return nil
        }
        func int(_ k: String) -> Int? { num(k).map { Int($0.rounded()) } }
        let current = json["current"] as? [String: Any]
        let currentCode: Int? = (current?["weather_code"] as? Int) ?? (current?["weather_code"] as? Double).map { Int($0) }
        let code = tomorrow ? (int("weather_code") ?? 0) : (currentCode ?? int("weather_code") ?? 0)
        return .init(city: p.name,
                     nowTemp: tomorrow ? nil : (current?["temperature_2m"] as? Double).map { Int($0.rounded()) },
                     code: code,
                     min: Int((num("temperature_2m_min") ?? 0).rounded()),
                     max: Int((num("temperature_2m_max") ?? 0).rounded()),
                     rainChance: int("precipitation_probability_max"),
                     wind: (current?["wind_speed_10m"] as? Double).map { Int($0.rounded()) })
    }

    private func geocode(_ city: String, fr: Bool) async -> (name: String, lat: Double, lon: Double)? {
        if let p = place, p.query == city { return (p.name, p.lat, p.lon) }
        var comps = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        comps.queryItems = [.init(name: "name", value: city), .init(name: "count", value: "1"),
                            .init(name: "language", value: fr ? "fr" : "en")]
        guard let url = comps.url,
              let (data, _) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 6)),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let first = (json["results"] as? [[String: Any]])?.first,
              let lat = first["latitude"] as? Double, let lon = first["longitude"] as? Double else { return nil }
        let name = first["name"] as? String ?? city
        place = (city, name, lat, lon)
        return (name, lat, lon)
    }
}

// MARK: - Contacts (asked the first time a mail is prepared)

enum ContactLookup {
    static func email(for name: String) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.contains("@") { return trimmed.replacingOccurrences(of: " ", with: "") }
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> String? in
            let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey,
                        CNContactEmailAddressesKey] as [CNKeyDescriptor]
            // The whole name first, then its parts: "il s'appelle Enzo" must find Enzo.
            let store = CNContactStore()
            for candidate in VoiceQuery.contactCandidates(trimmed) {
                let pred = CNContact.predicateForContacts(matchingName: candidate)
                let found = (try? store.unifiedContacts(matching: pred, keysToFetch: keys)) ?? []
                if let email = found.lazy.compactMap({ $0.emailAddresses.first?.value as String? }).first {
                    return email
                }
            }
            return nil
        }.value
    }
}

// MARK: - Files: Downloads / Desktop / Documents only

enum FileLookup {
    static func find(_ query: String, in folder: VoiceQuery.MailRequest.Folder?) -> URL? {
        let fm = FileManager.default
        let dirs: [FileManager.SearchPathDirectory]
        switch folder {
        case .downloads: dirs = [.downloadsDirectory]
        case .desktop:   dirs = [.desktopDirectory]
        case .documents: dirs = [.documentDirectory]
        case .pictures:  dirs = [.picturesDirectory]
        case nil:        dirs = [.downloadsDirectory, .desktopDirectory, .documentDirectory, .picturesDirectory]
        }
        let wanted = IntentParser.normalise(query).split(separator: " ").map(String.init)
        guard !wanted.isEmpty else { return nil }
        var best: (url: URL, date: Date)?
        for d in dirs {
            guard let root = fm.urls(for: d, in: .userDomainMask).first,
                  let e = fm.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                        options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { continue }
            for case let url as URL in e {
                if e.level > 2 { e.skipDescendants(); continue }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
                // "Goku.png" normalises to "gokupng": compare with the full file name too.
                let name = IntentParser.normalise(url.lastPathComponent)
                let ext  = url.pathExtension.lowercased()
                let ok = wanted.allSatisfy { w in name.contains(w) || ext == w }
                guard ok else { continue }
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                if best == nil || date > best!.date { best = (url, date) }
            }
        }
        return best?.url
    }
}

// MARK: - Apps

enum AppLookup {
    static func find(_ name: String) -> URL? {
        let wanted = IntentParser.normalise(name)
        guard !wanted.isEmpty else { return nil }
        let fm = FileManager.default
        let roots = ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var apps: [(norm: String, url: URL)] = []
        for r in roots {
            for item in (try? fm.contentsOfDirectory(atPath: r)) ?? [] where item.hasSuffix(".app") {
                let url = URL(fileURLWithPath: r).appendingPathComponent(item)
                apps.append((IntentParser.normalise(String(item.dropLast(4))), url))
            }
        }
        return apps.first(where: { $0.norm == wanted })?.url
            ?? apps.first(where: { $0.norm.hasPrefix(wanted) })?.url
            ?? apps.first(where: { $0.norm.contains(wanted) })?.url
    }
}
#endif
