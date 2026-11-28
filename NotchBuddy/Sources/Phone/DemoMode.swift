import Foundation

// The demo (Settings → Try the demo, or the first screens): sample agents, services and turns,
// so the app can be seen without a Mac. Nothing is sent to iCloud, nothing is saved, nothing is
// notified: the real data waits aside and comes back when the demo ends (or the app quits).
// Allowing, denying, answering, a task or an action play out here, with Face ID as for real.

/// The real state, kept aside while the demo shows.
struct DemoStash {
    var status: PhoneLink.Status
    var firstSyncDone: Bool
    var sessions: [SessionItem]
    var services: [String: ServiceSnapshot]
    var serviceDetails: [String: ServiceDetail]
    var turns: [String: TurnSnapshot]
    var archive: TurnArchive
    var history: [DecisionLog]
    var macAgents: MacAgents?
    var taskResults: [String: TaskResult]
}

extension SessionItem {
    /// A session made here (the demo), not read from iCloud.
    init(id: String, name: String, color: String, state: BotState, stepIndex: Int = 0, steps: [String] = [],
         approvalCommand: String = "", approvalTool: String? = nil, approvalFingerprint: String = "",
         question: String = "", questionPayload: QuestionPayload? = nil, finalLine: String = "",
         cwd: String = "", updatedAt: Date = .now) {
        self.id = id
        self.name = name
        self.color = color
        self.state = state
        self.stepIndex = stepIndex
        self.steps = steps
        self.needsApproval = !approvalFingerprint.isEmpty
        self.approvalCommand = approvalCommand
        self.approvalTool = approvalTool
        self.approvalFingerprint = approvalFingerprint
        self.acceptsInstructions = true
        self.question = question
        self.questionPayload = questionPayload
        self.questionFingerprint = questionPayload?.fingerprint ?? ""
        self.finalLine = finalLine
        self.cwd = cwd
        self.updatedAt = updatedAt
        self.macName = "Demo Mac"
    }
}

@MainActor
enum Demo {
    private static let claude = "integration_claude"
    private static let codex = "agent_codex"
    private static let cursor = "agent_cursor"
    private static let gemini = "agent_gemini"
    private static let approvalFingerprint = "demo-approval-build"

    // MARK: Start, stop

    static func start(_ link: PhoneLink) {
        guard !link.isDemo else { return }
        link.demoStash = DemoStash(status: link.status, firstSyncDone: link.firstSyncDone,
                                   sessions: link.sessions, services: link.services,
                                   serviceDetails: link.serviceDetails, turns: link.turns,
                                   archive: link.archive, history: link.history,
                                   macAgents: link.macAgents, taskResults: link.taskResults)
        link.isDemo = true
        link.status = .ready
        link.firstSyncDone = true
        link.sessions = sessions()
        link.services = services()
        link.serviceDetails = [:]
        link.turns = turns()
        var archive = TurnArchive()
        archive.today = TurnArchive.DayTally(turns: 6, files: 14, added: 412, removed: 97)
        link.archive = archive
        link.history = [
            DecisionLog(decision: .allow, pillId: codex, summary: "npm test", date: minutesAgo(25)),
            DecisionLog(decision: .deny, pillId: claude, summary: "rm -rf dist", date: minutesAgo(70)),
        ]
        link.macAgents = MacAgents(agents: [.claude, .codex, .cursor],
                                   projects: [.init(name: "botan-app", path: "/Users/you/Projects/botan-app"),
                                              .init(name: "landing-page", path: "/Users/you/Projects/landing-page"),
                                              .init(name: "api", path: "/Users/you/Projects/api")],
                                   updatedAt: .now)
        link.taskResults = [:]
        Journal.shared.showDemo(journal(link))
        BotanBridge.shared.sessionsChanged()
    }

