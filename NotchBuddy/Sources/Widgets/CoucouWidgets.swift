import SwiftUI
import WidgetKit

// Coucou widgets: Solo, Team and List on the Home Screen, plus the Lock
// Screen accessories. They show the sessions the iPhone app last saved to the
// App Group; the app reloads them whenever a session changes.

@main
struct CoucouWidgetBundle: WidgetBundle {
    var body: some Widget {
        SoloWidget()
        TeamWidget()
        ListWidget()
        LockScreenWidget()
        MochiLiveActivity()
    }
}

// MARK: - Timeline

struct SessionsEntry: TimelineEntry {
    let date: Date
    let sessions: [SharedSession]   // most urgent first
    /// Changes every minute so idle Mochi look around (MochiPose).
    var tick: Int = 0
}

struct SessionsProvider: TimelineProvider {
    func placeholder(in context: Context) -> SessionsEntry {
        SessionsEntry(date: .now, sessions: SharedSession.samples)
    }

    func getSnapshot(in context: Context, completion: @escaping (SessionsEntry) -> Void) {
        let saved = SharedSessions.load()
        completion(SessionsEntry(date: .now, sessions: context.isPreview && saved.isEmpty ? SharedSession.samples : saved))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<SessionsEntry>) -> Void) {
        // The sessions come from the app, which calls reloadAllTimelines() on
        // every change. The entries only give idle Mochi a new pose each
        // minute for an hour; no network, nothing read again.
        let sessions = SharedSessions.load()
        let start = Date.now
        let base = Int(start.timeIntervalSince1970 / 60)
        let entries = (0..<60).map { minute in
            SessionsEntry(date: start.addingTimeInterval(Double(minute) * 60), sessions: sessions, tick: base + minute)
        }
        completion(Timeline(entries: entries, policy: .atEnd))
    }
}

// MARK: - Widgets

struct SoloWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CoucouSolo", provider: SessionsProvider()) { entry in
            SoloView(session: entry.sessions.first)
        }
        .configurationDisplayName("Solo")
        .description("Your most urgent agent session.")
        .supportedFamilies([.systemSmall])
    }
}

struct TeamWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CoucouTeam", provider: SessionsProvider()) { entry in
            TeamView(sessions: Array(entry.sessions.prefix(4)), tick: entry.tick)
        }
        .configurationDisplayName("Team")
        .description("Up to four agents at a glance.")
        .supportedFamilies([.systemSmall])
    }
}

struct ListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CoucouList", provider: SessionsProvider()) { entry in
            ListView(sessions: Array(entry.sessions.prefix(4)))
        }
        .configurationDisplayName("List")
        .description("Your agent sessions and what they are doing.")
        .supportedFamilies([.systemMedium])
    }
}

struct LockScreenWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "CoucouLock", provider: SessionsProvider()) { entry in
            LockScreenView(sessions: entry.sessions)
        }
        .configurationDisplayName("Coucou")
        .description("Mochi on your Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline])
    }
}

// MARK: - Views

extension SharedSession {
    var botState: BotState { BotState(rawValue: state) ?? .idle }

    var toneColor: Color {
        switch tone {
        case .waiting: .orange
        case .question: .cyan
        case .error: .red
        case .done: .green
        case .working, .idle: .white.opacity(0.7)
        }
    }
}

extension Array where Element == SharedSession {
    var leadState: BotState {
        guard let lead = first else { return .sleeping }
        switch lead.tone {
        case .waiting: return .approval
        case .question: return .question
        default: return lead.botState
        }
    }
}

