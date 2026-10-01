import SwiftUI

// MARK: - Dispatch view content by IslandView

struct IslandViewContent: View {
    let view: IslandView
    @ObservedObject var state: AppState

    var body: some View {
        switch view {
        case .overview:  OverviewView(state: state)
        case .empty:     EmptyStateView(state: state)
        case .approval:  ApprovalView(state: state)
        case .question:  QuestionView(state: state)
        case .error:     ErrorView(state: state)
        case .finished:  FinishedView(state: state)
        case .confused:  ConfusedView()
        case .upload:    UploadView(state: state)
        case .uploading: UploadingView(state: state)
        case .choose:    ChooseView(state: state)
        case .mail:      MailView(state: state)
        case .prompt:    PromptView(state: state)
        case .agentPrompt: CodexSessionComposerView(state: state)
        case .agentSession: AgentSessionView(state: state)
        case .searching: SearchingView(state: state)
        case .result:    ResultView(state: state)
        case .note:      NoteView(state: state)
        case .settings:  SettingsIslandView(state: state)
        case .greeting:  EmptyView()  // GreetingCanvasView overlaid in IslandRootView
        }
    }
}

// MARK: - Overview

struct OverviewView: View {
    @ObservedObject var state: AppState
    @State private var showingN8nDetail = false

    var agent: AgentTask? { state.focusTask }

    var body: some View {
        HStack(spacing: 10) {
            // Left card: title row + ticker below + ↗ button overlay
            ZStack(alignment: .topLeading) {
                CardBackground(wash: nil)

                // Title row + ticker stacked (or integration card)
                if let agent = agent {
                    if agent.isIntegration {
                        IntegrationCardView(task: agent, showingDetail: $showingN8nDetail)
                    } else {
                        VStack(alignment: .leading, spacing: 0) {
                            HStack(spacing: 6) {
                                Circle()
                                    .fill(Color(hex: agent.color))
                                    .frame(width: 7, height: 7)
                                Text(agent.name)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundColor(Color(hex: "#F5F6F8"))
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                    .layoutPriority(1)
                                    .help(agent.name)
                                Text(agent.source.runtimeLabel)
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#8E939C"))
                                    .lineLimit(1)
                                    .fixedSize()
                                Spacer(minLength: 2)
                                if agent.steps.count > 1 {
                                    Text("\(min(agent.stepIndex + 1, agent.steps.count))/\(agent.steps.count)")
                                        .font(.system(size: 11))
                                        .foregroundColor(Color(hex: "#6B7079"))
                                        .fixedSize()
                                }
                            }
                            .padding(.top, 6)
                            .padding(.leading, 108)
                            .padding(.trailing, 36)

                            TickerView(task: agent)
                                .frame(height: 44)
                                .padding(.top, 6)
                                .padding(.leading, 108)
                                .padding(.trailing, 12)
                        }
                        .frame(maxWidth: .infinity, alignment: .topLeading)
                        .padding(.top, 4)
                    }
                }

                // ↗ jump button — last in ZStack so it renders on top; hidden while any detail is open
                if !showingN8nDetail,
                   agent?.source != .codex,
                   agent?.id != "integration_claude" {
                    Button(action: { openAgentTarget(agent) }) {
                        Image(systemName: "arrow.up.right")
                            .font(.system(size: 8, weight: .medium))
                            .foregroundColor(Color(hex: "#5F646D"))
                            .frame(width: 16, height: 16)
                            .background(Color.white.opacity(0.07))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 8)
                    .padding(.trailing, 10)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: 322)

            // Right card: agent pills
            CardBackground(wash: nil) {
                AgentPillsView(state: state)
            }
        }
        .onChange(of: state.focusId) { _, _ in showingN8nDetail = false }
    }

    private func openAgentTarget(_ task: AgentTask?) {
        guard let task else { return }
        switch task.id {
        case "integration_claude":
            break
        case "integration_resend":
            NSWorkspace.shared.open(URL(string: "https://resend.com/emails")!)
        case "integration_vercel":
            NSWorkspace.shared.open(URL(string: "https://vercel.com/dashboard")!)
        case "integration_github":
            NSWorkspace.shared.open(URL(string: "https://github.com")!)
        case "integration_n8n":
            if let urlStr = KeychainStore.shared.get("n8n-url"), let url = URL(string: urlStr) {
                NSWorkspace.shared.open(url)
            }
        case "integration_stripe":
            NSWorkspace.shared.open(URL(string: "https://dashboard.stripe.com/payments")!)
        case "integration_notion":
            NSWorkspace.shared.open(URL(string: "https://notion.so")!)
        case "integration_calcom":
            NSWorkspace.shared.open(URL(string: "https://app.cal.com/bookings")!)
        case "integration_codex":
            break
        default:
            // Non-integration real tasks
            if task.source == .n8n {
                if let urlStr = KeychainStore.shared.get("n8n-url"), let url = URL(string: urlStr) {
                    NSWorkspace.shared.open(url)
                }
            } else {
                #if !APPSTORE
                let terminalBundleIds = ["com.apple.Terminal", "com.googlecode.iterm2",
                                         "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
                if let hit = terminalBundleIds.compactMap({ id in
                    NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
                }).first {
                    hit.activate(options: .activateIgnoringOtherApps)
                }
                #endif
            }
        }
    }
}

// MARK: - Empty

struct EmptyStateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: nil)
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Nothing running right now.")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Drop a file or window, or ask me anything.")
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#9398A1"))
                }
                Spacer()
                PrimaryButton("Ask Claude") {
                    state.view = .prompt
                }
            }
            .padding(.leading, 118)
            .padding(.trailing, 18)
        }
    }
}

// MARK: - Approval

struct ApprovalView: View {
    @ObservedObject var state: AppState

    var approval: ApprovalInfo? { state.pendingApproval }
    var codexSession: AgentSession? {
        guard state.focusTask?.source == .codex,
              let id = state.selectedAgentSessionID else { return nil }
        return state.agentRuntimeManager.sessions[id]
    }