    static func stop(_ link: PhoneLink) {
        guard link.isDemo, let stash = link.demoStash else { return }
        link.isDemo = false
        link.demoStash = nil
        link.status = stash.status
        link.firstSyncDone = stash.firstSyncDone
        link.sessions = stash.sessions
        link.services = stash.services
        link.serviceDetails = stash.serviceDetails
        link.turns = stash.turns
        link.archive = stash.archive
        link.history = stash.history
        link.macAgents = stash.macAgents
        link.taskResults = stash.taskResults
        Journal.shared.showDemo(nil)
        BotanBridge.shared.sessionsChanged()
        Task { await link.refresh() }
    }

    // MARK: What you do in the demo

    static func decide(_ decision: Decision, fingerprint: String, pillId: String, summary: String,
                       link: PhoneLink) async -> Bool {
        guard let session = link.sessions.first(where: { $0.approvalFingerprint == fingerprint }) else { return false }
        link.history.insert(DecisionLog(decision: decision, pillId: pillId, summary: summary, date: .now), at: 0)
        let allowed = decision == .allow
        replace(link, SessionItem(id: session.id, name: session.name, color: session.color, state: .working,
                                  stepIndex: 2, steps: session.steps, cwd: session.cwd))
        if var turn = link.turns[session.id], let last = turn.actions.indices.last {
            if allowed {
                turn.actions[last].output = "vite v6.0.3 building for production…\n✓ 214 modules transformed.\n✓ built in 4.21s"
            } else {
                turn.actions[last].denied = true
            }
            link.turns[session.id] = turn
        }
        Journal.shared.showDemo(journal(link))
        BotanBridge.shared.sessionsChanged()
        later(link, seconds: 3) {
            finish(link, pillId: session.id, message: allowed
                   ? "Done. The Stripe page has a month picker now, and the build passes."
                   : "OK, I didn't run the build. The month picker is in place: run npm run build when you're ready.")
        }
        return true
    }

    static func answer(fingerprint: String, pillId: String, selections: [[String]], link: PhoneLink) async -> Bool {
        guard let session = link.sessions.first(where: { $0.questionFingerprint == fingerprint }) else { return false }
        let pick = selections.first?.first ?? "Redis"
        replace(link, SessionItem(id: session.id, name: session.name, color: session.color, state: .working,
                                  stepIndex: 1, steps: ["Reading the pricing API", "Adding the \(pick) cache", "Running the tests"],
                                  cwd: session.cwd))
        BotanBridge.shared.sessionsChanged()
        later(link, seconds: 4) {
            finish(link, pillId: session.id,
                   message: "The pricing API now goes through a \(pick) cache (5 minutes). Tests pass: 42 of 42.")
        }
        return true
    }

    static func instruction(_ text: String, pillId: String, link: PhoneLink) async -> Bool {
        guard let session = link.sessions.first(where: { $0.id == pillId }) else { return false }
        replace(link, SessionItem(id: session.id, name: session.name, color: session.color, state: .thinking,
                                  steps: ["Reading your message"], cwd: session.cwd))
        link.turns[pillId] = TurnSnapshot(pillId: pillId, sessionId: "demo", project: session.name, prompt: text,
                                          actions: [], files: [], finalMessage: "", startedAt: .now, endedAt: nil)
        BotanBridge.shared.sessionsChanged()
        later(link, seconds: 4) {
            finish(link, pillId: pillId, message: "Done: \(text)")
        }
        return true
    }

    static func task(_ text: String, agent: PhoneAgent, project: MacAgents.Project, link: PhoneLink) async -> String? {
        let id = UUID().uuidString
        later(link, seconds: 5) {
            link.taskResults[id] = TaskResult(id: id, agent: agent, project: project.name, ok: true,
                                              summary: "Done in \(project.name): \(text)", endedAt: .now)
        }
        return id
    }

    static func serviceDetail(_ pillId: String, period: String, link: PhoneLink) async -> Bool {
        try? await Task.sleep(for: .milliseconds(600))
        guard link.isDemo else { return false }
        link.serviceDetails[pillId] = detail(pillId, period: period, lastAction: link.serviceDetails[pillId]?.lastAction)
        return true
    }

