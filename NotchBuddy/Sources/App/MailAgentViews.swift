#if !APPSTORE
import SwiftUI

private let planBlue = Color(hex: "#2F8CFF")

/// A plan of the chat, under the answer that wrote it: what it will do, the mails it will send
/// (the ones that can't be sent in red), and Run. Nothing happens before that click.
struct MailPlanCard: View {
    let plan: MailPlan
    let messageId: UUID
    @ObservedObject private var agent = MailAgent.shared

    private var run: MailPlanRun? { agent.runs[messageId] }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "envelope.badge")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(planBlue)
                Text(plan.summary.isEmpty ? String(localized: "mail.plan.title") : plan.summary)
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let run {
                steps(run)
                controls(run)
            }
        }
        .padding(.horizontal, 9).padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(planBlue.opacity(0.08)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(planBlue.opacity(0.25)))
        .onAppear { agent.show(plan, for: messageId) }
    }

    @ViewBuilder private func steps(_ run: MailPlanRun) -> some View {
        let small = Font.system(size: 10.5)
        ForEach(Array(run.sorts.enumerated()), id: \.offset) { _, s in
            line(String(format: String(localized: "mail.plan.sort %@ %lld"), s.action.ruleLine, Int64(s.messages.count)), font: small)
        }
        ForEach(Array(run.replies.enumerated()), id: \.offset) { _, r in
            line(String(format: String(localized: "mail.plan.reply %@"), r.message.senderName), font: small)
        }
        ForEach(Array(run.saves.enumerated()), id: \.offset) { _, s in
            line(String(format: String(localized: "mail.plan.save %@ %@"), s.message.senderName, s.folder), font: small)
        }
        if !run.mails.isEmpty {
            line(String(format: String(localized: "mail.plan.mails %lld"), Int64(run.mails.filter { $0.problem == nil }.count)), font: small)
            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(run.mails) { m in
                        HStack(spacing: 6) {
                            Text(m.to.joined(separator: ", "))
                                .foregroundColor(Color(hex: m.problem == nil ? "#C5C8CD" : "#F4505E"))
                                .lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            Text(m.subject)
                                .foregroundColor(Color(hex: "#8E939C"))
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            if let problem = m.problem {
                                Text(problem).foregroundColor(Color(hex: "#F4505E")).lineLimit(1).fixedSize()
                            } else if let file = m.attachments.first {
                                Text(verbatim: "📎 " + file.lastPathComponent + (m.attachments.count > 1 ? " +\(m.attachments.count - 1)" : ""))
                                    .foregroundColor(Color(hex: "#8E939C"))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .frame(maxWidth: 150, alignment: .trailing)
                            }
                        }
                        .font(.system(size: 10))
                    }
                }
            }
            .frame(maxHeight: min(CGFloat(run.mails.count) * 15, 90))
        }
        ForEach(run.notes, id: \.self) { note in
            Text(note)
                .font(.system(size: 10))
                .foregroundColor(Color(hex: "#F5A524"))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func line(_ text: String, font: Font) -> some View {
        HStack(alignment: .top, spacing: 5) {
            Text(verbatim: "→").foregroundColor(planBlue)
            Text(text).foregroundColor(Color(hex: "#C5C8CD")).fixedSize(horizontal: false, vertical: true)
        }
        .font(font)
    }

    @ViewBuilder private func controls(_ run: MailPlanRun) -> some View {
        HStack(spacing: 10) {
            switch run.phase {
            case .preparing:
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("mail.plan.preparing").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
            case .ready, .cancelled:
                if run.stepCount > 0 {
                    Button(String(format: String(localized: "mail.plan.run %lld"), Int64(run.stepCount))) { agent.start(messageId) }
                        .buttonStyle(PlanButtonStyle(primary: true))
                }
                if !run.mails.isEmpty, agent.myAddress != nil {
                    Button(String(localized: "mail.plan.test")) { agent.sendTest(messageId) }
                        .buttonStyle(PlanButtonStyle(primary: false))
                }
                if run.phase == .cancelled {
                    Text("mail.plan.cancelled").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C"))
                } else if let to = run.testSentTo {
                    Text(String(format: String(localized: "mail.plan.test-sent %@"), to))
                        .font(.system(size: 10.5)).foregroundColor(Color(hex: "#34D399")).lineLimit(1)
                }
            case .countdown(let s):
                Text(String(format: String(localized: "mail.plan.countdown %lld"), Int64(s)))
                    .font(.system(size: 10.5, weight: .semibold)).foregroundColor(Color(hex: "#F5A524"))
                    .monospacedDigit()
                Button(String(localized: "mail.plan.cancel")) { agent.cancel(messageId) }
                    .buttonStyle(PlanButtonStyle(primary: false))
            case .running(let done, let total):
                ProgressView(value: Double(done), total: Double(max(1, total)))
                    .progressViewStyle(.linear)
                    .tint(planBlue)
                    .frame(width: 140)
                Text(verbatim: "\(done)/\(total)").font(.system(size: 10.5)).foregroundColor(Color(hex: "#8E939C")).monospacedDigit()
                Button(String(localized: "mail.plan.cancel")) { agent.cancel(messageId) }
                    .buttonStyle(PlanButtonStyle(primary: false))
            case .done(let ok, let failed):
                Image(systemName: failed == 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundColor(Color(hex: failed == 0 ? "#34D399" : "#F5A524"))
                Text(String(format: String(localized: "mail.plan.done %lld %lld"), Int64(ok), Int64(failed)))
                    .font(.system(size: 10.5)).foregroundColor(Color(hex: "#C5C8CD"))
            }
            Spacer(minLength: 0)
        }
        .padding(.top, 2)
    }
}

private struct PlanButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundColor(primary ? .white : Color(hex: "#C5C8CD"))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(primary ? planBlue : Color.white.opacity(0.08)))
            .opacity(configuration.isPressed ? 0.7 : 1)
            .contentShape(Capsule())
    }
}