    var body: some View {
        ZStack {
            CardBackground(wash: .amber)
            if let session = codexSession, let request = session.pendingApproval {
                VStack(alignment: .leading, spacing: 5) {
                    AgentWho(task: state.focusTask, label: "Codex needs permission")
                    CodeBlock(text: request.detail ?? request.title)
                        .lineLimit(1)
                    HStack(spacing: 8) {
                        SecondaryButton("Deny") { resolveCodex(session, request, .deny) }
                        PrimaryButton("Allow") { resolveCodex(session, request, .allow) }
                        if request.choices.contains(.allowForSession) {
                            SecondaryButton("Always") {
                                resolveCodex(session, request, .allowForSession)
                            }
                        }
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    AgentWho(task: state.focusTask, label: "needs permission")
                    CodeBlock(text: approval?.command ?? approval?.tool ?? "…")
                    HStack(spacing: 8) {
                        SecondaryButton("Deny") {
                            HookServer.shared.sendApprovalDecision("deny")
                        }
                        PrimaryButton("Allow") {
                            HookServer.shared.sendApprovalDecision("allow")
                        }
                        SecondaryButton("Always") {
                            HookServer.shared.sendApprovalDecision("always")
                        }
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private func resolveCodex(
        _ session: AgentSession,
        _ request: AgentApprovalRequest,
        _ decision: ApprovalDecision
    ) {
        Task {
            do {
                try await state.agentRuntimeManager.resolveApproval(
                    sessionID: session.id,
                    requestID: request.id,
                    decision: decision
                )
                state.isPinned = false
                state.view = .overview
            } catch {
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }
}

// MARK: - Question

struct QuestionView: View {
    @ObservedObject var state: AppState
    @State private var questionIndex = 0
    @State private var answers: [String: [String]] = [:]
    @State private var selectedChoice = ""
    @State private var typedAnswer = ""
    @State private var isSubmitting = false

    private var codexSession: AgentSession? {
        guard state.focusTask?.source == .codex,
              let id = state.selectedAgentSessionID else { return nil }
        return state.agentRuntimeManager.sessions[id]
    }

    var body: some View {
        ZStack {
            CardBackground(wash: .cyan)
            if let session = codexSession,
               let request = session.pendingUserInput,
               !request.questions.isEmpty {
                let index = min(questionIndex, request.questions.count - 1)
                let question = request.questions[index]
                VStack(alignment: .leading, spacing: 5) {
                    AgentWho(
                        task: state.focusTask,
                        label: request.questions.count == 1
                            ? "Codex needs input"
                            : "Codex needs input · \(index + 1)/\(request.questions.count)"
                    )
                    Text(question.question)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        if !question.options.isEmpty {
                            Menu {
                                ForEach(question.options, id: \.label) { option in
                                    Button(option.label) {
                                        selectedChoice = option.label
                                        typedAnswer = ""
                                    }
                                }
                            } label: {
                                HStack(spacing: 5) {
                                    Text(selectedChoice.isEmpty ? "Choose…" : selectedChoice)
                                        .lineLimit(1)
                                    Image(systemName: "chevron.down")
                                        .font(.system(size: 8, weight: .bold))
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#C9DFFF"))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 5)
                                .background(Color(hex: "#5EA2FF").opacity(0.13))
                                .clipShape(Capsule())
                                .overlay(Capsule().stroke(Color(hex: "#5EA2FF").opacity(0.28), lineWidth: 1))
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                        if question.options.isEmpty || question.allowsOther {
                            answerField(for: question)
                        }
                        PrimaryButton(index == request.questions.count - 1 ? "Send" : "Next") {
                            advance(session: session, request: request, question: question, index: index)
                        }
                        .disabled(!canAdvance(question) || isSubmitting)
                        .opacity(canAdvance(question) && !isSubmitting ? 1 : 0.45)
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .onChange(of: request.id) { _, _ in resetDraft() }
            } else {
                VStack(alignment: .leading, spacing: 5) {
                    AgentWho(task: state.focusTask, label: "Claude Code is asking a question")
                    Text("Return to Claude Code to answer this question.")
                        .font(.system(size: 14, weight: .semibold))
                    SecondaryButton("OK") {
                        state.isPinned = false
                        state.view = .overview
                    }
                }
                .padding(.leading, 116)
                .padding(.trailing, 16)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @ViewBuilder
    private func answerField(for question: AgentUserInputQuestion) -> some View {
        Group {
            if question.isSecret {
                SecureField("Type an answer…", text: $typedAnswer)
            } else {
                TextField("Type an answer…", text: $typedAnswer)
            }
        }
        .textFieldStyle(.plain)
        .font(.system(size: 11))
        .foregroundColor(Color(hex: "#F5F6F8"))
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        )
    }

    private func canAdvance(_ question: AgentUserInputQuestion) -> Bool {
        !typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !selectedChoice.isEmpty
            || answers[question.id]?.isEmpty == false
    }

    private func advance(
        session: AgentSession,
        request: AgentUserInputRequest,
        question: AgentUserInputQuestion,
        index: Int
    ) {
        let typed = typedAnswer.trimmingCharacters(in: .whitespacesAndNewlines)
        let answer = typed.isEmpty ? selectedChoice : typed
        guard !answer.isEmpty else { return }
        var submittedAnswers = answers
        submittedAnswers[question.id] = [answer]
        answers = submittedAnswers

        if index < request.questions.count - 1 {
            questionIndex = index + 1
            selectedChoice = ""
            typedAnswer = ""
            return
        }

        isSubmitting = true
        Task {
            do {
                try await state.agentRuntimeManager.respondToUserInput(
                    sessionID: session.id,
                    requestID: request.id,
                    answers: submittedAnswers
                )
                resetDraft()
                state.isPinned = false
                state.view = .overview
            } catch {
                isSubmitting = false
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }

    private func resetDraft() {
        questionIndex = 0
        answers = [:]
        selectedChoice = ""
        typedAnswer = ""
        isSubmitting = false
    }
}

// MARK: - Error

struct ErrorView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .red)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "n8n")
                Text("Workflow stopped.")
                    .font(.system(size: 15, weight: .semibold))
                Text("Gmail node timed out after 30s. Retry or open n8n.")
                    .font(.system(size: 12))
                    .foregroundColor(Color(hex: "#FF8D97"))
                HStack(spacing: 8) {
                    PrimaryButton("Retry") { /* retry */ }
                    SecondaryButton("Open in n8n") { /* open */ }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Finished

struct FinishedView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack {
            CardBackground(wash: .green)
            VStack(alignment: .leading, spacing: 5) {
                AgentWho(task: state.focusTask, label: "Claude Code finished")
                Text(state.focusTask?.steps.last ?? "Session finished")
                    .font(.system(size: 15, weight: .semibold))
                HStack(spacing: 8) {
                    #if !APPSTORE
                    PrimaryButton("Open terminal") {
                        let terminalBundleIds = ["com.apple.Terminal", "com.googlecode.iterm2", "net.kovidgoyal.kitty", "com.mitchellh.ghostty"]
                        let activated = terminalBundleIds.compactMap { id in
                            NSWorkspace.shared.runningApplications.first { $0.bundleIdentifier == id }
                        }.first.map { $0.activate(options: .activateIgnoringOtherApps) }
                        if activated == nil {
                            NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"))
                        }
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                    #endif
                    SecondaryButton("OK") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Confused

struct ConfusedView: View {
    var body: some View {
        ZStack {
            CardBackground(wash: .pink)
            VStack(alignment: .leading, spacing: 5) {
                Text("Too many hits at once.").font(.system(size: 15, weight: .semibold))
                Text("Give me a sec — back to work in three seconds.")
                    .font(.system(size: 13)).foregroundColor(Color(hex: "#9398A1"))
            }
            .padding(.leading, 128)
            .padding(.trailing, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Upload (drop zone)

struct UploadView: View {
    @ObservedObject var state: AppState
    @State private var dashPhase: CGFloat = 0
    @State private var breathAngle: Double = 0
    // Timer only runs while this is the active tab — killed on deactivation
    @State private var animTimer: Timer? = nil

    private var borderOpacity: Double {
        let breathe = 0.11 + 0.04 * (sin(breathAngle) * 0.5 + 0.5)
        return state.fileDragOver ? 0.65 : breathe
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#0E0F11"))
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    state.fileDragOver
                        ? Color(hex: "#22C55E").opacity(borderOpacity)
                        : Color.white.opacity(borderOpacity),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 5], dashPhase: dashPhase)
                )
            RoundedRectangle(cornerRadius: 20)
                .fill(RadialGradient(
                    colors: [Color(hex: "#22C55E").opacity(state.fileDragOver ? 0.13 : 0), Color.clear],
                    center: .bottom, startRadius: 0, endRadius: 200
                ))
            VStack(alignment: .leading, spacing: 8) {
                Text("Drop your files here")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(state.fileDragOver ? Color(hex: "#34D399") : Color(hex: "#D5D7DB"))
                HStack(spacing: 6) {
                    ForEach(["PDF", "Images", "Code", "Docs"], id: \.self) { label in
                        Text(label)
                            .font(.system(size: 11))
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.white.opacity(0.07))
                            .foregroundColor(Color(hex: "#B9BDC4"))
                            .clipShape(Capsule())
                    }
                }
            }
            .padding(.leading, 196)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onChange(of: state.view) { _, newView in
            newView == .upload ? startTimer() : stopTimer()
        }
        .onAppear {
            if state.view == .upload { startTimer() }
        }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard animTimer == nil else { return }
        // 20 fps — smooth enough for slow dash, 3× lighter than 60fps
        animTimer = Timer.scheduledTimer(withTimeInterval: 1.0/20.0, repeats: true) { _ in
            dashPhase  += 1.0          // 20 pt/s march
            breathAngle += 0.9 / 20.0  // advance sin phase at 0.9 rad/s
        }
    }

    private func stopTimer() {
        animTimer?.invalidate()
        animTimer = nil
    }
}

// MARK: - Uploading

struct UploadingView: View {
    @ObservedObject var state: AppState

    // Bar geometry in content coords (content has 10pt H padding each side).
    // Island bar: left=36, right=562 (640-78), width=526.
    // Content bar: left=26, width=526.
    // barTop=58 → island y = content_start(42)+58 = 100; bot cy=103 (center = barTop+3).
    private let barLeft: CGFloat  = 26
    private let barWidth: CGFloat = 526
    private let barTop: CGFloat   = 58

    var body: some View {
        // TimelineView fires at display refresh rate — progress derived from elapsed wall time,
        // not from @Published uploadProgress (which only flips to 1.0 at completion).
        TimelineView(.animation) { tl in
            let elapsed: Double = {
                guard let start = state.uploadStartTime else { return 0 }
                return tl.date.timeIntervalSince(start)
            }()
            let t        = min(1.0, max(0, elapsed / state.uploadDuration))
            let progress = CGFloat(t * (2 - t))          // ease-out quad
            let fillWidth = max(0, barWidth * progress)
            let isDone   = state.uploadProgress >= 0.999  // only true after handle() sets it

            ZStack(alignment: .topLeading) {
                // Background: dark base
                RoundedRectangle(cornerRadius: 20)
                    .fill(Color(hex: "#141518"))

                // Permanent green radial wash — brighter at completion
                RoundedRectangle(cornerRadius: 20)
                    .fill(RadialGradient(
                        colors: [Color(hex: "#34D399").opacity(isDone ? 0.28 : 0.14), Color.clear],
                        center: UnitPoint(x: 0.5, y: 1.4),
                        startRadius: 0,
                        endRadius: 260
                    ))

                // Bar track
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.white.opacity(0.09))
                    .frame(width: barWidth, height: 6)
                    .offset(x: barLeft, y: barTop)

                // Bar fill
                RoundedRectangle(cornerRadius: 3)
                    .fill(LinearGradient(
                        colors: [Color(hex: "#1FA87A"), Color(hex: "#34D399")],
                        startPoint: .leading, endPoint: .trailing
                    ))
                    .frame(width: fillWidth, height: 6)
                    .offset(x: barLeft, y: barTop)

                // Glow trail behind dot leading edge
                if progress > 0.01 {
                    Ellipse()
                        .fill(Color(hex: "#6EE7B7").opacity(0.45))
                        .frame(width: 28, height: 12)
                        .blur(radius: 5)
                        .offset(x: barLeft + fillWidth - 14, y: barTop - 3)
                }

                // Text row — filename + % (above bar)
                HStack(spacing: 0) {
                    if isDone {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(Color(hex: "#34D399"))
                        Text("  \(state.droppedFile?.name ?? "File")")
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundColor(Color(hex: "#34D399"))
                            .lineLimit(1).truncationMode(.middle)
                    } else {
                        Text("Uploading \(state.droppedFile?.name ?? "file")")
                            .font(.system(size: 12.5))
                            .foregroundColor(Color(hex: "#A9ADB5"))
                            .lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text("\(Int(progress * 100)) %")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundColor(Color(hex: "#A9ADB5"))
                            .monospacedDigit()
                    }
                }
                .frame(width: barWidth)
                .offset(x: barLeft, y: barTop - 22)

                // Subtle top border (same as CardBackground)
                RoundedRectangle(cornerRadius: 20)
                    .stroke(Color.white.opacity(0.035), lineWidth: 1)
            }
        }
    }
}

// MARK: - Choose

struct ChooseView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 8) {
                let fileName = state.droppedFile?.name ?? "file"
                (Text(fileName).font(.system(size: 14, weight: .semibold)) + Text(" is ready.").font(.system(size: 14, weight: .semibold)))
                Text("What do you want to do with it?").font(.system(size: 12.5)).foregroundColor(Color(hex: "#9398A1"))
                HStack(spacing: 8) {
                    PrimaryButton("Ask a question") { state.view = .prompt }
                    SecondaryButton("Send by email") { state.view = .mail }
                }
            }
            .padding(.leading, 98)
            .padding(.trailing, 18)
        }
    }
}

// MARK: - Mail

struct MailView: View {
    @ObservedObject var state: AppState
    @State private var to: String = ""
    @State private var subject: String = ""
    @State private var bodyText: String = ""
    @State private var statusMsg: String = ""
    @State private var isSending = false

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text("New email").font(.system(size: 12, weight: .semibold))
                    if let name = state.droppedFile?.name {
                        Text("with").font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
                        Text(name).font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1).truncationMode(.middle)
                    }
                }

                MailField(label: "To", placeholder: "address@example.com", text: $to)
                MailField(label: "Subject", placeholder: state.droppedFile?.name ?? "Subject", text: $subject)

                // Body — TextEditor scrolls internally when text overflows
                TextEditor(text: $bodyText)
                    .scrollContentBackground(.hidden)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .frame(height: 44)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.white.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                if !statusMsg.isEmpty {
                    Text(statusMsg).font(.system(size: 11)).foregroundColor(Color(hex: "#FF8D97"))
                }

                HStack(spacing: 8) {
                    PrimaryButton(isSending ? "Sending…" : "Send") {
                        guard !isSending else { return }
                        sendMail()
                    }
                    SecondaryButton("Cancel") { state.view = .choose }
                }
            }
            .padding(.leading, 92)
            .padding(.trailing, 18)
            .padding(.vertical, 8)
        }
        .onAppear { subject = state.droppedFile?.name ?? "" }
    }

    private func sendMail() {
        guard !to.isEmpty else { statusMsg = "Missing recipient."; return }
        let subj = subject.isEmpty ? (state.droppedFile?.name ?? "File") : subject

        // Prefer Resend if API key + sender address are configured
        let apiKey  = KeychainStore.shared.get("resend-api-key")
        let fromAddr = KeychainStore.shared.get("resend-from")

        if let apiKey, let fromAddr {
            isSending = true
            statusMsg = ""
            let recipient = to
            let msgBody  = bodyText
            let fileURL  = state.droppedFile?.url
            Task {
                let ok = await sendViaResend(apiKey: apiKey, from: fromAddr,
                                              to: recipient, subject: subj,
                                              body: msgBody, fileURL: fileURL)
                await MainActor.run {
                    isSending = false
                    if ok { onSuccess(recipient: recipient) }
                    else  { statusMsg = "Resend error — check API key & sender." }
                }
            }
        } else if apiKey != nil && fromAddr == nil {
            // API key set but no sender — guide user instead of silent fallback
            statusMsg = "Set sender address in Settings."
        } else {
            // No Resend — fallback to Mail
            sendViaAppleMail(to: to, subject: subj)
        }
    }

    private func sendViaResend(apiKey: String, from: String, to: String,
                                subject: String, body: String, fileURL: URL?) async -> Bool {
        guard let url = URL(string: "https://api.resend.com/emails") else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "from": from,
            "to": [to],
            "subject": subject,
            "text": body.isEmpty ? " " : body
        ]
        if let fileURL, let data = try? Data(contentsOf: fileURL) {
            payload["attachments"] = [[
                "filename": fileURL.lastPathComponent,
                "content": data.base64EncodedString()
            ]]
        }
        guard let httpBody = try? JSONSerialization.data(withJSONObject: payload) else { return false }
        request.httpBody = httpBody
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        if code == 200 || code == 201 { return true }
        print("[Resend] HTTP \(code)")
        return false
    }

    private func sendViaAppleMail(to: String, subject: String) {
        #if APPSTORE
        // App Store: no AppleScript — use NSSharingService to compose (user sends manually)
        guard let service = NSSharingService(named: .composeEmail) else {
            statusMsg = "Mail not available."
            return
        }
        var items: [Any] = [bodyText.isEmpty ? " " : bodyText]
        if let url = state.droppedFile?.url,
           FileManager.default.fileExists(atPath: url.path) {
            items.append(url)
        }
        service.recipients = [to]
        service.subject = subject
        service.perform(withItems: items)
        onSuccess(recipient: to)
        #else
        func asEscape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "\\\\")
             .replacingOccurrences(of: "\"", with: "\\\"")
        }

        let bodyLines = bodyText.isEmpty ? [""] : bodyText.components(separatedBy: "\n")
        let bodyExpr = bodyLines.map { "\"\(asEscape($0))\"" }.joined(separator: " & linefeed & ")
            + " & return & return"

        let attachBlock: String
        if let url = state.droppedFile?.url,
           FileManager.default.fileExists(atPath: url.path) {
            let escapedPath = asEscape(url.path)
            attachBlock = "make new attachment with properties {file name:(POSIX file \"\(escapedPath)\")} at after the last paragraph of content"
        } else {
            attachBlock = ""
        }

        let script = """
        tell application "Mail"
            set m to make new outgoing message with properties {subject:"\(asEscape(subject))", visible:false}
            set content of m to \(bodyExpr)
            tell m
                make new to recipient at end of to recipients with properties {address:"\(asEscape(to))"}
                \(attachBlock)
            end tell
            delay 1
            send m
        end tell
        """
        var err: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&err)
        if err == nil { onSuccess(recipient: to) }
        else { statusMsg = "Mail error: \(err?["NSAppleScriptErrorMessage"] as? String ?? "unknown")" }
        #endif
    }

    private func onSuccess(recipient: String) {
        SoundEngine.shared.play("send")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.wink)
        state.noteMessage = "Email sent to \(recipient)."
        state.view = .note
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            NotificationCenter.default.post(name: .islandCollapse, object: nil)
        }
    }
}

// MARK: - Prompt (chat)

struct PromptView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var chatService = InternalChatService.shared
    @State private var text: String = ""
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Picker("Provider", selection: providerBinding) {
                        ForEach(chatService.availableProviders, id: \.self) { provider in
                            Text(providerName(provider)).tag(provider)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()

                    Picker("Model", selection: modelBinding) {
                        if chatService.models.isEmpty {
                            Text(chatService.selectedModelID).tag(chatService.selectedModelID)
                        } else {
                            if chatService.selectedModel == nil {
                                Text("Unavailable · \(chatService.selectedModelID)")
                                    .tag(chatService.selectedModelID)
                            }
                            ForEach(chatService.models) { model in
                                Text(model.displayName).tag(model.id)
                            }
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(chatService.isLoadingModels)

                    if let model = chatService.selectedModel, !model.reasoningOptions.isEmpty {
                        Picker("Reasoning", selection: reasoningBinding) {
                            ForEach(model.reasoningOptions) { option in
                                Text(option.displayName).tag(Optional(option.id))
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .fixedSize()
                    }

                    Spacer()
                    if chatService.isLoadingModels {
                        ProgressView().controlSize(.small)
                    } else if chatService.selectionWarning != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.orange)
                            .help(chatService.selectionWarning ?? "Model unavailable")
                    }
                }
                .font(.system(size: 10.5, weight: .medium))

                if let ctx = state.promptContext {
                    ContextChip(context: ctx).padding(.top, 4)
                }

                if !state.chatHistory.isEmpty {
                    ScrollViewReader { proxy in
                        ScrollView(.vertical, showsIndicators: false) {
                            VStack(alignment: .leading, spacing: 6) {
                                ForEach(state.chatHistory) { msg in
                                    ChatBubble(message: msg).id(msg.id)
                                }
                                if state.stateOverride != nil {
                                    HStack { TypingDotsView(); Spacer(minLength: 32) }
                                        .id("typing")
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .onChange(of: state.chatHistory.count) { _, _ in
                            if let last = state.chatHistory.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                        .onChange(of: state.stateOverride) { _, v in
                            if v != nil { withAnimation { proxy.scrollTo("typing", anchor: .bottom) } }
                        }
                        .onAppear {
                            if let last = state.chatHistory.last {
                                proxy.scrollTo(last.id, anchor: .bottom)
                            }
                        }
                    }
                    .frame(maxHeight: .infinity)
                } else {
                    Spacer()
                }

                HStack(spacing: 8) {
                    TextField(state.chatHistory.isEmpty ? "Ask me anything…" : "Continue…", text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .tint(Color(hex: "#8EBBFF"))
                        .focused($focused)
                        .onSubmit { sendMessage() }

                    Button(action: sendMessage) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(text.isEmpty)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(TapGesture().onEnded { focused = true })
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .padding(.bottom, 10)
        .onAppear {
            focused = true
            chatService.loadModels()
        }
    }

    private func sendMessage() {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return }
        text = ""
        focused = false
        state.chatHistory.append(ChatMessage(role: .user, content: query))
        state.stateOverride = .thinking
        Task {
            await chatService.chat(query: query, context: state.promptContext, state: state)
            await MainActor.run { focused = true }
        }
    }

    private var providerBinding: Binding<ProviderID> {
        Binding(
            get: { chatService.selectedProviderID },
            set: { chatService.selectProvider($0, state: state) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { chatService.selectedModelID },
            set: { chatService.selectModel($0) }
        )
    }

    private var reasoningBinding: Binding<String?> {
        Binding(
            get: { chatService.selectedReasoningID },
            set: { chatService.selectReasoning($0) }
        )
    }

    private func providerName(_ provider: ProviderID) -> String {
        switch provider {
        case .anthropic: "Anthropic"
        case .openAI: "OpenAI"
        case .google: "Google"
        }
    }
}


struct ChatBubble: View {
    let message: ChatMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user {
                Spacer(minLength: 32)
                Text(message.content)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.white.opacity(0.13))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            } else {
                Text(message.content)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#B0B5BE"))
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 8)
            }
        }
    }
}

struct TypingDotsView: View {
    @State private var phase = false

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .fill(Color(hex: "#6B7079"))
                    .frame(width: 5, height: 5)
                    .scaleEffect(phase ? 1.2 : 0.6)
                    .animation(
                        .easeInOut(duration: 0.45).repeatForever().delay(Double(i) * 0.14),
                        value: phase
                    )
            }
        }
        .padding(.horizontal, 2).padding(.vertical, 4)
        .onAppear { phase = true }
    }
}

// MARK: - Searching

struct SearchingView: View {
    @ObservedObject var state: AppState

    var label: String {
        switch state.promptContext {
        case .window(_, let title, _): return "Claude is reading \(title)…"
        case .file(let name, _): return "Claude is reading \(name)…"
        case nil: return "Claude is searching…"
        }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)

            VStack(alignment: .leading, spacing: 8) {
                if let ctx = state.promptContext {
                    ContextChip(context: ctx)
                }
                ShimmeringText(label)
                    .font(.system(size: 13.5))
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
        }
    }
}

// MARK: - Result

struct ResultView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .green)

