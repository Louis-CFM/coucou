import SwiftUI

/// Main screen: the notch on top, every agent session from the Mac (most
/// urgent first), then every service Mochi.
struct HomeView: View {
    let link: PhoneLink
    @State private var path: [String] = []
    @AppStorage("onboardingDone") private var onboardingDone = false

    var body: some View {
        NavigationStack(path: $path) {
            ScrollView {
                VStack(spacing: 16) {
                    NotchHeader(sessions: link.sessions, status: link.status)
                    TodayCard(link: link)
                    if link.sessions.isEmpty {
                        EmptySessionsView(status: link.status)
                    } else {
                        VStack(spacing: 0) {
                            let sorted = link.sessions.sortedByUrgency()
                            ForEach(sorted) { session in
                                NavigationLink(value: session.id) {
                                    SessionRow(session: session)
                                }
                                .buttonStyle(.plain)
                                if session.id != sorted.last?.id {
                                    Divider().padding(.leading, 64)
                                }
                            }
                        }
                        .padding(.vertical, 6)
                        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
                        // Sessions move to their new place and change status smoothly.
                        .animation(.spring(duration: 0.5, bounce: 0.2),
                                   value: link.sessions.map { "\($0.id)|\($0.statusText)" })
                    }
                    ServicesList(services: link.services)
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 24)
            }
            .background(Color.black)
            .refreshable { await link.refresh() }
            .navigationDestination(for: String.self) { id in
                if PillCatalog.isSession(id) {
                    SessionDetailView(link: link, sessionId: id)
                } else {
                    ServiceDetailView(link: link, pillId: id)
                }
            }
            // A widget tile was tapped: open that Mochi.
            .onOpenURL { url in
                if let id = SharedSession.sessionId(from: url) { path = [id] }
            }
            // A notification, Siri or the Control Center asked for a session.
            .onChange(of: link.openPillId) { _, id in
                guard let id else { return }
                path = [id]
                link.openPillId = nil
            }
            .sheet(isPresented: Binding(get: { link.reviewFingerprint != nil },
                                        set: { if !$0 { link.reviewFingerprint = nil } })) {
                if let fingerprint = link.reviewFingerprint {
                    ReviewSheet(link: link, fingerprint: fingerprint)
                }
            }
            // First launch: how to connect the Mac.
            .fullScreenCover(isPresented: Binding(get: { !onboardingDone }, set: { if !$0 { onboardingDone = true } })) {
                OnboardingView()
            }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink {
                        HistoryView(link: link)
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        AboutView(link: link)
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
                #if DEBUG
                // Test screens, in builds run from Xcode only (the link test has its own "Kit" button).
                ToolbarItem(placement: .topBarTrailing) {
                    NavigationLink {
                        LinkTestView(link: link)
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                }
                #endif
            }
        }
    }
}

/// The black island at the top: Mochi with the most urgent state and a summary.
struct NotchHeader: View {
    let sessions: [SessionItem]
    let status: PhoneLink.Status

    var body: some View {
        HStack(spacing: 14) {
            MochiLive(state: sessions.leadState)
                .frame(width: 52, height: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(headline)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .contentTransition(.interpolate)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)
                        .contentTransition(.interpolate)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .background(Color.black, in: RoundedRectangle(cornerRadius: 28))
        .overlay(
            RoundedRectangle(cornerRadius: 28)
                .strokeBorder(sessions.contains(where: \.isWaitingForYou) ? Color.orange.opacity(0.8) : Color.white.opacity(0.12),
                              lineWidth: 1.5)
        )
        .animation(.spring(duration: 0.5, bounce: 0.2), value: "\(headline)|\(detail ?? "")")
    }

    private var headline: String {
        switch status {
        case .noAccount: return "iCloud not connected"
        case .failed: return "Can't reach iCloud"
        default: break
        }
        return sessions.summary ?? (sessions.isEmpty ? "Nothing yet" : "All quiet")
    }

    private var detail: String? {
        guard let lead = sessions.sortedByUrgency().first else { return nil }
        return "\(lead.title) · \(lead.statusText)"
    }
}

struct SessionRow: View {
    let session: SessionItem

    var body: some View {
        HStack(spacing: 12) {
            MochiLive(state: session.state, fps: 20)
                .padding(4)
                .frame(width: 40, height: 40)
                .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 11))
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                // The agent under the project name; for a session without a project
                // name (title is the agent already), what runs in it.
                Text(session.title == session.pillName
                     ? (PillCatalog.definition(for: session.id)?.sessionSubtitle ?? session.pillName)
                     : session.pillName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                Text(session.statusText)
                    .font(.subheadline.weight(session.isWaitingForYou ? .semibold : .regular))
                    .foregroundStyle(session.statusColor)
                    .contentTransition(.interpolate)
                Text(session.updatedAt, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }
}

struct EmptySessionsView: View {
    let status: PhoneLink.Status

    var body: some View {
        VStack(spacing: 8) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
    }

    private var message: String {
        switch status {
        case .starting: "Connecting to iCloud…"
        case .noAccount(let reason): "\(reason) Sign in to iCloud with the same account as your Mac."
        case .zoneMissing: "Open Coucou on your Mac: your sessions will show up here."
        case .failed(let message): message
        case .ready: "No session yet. Start Claude Code, Cursor or Codex on your Mac."
        }
    }
}

/// Today, as this iPhone saw it: turns finished, files and lines changed,
/// commands you answered. Counted on the iPhone, never sent anywhere.
struct TodayCard: View {
    let link: PhoneLink

    private var decisionsToday: Int {
        link.history.filter { Calendar.current.isDateInToday($0.date) }.count
    }

    var body: some View {
        let tally = link.archive.currentTally
        if !tally.isEmpty || decisionsToday > 0 {
            HStack(spacing: 0) {
                stat("\(tally.turns)", tally.turns == 1 ? "turn" : "turns")
                stat("\(tally.files)", tally.files == 1 ? "file" : "files")
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        Text("+\(tally.added)").foregroundStyle(.green)
                        Text("−\(tally.removed)").foregroundStyle(.red)
                    }
                    .font(.headline.monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    Text("lines").font(.caption2).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                stat("\(decisionsToday)", decisionsToday == 1 ? "OK given" : "OKs given")
            }
            .padding(.vertical, 12)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
            .overlay(alignment: .topLeading) {
                Text("TODAY")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.tertiary)
                    .padding(.horizontal, 10)
                    .offset(y: -16)
            }
            .padding(.top, 10)
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline.monospacedDigit())
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
