import SwiftUI

/// The command an agent waits on, with Allow (Face ID) and Deny.
/// Used in the session screen and in the sheet opened from a notification.
struct ApprovalCard: View {
    let link: PhoneLink
    let session: SessionItem

    @State private var sending: Decision?
    @State private var sent: Decision?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Waiting for your OK").font(.subheadline.weight(.semibold)).foregroundStyle(.orange)
            Text(session.approvalCommand.isEmpty ? "The agent asks for a permission." : session.approvalCommand)
                .font(.callout.monospaced())
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.white.opacity(0.07), in: RoundedRectangle(cornerRadius: 12))
                .textSelection(.enabled)
            if let sent {
                HStack(spacing: 12) {
                    if sent == .allow {
                        // Apple Pay's "Done": the ring, then the check, draw themselves.
                        DrawnCheckmark(size: 34)
                    } else {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.red)
                            .symbolEffect(.bounce, value: sent)
                    }
                    Text(sent == .allow ? "Allowed, sent to your Mac" : "Denied, sent to your Mac")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(sent == .allow ? .green : .red)
                }
                .transition(.scale(scale: 0.8).combined(with: .opacity))
            } else if session.approvalFingerprint.isEmpty {
                Text("Answer on your Mac. This request can't be answered from the iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ApprovalChoiceButtons(disabled: sending != nil) {
                    Task { await send(.deny) }
                } allow: {
                    Task { await send(.allow) }
                }
                Text("Allow asks for Face ID. The request expires after 2 minutes.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .glassCard()
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.orange.opacity(0.35), lineWidth: 1))
        .animation(.spring(duration: 0.5, bounce: 0.3), value: sent)
        .onChange(of: session.approvalFingerprint) { sent = nil; error = nil }
    }

    private func send(_ decision: Decision) async {
        sending = decision
        defer { sending = nil }
        error = nil
        if decision == .allow {
            guard await OwnerCheck.confirm(reason: "Allow this command on your Mac") else {
                error = "Face ID didn't confirm. Nothing was sent."
                Haptics.warning()
                return
            }
        }
        let summary = session.approvalCommand.isEmpty ? "Permission" : session.approvalCommand
        if await link.decide(decision, fingerprint: session.approvalFingerprint, pillId: session.id,
                             summary: String(summary.prefix(200))) {
            sent = decision
            if decision == .allow { Haptics.success() } else { Haptics.impact() }
        } else {
            Haptics.error()
            error = link.lastPong ?? "Couldn't reach iCloud."
        }
    }
}

/// Opened from the "Review" action of an approval notification.
struct ReviewSheet: View {
    let link: PhoneLink
    let fingerprint: String
    @Environment(\.dismiss) private var dismiss

    private var session: SessionItem? { link.sessions.first { $0.approvalFingerprint == fingerprint } }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let session {
                        HStack(spacing: 12) {
                            MochiLive(state: session.state)
                                .padding(6)
                                .frame(width: 52, height: 52)
                                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 14))
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(session.pillName) · \(session.title)").font(.headline)
                                if !session.macName.isEmpty {
                                    Text(session.macName).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        ApprovalCard(link: link, session: session)
                    } else {
                        Text("This request was already answered or has expired.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(40)
                    }
                }
                .padding(16)
            }
            .background(Color.black)
            .navigationTitle("Review")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .refreshable { await link.refresh() }
        }
    }
}

/// Decisions taken on this iPhone.
struct HistoryView: View {
    let link: PhoneLink

    /// Newest day first, each day's decisions newest first.
    private var days: [(day: Date, logs: [DecisionLog])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: link.history) { calendar.startOfDay(for: $0.date) }
        return grouped.keys.sorted(by: >).map { (day: $0, logs: grouped[$0]!.sorted { $0.date > $1.date }) }
    }

    var body: some View {
        List {
            if link.history.isEmpty {
                VStack(spacing: 10) {
                    MochiLive(state: .sleeping).frame(width: 56, height: 56)
                    Text("No decision yet").font(.headline)
                    Text("Commands you allow or deny from your iPhone show up here. They stay on this iPhone.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
                .listRowBackground(Color.clear)
            }
            ForEach(days, id: \.day) { day in
                Section(Self.dayTitle(day.day)) {
                    ForEach(day.logs) { log in row(log) }
                }
            }
        }
        .navigationTitle("History")
    }

    private func row(_ log: DecisionLog) -> some View {
        let pill = PillCatalog.definition(for: log.pillId)
        return HStack(alignment: .top, spacing: 12) {
            MochiStill(state: log.decision == .allow ? .finished : .error, bodyHex: pill?.color ?? "#FFFFFF")
                .padding(3)
                .frame(width: 34, height: 34)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(log.summary)
                    .font(.callout.monospaced())
                    .lineLimit(3)
                HStack(spacing: 6) {
                    Label(log.decision == .allow ? "Allowed" : "Denied",
                          systemImage: log.decision == .allow ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(log.decision == .allow ? .green : .red)
                    Text(pill?.name ?? log.pillId).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Text(log.date, format: .dateTime.hour().minute()).foregroundStyle(.tertiary)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 2)
    }

    static func dayTitle(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).day().month(.wide))
    }
}