            if let result = state.searchResult {
                VStack(alignment: .leading, spacing: 7) {
                    Text(result.title)
                        .font(.system(size: 15, weight: .semibold))

                    VStack(spacing: 4) {
                        ForEach(result.items.prefix(3), id: \.label) { item in
                            HStack {
                                Text(item.label).font(.system(size: 12.5, weight: .semibold))
                                Spacer()
                                Text(item.detail).font(.system(size: 12.5)).foregroundColor(Color(hex: "#9398A1"))
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color.white.opacity(0.05))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }

                    if let note = result.note {
                        Text(note).font(.system(size: 11)).foregroundColor(Color(hex: "#6E737C"))
                    }

                    HStack(spacing: 8) {
                        // The URL comes from the model, which may have read attacker-controlled
                        // files or pages: only plain web links may leave the app.
                        let openURL = safeWebURL(result.items.first?.url)
                        PrimaryButton("Open") {
                            if let openURL { NSWorkspace.shared.open(openURL) }
                        }
                        .disabled(openURL == nil)
                        .help(openURL?.absoluteString ?? "")
                        SecondaryButton("Copy") {
                            let text = result.items.map { "\($0.label): \($0.detail)" }.joined(separator: "\n")
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(text, forType: .string)
                        }
                        SecondaryButton("Close") { state.view = state.tasks.isEmpty ? .empty : .overview }
                    }
                }
                .padding(.leading, 84)
                .padding(.trailing, 16)
            }
        }
    }
}

// MARK: - Note (short message, auto-closes)

struct NoteView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 4) {
                Text(state.noteMessage ?? "")
                    .font(.system(size: 15, weight: .semibold))
            }
            .padding(.leading, 98)
        }
    }
}

// MARK: - Integration card (overview left card when an integration pill is focused)

struct IntegrationCardView: View {
    let task: AgentTask
    @Binding var showingDetail: Bool
    @ObservedObject private var appState = AppState.shared

    private var isConfigured: Bool {
        switch task.id {
        case "integration_claude":
            #if APPSTORE
            // Sandboxed: can't read ~/.claude directly — check install flag set by HookServer
            return UserDefaults.standard.bool(forKey: "coucouHooksInstalled")
            #else
            let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/settings.json")
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let hooks = json["hooks"] as? [String: Any],
                  let ss = hooks["SessionStart"] as? [[String: Any]] else { return false }
            return ss.contains { ($0["hooks"] as? [[String: Any]])?.contains {
                let cmd = $0["command"] as? String
                return cmd?.contains("NotchBuddy") == true || cmd?.contains("coucou") == true
            } ?? false }
            #endif
        case "integration_codex":
            switch appState.agentRuntimeManager.availability[.codex] {
            case .available, .disconnected:
                return true
            default:
                return false
            }
        case "integration_resend":  return KeychainStore.shared.get("resend-api-key") != nil
        case "integration_n8n":     return KeychainStore.shared.get("n8n-api-key")    != nil
        case "integration_vercel":  return KeychainStore.shared.get("vercel-token")   != nil
        case "integration_github":  return KeychainStore.shared.get("github-token")   != nil
        case "integration_stripe":  return KeychainStore.shared.get("stripe-api-key") != nil
        case "integration_notion":  return KeychainStore.shared.get("notion-api-key") != nil
        case "integration_calcom":  return KeychainStore.shared.get("calcom-api-key") != nil
        default: return false
        }
    }

    private var openURL: URL? {
        switch task.id {
        case "integration_claude":  return nil  // uses terminal button below
        case "integration_codex":   return nil
        case "integration_resend":  return URL(string: "https://resend.com/emails")
        case "integration_n8n":
            if let s = KeychainStore.shared.get("n8n-url") { return URL(string: s) }
            return nil
        case "integration_vercel":  return URL(string: "https://vercel.com/dashboard")
        case "integration_github":  return URL(string: "https://github.com")
        case "integration_stripe":  return URL(string: "https://dashboard.stripe.com/payments")
        case "integration_notion":  return URL(string: "https://notion.so")
        case "integration_calcom":  return URL(string: "https://app.cal.com/bookings")
        default: return nil
        }
    }

    // Claude Code with an active session: show ticker layout (same as overview)
    private var claudeSessionActive: Bool {
        task.id == "integration_claude" && (task.state != .idle || !task.steps.isEmpty)
    }

    // n8n with a finished execution: show result row instead of "Open n8n" button
    private var n8nHasActivity: Bool {
        task.id == "integration_n8n" && !task.steps.isEmpty &&
        (task.state == .finished || task.state == .error)
    }

    // Vercel with recent deployments
    private var vercelHasActivity: Bool {
        task.id == "integration_vercel" && !appState.vercelDeployments.isEmpty
    }

    // Resend with recent emails
    private var resendHasData: Bool {
        task.id == "integration_resend" && !appState.resendEmails.isEmpty
    }

    // GitHub with stats loaded
    private var githubHasData: Bool {
        task.id == "integration_github" && appState.githubStats != nil
    }

    // Stripe: show card as soon as first poll completes (balance OR payments)
    private var stripeHasData: Bool {
        task.id == "integration_stripe" && appState.stripeLoaded
    }

    // Cal.com: show calendar as soon as first poll completes
    private var calcomHasData: Bool {
        task.id == "integration_calcom" && appState.calcomLoaded
    }

    // Notion: show pages as soon as first poll completes
    private var notionHasData: Bool {
        task.id == "integration_notion" && appState.notionLoaded
    }

