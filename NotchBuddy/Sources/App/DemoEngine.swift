import Foundation
import SwiftUI
import Combine

// MARK: - DemoEngine
// Scripted ~60 s tour of Coucou for App Store review.
// Zero network calls, nothing written to disk or Keychain.

@MainActor
final class DemoEngine: ObservableObject {

    static let shared = DemoEngine()
    private init() {}

    // MARK: Published state

    @Published var isActive: Bool = false

    // Checked from background threads (pollers). Written only from @MainActor.
    nonisolated(unsafe) private(set) static var isPollerPaused: Bool = false

    // MARK: Private state

    private var demoTask: Task<Void, Never>? = nil
    private var modeCancellable: AnyCancellable? = nil

    private var visibilityContinuation: CheckedContinuation<Void, Never>? = nil
    private var approvalContinuation: CheckedContinuation<String, Never>? = nil
    private var questionContinuation: CheckedContinuation<Void, Never>? = nil

    private var generation: Int = 0                   // incremented on each start() to orphan stale closures
    private var demoInjectedTaskIds: [String] = []   // integration task IDs added by demo
    private var realTaskIdsAtStart: Set<String> = [] // real task IDs that existed before demo
    private var demoCycleIndex: Int = 0
    private let rotatingIntegrationIds = [
        "integration_stripe", "integration_calcom",
        "integration_n8n", "integration_notion", "integration_vercel"
    ]
    private var demoDiffIds: [String: [Int]] = [:]   // [pillId: [diffId]]
    private var lastApprovalDecision: String = "allow"
    private var lastQuestionAnswer: String? = nil

    // MARK: Snapshot

    private struct Snapshot {
        var tasks: [AgentTask]
        var focusId: String?
        var chatHistory: [ChatMessage]
        var stateOverride: BotState?
        var isPinned: Bool
        var noteMessage: String?
        // Integration data
        var vercelDeployments: [VercelDeployment]
        var resendEmails: [ResendEmail]
        var resendTotal: Int?
        var githubPulse: GitHubPulse?
        var githubActivity: GitHubActivity?
        var githubStats: GitHubStats?
        var stripePayments: [StripePayment]
        var stripeBalance: Int
        var stripeDisplayBalance: Int
        var stripeCurrency: String
        var stripeLoaded: Bool
        var stripeError: String?
        var calcomBookings: [CalcomBooking]
        var calcomLoaded: Bool
        var n8nRuns: [N8nRun]
        var notionPages: [NotionPage]
        var notionLoaded: Bool
        // NOTE: pendingApproval and pendingQuestion are intentionally NOT snapshotted.
        // HookServer's file descriptors are authoritative for real requests.
        var mode: IslandMode
        var view: IslandView
    }

    private var snapshot: Snapshot? = nil

    // MARK: Start

    func start() {
        guard !isActive else { return }
        isActive = true
        DemoEngine.isPollerPaused = true
        generation += 1
        demoCycleIndex = 0

        let s = AppState.shared

        // Record which tasks are real (not demo-injected) before demo starts
        realTaskIdsAtStart = Set(s.tasks.map { $0.id })

        snapshot = Snapshot(
            tasks:               s.tasks,
            focusId:             s.focusId,
            chatHistory:         s.chatHistory,
            stateOverride:       s.stateOverride,
            isPinned:            s.isPinned,
            noteMessage:         s.noteMessage,
            vercelDeployments:   s.vercelDeployments,
            resendEmails:        s.resendEmails,
            resendTotal:         s.resendTotal,
            githubPulse:         s.githubPulse,
            githubActivity:      s.githubActivity,
            githubStats:         s.githubStats,
            stripePayments:      s.stripePayments,
            stripeBalance:       s.stripeBalance,
            stripeDisplayBalance: s.stripeDisplayBalance,
            stripeCurrency:      s.stripeCurrency,
            stripeLoaded:        s.stripeLoaded,
            stripeError:         s.stripeError,
            calcomBookings:      s.calcomBookings,
            calcomLoaded:        s.calcomLoaded,
            n8nRuns:             s.n8nRuns,
            notionPages:         s.notionPages,
            notionLoaded:        s.notionLoaded,
            mode:                s.mode,
            view:                s.view
        )

        // Hide all real pills — show only main during demo (integration + Codex added progressively).
        let mainTask = s.tasks.first(where: { $0.id == s.mainPillId })
        s.tasks = mainTask.map { [$0] } ?? []

        // Weekly recap: available immediately so the reviewer can share it
        RecapStore.shared.demoSummaryOverride = demoWeeklySummary()

        // Plan usage override (in-memory, never persisted)
        #if !APPSTORE
        let now = Date()
        s.demoPlanUsageOverride = PlanUsage(
            fiveHour: PlanWindow(usedPct: 42.0, resetsAt: now.addingTimeInterval(4 * 3600)),
            sevenDay: PlanWindow(usedPct: 37.0, resetsAt: now.addingTimeInterval(3 * 24 * 3600)),
            updatedAt: now
        )
        #endif

        // Inject integration data (no activeIntegrations setter, no UserDefaults write)
        injectIntegrationData()

        // Observe mode changes to unblock waitUntilVisible()
        modeCancellable = s.$mode
            .dropFirst()
            .sink { [weak self] mode in
                MainActor.assumeIsolated {
                    if mode != .hidden, let cont = self?.visibilityContinuation {
                        self?.visibilityContinuation = nil
                        cont.resume()
                    }
                }
            }

        // Open island immediately on the demo session
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.overview)