    static func action(_ action: ServiceActionDef, pillId: String, link: PhoneLink) async -> Bool {
        try? await Task.sleep(for: .seconds(1.5))
        guard link.isDemo, var detail = link.serviceDetails[pillId] else { return false }
        detail.lastAction = ServiceActionResult(title: action.title, ok: true,
                                                message: "\(action.title): done (demo).", date: .now)
        link.serviceDetails[pillId] = detail
        return true
    }

    // MARK: Sample sessions and turns

    private static func sessions() -> [SessionItem] {
        let question = QuestionPayload(items: [.init(
            question: "Which cache should I put in front of the pricing API?",
            header: "Cache",
            options: [.init(label: "Redis", description: "Shared by every server, survives a restart"),
                      .init(label: "In memory", description: "Nothing to install, one per server")],
            multiSelect: false)])
        return [
            SessionItem(id: claude, name: "botan-app", color: "#F5F6F8", state: .approval, stepIndex: 2,
                        steps: ["Reading ServiceViews.swift", "Adding the month picker", "Building"],
                        approvalCommand: "npm run build", approvalTool: "Bash",
                        approvalFingerprint: approvalFingerprint, cwd: "/Users/you/Projects/botan-app",
                        updatedAt: minutesAgo(1)),
            SessionItem(id: codex, name: "landing-page", color: "#2DD4BF", state: .working, stepIndex: 2,
                        steps: ["Reading index.html", "Writing the hero", "Running the tests", "Checking the layout"],
                        cwd: "/Users/you/Projects/landing-page", updatedAt: minutesAgo(2)),
            SessionItem(id: cursor, name: "api", color: "#C0C4CC", state: .question,
                        question: question.items[0].question, questionPayload: question,
                        cwd: "/Users/you/Projects/api", updatedAt: minutesAgo(4)),
            SessionItem(id: gemini, name: "docs", color: "#8AB4F8", state: .finished,
                        finalLine: "README updated with the new install steps.",
                        cwd: "/Users/you/Projects/docs", updatedAt: minutesAgo(18)),
        ]
    }