    var body: some View {
        if task.id == "integration_codex" {
            CodexRuntimeCardView(
                state: appState,
                runtimeManager: appState.agentRuntimeManager
            )
        } else if showingDetail && n8nHasActivity {
            N8nDetailView(task: task) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = false }
            }
            .transition(.opacity)
        } else if showingDetail && vercelHasActivity {
            VercelDetailView(deployment: appState.vercelDeployments[0]) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = false }
            }
            .transition(.opacity)
        } else if vercelHasActivity {
            VercelDeploymentListView(deployments: appState.vercelDeployments, onOpenDetail: {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = true }
            })
            .transition(.opacity)
        } else if resendHasData {
            ResendCardView(emails: appState.resendEmails, total: appState.resendTotal)
                .transition(.opacity)
        } else if githubHasData {
            GitHubStatsCardView(stats: appState.githubStats!)
                .transition(.opacity)
        } else if stripeHasData {
            StripeCardView()
                .transition(.opacity)
        } else if calcomHasData {
            CalcomCardView()
                .transition(.opacity)
        } else if notionHasData {
            NotionCardView()
                .transition(.opacity)
        } else if claudeSessionActive {
            // Active session view — reuse overview layout
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: task.color))
                        .frame(width: 7, height: 7)
                    Text(task.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                    Text("Claude Code")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 2)
                    if task.steps.count > 1 {
                        Text("\(min(task.stepIndex + 1, task.steps.count))/\(task.steps.count)")
                            .font(.system(size: 11))
                            .foregroundColor(Color(hex: "#6B7079"))
                            .fixedSize()
                    }
                }
                .padding(.top, 6)
                .padding(.leading, 108)
                .padding(.trailing, 36)

                TickerView(task: task)
                    .frame(height: 44)
                    .padding(.top, 6)
                    .padding(.leading, 108)
                    .padding(.trailing, 12)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 4)
        } else {
            // Idle / not connected view — slides in from left when returning from detail
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(Color(hex: task.color))
                        .frame(width: 7, height: 7)
                    Text(task.name)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Text("Integration")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                    Spacer(minLength: 2)
                }
                .padding(.top, 6)
                .padding(.leading, 108)
                .padding(.trailing, 36)

                HStack(spacing: 5) {
                    let stripeErr = task.id == "integration_stripe" ? appState.stripeError
                                  : task.id == "integration_calcom"  ? appState.calcomError
                                  : nil
                    let dot = stripeErr != nil ? Color(hex: "#F4505E")
                            : isConfigured    ? Color(hex: "#22C55E")
                            :                   Color(hex: "#F4505E")
                    let label: String = if let stripeErr {
                        stripeErr
                    } else if task.id == "integration_claude" {
                        isConfigured ? "Hooks connected · waiting for a session" : "Hooks not configured"
                    } else {
                        isConfigured ? "Connected · loading…" : "Key not configured"
                    }
                    Circle().fill(dot).frame(width: 5, height: 5)
                    Text(label)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
                .padding(.leading, 108)
                .padding(.top, 2)

                HStack(spacing: 8) {
                    if n8nHasActivity {
                        // Clickable pill — tap to open execution detail
                        let success = task.state == .finished
                        let accent  = success ? Color(hex: "#22C55E") : Color(hex: "#F4505E")
                        Button(action: {
                            withAnimation(.spring(response: 0.28, dampingFraction: 0.82)) { showingDetail = true }
                        }) {
                            HStack(spacing: 5) {
                                Circle().fill(accent).frame(width: 5, height: 5)
                                Text(task.steps.first ?? "Workflow")
                                    .font(.system(size: 11))
                                    .foregroundColor(Color(hex: "#C5C8CD"))
                                    .lineLimit(1).truncationMode(.tail)
                                Image(systemName: "ellipsis")
                                    .font(.system(size: 8, weight: .medium))
                                    .foregroundColor(Color(hex: "#6B7079"))
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(accent.opacity(0.1))
                            .clipShape(Capsule())
                            .overlay(Capsule().stroke(accent.opacity(0.22), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    } else if let url = openURL {
                        Button("Open \(task.name)") { NSWorkspace.shared.open(url) }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: task.color).opacity(0.85))
                            .buttonStyle(.plain)
                    }
                    if task.id == "integration_stripe" {
                        if isConfigured {
                            Button("Refresh") { Task { @MainActor in StripePoller.shared.pollNow() } }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(Color(hex: "#0570DE").opacity(0.85))
                                .buttonStyle(.plain)
                        }
                    }
                    if task.id == "integration_calcom" && isConfigured {
                        Button("Refresh") { Task { @MainActor in CalcomPoller.shared.pollNow() } }
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#C9956A").opacity(0.85))
                            .buttonStyle(.plain)
                    }
                    if !isConfigured {
                        Button("Settings…") {
                            NotificationCenter.default.post(name: .openFullSettings, object: nil)
                        }
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .buttonStyle(.plain)
                    }
                }
                .padding(.leading, 108)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .padding(.top, 4)
            .transition(.opacity)
        }
    }

}

// MARK: - Codex runtime card

struct CodexRuntimeCardView: View {
    @ObservedObject var state: AppState
    @ObservedObject var runtimeManager: AgentRuntimeManager

