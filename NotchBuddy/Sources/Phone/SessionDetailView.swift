import SwiftUI
import UIKit

/// One session: what the agent is doing, its plan, and what it waits for.
struct SessionDetailView: View {
    let link: PhoneLink
    let sessionId: String

    private var session: SessionItem? { link.sessions.first { $0.id == sessionId } }
    private var turn: TurnSnapshot? { link.turns[sessionId] }
    private var pastTurns: [TurnSnapshot] { link.archive.past[sessionId] ?? [] }
    @State private var shareImage: UIImage?

    var body: some View {
        ScrollView {
            if let session {
                VStack(alignment: .leading, spacing: 16) {
                    header(session)
                    if session.needsApproval {
                        ApprovalCard(link: link, session: session)
                            .transition(.phaseCard)
                    } else if let payload = session.questionPayload, !session.questionFingerprint.isEmpty {
                        QuestionCard(link: link, session: session, payload: payload)
                            .transition(.phaseCard)
                    } else if !session.question.isEmpty {
                        waiting(title: "Question", text: session.question, monospaced: false, color: .cyan,
                                footnote: "Answer on your Mac: this question can't be answered from the iPhone.")
                    }
                    if let turn {
                        LastTurnView(turn: turn, working: session.isWorking)
                    } else if !session.steps.isEmpty {
                        plan(session)
                    }
                    if turn == nil, !session.finalLine.isEmpty {
                        card(title: "Last message") {
                            Text(session.finalLine)
                                .font(.callout)
                                .textSelection(.enabled)
                        }
                    }
                    if !pastTurns.isEmpty { earlierTurns }
                }
                .padding(16)
                // A new phase (working, question, waiting, done) slides in instead of jumping.
                .animation(.spring(duration: 0.5, bounce: 0.2),
                           value: "\(session.state.rawValue)|\(session.statusText)|\(session.approvalFingerprint)|\(session.questionFingerprint)")
            } else if let turn {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This session ended on your Mac. Its last turn:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LastTurnView(turn: turn, working: false)
                    if !pastTurns.isEmpty { earlierTurns }
                }
                .padding(16)
            } else {
                Text("This session ended on your Mac.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        // The agent's color, moving softly behind the top of the screen.
        .background(alignment: .top) {
            ZStack {
                Color.black
                if let session {
                    AgentBackdrop(hex: PillCatalog.definition(for: session.id)?.color ?? session.color)
                        .frame(height: 360)
                        .mask(LinearGradient(colors: [.black, .black.opacity(0.5), .clear],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(maxHeight: .infinity, alignment: .top)
                }
            }
            .ignoresSafeArea()
        }
        // The composer stays at the bottom, like a chat.
        .safeAreaInset(edge: .bottom) {
            if let session, session.id == "integration_claude" || session.id == "agent_cursor" {
                InstructionComposer(link: link, session: session)
            }
        }
        // Scrolling or a tap on the conversation puts the keyboard away.
        .scrollDismissesKeyboard(.immediately)
        .simultaneousGesture(TapGesture().onEnded {
            UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        })
        // A conversation takes the whole screen, like Messages: no tabs below,
        // and the field stays put at the bottom.
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await link.refresh() }
        .toolbar {
            // The last turn as a picture, to show what Claude did.
            if let shareImage {
                ToolbarItem(placement: .topBarTrailing) {
                    ShareLink(item: Image(uiImage: shareImage),
                              preview: SharePreview(turn?.project ?? "Coucou", image: Image(uiImage: shareImage))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: turn?.endedAt) {
            guard let turn, turn.endedAt != nil else { shareImage = nil; return }
            shareImage = TurnShareCard.render(turn: turn, color: session?.color ?? "#4A86E8")
        }
    }

    /// The turns before the latest one, as this iPhone saw them.
    private var earlierTurns: some View {
        card(title: "Earlier turns") {
            VStack(spacing: 0) {
                ForEach(Array(pastTurns.enumerated()), id: \.offset) { index, past in
                    NavigationLink {
                        ScrollView {
                            LastTurnView(turn: past, working: false).padding(16)
                        }
                        .background(Color.black)
                        .navigationTitle(past.startedAt.formatted(date: .abbreviated, time: .shortened))
                        .navigationBarTitleDisplayMode(.inline)
                    } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(past.headline)
                                    .font(.callout)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text(past.startedAt, format: .dateTime.hour().minute())
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            Spacer(minLength: 6)
                            if !past.files.isEmpty {
                                Text("\(past.files.count) file\(past.files.count == 1 ? "" : "s")")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 8)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if index < pastTurns.count - 1 { Divider() }
                }
            }
        }
    }

    private func header(_ session: SessionItem) -> some View {
        HStack(spacing: 16) {
            MochiLive(state: session.state)
                .padding(10)
                .frame(width: 84, height: 84)
                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 4) {
                // "VS Code · coucou", or just "VS Code" when there's no project name.
                Text(session.title == session.pillName ? session.pillName : "\(session.pillName) · \(session.title)")
                    .font(.headline)
                Text(session.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.statusColor)
                    .contentTransition(.interpolate)
                HStack(spacing: 4) {
                    if !session.macName.isEmpty {
                        Text(session.macName)
                        Text("·")
                    }
                    Text(session.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                if !session.cwd.isEmpty {
                    Label(Self.shortPath(session.cwd), systemImage: "folder")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// "/Users/louis/Documents/hi" → "~/Documents/hi".
    static func shortPath(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count >= 2, parts[0] == "Users" {
            return "~/" + parts.dropFirst(2).joined(separator: "/")
        }
        return path
    }

    private func waiting(title: String, text: String, monospaced: Bool, color: Color, footnote: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(color)
            Text(text)
                .font(monospaced ? .callout.monospaced() : .callout)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
                .textSelection(.enabled)
            Text(footnote).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(color.opacity(0.7), lineWidth: 1.5))
    }

    private func plan(_ session: SessionItem) -> some View {
        card(title: "Activity · \(min(session.stepIndex + 1, session.steps.count))/\(session.steps.count)") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(session.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: icon(index, session))
                            .foregroundStyle(index == session.stepIndex && session.isWorking ? Color.accentColor : Color.secondary)
                            .font(.footnote)
                        Text(step)
                            .font(.callout)
                            .foregroundStyle(index > session.stepIndex ? Color.secondary : Color.primary)
                    }
                }
            }
        }
    }

    private func icon(_ index: Int, _ session: SessionItem) -> String {
        if index < session.stepIndex || session.state == .finished { return "checkmark.circle.fill" }
        if index == session.stepIndex { return "circle.dotted" }
        return "circle"
    }

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }
}

extension AnyTransition {
    /// A card that comes with a phase (an OK to give, a question): drops in from above.
    static var phaseCard: AnyTransition {
        .asymmetric(insertion: .move(edge: .top).combined(with: .opacity),
                    removal: .scale(scale: 0.95).combined(with: .opacity))
    }
}