    private static func turns() -> [String: TurnSnapshot] {
        let monthPicker = TurnFile(path: "/Users/you/Projects/botan-app/Sources/ServiceViews.swift", added: 6, removed: 1, isNew: false,
                                   lines: [.init(kind: .context, text: "    var body: some View {"),
                                           .init(kind: .context, text: "        VStack(spacing: 16) {"),
                                           .init(kind: .removed, text: "            header"),
                                           .init(kind: .added, text: "            header"),
                                           .init(kind: .added, text: "            if byMonth {"),
                                           .init(kind: .added, text: "                MonthPicker(month: $month)"),
                                           .init(kind: .added, text: "                    .onChange(of: month) { load($1) }"),
                                           .init(kind: .added, text: "            }"),
                                           .init(kind: .added, text: "            details"),
                                           .init(kind: .context, text: "        }")])
        let hero = TurnFile(path: "/Users/you/Projects/landing-page/src/Hero.tsx", added: 9, removed: 0, isNew: true,
                            lines: [.init(kind: .added, text: "export function Hero() {"),
                                    .init(kind: .added, text: "  return ("),
                                    .init(kind: .added, text: "    <section className=\"hero\">"),
                                    .init(kind: .added, text: "      <h1>Your agents, in your pocket</h1>"),
                                    .init(kind: .added, text: "      <p>Allow, deny and follow every run.</p>"),
                                    .init(kind: .added, text: "      <a href=\"/download\">Get Coucou</a>"),
                                    .init(kind: .added, text: "    </section>"),
                                    .init(kind: .added, text: "  )"),
                                    .init(kind: .added, text: "}")])
        let readme = TurnFile(path: "/Users/you/Projects/docs/README.md", added: 3, removed: 2, isNew: false,
                              lines: [.init(kind: .context, text: "## Install"),
                                      .init(kind: .removed, text: "Download the zip and move it to Applications."),
                                      .init(kind: .removed, text: "Open it once."),
                                      .init(kind: .added, text: "brew install --cask coucou"),
                                      .init(kind: .added, text: "coucou setup"),
                                      .init(kind: .added, text: "That's it: Mochi shows up in your notch.")])
        return [
            claude: TurnSnapshot(pillId: claude, sessionId: "demo-1", project: "botan-app",
                                 prompt: "Add a month picker to the Stripe page, then make sure the build passes.",
                                 actions: [.init(tool: "Read", summary: "Sources/ServiceViews.swift", date: minutesAgo(4)),
                                           .init(tool: "Edit", summary: "Sources/ServiceViews.swift", date: minutesAgo(3), fileIndex: 0),
                                           .init(tool: "Bash", summary: "npm run build", date: minutesAgo(1))],
                                 files: [monthPicker], finalMessage: "", startedAt: minutesAgo(5), endedAt: nil),
            codex: TurnSnapshot(pillId: codex, sessionId: "demo-2", project: "landing-page",
                                prompt: "Write the hero section of the landing page.",
                                actions: [.init(tool: "Read", summary: "index.html", date: minutesAgo(6)),
                                          .init(tool: "Write", summary: "src/Hero.tsx", date: minutesAgo(4), fileIndex: 0),
                                          .init(tool: "Bash", summary: "npm test", output: "✓ 18 tests passed", date: minutesAgo(2))],
                                files: [hero], finalMessage: "", startedAt: minutesAgo(7), endedAt: nil),
            cursor: TurnSnapshot(pillId: cursor, sessionId: "demo-3", project: "api",
                                 prompt: "Add a cache in front of the pricing API.",
                                 actions: [.init(tool: "Read", summary: "src/pricing.ts", date: minutesAgo(5)),
                                           .init(tool: "Grep", summary: "fetchPrices", date: minutesAgo(5))],
                                 files: [], finalMessage: "", startedAt: minutesAgo(6), endedAt: nil),
            gemini: TurnSnapshot(pillId: gemini, sessionId: "demo-4", project: "docs",
                                 prompt: "Update the README with the new install steps.",
                                 actions: [.init(tool: "Read", summary: "README.md", date: minutesAgo(22)),
                                           .init(tool: "Edit", summary: "README.md", date: minutesAgo(20), fileIndex: 0)],
                                 files: [readme], finalMessage: "README updated: install with Homebrew, then run coucou setup.",
                                 startedAt: minutesAgo(23), endedAt: minutesAgo(18)),
        ]
    }

    // MARK: Sample services

    private static func services() -> [String: ServiceSnapshot] {
        let stripe = ServiceSnapshot(
            pillId: "integration_stripe", tone: .ok, headline: "Balance €1,240.00", reason: "Payments are coming in.",
            sections: [ServiceSection(title: "Payments", items: [
                .init(title: "€49.00 from Ada L.", detail: "Pro plan", tone: .ok, date: minutesAgo(35)),
                .init(title: "€99.00 from Grace H.", detail: "Team plan", tone: .ok, date: minutesAgo(190)),
                .init(title: "€49.00 failed", detail: "Card declined", tone: .error, date: minutesAgo(400)),
            ])],
            updatedAt: .now, today: [DetailStat(label: "In today", value: "€148.00", tone: .ok)], months: months())
        let github = ServiceSnapshot(
            pillId: "integration_github", tone: .warning, headline: "2 pull requests", reason: "CI failing on landing-page · main",
            sections: [ServiceSection(title: "Pull requests", items: [
                .init(title: "Add the month picker", detail: "botan-app #42 · review requested", tone: .info, date: minutesAgo(50)),
                .init(title: "New hero section", detail: "landing-page #7 · checks failing", tone: .error, date: minutesAgo(80)),
            ])],
            updatedAt: .now, today: [DetailStat(label: "PRs", value: "2", tone: .info)])
        let vercel = ServiceSnapshot(
            pillId: "integration_vercel", tone: .ok, headline: "3 deploys today", reason: "Production is up.",
            sections: [ServiceSection(title: "Deployments", items: [
                .init(title: "landing-page", detail: "Production · ready", tone: .ok, date: minutesAgo(15)),
                .init(title: "docs", detail: "Preview · ready", tone: .ok, date: minutesAgo(140)),
            ])],
            updatedAt: .now, today: [DetailStat(label: "Deploys", value: "3", tone: .ok)])
        return [stripe.pillId: stripe, github.pillId: github, vercel.pillId: vercel]
    }