    private var sessions: [AgentSession] {
        runtimeManager.sessions.values
            .filter { $0.runtime == .codex }
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private var selected: AgentSession? {
        if let id = state.selectedAgentSessionID,
           let session = runtimeManager.sessions[id], session.runtime == .codex {
            return session
        }
        return sessions.first
    }

    private var selectedIndex: Int? {
        guard let selected else { return nil }
        return sessions.firstIndex(where: { $0.id == selected.id })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: "#5EA2FF"))
                    .frame(width: 7, height: 7)
                    .shadow(color: Color(hex: "#5EA2FF").opacity(0.55), radius: 4)
                Text(selected?.displayTitle ?? "Codex")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .help(selected?.displayTitle ?? "Codex")
                Text("Codex")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .foregroundColor(Color(hex: "#5EA2FF"))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color(hex: "#5EA2FF").opacity(0.12))
                    .clipShape(Capsule())
                    .fixedSize()
                Spacer(minLength: 2)
                Button("New") { state.view = .agentPrompt }
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#5EA2FF"))
                    .buttonStyle(.plain)
                    .fixedSize()
                if sessions.count > 1, let selectedIndex {
                    Button(action: { cycle(from: selectedIndex, offset: 1) }) {
                        HStack(spacing: 3) {
                            Text("\(selectedIndex + 1)/\(sessions.count)")
                            Image(systemName: "chevron.down")
                        }
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(Color(hex: "#727781"))
                    }
                    .buttonStyle(.plain)
                    .fixedSize()
                }
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 10)

            if let session = selected {
                HStack(spacing: 6) {
                    Circle()
                        .fill(session.state.statusColor)
                        .frame(width: 5, height: 5)
                    Text(session.state.displayLabel)
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundColor(session.state.statusColor)
                    if let model = session.model?.modelID {
                        Text(model)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundColor(Color(hex: "#686D76"))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                }
                .padding(.leading, 108)
                .padding(.top, 6)

                HStack(spacing: 7) {
                    Text(activityText(for: session))
                        .font(.system(size: 11.5))
                        .foregroundColor(Color(hex: "#A7ABB3"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 4)
                    action(for: session)
                }
                .padding(.leading, 108)
                .padding(.trailing, 10)
                .padding(.top, 5)
            } else {
                HStack(spacing: 6) {
                    Circle()
                        .fill(availabilityColor)
                        .frame(width: 5, height: 5)
                    Text(availabilityLabel)
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#777C85"))
                }
                .padding(.leading, 108)
                .padding(.top, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    @ViewBuilder
    private func action(for session: AgentSession) -> some View {
        if session.pendingApproval != nil {
            Button("Review") {
                state.selectAgentSession(session.id)
                state.view = .approval
                state.isPinned = true
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Color(hex: "#F5A524"))
            .buttonStyle(.plain)
        } else if session.pendingUserInput != nil {
            Button("Answer") {
                state.selectAgentSession(session.id)
                state.view = .question
                state.isPinned = true
            }
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(Color(hex: "#36CFC9"))
            .buttonStyle(.plain)
        } else if session.state == .working {
            HStack(spacing: 9) {
                openConversationButton(session)
                Button("Stop") { interrupt(session) }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#F17882"))
                    .buttonStyle(.plain)
            }
        } else if session.state == .disconnected {
            HStack(spacing: 9) {
                openConversationButton(session)
                Button("Resume") { resume(session) }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#8EBBFF"))
                    .buttonStyle(.plain)
            }
        } else {
            openConversationButton(session)
        }
    }

    private func openConversationButton(_ session: AgentSession) -> some View {
        Button("Open") {
            state.selectAgentSession(session.id)
            state.view = .agentSession
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundColor(Color(hex: "#8EBBFF"))
        .buttonStyle(.plain)
    }

    private func activityText(for session: AgentSession) -> String {
        if let activity = session.latestActivity?.title, !activity.isEmpty { return activity }
        if let preview = session.metadata["preview"]?.stringValue, !preview.isEmpty { return preview }
        if session.state == .waitingForUser { return "Waiting for your input" }
        return session.workspace?.path ?? "No recent activity"
    }

    private func cycle(from index: Int, offset: Int) {
        guard !sessions.isEmpty else { return }
        let next = (index + offset + sessions.count) % sessions.count
        withAnimation(.easeInOut(duration: 0.18)) {
            state.selectAgentSession(sessions[next].id)
        }
        SoundEngine.shared.play("blip")
    }

    private func interrupt(_ session: AgentSession) {
        Task {
            do {
                try await runtimeManager.interrupt(sessionID: session.id)
            } catch {
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }

    private func resume(_ session: AgentSession) {
        Task {
            do {
                let resumed = try await runtimeManager.resumeSession(sessionID: session.id)
                state.selectAgentSession(resumed.id)
            } catch {
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }

    private var availabilityLabel: String {
        switch runtimeManager.availability[.codex] {
        case .available(let version): version ?? "Codex connected"
        case .disconnected(let version, let reason):
            reason ?? version.map { "Codex \($0) disconnected" } ?? "Codex disconnected"
        case .unavailable(let reason): reason ?? "Codex unavailable"
        case .authenticationRequired(let reason): reason ?? "Codex authentication required"
        case .unsupported(let reason): reason
        case nil: "Detecting Codex…"
        }
    }

    private var availabilityColor: Color {
        switch runtimeManager.availability[.codex] {
        case .available:
            Color(hex: "#22C55E")
        case .disconnected:
            .orange
        default:
            Color(hex: "#6B7079")
        }
    }
}

// MARK: - Codex session composer

struct CodexSessionComposerView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var runtimeManager = AppState.shared.agentRuntimeManager
    @State private var prompt = ""
    @State private var selectedModelID = ""
    @State private var selectedEffortID = ""
    @State private var workspaceURL: URL?
    @State private var isStarting = false
    @FocusState private var promptFocused: Bool

    private var models: [ModelDescriptor] {
        runtimeManager.models[.codex] ?? []
    }

    private var selectedModel: ModelDescriptor? {
        models.first { $0.id == selectedModelID }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(Color(hex: "#5EA2FF"))
                        .frame(width: 7, height: 7)
                    Text("New Codex session")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                    Spacer()
                    Button(workspaceURL?.lastPathComponent ?? "Choose project…") {
                        chooseWorkspace()
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundColor(Color(hex: "#8EBBFF"))
                    .buttonStyle(.plain)
                }

                HStack(spacing: 7) {
                    selector(
                        title: selectedModel?.displayName ?? (models.isEmpty ? "No models" : "Model"),
                        options: models.map { ($0.id, $0.displayName) },
                        selection: $selectedModelID
                    )
                    if let selectedModel, !selectedModel.reasoningOptions.isEmpty {
                        selector(
                            title: selectedModel.reasoningOptions.first(where: { $0.id == selectedEffortID })?.displayName ?? "Effort",
                            options: selectedModel.reasoningOptions.map { ($0.id, $0.displayName) },
                            selection: $selectedEffortID
                        )
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: 8) {
                    TextField("What should Codex do?", text: $prompt)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .tint(Color(hex: "#8EBBFF"))
                        .focused($promptFocused)
                        .onSubmit { startSession() }
                    Button(action: startSession) {
                        Image(systemName: isStarting ? "ellipsis" : "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(!canStart)
                    .opacity(canStart ? 1 : 0.45)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.vertical, 12)
        }
        .onAppear {
            workspaceURL = selectedCodexSession?.workspace
            selectInitialModel()
            promptFocused = true
        }
        .onChange(of: selectedModelID) { _, _ in selectDefaultEffort() }
    }

    private var selectedCodexSession: AgentSession? {
        state.selectedAgentSessionID.flatMap { runtimeManager.sessions[$0] }
    }

    private var canStart: Bool {
        !isStarting
            && !selectedModelID.isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    @ViewBuilder
    private func selector(
        title: String,
        options: [(String, String)],
        selection: Binding<String>
    ) -> some View {
        Menu {
            ForEach(options, id: \.0) { id, label in
                Button(label) { selection.wrappedValue = id }
            }
        } label: {
            HStack(spacing: 5) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 10.5, weight: .medium))
            .foregroundColor(Color(hex: "#C9DFFF"))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(hex: "#5EA2FF").opacity(0.12))
            .clipShape(Capsule())
            .overlay(Capsule().stroke(Color(hex: "#5EA2FF").opacity(0.24), lineWidth: 1))
        }
        .menuStyle(.borderlessButton)
        .disabled(options.isEmpty)
        .fixedSize()
    }

    private func selectInitialModel() {
        guard selectedModelID.isEmpty, let model = models.first else { return }
        selectedModelID = model.id
        selectDefaultEffort()
    }

    private func selectDefaultEffort() {
        guard let model = selectedModel else {
            selectedEffortID = ""
            return
        }
        let preferred = model.metadata["defaultReasoningEffort"]
        selectedEffortID = model.reasoningOptions.contains(where: { $0.id == preferred })
            ? (preferred ?? "")
            : (model.reasoningOptions.first?.id ?? "")
    }

    private func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.message = "Choose the project Codex should work in"
        panel.prompt = "Choose project"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK {
            workspaceURL = panel.url
        }
    }

    private func startSession() {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canStart else { return }
        isStarting = true
        promptFocused = false
        let selection = ModelSelection(
            modelID: selectedModelID,
            reasoningOptionID: selectedEffortID.isEmpty ? nil : selectedEffortID
        )
        Task {
            do {
                let session = try await runtimeManager.startSession(
                    runtimeID: .codex,
                    request: StartAgentSessionRequest(
                        workspace: workspaceURL,
                        prompt: trimmedPrompt,
                        model: selection,
                        metadata: [:]
                    )
                )
                state.selectAgentSession(session.id)
                state.isPinned = false
                state.view = .overview
            } catch {
                isStarting = false
                state.noteMessage = error.localizedDescription
                state.view = .note
            }
        }
    }
}

// MARK: - Running agent conversation

struct AgentSessionView: View {
    private static let conversationBottomID = "agent-conversation-bottom"

    @ObservedObject var state: AppState
    @ObservedObject private var runtimeManager = AppState.shared.agentRuntimeManager
    @State private var prompt = ""
    @State private var errorMessage: String?
    @State private var isSending = false
    @FocusState private var promptFocused: Bool

    private var sessions: [AgentSession] {
        runtimeManager.sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private var session: AgentSession? {
        guard let id = state.selectedAgentSessionID else { return sessions.first }
        return runtimeManager.sessions[id]
    }

    private var messages: [AgentConversationMessage] {
        guard let id = session?.id else { return [] }
        return runtimeManager.conversations[id] ?? []
    }

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(spacing: 8) {
                header
                Divider().overlay(Color.white.opacity(0.07))
                conversation
                composer
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
        }
        .task(id: conversationLoadID) {
            guard state.view == .agentSession,
                  let id = session?.id,
                  session?.runtime == .codex else { return }
            promptFocused = true
            await Task.yield()
            do {
                try await runtimeManager.loadConversation(sessionID: id)
                errorMessage = nil
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    private var conversationLoadID: String {
        "\(state.view.rawValue):\(session?.id ?? "none")"
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button {
                state.view = state.tasks.isEmpty ? .empty : .overview
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Back to overview")

            Menu {
                ForEach(sessions) { item in
                    Button {
                        state.selectAgentSession(item.id)
                    } label: {
                        Text("\(item.workspace?.lastPathComponent ?? item.runtime.displayName) · \(item.runtime.displayName)")
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(session?.state.statusColor ?? Color(hex: "#727781"))
                        .frame(width: 7, height: 7)
                    Text(session?.displayTitle ?? "Choose a session")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color(hex: "#F5F6F8"))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(Color(hex: "#727781"))
                }
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 280, alignment: .leading)

            if let session {
                Text(session.runtime.displayName)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                Text(session.state.displayLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(session.state.statusColor)
            }
            Spacer()
            if session?.runtime == .codex {
                Button("New") { state.view = .agentPrompt }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#8EBBFF"))
                    .buttonStyle(.plain)
            }
        }
        .frame(height: 22)
    }

    @ViewBuilder
    private var conversation: some View {
        if let session {
            if runtimeManager.conversationLoading.contains(session.id) && messages.isEmpty {
                VStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading conversation…")
                        .font(.system(size: 11))
                        .foregroundColor(Color(hex: "#727781"))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                VStack(spacing: 6) {
                    Text(session.latestActivity?.title ?? "No conversation loaded yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Color(hex: "#B0B5BE"))
                        .lineLimit(2)
                    Text(errorMessage ?? emptyMessage(for: session))
                        .font(.system(size: 11))
                        .foregroundColor(errorMessage == nil ? Color(hex: "#727781") : Color(hex: "#FF8D97"))
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollViewReader { proxy in
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView(.vertical, showsIndicators: false) {
                            LazyVStack(alignment: .leading, spacing: 8) {
                                ForEach(messages) { message in
                                    AgentConversationBubble(message: message)
                                        .id(message.id)
                                }
                                if session.state == .working {
                                    HStack(spacing: 6) {
                                        TypingDotsView()
                                        Text("Codex is working")
                                            .font(.system(size: 10.5))
                                            .foregroundColor(Color(hex: "#727781"))
                                    }
                                }
                                Color.clear
                                    .frame(height: 1)
                                    .id(Self.conversationBottomID)
                            }
                            .padding(.vertical, 2)
                        }
                        .defaultScrollAnchor(.bottom)

                        Button {
                            scrollToBottom(proxy)
                        } label: {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundColor(Color(hex: "#D6D9DE"))
                                .frame(width: 24, height: 24)
                                .background(Color.black.opacity(0.78))
                                .clipShape(Circle())
                                .overlay {
                                    Circle().stroke(Color.white.opacity(0.12), lineWidth: 1)
                                }
                        }
                        .buttonStyle(.plain)
                        .help("Jump to latest message")
                        .padding(.trailing, 4)
                        .padding(.bottom, 4)
                    }
                    .onAppear { scrollToBottom(proxy, animated: false) }
                    .onChange(of: messages.count) { _, _ in scrollToBottom(proxy) }
                    .onChange(of: session.state) { _, _ in scrollToBottom(proxy) }
                }
            }
        } else {
            VStack(spacing: 6) {
                Text("No active sessions")
                    .font(.system(size: 13, weight: .semibold))
                Text("Start a Codex session to follow its work here.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#727781"))
                Button("Start session") { state.view = .agentPrompt }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#8EBBFF"))
                    .buttonStyle(.plain)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private var composer: some View {
        if let session, session.runtime == .codex {
            HStack(spacing: 8) {
                TextField("Continue this Codex chat…", text: $prompt)
                    .textFieldStyle(.plain)
                    .font(.system(size: 12.5))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .tint(Color(hex: "#8EBBFF"))
                    .focused($promptFocused)
                    .onSubmit { send() }
                if session.state == .working {
                    Button {
                        Task { try? await runtimeManager.interrupt(sessionID: session.id) }
                    } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundColor(Color(hex: "#F17882"))
                    }
                    .buttonStyle(.plain)
                } else {
                    Button(action: send) {
                        Image(systemName: isSending ? "ellipsis" : "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(!canSend)
                    .opacity(canSend ? 1 : 0.45)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color.white.opacity(0.07))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else if session != nil {
            Text("This runtime is observation-only in Coucou.")
                .font(.system(size: 10.5))
                .foregroundColor(Color(hex: "#727781"))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
        }
    }

    private var canSend: Bool {
        !isSending && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func emptyMessage(for session: AgentSession) -> String {
        session.runtime == .codex
            ? "Type below to continue this chat."
            : "Coucou can show this runtime's status, but its chat protocol is not available."
    }

    private func send() {
        guard let session, canSend else { return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        prompt = ""
        isSending = true
        errorMessage = nil
        Task {
            do {
                try await runtimeManager.sendPrompt(sessionID: session.id, prompt: text)
            } catch {
                errorMessage = error.localizedDescription
                prompt = text
            }
            isSending = false
            promptFocused = true
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy, animated: Bool = true) {
        DispatchQueue.main.async {
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(Self.conversationBottomID, anchor: .bottom)
                }
            } else {
                proxy.scrollTo(Self.conversationBottomID, anchor: .bottom)
            }
        }
    }
}

private struct AgentConversationBubble: View {
    let message: AgentConversationMessage

    var body: some View {
        HStack(alignment: .top) {
            if message.role == .user { Spacer(minLength: 72) }
            Text(message.content)
                .font(.system(size: 11.5))
                .foregroundColor(message.role == .user ? Color(hex: "#F1F2F4") : Color(hex: "#BEC2C9"))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, message.role == .user ? 10 : 0)
                .padding(.vertical, message.role == .user ? 6 : 2)
                .background(message.role == .user ? Color.white.opacity(0.11) : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            if message.role != .user { Spacer(minLength: 28) }
        }
        .frame(maxWidth: .infinity)
    }
}

private extension AgentRuntimeID {
    var displayName: String {
        switch self {
        case .claudeCode: "Claude Code"
        case .codex: "Codex"
        case .geminiCLI: "Gemini CLI"
        case .antigravity: "Antigravity"
        }
    }
}

private extension AgentSessionState {
    var displayLabel: String {
        switch self {
        case .starting: "Starting"
        case .idle: "Idle"
        case .working: "Working"
        case .waitingForApproval: "Approval"
        case .waitingForUser: "Needs input"
        case .completed: "Completed"
        case .failed: "Failed"
        case .cancelled: "Stopped"
        case .disconnected: "Saved"
        }
    }

    var statusColor: Color {
        switch self {
        case .working, .starting: Color(hex: "#5EA2FF")
        case .waitingForApproval: Color(hex: "#F5A524")
        case .waitingForUser: Color(hex: "#36CFC9")
        case .completed: Color(hex: "#22C55E")
        case .failed: Color(hex: "#F4505E")
        case .cancelled, .idle, .disconnected: Color(hex: "#727781")
        }
    }
}

// MARK: - Vercel Deployment List View

struct VercelDeploymentListView: View {
    let deployments: [VercelDeployment]
    let onOpenDetail: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: "#7C5CFF"))
                    .frame(width: 7, height: 7)
                Text("Vercel")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("Deployments")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Deployment rows
            VStack(alignment: .leading, spacing: 3) {
                // First deployment — highlighted, with detail button
                if let first = deployments.first {
                    let accent = Color(hex: first.isSuccess ? "#22C55E" : "#F4505E")
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(first.projectName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#C5C8CD"))
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                        Text(first.timeAgo)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                        Button(action: onOpenDetail) {
                            Image(systemName: "ellipsis")
                                .font(.system(size: 8, weight: .medium))
                                .foregroundColor(Color(hex: "#6B7079"))
                                .frame(width: 18, height: 18)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                // Remaining deployments — plain rows, identical structure → perfect alignment
                ForEach(Array(deployments.dropFirst().prefix(2))) { dep in
                    let accent = Color(hex: dep.isSuccess ? "#22C55E" : "#F4505E")
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(dep.projectName)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#9398A1"))
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                        Text(dep.timeAgo)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 5)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

// MARK: - Vercel Deployment Detail View

struct VercelDetailView: View {
    let deployment: VercelDeployment
    let onClose: () -> Void

    private var accent: Color { Color(hex: deployment.isSuccess ? "#22C55E" : "#F4505E") }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header
            HStack(spacing: 7) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Circle().fill(accent).frame(width: 6, height: 6)
                Text(deployment.projectName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                Spacer(minLength: 2)
                Text(deployment.statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(accent.opacity(0.14))
                    .clipShape(Capsule())
            }

            // Details
            VStack(alignment: .leading, spacing: 4) {
                if let commit = deployment.commitMessage {
                    Text(commit)
                        .font(.system(size: 10.5))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    if let branch = deployment.branch {
                        Label(branch, systemImage: "arrow.branch")
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    Text(deployment.timeAgo + " ago")
                        .font(.system(size: 10))
                        .foregroundColor(Color(hex: "#6B7079"))
                }
                Button(action: {
                    if let url = URL(string: "https://\(deployment.url)") {
                        NSWorkspace.shared.open(url)
                    }
                }) {
                    Text(deployment.url)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundColor(Color(hex: "#7C5CFF").opacity(0.85))
                        .lineLimit(1).truncationMode(.middle)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 8)
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())
    }
}

// MARK: - Resend Card View

struct ResendPulseDot: View {
    @State private var on = false
    var body: some View {
        Circle()
            .fill(Color(hex: "#22C55E"))
            .frame(width: 4, height: 4)
            .opacity(on ? 1 : 0.2)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) { on = true }
            }
    }
}

struct ResendCardView: View {
    let emails: [ResendEmail]
    let total: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: "#22C55E"))
                    .frame(width: 7, height: 7)
                Text("Resend")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("Emails")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
                if let total {
                    ResendPulseDot()
                    Text("\(total)")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                        .monospacedDigit()
                }
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Email rows — first is highlighted, rest plain (same structure as Vercel list)
            VStack(alignment: .leading, spacing: 3) {
                if let first = emails.first {
                    let accent = Color(hex: first.isDelivered ? "#22C55E" : "#F4505E")
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(first.recipientShort)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#C5C8CD"))
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                        Text(first.timeAgo)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                        if !first.subject.isEmpty {
                            Text(first.subject)
                                .font(.system(size: 10))
                                .foregroundColor(Color(hex: "#4D5159"))
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(accent.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                }

                ForEach(Array(emails.dropFirst().prefix(2))) { email in
                    let accent = Color(hex: email.isDelivered ? "#22C55E" : "#F4505E")
                    HStack(spacing: 5) {
                        Circle().fill(accent).frame(width: 5, height: 5)
                        Text(email.recipientShort)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(Color(hex: "#9398A1"))
                            .lineLimit(1).truncationMode(.tail)
                            .layoutPriority(1)
                        Text(email.timeAgo)
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#6B7079"))
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.top, 5)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }
}

// MARK: - GitHub Stats Card View

struct GitHubStatsCardView: View {
    let stats: GitHubStats

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: "#F4505E"))
                    .frame(width: 7, height: 7)
                Text("GitHub")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("Overview")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Stats rows
            VStack(alignment: .leading, spacing: 5) {
                StatRow(icon: "star.fill", color: "#F5A524",
                        label: "Total stars", value: formatCount(stats.totalStars))
                StatRow(icon: "square.stack.fill", color: "#6B7079",
                        label: "Repositories", value: "\(stats.totalRepos)")
            }
            .padding(.top, 8)
            .padding(.leading, 108)
            .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private func formatCount(_ n: Int) -> String {
        if n >= 1000 { return String(format: "%.1fk", Double(n) / 1000) }
        return "\(n)"
    }
}

private struct StatRow: View {
    let icon: String
    let color: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: color))
                .frame(width: 14)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#6B7079"))
            Spacer()
            Text(value)
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Stripe Card View

struct StripeCardView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(hex: "#0570DE"))
                    .frame(width: 7, height: 7)
                Text("Stripe")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                Text("Payments")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6)
            .padding(.leading, 108)
            .padding(.trailing, 36)

            // Balance
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(balanceFormatted)
                    .font(.system(size: 20, weight: .bold, design: .monospaced))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .contentTransition(.numericText(countsDown: false))
                    .animation(.easeOut(duration: 1.2), value: appState.stripeDisplayBalance)
                Text(appState.stripeCurrency.uppercased())
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .padding(.bottom, 1)
            }
            .padding(.leading, 108)
            .padding(.top, 4)

            // Payment rows (animated list)
            VStack(alignment: .leading, spacing: 2) {
                ForEach(appState.stripePayments) { payment in
                    StripePaymentRow(payment: payment)
                        .transition(.asymmetric(
                            insertion: .move(edge: .top).combined(with: .opacity),
                            removal:   .move(edge: .bottom).combined(with: .opacity)
                        ))
                }
            }
            .animation(.spring(response: 0.38, dampingFraction: 0.82),
                        value: appState.stripePayments.map(\.id))
            .padding(.leading, 108)
            .padding(.trailing, 12)
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(.top, 4)
    }

    private var balanceFormatted: String {
        String(format: "%.2f", Double(appState.stripeDisplayBalance) / 100.0)
    }
}

private struct StripePaymentRow: View {
    let payment: StripePayment

    var body: some View {
        let accent = payment.isSuccess ? Color(hex: "#22C55E") : Color(hex: "#F4505E")
        HStack(spacing: 5) {
            Circle().fill(accent).frame(width: 5, height: 5)
            Text(payment.description ?? "Payment")
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#C5C8CD"))
                .lineLimit(1).truncationMode(.tail)
                .layoutPriority(1)
            Spacer(minLength: 4)
            Text("+\(payment.amountFormatted)")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(Color(hex: "#22C55E"))
                .fixedSize()
            Text(payment.timeAgo)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#6B7079"))
                .fixedSize()
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Cal.com Card View

struct CalcomCardView: View {
    @ObservedObject private var appState = AppState.shared
    @State private var selectedDate: Date? = nil
    @State private var selectedBooking: CalcomBooking? = nil
    @State private var displayMonth: Date = Date()
    @State private var displayHalf: Int = 1  // 1 = first half, 2 = second half

    var body: some View {
        Group {
            if let booking = selectedBooking {
                CalcomBookingDetailView(booking: booking) {
                    withAnimation(.easeOut(duration: 0.2)) { selectedBooking = nil }
                }
            } else if let date = selectedDate {
                CalcomDayView(
                    date: date,
                    bookings: bookingsFor(date),
                    onSelect: { b in withAnimation(.easeOut(duration: 0.2)) { selectedBooking = b } },
                    onBack:   { withAnimation(.easeOut(duration: 0.2)) { selectedDate = nil } }
                )
            } else {
                CalcomCalendarView(
                    displayMonth: $displayMonth,
                    displayHalf: $displayHalf,
                    bookings: appState.calcomBookings,
                    onSelect: { d in withAnimation(.easeOut(duration: 0.2)) { selectedDate = d } }
                )
            }
        }
        .onChange(of: appState.focusId) { _, _ in
            selectedDate = nil; selectedBooking = nil; displayHalf = 1
        }
    }

    private func bookingsFor(_ date: Date) -> [CalcomBooking] {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        let key = "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
        return appState.calcomBookings.filter { $0.dayKey == key }
                                      .sorted { $0.startTime < $1.startTime }
    }
}

struct CalcomCalendarView: View {
    @Binding var displayMonth: Date
    @Binding var displayHalf: Int
    let bookings: [CalcomBooking]
    let onSelect: (Date) -> Void

    private let cal = Calendar.current

    private var navLabel: String {
        let f = DateFormatter(); f.dateFormat = "MMMM yyyy"
        return "\(f.string(from: displayMonth)) Q\(displayHalf)"
    }

    // 7 consecutive days per row, day 1 always at far left — no weekday alignment
    private var allWeeks: [[Date?]] {
        let comps = cal.dateComponents([.year, .month], from: displayMonth)
        let monthStart = cal.date(from: comps)!
        let daysInMonth = cal.range(of: .day, in: .month, for: displayMonth)!.count
        var result: [[Date?]] = []
        var chunk: [Date?] = []
        for i in 0..<daysInMonth {
            chunk.append(cal.date(byAdding: .day, value: i, to: monthStart)!)
            if chunk.count == 7 { result.append(chunk); chunk = [] }
        }
        if !chunk.isEmpty {
            while chunk.count < 7 { chunk.append(nil) }
            result.append(chunk)
        }
        return result
    }

    // Visible weeks for current half
    private var visibleWeeks: [[Date?]] {
        let all = allWeeks
        let splitAt = 2  // always 2 weeks per Q
        return displayHalf == 1 ? Array(all[0..<splitAt]) : Array(all[splitAt...])
    }

    private func hasBookings(_ d: Date) -> Bool {
        let c = cal.dateComponents([.year, .month, .day], from: d)
        let key = "\(c.year!)-\(String(format: "%02d", c.month!))-\(String(format: "%02d", c.day!))"
        return bookings.contains { $0.dayKey == key }
    }

    private func goBack() {
        if displayHalf == 1 {
            displayMonth = cal.date(byAdding: .month, value: -1, to: displayMonth) ?? displayMonth
            displayHalf = 2
        } else {
            displayHalf = 1
        }
    }

    private func goForward() {
        if displayHalf == 1 {
            displayHalf = 2
        } else {
            displayMonth = cal.date(byAdding: .month, value: 1, to: displayMonth) ?? displayMonth
            displayHalf = 1
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#C9956A")).frame(width: 7, height: 7)
                Text("Cal.com").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text("Schedule").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            HStack(spacing: 0) {
                Button { goBack() } label: {
                    Image(systemName: "chevron.left").font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079")).frame(width: 18, height: 16)
                }.buttonStyle(.plain)
                Text(navLabel).font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color(hex: "#C5C8CD")).frame(maxWidth: .infinity)
                Button { goForward() } label: {
                    Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079")).frame(width: 18, height: 16)
                }.buttonStyle(.plain)
            }
            .padding(.leading, 108).padding(.trailing, 12).padding(.top, 2)

            VStack(spacing: 1) {
                ForEach(visibleWeeks.indices, id: \.self) { i in
                    CalcomWeekRow(week: visibleWeeks[i], hasBookings: hasBookings,
                                  isToday: cal.isDateInToday, onSelect: onSelect)
                }
            }
            .padding(.leading, 108).padding(.trailing, 12).padding(.top, 2)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
        .transition(.opacity)
    }
}

private struct CalcomWeekRow: View {
    let week: [Date?]
    let hasBookings: (Date) -> Bool
    let isToday: (Date) -> Bool
    let onSelect: (Date) -> Void

    private var weekLabel: String {
        guard let first = week.compactMap({ $0 }).first else { return "" }
        let f = DateFormatter(); f.dateFormat = "dd/MM"
        return f.string(from: first)
    }

    var body: some View {
        HStack(spacing: 0) {
            Text(weekLabel).font(.system(size: 7)).foregroundColor(Color(hex: "#4B5563"))
                .frame(width: 26, alignment: .leading)
            ForEach(0..<7, id: \.self) { i in
                if let day = week[i] {
                    CalcomDayCell(day: day, hasEvents: hasBookings(day), isToday: isToday(day))
                        .contentShape(Rectangle()).onTapGesture { onSelect(day) }.frame(maxWidth: .infinity)
                } else {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 18)
                }
            }
        }
    }
}

private struct CalcomDayCell: View {
    let day: Date
    let hasEvents: Bool
    let isToday: Bool
    var body: some View {
        VStack(spacing: 1) {
            Text("\(Calendar.current.component(.day, from: day))")
                .font(.system(size: 9, weight: isToday ? .bold : .regular))
                .foregroundColor(isToday ? .white : Color(hex: "#9398A1"))
                .frame(width: 13, height: 13)
                .background(isToday ? Color(hex: "#C9956A").opacity(0.55) : Color.clear)
                .clipShape(Circle())
            Circle().fill(hasEvents ? Color(hex: "#C9956A") : Color.clear).frame(width: 3, height: 3)
        }
        .frame(height: 18)
    }
}

struct CalcomDayView: View {
    let date: Date
    let bookings: [CalcomBooking]
    let onSelect: (CalcomBooking) -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079")).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.leading, 108)
                Text(dayLabel).font(.system(size: 11, weight: .semibold)).foregroundColor(Color(hex: "#C5C8CD"))
                Spacer()
            }
            .padding(.top, 6).padding(.trailing, 12)

            if bookings.isEmpty {
                Text("No calls scheduled").font(.system(size: 11)).foregroundColor(Color(hex: "#6B7079"))
                    .padding(.leading, 116).padding(.top, 8)
            } else {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(bookings) { b in
                        Button { onSelect(b) } label: {
                            HStack(spacing: 6) {
                                Circle().fill(Color(hex: "#C9956A")).frame(width: 4, height: 4)
                                Text(b.timeLabel)
                                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                                    .foregroundColor(Color(hex: "#C9956A")).fixedSize()
                                Text(b.title).font(.system(size: 11)).foregroundColor(Color(hex: "#C5C8CD"))
                                    .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                                Spacer(minLength: 2)
                                Image(systemName: "chevron.right").font(.system(size: 8))
                                    .foregroundColor(Color(hex: "#4B5563"))
                            }
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color(hex: "#C9956A").opacity(0.06))
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.leading, 108).padding(.trailing, 12).padding(.top, 5)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
        .transition(.opacity)
    }
    private var dayLabel: String {
        let f = DateFormatter(); f.dateFormat = "EEEE d MMMM"; return f.string(from: date)
    }
}

struct CalcomBookingDetailView: View {
    let booking: CalcomBooking
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left").font(.system(size: 9, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079")).frame(width: 22, height: 22).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.leading, 108)
                Text(booking.timeLabel)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#C9956A"))
                Spacer()
            }
            .padding(.top, 6).padding(.trailing, 12)

            VStack(alignment: .leading, spacing: 4) {
                Text(booking.title).font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8")).lineLimit(1)
                if let name = booking.attendeeName, !name.isEmpty {
                    CalcomDetailRow(icon: "person.fill", text: name, size: 11)
                }
                if let email = booking.attendeeEmail, !email.isEmpty {
                    CalcomDetailRow(icon: "envelope.fill", text: email, size: 10, truncate: true)
                }
                if let notes = booking.attendeeNotes, !notes.isEmpty {
                    CalcomDetailRow(icon: "note.text", text: notes, size: 10, lines: 2)
                }
            }
            .padding(.leading, 114).padding(.trailing, 12).padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
        .transition(.opacity)
    }
}

private struct CalcomDetailRow: View {
    let icon: String
    let text: String
    var size: CGFloat = 11
    var truncate: Bool = false
    var lines: Int = 1
    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Image(systemName: icon).font(.system(size: 9)).foregroundColor(Color(hex: "#6B7079")).frame(width: 10)
            Text(text).font(.system(size: size)).foregroundColor(Color(hex: "#9398A1"))
                .lineLimit(lines).truncationMode(truncate ? .middle : .tail)
        }
    }
}

// MARK: - Notion Card View

struct NotionCardView: View {
    @ObservedObject private var appState = AppState.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Circle().fill(Color(hex: "#E8E8E8")).frame(width: 7, height: 7)
                Text("Notion").font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
                Text("Recent").font(.system(size: 11)).foregroundColor(Color(hex: "#8E939C"))
            }
            .padding(.top, 6).padding(.leading, 108).padding(.trailing, 36)

            VStack(alignment: .leading, spacing: 2) {
                ForEach(appState.notionPages.prefix(3)) { page in
                    Button {
                        if let url = safeWebURL(page.url) { NSWorkspace.shared.open(url) }
                    } label: {
                        HStack(spacing: 6) {
                            if let emoji = page.emoji {
                                Text(emoji).font(.system(size: 10)).frame(width: 14)
                            } else {
                                Image(systemName: "doc.text").font(.system(size: 9))
                                    .foregroundColor(Color(hex: "#6B7079")).frame(width: 14)
                            }
                            Text(page.title).font(.system(size: 11))
                                .foregroundColor(Color(hex: "#C5C8CD"))
                                .lineLimit(1).truncationMode(.tail).layoutPriority(1)
                            Spacer(minLength: 4)
                            Text(page.timeAgo).font(.system(size: 9))
                                .foregroundColor(Color(hex: "#4B5563"))
                        }
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 102).padding(.trailing, 12).padding(.top, 5)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading).padding(.top, 4)
        .transition(.opacity)
    }
}

// MARK: - n8n Execution Detail View

struct N8nDetailView: View {
    let task: AgentTask
    let onClose: () -> Void

    private var success: Bool  { task.state == .finished }
    private var accent: Color  { success ? Color(hex: "#22C55E") : Color(hex: "#F4505E") }
    private var statusLabel: String { success ? "Success" : "Failed" }
    private var detail: String? { task.steps.dropFirst().first }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {

            // Header: back button + workflow name + status badge
            HStack(spacing: 7) {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(Color(hex: "#6B7079"))
                        .frame(width: 28, height: 28)   // large hit area
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                Circle().fill(accent).frame(width: 6, height: 6)

                Text(task.steps.first ?? "Workflow")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color(hex: "#F5F6F8"))
                    .lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)

                Spacer(minLength: 2)

                Text(statusLabel)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(accent)
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(accent.opacity(0.14))
                    .clipShape(Capsule())
            }

            // Detail body — monospaced, selectable
            if let detail {
                ScrollView(.vertical, showsIndicators: false) {
                    Text(detail)
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundColor(Color(hex: "#9398A1"))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .lineSpacing(2)
                        .textSelection(.enabled)
                }
                .frame(maxHeight: 88)
            } else {
                Text(success ? "Completed successfully." : "No error details available.")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: "#6B7079"))
            }
        }
        .padding(.top, 8)
        .padding(.leading, 108)
        .padding(.trailing, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .contentShape(Rectangle())   // prevent taps falling through transparent areas
    }
}

// MARK: - Ticker (overview scrolling task steps) V2

struct TickerView: View {
    let task: AgentTask?

    @State private var rowA: String = "…"   // completed (above, left-shifted)
    @State private var rowB: String = "…"   // current (below) → animates diagonally up-left
    @State private var rowC: String = ""    // incoming current — slides in from below

    @State private var rowAOffset: CGFloat = 0
    @State private var rowAOpacity: Double = 1
    @State private var rowBOffset: CGFloat = 22
    @State private var rowBPhase:  Double  = 0   // 0=current, 1=completed (drives X+scale)
    @State private var rowCOffset: CGFloat = 44
    @State private var rowCOpacity: Double = 0

    @State private var displayIndex: Int = -1
    @State private var isTransitioning = false

    private let completedScale: CGFloat = 11.5 / 13   // 0.885 — matches completed font size

    var steps: [String] {
        let raw = task?.steps ?? []
        return raw.isEmpty ? ["…"] : raw
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear

            // Row A: completed row — always rendered at phase=1 + completedScale
            TickerRowView(text: rowA, phase: 1.0)
                .scaleEffect(completedScale, anchor: .leading)
                .offset(x: -10, y: rowAOffset)
                .opacity(rowAOpacity)

            // Row B: current step → animates diagonally up-left, phase 0→1, scale 1→completedScale
            TickerRowView(text: rowB, phase: rowBPhase)
                .scaleEffect(1 - rowBPhase * (1 - completedScale), anchor: .leading)
                .offset(x: -rowBPhase * 10, y: rowBOffset)

            // Row C: incoming new step — slides in from below at phase=0
            TickerRowView(text: rowC, phase: 0.0)
                .offset(y: rowCOffset)
                .opacity(rowCOpacity)
        }
        .frame(height: 44)
        .clipped()
        .mask(LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: .black, location: 0.12),
                .init(color: .black, location: 0.85),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top, endPoint: .bottom
        ))
        .onAppear {
            let idx = task?.stepIndex ?? -1
            displayIndex = idx
            if idx >= 0, !steps.isEmpty {
                rowA = idx > 0 ? steps[max(0, idx - 1)] : "…"
                rowB = steps[min(idx, steps.count - 1)]
            }
        }
        .onChange(of: task?.steps.count) { _, _ in
            guard let task, !task.steps.isEmpty, !isTransitioning else { return }
            let newIdx = task.stepIndex
            if displayIndex < 0 {
                displayIndex = newIdx
                rowA = newIdx > 0 ? steps[max(0, newIdx - 1)] : "…"
                rowB = steps[min(newIdx, steps.count - 1)]
                return
            }
            guard newIdx != displayIndex else { return }
            tickerAnimate(to: newIdx)
        }
    }

    private func tickerAnimate(to newIdx: Int) {
        isTransitioning = true
        rowC = steps[min(newIdx, steps.count - 1)]
        rowCOffset = 44
        rowCOpacity = 0

        // Old completed (rowA): fades + slides further up
        withAnimation(.easeOut(duration: 0.28)) {
            rowAOffset  = -22
            rowAOpacity = 0
        }

        // Current (rowB): moves diagonally up-left + shrinks to completed size
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowBOffset = 0
            rowBPhase  = 1
        }

        // New current (rowC): slides in from below
        withAnimation(.timingCurve(0.4, 0, 0.2, 1, duration: 0.38)) {
            rowCOffset  = 22
            rowCOpacity = 1
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.50) {
            self.displayIndex    = newIdx
            self.rowA            = self.rowB
            self.rowAOffset      = 0
            self.rowAOpacity     = 1
            self.rowB            = self.rowC
            self.rowBOffset      = 22
            self.rowBPhase       = 0
            self.rowCOffset      = 44
            self.rowCOpacity     = 0
            self.isTransitioning = false
        }
    }
}