/// The chat's Mail switch: on, the AI sees the latest messages and can prepare actions.
struct ChatMailToggle: View {
    @ObservedObject var state: AppState

    var body: some View {
        Button { state.chatMailMode.toggle() } label: {
            HStack(spacing: 4) {
                Image(systemName: state.chatMailMode ? "envelope.fill" : "envelope")
                    .font(.system(size: 9))
                Text("mail.chat.toggle")
                    .font(.system(size: 10.5, weight: .medium))
            }
            .foregroundColor(state.chatMailMode ? .white : Color(hex: "#7B8089"))
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(state.chatMailMode ? planBlue.opacity(0.85) : Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(String(localized: "mail.chat.toggle-help"))
    }
}

/// The Overview's list of what Coucou sent for the chat.
struct HubMailSentList: View {
    @ObservedObject private var store = MailTriageStore.shared

    var body: some View {
        if !store.sent.isEmpty {
            HubLabel(String(localized: "hub.mail.sent"))
            HubCard {
                ForEach(Array(store.sent.prefix(50).enumerated()), id: \.element.id) { i, e in
                    if i > 0 { HubDivider() }
                    HStack(spacing: 12) {
                        Image(systemName: "paperplane")
                            .font(.system(size: 13))
                            .foregroundColor(planBlue)
                            .frame(width: 22)
                        Text(e.to.joined(separator: ", "))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(e.subject)
                            .font(.system(size: 12.5))
                            .foregroundColor(HubTheme.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        if !e.attachments.isEmpty {
                            Text(verbatim: "📎 " + e.attachments.joined(separator: ", "))
                                .font(.system(size: 11.5))
                                .foregroundColor(HubTheme.muted)
                                .lineLimit(1)
                                .frame(maxWidth: 200, alignment: .trailing)
                        }
                        Text(e.date, format: .dateTime.day().month().hour().minute())
                            .font(.system(size: 11.5))
                            .foregroundColor(HubTheme.muted)
                    }
                }
            }
        }
    }
}
#endif