    /// Twelve months of sample figures, newest first.
    private static func months() -> [ServiceMonth] {
        let now = ServicePeriod.key(for: Date())
        let received = [1_480, 2_120, 1_960, 1_730, 1_610, 1_390, 1_250, 1_180, 960, 870, 720, 640]
        return received.enumerated().map { index, euros in
            ServiceMonth(month: ServicePeriod.shifted(now, by: -index), stats: [
                DetailStat(label: "Received", value: money(euros), tone: .ok),
                DetailStat(label: "Payments", value: "\(euros / 49)"),
                DetailStat(label: "Failed", value: "\(index % 3)", tone: index % 3 == 0 ? .idle : .error),
                DetailStat(label: "Paid out", value: money(euros - 120)),
            ])
        }
    }

    private static func detail(_ pillId: String, period: String, lastAction: ServiceActionResult?) -> ServiceDetail {
        switch pillId {
        case "integration_stripe":
            let month = period.isEmpty ? ServicePeriod.key(for: Date()) : period
            let stats = months().first { $0.month == month }?.stats
                ?? [DetailStat(label: "Received", value: money(0)), DetailStat(label: "Payments", value: "0")]
            let start = ServicePeriod.range(of: month)?.start ?? .now
            let isNow = month == ServicePeriod.key(for: Date())
            func day(_ n: Int) -> Date { isNow ? minutesAgo(Double(n * 60)) : start.addingTimeInterval(Double(n) * 86_400) }
            return ServiceDetail(pillId: pillId, stats: stats, sections: [
                DetailSection(title: "Payments · \(ServicePeriod.name(of: month))", items: [
                    .init(title: "€49.00", subtitle: "Ada L. · Pro plan", tone: .ok, date: day(1), badge: "Paid",
                          fields: [DetailStat(label: "Fee", value: "€1.04"), DetailStat(label: "From", value: "Payment link")]),
                    .init(title: "€99.00", subtitle: "Grace H. · Team plan", tone: .ok, date: day(3), badge: "Paid"),
                    .init(title: "€49.00", subtitle: "Card declined", tone: .error, date: day(6), badge: "Failed"),
                ]),
                DetailSection(title: "Payouts · \(ServicePeriod.name(of: month))", items: [
                    .init(title: money(860), subtitle: "To your bank", tone: .ok, date: day(4), badge: "Paid"),
                ]),
            ], fetchedAt: .now, lastAction: lastAction, period: month)
        case "integration_vercel":
            let redeploy = ServiceActionDef(kind: "vercel.redeploy", title: "Redeploy", symbol: "arrow.clockwise",
                                            target: "demo-deployment", confirm: "Redeploy landing-page to production?")
            return ServiceDetail(pillId: pillId, stats: [DetailStat(label: "Deploys today", value: "3", tone: .ok),
                                                         DetailStat(label: "Failed", value: "0")], sections: [
                DetailSection(title: "Deployments", items: [
                    .init(title: "landing-page", subtitle: "main · New hero section", tone: .ok, date: minutesAgo(15),
                          badge: "Production", actions: [redeploy]),
                    .init(title: "docs", subtitle: "readme · Install steps", tone: .ok, date: minutesAgo(140), badge: "Preview"),
                ]),
            ], fetchedAt: .now, lastAction: lastAction)
        default:
            let rerun = ServiceActionDef(kind: "github.rerun", title: "Re-run failed jobs", symbol: "arrow.triangle.2.circlepath",
                                         target: "demo/landing-page#7")
            return ServiceDetail(pillId: pillId, stats: [DetailStat(label: "Open PRs", value: "2", tone: .info),
                                                         DetailStat(label: "CI", value: "1 failing", tone: .error)], sections: [
                DetailSection(title: "Pull requests", items: [
                    .init(title: "Add the month picker", subtitle: "botan-app #42", tone: .info, date: minutesAgo(50), badge: "Review"),
                    .init(title: "New hero section", subtitle: "landing-page #7 · checks failing", tone: .error,
                          date: minutesAgo(80), badge: "Failing", actions: [rerun]),
                ]),
            ], fetchedAt: .now, lastAction: lastAction)
        }
    }