struct TickerRowView: View {
    let text: String
    let phase: Double   // 0 = current (shimmer, large), 1 = completed (dim, scaled down by caller)

    var body: some View {
        HStack(spacing: 6) {
            // Icon: chevron fades out first half, checkmark fades in second half
            ZStack {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .opacity(max(0, 1 - phase * 2))
                Image(systemName: "checkmark")
                    .font(.system(size: 8, weight: .regular))
                    .foregroundColor(Color(hex: "#454850"))
                    .opacity(max(0, phase * 2 - 1))
            }
            .frame(width: 12, alignment: .center)

            // Text: shimmer fades out, dim completed text fades in (overlapping cross-fade)
            ZStack(alignment: .leading) {
                TickerShimmerText(text: text)
                    .opacity(max(0, 1 - phase * 1.6))
                Text(text)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundColor(Color(hex: "#6B7079"))
                    .lineLimit(1).truncationMode(.tail)
                    .opacity(min(1, max(0, phase * 2 - 0.4)))
            }
        }
        .frame(height: 22, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct TickerShimmerText: View {
    let text: String

    var body: some View {
        TimelineView(.animation) { tl in
            let t = tl.date.timeIntervalSinceReferenceDate
            let p = CGFloat(t.truncatingRemainder(dividingBy: 2.2) / 2.2)
            // phase sweeps -0.1 → 1.1 so white peak enters from left and exits right
            let phase = p * 1.2 - 0.1
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
                .truncationMode(.tail)
                .foregroundStyle(LinearGradient(stops: [
                    .init(color: Color(hex: "#7c818a"), location: max(0, phase - 0.3)),
                    .init(color: Color(hex: "#F2F3F5"), location: max(0, min(1, phase))),
                    .init(color: Color(hex: "#7c818a"), location: min(1, phase + 0.3)),
                ], startPoint: .leading, endPoint: .trailing))
        }
    }
}

// MARK: - Agent pills (overview right card)

struct AgentPillsView: View {
    @ObservedObject var state: AppState
    @State private var swapping = false

    private var others: [AgentTask] {
        state.tasks
            .filter { $0.id != state.focusId }
            .sorted { taskPriority($0) < taskPriority($1) }
    }

    private var displayTasks: [AgentTask] {
        Array(others.prefix(4))
    }

    private let columns = [
        GridItem(.flexible(), spacing: 4),
        GridItem(.flexible(), spacing: 4)
    ]

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            LazyVGrid(columns: columns, spacing: 4) {
                ForEach(displayTasks) { task in
                    AgentPill(task: task, state: state, swapping: $swapping) {
                        swapping = true
                        if let sessionID = task.agentSessionID {
                            state.selectAgentSession(sessionID)
                            state.view = .agentSession
                        } else {
                            state.setFocus(task.id)
                        }
                        SoundEngine.shared.play("blip")
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { swapping = false }
                    }
                }
            }
            .padding(.horizontal, 8)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func taskPriority(_ task: AgentTask) -> Int {
        if task.pillBadge != nil { return 0 }
        if task.agentSessionID != nil && task.state != .idle { return 1 }
        if task.agentSessionID != nil { return 2 }
        return 3
    }
}

struct AgentPill: View {
    let task: AgentTask
    @ObservedObject var state: AppState
    @Binding var swapping: Bool
    let onTap: () -> Void
    @State private var isHovered = false

    // Idle runtimes use their product name; active sessions use the project name.
    private var displayName: String {
        task.name
    }

    var body: some View {
        Button(action: { onTap() }) {
            ZStack(alignment: .topTrailing) {
                ZStack {
                    Capsule()
                        .fill(isHovered
                              ? Color(hex: task.color).opacity(0.18)
                              : Color(hex: "#0E0F11"))
                    Capsule()
                        .stroke(Color(hex: task.color).opacity(isHovered ? 0.55 : 0.14), lineWidth: 1)
                    HStack(spacing: 6) {
                        MiniBotCanvasView(task: task)
                            .frame(width: 22 / 0.6, height: 22 / 0.6)
                            .frame(width: 22, height: 22, alignment: .center)
                            .fixedSize()
                        Text(displayName)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundColor(isHovered
                                             ? Color(hex: task.color).lighter(by: 0.3)
                                             : Color(hex: "#6B7079"))
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .layoutPriority(1)
                        if task.agentSessionID != nil {
                            Image(systemName: "terminal.fill")
                                .font(.system(size: 6.5, weight: .semibold))
                                .foregroundColor(Color(hex: task.color).opacity(0.6))
                                .fixedSize()
                        }
                    }
                    .padding(.horizontal, 7)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 28)
                .shadow(color: Color(hex: task.color).opacity(isHovered ? 0.35 : 0), radius: 10, x: 0, y: 2)

                // Alert badge (approval / finished / error)
                if let badge = task.pillBadge {
                    PillBadgeView(badge: badge, taskColor: task.color)
                        .offset(x: 3, y: -3)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(displayName), \(task.source.runtimeLabel), \(task.state.rawValue)")
        .help(displayName)
        .scaleEffect(isHovered ? 1.04 : 1.0)
        .brightness(isHovered ? 0.06 : 0)
        .onHover { newHover in
            guard !swapping else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.7)) { isHovered = newHover }
        }
    }
}

struct PillBadgeView: View {
    let badge: PillBadge
    let taskColor: String

    private var badgeColor: Color {
        switch badge {
        case .approval: return Color(hex: "#F5A524")
        case .question: return Color(hex: "#22D3EE")
        case .finished: return Color(hex: "#22C55E")
        case .error:    return Color(hex: "#F4505E")
        }
    }

    private var icon: String {
        switch badge {
        case .approval: return "exclamationmark"
        case .question: return "questionmark"
        case .finished: return "checkmark"
        case .error:    return "xmark"
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color(hex: "#0B0C0E"))
                .frame(width: 14, height: 14)
            Circle()
                .fill(badgeColor)
                .frame(width: 12, height: 12)
            Image(systemName: icon)
                .font(.system(size: 6, weight: .bold))
                .foregroundColor(.black)
        }
        .shadow(color: badgeColor.opacity(0.6), radius: 4, x: 0, y: 0)
    }
}

// MARK: - Column agents (right side of non-overview views)

struct ColumnAgentsView: View {
    @ObservedObject var state: AppState

    var others: [AgentTask] {
        state.tasks.filter { $0.id != state.focusId }
    }

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(others.prefix(4).enumerated()), id: \.1.id) { idx, task in
                MiniBotCanvasView(task: task)
                    .frame(width: 16 / 0.6, height: 16 / 0.6)
                    .frame(width: 16, height: 16)
                    .position(x: 0, y: CGFloat(50 + idx * 24))
                    .animation(.spring(response: 0.5, dampingFraction: 0.72).delay(Double(idx) * 0.035), value: idx)
            }
        }
    }
}