struct SoloView: View {
    let session: SharedSession?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            MochiStill(state: session?.botState ?? .sleeping)
                .frame(width: 56, height: 56)
            Spacer(minLength: 0)
            if let session {
                Text(session.title)
                    .font(.headline)
                    .lineLimit(1)
                Text(session.currentStep.isEmpty ? session.agent : session.currentStep)
                    .font(.caption)
                    .lineLimit(2)
                    .opacity(0.85)
                HStack(spacing: 4) {
                    Text(session.statusText).foregroundStyle(session.toneColor)
                    Text("·")
                    Text(session.updatedAt, style: .relative)
                }
                .font(.caption2)
                .lineLimit(1)
                .opacity(0.8)
            } else {
                Text("All quiet").font(.headline)
                Text("No agent session").font(.caption).opacity(0.7)
            }
        }
        .foregroundStyle(.white)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .containerBackground(for: .widget) {
            LinearGradient(colors: [Color(hex: session?.color ?? "#3B4A6B").opacity(0.55), Color(white: 0.08)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }
}

struct TeamView: View {
    let sessions: [SharedSession]
    var tick: Int = 0

    var body: some View {
        Grid(horizontalSpacing: 8, verticalSpacing: 8) {
            GridRow { tile(0); tile(1) }
            GridRow { tile(2); tile(3) }
        }
        .containerBackground(for: .widget) { Color(white: 0.08) }
    }

    @ViewBuilder private func tile(_ index: Int) -> some View {
        if sessions.indices.contains(index) {
            let session = sessions[index]
            // A tap opens that session in the app.
            Link(destination: SharedSession.url(for: session.id)) {
                TeamTile(session: session, tick: tick)
            }
        } else {
            EmptyTeamTile(tick: tick, slot: index)
        }
    }
}

/// One Mochi of the team: his face, his name, and a dot for his state.
struct TeamTile: View {
    let session: SharedSession
    var tick: Int = 0

    /// Calm Mochi look around; one who needs you keeps his state's face.
    private var pose: MochiPose {
        switch session.tone {
        case .idle, .done, .working: MochiPose.idle(id: session.id, tick: tick)
        default: .neutral
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // In his own color, like the little Mochi in the Mac's notch.
            MochiStill(state: session.botState, bodyHex: session.color, pose: pose)
                .padding(.horizontal, 4)
                .padding(.top, 2)
            Text(session.agent)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.white.opacity(0.85))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 4)
                .offset(y: -6)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(white: 0.14), in: RoundedRectangle(cornerRadius: 16))
        .overlay(alignment: .topTrailing) {
            if session.tone != .idle {
                Circle()
                    .fill(session.toneColor)
                    .frame(width: 8, height: 8)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1))
                    .padding(6)
            }
        }
        .overlay {
            // Waiting on you: the whole tile is outlined, like the notch.
            if session.isWaitingForYou {
                RoundedRectangle(cornerRadius: 16).strokeBorder(session.toneColor, lineWidth: 2)
            }
        }
    }
}

/// A free spot: Mochi asleep, faded, instead of an empty square.
struct EmptyTeamTile: View {
    var tick: Int = 0
    var slot: Int = 0

    var body: some View {
        MochiStill(state: .sleeping, showBadge: false,
                   pose: MochiPose(tilt: (tick + slot) % 2 == 0 ? -0.06 : 0.06))
            .padding(14)
            .opacity(0.18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ListView: View {
    let sessions: [SharedSession]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if sessions.isEmpty {
                HStack(spacing: 10) {
                    MochiStill(state: .sleeping).frame(width: 34, height: 34)
                    Text("All quiet: no agent session").font(.subheadline).opacity(0.7)
                }
                .frame(maxHeight: .infinity)
            }
            ForEach(sessions) { session in
                HStack(spacing: 8) {
                    MochiStill(state: session.botState)
                        .padding(2)
                        .frame(width: 24, height: 24)
                        .background(Color.mochiTile(hex: session.color), in: RoundedRectangle(cornerRadius: 7))
                    Text(session.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(session.agent)
                        .font(.caption)
                        .opacity(0.6)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(session.statusText)
                        .font(.caption.weight(session.isWaitingForYou ? .semibold : .regular))
                        .foregroundStyle(session.toneColor)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .containerBackground(for: .widget) { Color(white: 0.08) }
    }
}

struct LockScreenView: View {
    @Environment(\.widgetFamily) private var family
    let sessions: [SharedSession]

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                MochiStill(state: sessions.leadState).padding(6)
            }
            .containerBackground(for: .widget) { Color.clear }
        case .accessoryRectangular:
            HStack(spacing: 6) {
                MochiStill(state: sessions.leadState).frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 0) {
                    Text(sessions.summary ?? "All quiet")
                        .font(.headline)
                        .lineLimit(1)
                    if let lead = sessions.first {
                        Text("\(lead.title) · \(lead.statusText)")
                            .font(.caption)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .containerBackground(for: .widget) { Color.clear }
        default:
            Text(sessions.summary.map { "Coucou · \($0)" } ?? "Coucou · all quiet")
                .containerBackground(for: .widget) { Color.clear }
        }
    }
}

// MARK: - Samples (widget gallery)

extension SharedSession {
    static let samples: [SharedSession] = [
        SharedSession(id: "integration_claude", title: "coucou", agent: "VS Code", color: "#4A86E8",
                      state: "approval", statusText: "waiting for your OK", tone: .waiting, urgency: 0,
                      stepIndex: 2, stepCount: 7, currentStep: "npm run test", updatedAt: .now),
        SharedSession(id: "agent_codex", title: "site-perso", agent: "Codex", color: "#D9663A",
                      state: "working", statusText: "working · 3/7", tone: .working, urgency: 3,
                      stepIndex: 2, stepCount: 7, currentStep: "Edit index.html", updatedAt: .now),
        SharedSession(id: "agent_gemini", title: "api-factures", agent: "Gemini CLI", color: "#4CA63A",
                      state: "finished", statusText: "✓ done", tone: .done, urgency: 4,
                      stepIndex: 4, stepCount: 4, currentStep: "", updatedAt: .now),
        SharedSession(id: "agent_cursor", title: "notes", agent: "Cursor", color: "#4FA37E",
                      state: "sleeping", statusText: "asleep", tone: .idle, urgency: 5,
                      stepIndex: 0, stepCount: 0, currentStep: "", updatedAt: .now),
    ]
}