    // MARK: History

    private static func journal(_ link: PhoneLink) -> [JournalEntry] {
        var entries: [JournalEntry] = link.history.map { log in
            JournalEntry(id: "demo-decision|\(log.id)", kind: .decision, pillId: log.pillId,
                         title: log.decision == .allow ? "Allowed" : "Denied", detail: log.summary, date: log.date,
                         tone: log.decision == .allow ? .ok : .error, url: nil, themes: [.needsYou, .code])
        }
        for turn in link.turns.values where turn.endedAt != nil {
            entries.append(JournalEntry(id: "demo-turn|\(turn.pillId)|\(turn.startedAt.timeIntervalSince1970)", kind: .turn,
                                        pillId: turn.pillId, title: turn.headline, detail: turn.project,
                                        date: turn.endedAt ?? turn.startedAt, tone: .ok, url: nil, themes: [.code]))
        }
        for (pillId, snapshot) in link.services {
            for section in snapshot.sections {
                for item in section.items {
                    let themes: [JournalEntry.Theme] = pillId == "integration_stripe" ? [.money]
                        : pillId == "integration_vercel" ? [.deploys] : [.code]
                    entries.append(JournalEntry(id: "demo-service|\(pillId)|\(item.title)", kind: .service, pillId: pillId,
                                                title: item.title, detail: item.detail, date: item.date ?? .now,
                                                tone: item.tone, url: nil,
                                                themes: item.tone == .error ? themes + [.errors] : themes))
                }
            }
        }
        return entries.sorted { $0.date > $1.date }
    }

    // MARK: Helpers

    private static func replace(_ link: PhoneLink, _ session: SessionItem) {
        link.sessions.removeAll { $0.id == session.id }
        link.sessions.append(session)
        link.sessions.sort { $0.updatedAt > $1.updatedAt }
    }

    private static func finish(_ link: PhoneLink, pillId: String, message: String) {
        guard let session = link.sessions.first(where: { $0.id == pillId }) else { return }
        replace(link, SessionItem(id: session.id, name: session.name, color: session.color, state: .finished,
                                  finalLine: message, cwd: session.cwd))
        if var turn = link.turns[pillId] {
            turn.finalMessage = message
            turn.endedAt = .now
            link.turns[pillId] = turn
        }
        Journal.shared.showDemo(journal(link))
        BotanBridge.shared.sessionsChanged()
    }

    /// Runs a step of the demo a moment later, unless the demo ended meanwhile.
    private static func later(_ link: PhoneLink, seconds: Double, _ step: @escaping @MainActor @Sendable () -> Void) {
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            guard link.isDemo else { return }
            step()
        }
    }

    private static func minutesAgo(_ minutes: Double) -> Date { Date().addingTimeInterval(-minutes * 60) }

    private static func money(_ euros: Int) -> String {
        (Double(euros)).formatted(.currency(code: "EUR").locale(Locale(identifier: "en_IE")))
    }
}