// MARK: - Card background

struct CardBackground<Content: View>: View {
    enum Wash { case red, green, pink, amber, cyan, indigo, soft }

    let wash: Wash?
    let content: (() -> Content)?

    init(wash: Wash?, @ViewBuilder content: @escaping () -> Content) {
        self.wash = wash
        self.content = content
    }

    var washColor: Color {
        switch wash {
        case .red:    return Color(hex: "#F4505E").opacity(0.55)
        case .green:  return Color(hex: "#34D399").opacity(0.5)
        case .pink:   return Color(hex: "#F472B6").opacity(0.55)
        case .amber:  return Color(hex: "#F5A524").opacity(0.42)
        case .cyan:   return Color(hex: "#22D3EE").opacity(0.38)
        case .indigo: return Color(hex: "#6366F1").opacity(0.5)
        case .soft:   return Color.white.opacity(0.08)
        case nil:     return Color.clear
        }
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )

            if let content = content {
                content()
            }
        }
    }
}

extension CardBackground where Content == EmptyView {
    init(wash: Wash?) {
        self.wash = wash
        self.content = nil
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color(hex: "#141518"))
                .overlay(
                    RadialGradient(
                        gradient: Gradient(stops: [
                            .init(color: washColor, location: 0),
                            .init(color: .clear, location: 0.7)
                        ]),
                        center: UnitPoint(x: 0.5, y: 1.3),
                        startRadius: 0,
                        endRadius: 280
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 20))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 20)
                        .stroke(Color.white.opacity(0.035), lineWidth: 1)
                )
        }
    }
}