        let gen = generation
        demoTask = Task { @MainActor [weak self] in
            await self?.runDemoLoop(gen: gen)
        }
    }

    // MARK: Stop

    func stop() {
        guard isActive else { return }
        isActive = false
        DemoEngine.isPollerPaused = false
        GithubPoller.shared.triggerPulseNow()

        demoTask?.cancel()
        demoTask = nil
        modeCancellable = nil

        // Unblock any waiting continuations so the loop exits cleanly
        let vc = visibilityContinuation; visibilityContinuation = nil; vc?.resume()
        let ac = approvalContinuation;   approvalContinuation  = nil; ac?.resume(returning: "allow")
        let qc = questionContinuation;   questionContinuation  = nil; qc?.resume()

        // Clear demo overrides
        RecapStore.shared.demoSummaryOverride = nil
        #if !APPSTORE
        AppState.shared.demoPlanUsageOverride = nil
        #endif

        let s = AppState.shared

        // Clear demo approval card (never real — real cards have a fd in HookServer)
        if s.pendingApproval?.sessionId == "demo_session" {
            s.pendingApproval = nil
        }
        // Clear demo question (real questions always have pendingQuestionFD >= 0)
        if !HookServer.shared.hasRealPendingQuestion {
            s.pendingQuestion = nil
        }
        // Only restore isPinned if no real request is now pending
        if s.pendingApproval == nil && s.pendingQuestion == nil {
            s.isPinned = snapshot?.isPinned ?? false
        }

        guard let snap = snapshot else { return }
        snapshot = nil

        // Restore AppState (NOT pendingApproval, NOT pendingQuestion — HookServer owns those)
        s.chatHistory   = snap.chatHistory
        s.stateOverride = snap.stateOverride
        s.noteMessage   = snap.noteMessage

        // Restore integration data
        s.vercelDeployments    = snap.vercelDeployments
        s.resendEmails         = snap.resendEmails
        s.resendTotal          = snap.resendTotal
        s.githubPulse          = snap.githubPulse
        s.githubActivity       = snap.githubActivity
        s.githubStats          = snap.githubStats
        s.stripePayments       = snap.stripePayments
        s.stripeBalance        = snap.stripeBalance
        s.stripeDisplayBalance = snap.stripeDisplayBalance
        s.stripeCurrency       = snap.stripeCurrency
        s.stripeLoaded         = snap.stripeLoaded
        s.stripeError          = snap.stripeError
        s.calcomBookings       = snap.calcomBookings
        s.calcomLoaded         = snap.calcomLoaded
        s.n8nRuns              = snap.n8nRuns
        s.notionPages          = snap.notionPages
        s.notionLoaded         = snap.notionLoaded

        // Restore tasks: keep real tasks that arrived during the demo, discard demo-only ones.
        // For tasks that existed before the demo (realTaskIdsAtStart), use the CURRENT version
        // from AppState (real Claude Code events may have updated them during demo).
        let demoIds: Set<String> = Set(demoInjectedTaskIds + ["demo_codex"])
        let currentTasksById = Dictionary(uniqueKeysWithValues: s.tasks.map { ($0.id, $0) })
        let realNewTasks = s.tasks.filter { task in
            !snap.tasks.contains(where: { $0.id == task.id }) && !demoIds.contains(task.id)
        }
        let mainPillId = s.mainPillId
        let restoredSnapTasks = snap.tasks.map { snapTask -> AgentTask in
            // Main pill: always restore from snapshot — demo may have left steps/finalLine mid-cycle.
            if snapTask.id == mainPillId { return snapTask }
            // Other real tasks: keep current (may have received real hook events during demo).
            if realTaskIdsAtStart.contains(snapTask.id), !demoIds.contains(snapTask.id),
               let current = currentTasksById[snapTask.id] {
                return current
            }
            return snapTask
        }
        s.tasks = restoredSnapTasks + realNewTasks

        // Remove only demo diffs; leave real diffs untouched
        for (pillId, ids) in demoDiffIds {
            for id in ids {
                s.sessionDiffs[pillId]?.removeAll { $0.id == id }
            }
            if s.sessionDiffs[pillId]?.isEmpty == true {
                s.sessionDiffs.removeValue(forKey: pillId)
            }
        }
        demoDiffIds = [:]
        demoInjectedTaskIds = []
        realTaskIdsAtStart = []
        demoCycleIndex = 0
        lastApprovalDecision = "allow"
        lastQuestionAnswer = nil

        // Restore focus
        let fid = snap.focusId ?? s.mainPillId
        s.focusId = s.tasks.contains(where: { $0.id == fid }) ? fid : s.mainPillId

        // Restore view/mode only when no real request is pinned
        if s.pendingApproval == nil && s.pendingQuestion == nil {
            s.mode = snap.mode
            s.view = snap.view
        }

        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    // MARK: Integration data injection (no UserDefaults writes)

    private func injectIntegrationData() {
        let s = AppState.shared
        let now = Date()

        // GitHub
        s.githubStats = GitHubStats(totalRepos: 34, totalStars: 127)
        s.githubPulse = GitHubPulse(
            login: "demo-user",
            myPRs: [
                GitHubPR(id: "my-app/auth#42", title: "feat: OAuth2 PKCE flow",
                         url: "https://github.com/demo/my-app/pull/42",
                         repo: "my-app", number: 42, isDraft: false, ci: .success, review: .approved),
                GitHubPR(id: "my-app/api#38", title: "fix: rate limit headers",
                         url: "https://github.com/demo/my-app/pull/38",
                         repo: "my-app", number: 38, isDraft: false, ci: .pending, review: .pending),
            ],
            toReview: [
                GitHubPR(id: "my-app/ui#21", title: "refactor: design system tokens",
                         url: "https://github.com/demo/my-app/pull/21",
                         repo: "my-app", number: 21, isDraft: false, ci: .success, review: .pending),
            ],
            mainCI: [
                GitHubRepoCI(repo: "my-app", url: "https://github.com/demo/my-app/actions",
                             branch: "main", ci: .success),
            ],
            fetchedAt: now
        )
        s.githubActivity = nil

        // Stripe
        s.stripeCurrency       = "eur"
        s.stripeBalance        = 124750
        s.stripeDisplayBalance = 124750
        s.stripeLoaded         = true
        s.stripeError          = nil
        s.stripePayments = [
            StripePayment(id: "py_demo1", amount: 4900, currency: "eur",
                          description: "Pro plan — monthly",
                          createdAt: now.addingTimeInterval(-3600), status: "succeeded"),
            StripePayment(id: "py_demo2", amount: 9900, currency: "eur",
                          description: "Pro plan — annual",
                          createdAt: now.addingTimeInterval(-7200), status: "succeeded"),
            StripePayment(id: "py_demo3", amount: 2900, currency: "eur",
                          description: "Starter plan",
                          createdAt: now.addingTimeInterval(-14400), status: "succeeded"),
        ]

        // Vercel
        s.vercelDeployments = [
            VercelDeployment(id: "dpl_demo1", projectName: "my-app",
                             url: "my-app-abc123.vercel.app", state: "READY",
                             createdAt: now.addingTimeInterval(-1800),
                             commitMessage: "feat: auth refactor", branch: "main"),
            VercelDeployment(id: "dpl_demo2", projectName: "my-app",
                             url: "my-app-prev.vercel.app", state: "READY",
                             createdAt: now.addingTimeInterval(-86400),
                             commitMessage: "fix: mobile nav", branch: "main"),
        ]

        // Resend
        s.resendTotal = 1284
        s.resendEmails = [
            ResendEmail(id: "re_demo1", to: ["alice@example.com"], subject: "Welcome to my-app",
                        createdAt: now.addingTimeInterval(-600), lastEvent: "delivered"),
            ResendEmail(id: "re_demo2", to: ["bob@example.com"], subject: "Your weekly digest",
                        createdAt: now.addingTimeInterval(-3600), lastEvent: "opened"),
        ]

        // Cal.com
        let cal = Calendar.current
        let tomorrow = cal.date(byAdding: .day, value: 1, to: now)!
        let tomorrowMorning = cal.date(bySettingHour: 10, minute: 0, second: 0, of: tomorrow)!
        let tomorrowNoon    = cal.date(bySettingHour: 14, minute: 30, second: 0, of: tomorrow)!
        s.calcomBookings = [
            CalcomBooking(id: 1001, title: "Product demo call",
                          startTime: tomorrowMorning,
                          endTime: tomorrowMorning.addingTimeInterval(3600),
                          status: "ACCEPTED",
                          attendeeName: "Alice Martin",
                          attendeeEmail: "alice@example.com",
                          attendeeNotes: "Interested in the Pro plan"),
            CalcomBooking(id: 1002, title: "Onboarding call",
                          startTime: tomorrowNoon,
                          endTime: tomorrowNoon.addingTimeInterval(1800),
                          status: "ACCEPTED",
                          attendeeName: "Bob Chen",
                          attendeeEmail: "bob@example.com",
                          attendeeNotes: nil),
        ]
        s.calcomLoaded = true

        // n8n
        s.n8nRuns = [
            N8nRun(workflow: "Notify on new Stripe payment", detail: "3 payments processed",
                   success: true, date: now.addingTimeInterval(-300)),
        ]

        // Notion
        s.notionPages = [
            NotionPage(id: "notion_demo1", title: "Product Roadmap Q4",
                       emoji: "🗺️", lastEditedAt: now.addingTimeInterval(-1800),
                       url: "https://notion.so/demo/roadmap"),
            NotionPage(id: "notion_demo2", title: "Auth Refactor Notes",
                       emoji: "🔐", lastEditedAt: now.addingTimeInterval(-7200),
                       url: "https://notion.so/demo/auth-notes"),
        ]
        s.notionLoaded = true

        // Inject GitHub pill only — rotating 4th integration added per cycle.
        var injected: [String] = []
        let githubId = "integration_github"
        if !s.tasks.contains(where: { $0.id == githubId }),
           let def = PillCatalog.available.first(where: { $0.id == githubId }) {
            s.tasks.append(AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: .idle, steps: [], source: def.source, isIntegration: true))
            injected.append(githubId)
        }
        demoInjectedTaskIds = injected
        s.syncMode()
    }

    // MARK: Demo loop

    private func runDemoLoop(gen: Int) async {
        while !Task.isCancelled {
            guard self.generation == gen else { return }
            await runOneDemoCycle(gen: gen)
            guard !Task.isCancelled, isActive, self.generation == gen else { break }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func runOneDemoCycle(gen: Int) async {
        guard isActive else { return }
        let s = AppState.shared
        let mainPillId = s.mainPillId

        // Inject the rotating 4th integration pill for this cycle.
        let rotId = rotatingIntegrationIds[demoCycleIndex % rotatingIntegrationIds.count]
        if !s.tasks.contains(where: { $0.id == rotId }),
           let def = PillCatalog.available.first(where: { $0.id == rotId }) {
            let rotState: BotState = (rotId == "integration_n8n") ? .finished : .idle
            let rotSteps: [String] = (rotId == "integration_n8n")
                ? ["Notify on new Stripe payment", "3 nodes executed", "Workflow success"]
                : []
            s.tasks.append(AgentTask(id: def.id, name: def.name, color: def.color,
                                     state: rotState, steps: rotSteps, source: def.source, isIntegration: true))
            if !demoInjectedTaskIds.contains(rotId) { demoInjectedTaskIds.append(rotId) }
        }
        s.syncMode()

        // ── Step 1: Start VS Code session ────────────────────────────────────────
        await waitUntilVisible()
        guard isActive, self.generation == gen else { return }

        s.focusId = mainPillId
        if let idx = s.tasks.firstIndex(where: { $0.id == mainPillId }) {
            s.tasks[idx].state     = .working
            s.tasks[idx].steps     = []
            s.tasks[idx].stepIndex = 0
            s.tasks[idx].finalLine = nil
        }

        // ── Step 2: Session steps with diff ─────────────────────────────────────
        let oldCode = """
        const handleSubmit = async (e) => {
          e.preventDefault()
          setLoading(true)
          const result = await signIn(email, password)
          router.push('/dashboard')
          setLoading(false)
        }
        """
        let newCode = """
        const handleSubmit = useCallback(async (e: FormEvent) => {
          e.preventDefault()
          setLoading(true)
          try {
            const result = await signIn(email, password)
            if (result.error) throw new Error(result.error)
            router.push('/dashboard')
          } catch (err) {
            setError((err as Error).message)
          } finally {
            setLoading(false)
          }
        }, [email, password, router])
        """
        let diff = DiffEngine.fromEdit(old: oldCode, new: newCode, path: "components/LoginForm.tsx")

        let plainSteps = ["Reading auth/middleware.ts", "Running npm test — 23 tests"]
        // Step 0
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        if let idx = s.tasks.firstIndex(where: { $0.id == mainPillId }) {
            s.tasks[idx].steps.append(plainSteps[0])
            s.tasks[idx].stepIndex = 0
        }
        await sleep(2.0); guard isActive, self.generation == gen else { return }

        // Diff step (index 1)
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        let diffId = s.appendSessionDiff(diff, for: mainPillId)
        trackDemoDiff(id: diffId, for: mainPillId)
        let diffStep = String.makeDiffStep(filename: diff.name, added: diff.added,
                                           removed: diff.removed, diffId: diffId)
        if let idx = s.tasks.firstIndex(where: { $0.id == mainPillId }) {
            s.tasks[idx].steps.append(diffStep)
            s.tasks[idx].stepIndex = 1
        }
        await sleep(2.0); guard isActive, self.generation == gen else { return }

        // Step 2
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        if let idx = s.tasks.firstIndex(where: { $0.id == mainPillId }) {
            s.tasks[idx].steps.append(plainSteps[1])
            s.tasks[idx].stepIndex = 2
        }
        await sleep(2.0); guard isActive, self.generation == gen else { return }

        // ── Step 3: Second session (Codex) ──────────────────────────────────────
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        if !s.tasks.contains(where: { $0.id == "demo_codex" }) {
            s.tasks.append(AgentTask(
                id: "demo_codex", name: "Codex", color: "#E07950", state: .working,
                steps: ["Reading src/api/routes.ts", "Editing routes.ts (+15 -3)"],
                source: .agent, isIntegration: false
            ))
            s.syncMode()
        }
        await sleep(1.5); guard isActive, self.generation == gen else { return }

        // ── Step 4: Permission request ───────────────────────────────────────────
        // Does NOT call waitUntilVisible — the hookExpand will open the island.
        // Skip if a real approval is waiting (don't overwrite HookServer's card).
        var decision = "allow"
        if !HookServer.shared.hasRealPendingApproval {
            playSound("approval")
            s.pendingApproval = ApprovalInfo(
                sessionId: "demo_session",
                tool: "Bash",
                command: "npm test",
                description: "Run the project test suite to verify the changes before finishing.",
                inputKey: #"{"command":"npm test"}"#,
                pillId: mainPillId
            )
            s.isPinned = true
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.approval)
            decision = await waitForApprovalOrTimeout(seconds: 8.0)
            guard isActive, self.generation == gen else { return }
        }

        // ── Step 5: AskUserQuestion ──────────────────────────────────────────────
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        var chosenReporter = "Verbose"
        if !HookServer.shared.hasRealPendingQuestion {
            await sleep(0.5); guard isActive, self.generation == gen else { return }
            playSound("question")
            s.pendingQuestion = AskQuestion(questions: [
                AskQuestionItem(
                    question: "Which test reporter format?",
                    header: "Reporter",
                    options: [
                        AskQuestionOption(label: "Verbose", description: "Full output for each test"),
                        AskQuestionOption(label: "Dot",     description: "Minimal one-dot-per-test"),
                        AskQuestionOption(label: "JSON",    description: "Machine-readable JSON report"),
                    ],
                    multiSelect: false
                )
            ])
            s.isPinned = true
            NotificationCenter.default.post(name: .hookExpand, object: IslandView.question)
            await waitForQuestionOrTimeout(seconds: 8.0)
            chosenReporter = lastQuestionAnswer ?? "Verbose"
            guard isActive, self.generation == gen else { return }
        }

        // ── Step 6: Finish primary session ───────────────────────────────────────
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        await sleep(0.5); guard isActive, self.generation == gen else { return }
        playSound("finish")
        if let idx = s.tasks.firstIndex(where: { $0.id == mainPillId }) {
            s.tasks[idx].state = .finished
            s.tasks[idx].finalLine = decision == "deny"
                ? "npm test skipped (denied). Staged — run tests before merge."
                : "All 23 tests pass (\(chosenReporter)). Auth refactor complete — 94 % coverage."
        }
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.finished)
        await sleep(2.5); guard isActive, self.generation == gen else { return }

        // ── Step 7: Chat ─────────────────────────────────────────────────────────
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        s.chatHistory = []
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.prompt)
        await sleep(1.0); guard isActive, self.generation == gen else { return }
        s.chatHistory.append(ChatMessage(role: .user, content: "What did you change in LoginForm?"))
        await sleep(0.4); guard isActive, self.generation == gen else { return }
        await streamChatResponse(for: "What did you change in LoginForm?", gen: gen)
        guard isActive, self.generation == gen else { return }
        await sleep(2.0); guard isActive, self.generation == gen else { return }

        // ── Step 8: Weekly recap ─────────────────────────────────────────────────
        await waitUntilVisible(); guard isActive, self.generation == gen else { return }
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.recap)
        await sleep(5.0); guard isActive, self.generation == gen else { return }

        // ── Step 9: Reset for next cycle ─────────────────────────────────────────
        s.chatHistory = []
        s.stateOverride = nil
        if let idx = s.tasks.firstIndex(where: { $0.id == mainPillId }) {
            s.tasks[idx].state     = .idle
            s.tasks[idx].steps     = []
            s.tasks[idx].stepIndex = 0
            s.tasks[idx].finalLine = nil
            s.tasks[idx].pillBadge = nil
        }
        // Remove only demo diffs for mainPill
        for id in (demoDiffIds[mainPillId] ?? []) {
            s.sessionDiffs[mainPillId]?.removeAll { $0.id == id }
        }
        if s.sessionDiffs[mainPillId]?.isEmpty == true {
            s.sessionDiffs.removeValue(forKey: mainPillId)
        }
        demoDiffIds.removeValue(forKey: mainPillId)

        s.tasks.removeAll { $0.id == "demo_codex" }
        // Remove rotating integration and advance cycle counter.
        s.tasks.removeAll { $0.id == rotId }
        demoInjectedTaskIds.removeAll { $0 == rotId }
        demoCycleIndex += 1

        if s.pendingApproval?.sessionId == "demo_session" { s.pendingApproval = nil }
        if !HookServer.shared.hasRealPendingQuestion     { s.pendingQuestion = nil }
        if s.pendingApproval == nil && s.pendingQuestion == nil { s.isPinned = false }
        s.focusId = mainPillId
        lastApprovalDecision = "allow"
        lastQuestionAnswer = nil
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    // MARK: Intercept handlers (called by HookServer)

    func handleApprovalDecision(_ decision: String) {
        lastApprovalDecision = decision
        let c = approvalContinuation
        approvalContinuation = nil
        c?.resume(returning: decision)
    }

    func handleQuestionAnswered(answers: [String: Any]) {
        lastQuestionAnswer = answers.values.first as? String
        let c = questionContinuation
        questionContinuation = nil
        c?.resume()
    }

    // MARK: Chat streaming

    /// Called by ClaudeService when the user types in chat during a demo.
    func streamChatResponse(for query: String) async {
        await streamChatResponse(for: query, gen: self.generation)
    }

    private func streamChatResponse(for query: String, gen: Int) async {
        let s = AppState.shared
        let response = """
        I refactored LoginForm.tsx to be type-safe and resilient. \
        The main change is wrapping handleSubmit in useCallback so it only recreates \
        when its dependencies change, and adding a proper try/catch/finally block so \
        loading is always reset even on error. An error state now shows the message \
        inline rather than letting the exception bubble up unhandled. \
        Coverage went from 79 % to 94 % after the test suite caught two edge \
        cases the old code missed.
        """
        let msg = ChatMessage(role: .assistant, content: "")
        let msgId = msg.id
        s.chatHistory.append(msg)
        let words = response.components(separatedBy: " ")
        var built = ""
        for word in words {
            guard isActive, !Task.isCancelled, self.generation == gen else { break }
            built += (built.isEmpty ? "" : " ") + word
            guard let idx = s.chatHistory.firstIndex(where: { $0.id == msgId }) else { break }
            s.chatHistory[idx].content = built
            try? await Task.sleep(nanoseconds: 60_000_000)
            guard isActive, !Task.isCancelled, self.generation == gen else { break }
        }
    }

    // MARK: Helpers

    private func trackDemoDiff(id: Int, for pillId: String) {
        if demoDiffIds[pillId] == nil { demoDiffIds[pillId] = [] }
        demoDiffIds[pillId]!.append(id)
    }

    private func playSound(_ name: String) {
        let s = AppState.shared
        guard s.soundEnabled, s.mode != .hidden else { return }
        SoundEngine.shared.play(name)
    }

    /// Pauses until the island is visible (not hidden), or demo is stopped.
    /// Observed via Combine publisher — no polling.
    private func waitUntilVisible() async {
        guard isActive, AppState.shared.mode == .hidden else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            visibilityContinuation = cont
        }
    }

    private func waitForApprovalOrTimeout(seconds: Double) async -> String {
        let gen = self.generation
        return await withCheckedContinuation { continuation in
            self.approvalContinuation = continuation
            let ns = UInt64(seconds * 1_000_000_000)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: ns)
                guard self.generation == gen else { return }
                guard self.isActive else { return }
                guard let c = self.approvalContinuation else { return }
                self.approvalContinuation = nil
                // Auto-dismiss: only clear if still a demo card
                let s = AppState.shared
                if s.pendingApproval?.sessionId == "demo_session" {
                    s.pendingApproval = nil
                    s.isPinned = false
                    s.view = s.tasks.isEmpty ? .empty : .overview
                }
                c.resume(returning: "allow")
            }
        }
    }

    private func waitForQuestionOrTimeout(seconds: Double) async {
        let gen = self.generation
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            self.questionContinuation = continuation
            let ns = UInt64(seconds * 1_000_000_000)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: ns)
                guard self.generation == gen else { return }
                guard self.isActive else { return }
                guard let c = self.questionContinuation else { return }
                self.questionContinuation = nil
                // Only clear if no real question is pending
                if !HookServer.shared.hasRealPendingQuestion {
                    let s = AppState.shared
                    s.pendingQuestion = nil
                    s.isPinned = false
                    s.view = s.tasks.isEmpty ? .empty : .overview
                }
                c.resume()
            }
        }
    }

    private func sleep(_ seconds: Double) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    // MARK: Demo weekly summary

    private func demoWeeklySummary() -> WeeklySummary {
        let cal = Calendar(identifier: .iso8601)
        var comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: Date())
        comps.weekday = 2
        let thisMonday = cal.date(from: comps) ?? Date()
        let lastMonday = cal.date(byAdding: .weekOfYear, value: -1, to: thisMonday) ?? Date()
        let lastSunday = cal.date(byAdding: .day, value: 6, to: lastMonday) ?? Date()
        return WeeklySummary(
            weekStart: lastMonday, weekEnd: lastSunday,
            totalMinutes: 840, sessionCount: 23,
            filesChanged: 187, linesAdded: 3412, linesRemoved: 891,
            commandsRun: 142, questionsAnswered: 31,
            permissionsAllowed: 58, permissionsDenied: 4,
            topAgent: "Claude Code", topProject: "my-app",
            busiestDay: "Wednesday", longestSessionMinutes: 94
        )
    }
}
