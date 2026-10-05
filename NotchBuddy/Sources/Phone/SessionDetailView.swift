import SwiftUI

/// One session: what the agent is doing, its plan, and what it waits for.
struct SessionDetailView: View {
    let link: PhoneLink
    let sessionId: String

    private var session: SessionItem? { link.sessions.first { $0.id == sessionId } }
    private var turn: TurnSnapshot? { link.turns[sessionId] }

    var body: some View {
        ScrollView {
            if let session {
                VStack(alignment: .leading, spacing: 16) {
                    header(session)
                    if session.needsApproval {
                        ApprovalCard(link: link, session: session)
                    } else if !session.question.isEmpty {
                        waiting(title: "Question", text: session.question, monospaced: false, color: .cyan,
                                footnote: "Answer on your Mac for now.")
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
                    if !session.cwd.isEmpty {
                        card(title: "Folder") {
                            Text(session.cwd)
                                .font(.footnote.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(16)
            } else if let turn {
                VStack(alignment: .leading, spacing: 16) {
                    Text("This session ended on your Mac. Its last turn:")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    LastTurnView(turn: turn, working: false)
                }
                .padding(16)
            } else {
                Text("This session ended on your Mac.")
                    .foregroundStyle(.secondary)
                    .padding(40)
            }
        }
        .background(Color.black)
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await link.refresh() }
    }

    private func header(_ session: SessionItem) -> some View {
        HStack(spacing: 16) {
            MochiStill(state: session.state)
                .padding(10)
                .frame(width: 84, height: 84)
                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 22))
            VStack(alignment: .leading, spacing: 4) {
                Text("\(session.pillName) · \(session.title)")
                    .font(.headline)
                Text(session.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(session.statusColor)
                HStack(spacing: 4) {
                    if !session.macName.isEmpty {
                        Text(session.macName)
                        Text("·")
                    }
                    Text(session.updatedAt, style: .relative)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
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
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
    }
}