// MARK: - Shared sub-components

struct AgentWho: View {
    let task: AgentTask?
    let label: String

    var body: some View {
        HStack(spacing: 7) {
            if let task = task {
                Circle().fill(Color(hex: task.color)).frame(width: 8, height: 8)
                Text(task.name).font(.system(size: 12, weight: .semibold)).foregroundColor(Color(hex: "#F5F6F8"))
            }
            Text(label).font(.system(size: 12)).foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

struct CodeBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color.white.opacity(0.07))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.06)))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .foregroundColor(Color(hex: "#E8E9EC"))
    }
}

struct ContextChip: View {
    let context: PromptContext
    @State private var glowing = false

    var label: String {
        switch context {
        case .window(let app, _, let url):
            if let url = url, let host = URL(string: url)?.host { return "\(app) · \(host)" }
            return app
        case .file(let name, _): return name
        }
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(LinearGradient(colors: [Color(hex: "#FF6B5B"), Color(hex: "#F7B32B"), Color(hex: "#2DD4A7"), Color(hex: "#38BDF8"), Color(hex: "#A78BFA")], startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5))
                .foregroundColor(Color(hex: "#F1F2F4"))
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.white.opacity(0.1))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(Color.white.opacity(glowing ? 0.75 : 0), lineWidth: 1.5))
        .scaleEffect(glowing ? 1.06 : 1.0)
        .onAppear {
            withAnimation(.spring(response: 0.25, dampingFraction: 0.55)) { glowing = true }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                withAnimation(.easeOut(duration: 0.3)) { glowing = false }
            }
        }
    }
}

struct MailField: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#80858E"))
                .frame(width: 44, alignment: .leading)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 12.5))
                .foregroundColor(Color(hex: "#F5F6F8"))
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(Color.white.opacity(0.06))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct ShimmeringText: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .foregroundStyle(
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: "#7c818a"), location: 0),
                        .init(color: .white, location: 0.4),
                        .init(color: Color(hex: "#7c818a"), location: 0.7)
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
            )
    }
}

struct ShimmerOverlay: View {
    @State private var phase: CGFloat = 0.0

    var body: some View {
        LinearGradient(
            stops: [
                // Clamp all locations to [0,1] and keep them ordered
                .init(color: .clear,                   location: max(0, phase - 0.3)),
                .init(color: Color.white.opacity(0.6), location: max(0, min(1, phase))),
                .init(color: .clear,                   location: min(1, phase + 0.3))
            ],
            startPoint: .leading, endPoint: .trailing
        )
        .blendMode(.overlay)
        .onAppear {
            withAnimation(.linear(duration: 2.2).repeatForever(autoreverses: false)) {
                phase = 1.3  // travels left→right, exits right edge cleanly
            }
        }
    }
}

// MARK: - Button styles

struct PrimaryButton: View {
    let title: String
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.black.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color(hex: "#F5F6F8"))
            .foregroundColor(Color(hex: "#0B0C0E"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct SecondaryButton: View {
    let title: String
    let kbd: String?
    let action: () -> Void

    init(_ title: String, kbd: String? = nil, action: @escaping () -> Void) {
        self.title = title; self.kbd = kbd; self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Text(title).font(.system(size: 12.5, weight: .medium))
                if let k = kbd {
                    Text(k).font(.system(size: 10.5))
                        .padding(.horizontal, 4)
                        .overlay(RoundedRectangle(cornerRadius: 4).stroke(Color.white.opacity(0.4)))
                        .opacity(0.55)
                }
            }
            .padding(.horizontal, 13).padding(.vertical, 7)
            .background(Color.white.opacity(0.09))
            .foregroundColor(Color(hex: "#F1F2F4"))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color.white.opacity(0.08))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

struct SendButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: 28, height: 28)
            .background(Color(hex: "#F5F6F8"))
            .clipShape(Circle())
            .scaleEffect(configuration.isPressed ? 0.94 : 1)
    }
}

// MARK: - Settings island view (Point 7)

struct SettingsIslandView: View {
    @ObservedObject var state: AppState

    private var claudeConnected: Bool {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = json["hooks"] as? [String: Any],
              let ss = hooks["SessionStart"] as? [[String: Any]] else { return false }
        return ss.contains { matcher in
            (matcher["hooks"] as? [[String: Any]])?.contains {
                ($0["command"] as? String)?.contains("NotchBuddy") == true
            } ?? false
        }
    }

    private var apiConnected: Bool {
        KeychainStore.shared.get("anthropic-api-key") != nil
    }

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: nil)
            VStack(alignment: .leading, spacing: 10) {
                // Sound row
                HStack(spacing: 10) {
                    Toggle("", isOn: $state.soundEnabled)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .scaleEffect(0.75)
                        .frame(width: 44)
                    Text("Sound")
                        .font(.system(size: 12.5))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Slider(value: $state.soundVolume, in: 0...0.2)
                        .frame(width: 72)
                        .opacity(state.soundEnabled ? 1 : 0.4)
                }

                // Auto-close row
                HStack(spacing: 10) {
                    Image(systemName: "timer")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .frame(width: 16)
                    Text("Auto-close · \(Int(state.autoCloseInterval))s")
                        .font(.system(size: 12))
                        .foregroundColor(Color(hex: "#C5C8CD"))
                    Spacer()
                    HStack(spacing: 6) {
                        ForEach([10, 15, 30], id: \.self) { s in
                            Button("\(s)s") {
                                state.autoCloseInterval = Double(s)
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(state.autoCloseInterval == Double(s) ? Color(hex: "#252830") : Color.clear)
                            .foregroundColor(state.autoCloseInterval == Double(s) ? Color(hex: "#F5F6F8") : Color(hex: "#6B7079"))
                            .clipShape(Capsule())
                            .buttonStyle(.plain)
                        }
                    }
                }

                // Connection status
                HStack(spacing: 14) {
                    StatusBadge(label: "Claude Code", ok: claudeConnected)
                    StatusBadge(label: "API", ok: apiConnected)
                    Spacer()
                    Button("Settings…") {
                        NotificationCenter.default.post(name: .openFullSettings, object: nil)
                    }
                    .font(.system(size: 11.5))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .buttonStyle(.plain)
                }
            }
            .padding(.leading, 84)
            .padding(.trailing, 16)
            .padding(.vertical, 14)
        }
    }
}

struct StatusBadge: View {
    let label: String
    let ok: Bool

    var body: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(ok ? Color(hex: "#22C55E") : Color(hex: "#F4505E"))
                .frame(width: 6, height: 6)
            Text(label)
                .font(.system(size: 11))
                .foregroundColor(Color(hex: "#8E939C"))
        }
    }
}

// MARK: - Color extension (lighten)

extension Color {
    func lighter(by amount: Double) -> Color {
        guard let components = NSColor(self).usingColorSpace(.sRGB) else { return self }
        return Color(
            red: min(1, Double(components.redComponent) + amount),
            green: min(1, Double(components.greenComponent) + amount),
            blue: min(1, Double(components.blueComponent) + amount)
        )
    }
}
