import ActivityKit
import SwiftUI
import WidgetKit

// Mochi's Live Activity: on the Lock Screen and in the Dynamic Island while an
// agent works. Like on Botan's screen, Mochi takes the color and the face of
// the moment (working, thinking, waiting for your OK, done), then leaves once
// the work is done. The Mac starts it; the iPhone keeps it up to date and ends it.

struct MochiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MochiActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, stale: context.isStale)
                // See-through, like the notifications around it, instead of a black slab.
                .activityBackgroundTint(Color.black.opacity(0.22))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MochiSwap(state: state)
                        .frame(width: 44, height: 44)
                        .padding(.leading, 4)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(state.agent)
                            .font(.headline)
                            .lineLimit(1)
                        Text(state.statusText)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(state.toneColor)
                            .lineLimit(1)
                            .contentTransition(.interpolate)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .animation(.phaseChange, value: state)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    VStack(alignment: .trailing, spacing: 2) {
                        if let since = state.sinceDate, state.isActive {
                            Text(since, style: .timer)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 52, alignment: .trailing)
                        }
                        if state.others > 0 {
                            Text("+\(state.others)")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.trailing, 4)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let fingerprint = state.approval, state.tone == "waiting" {
                        ApprovalButtons(fingerprint: fingerprint, pillId: state.pillId)
                            .padding(.horizontal, 4)
                            .transition(.phaseIn)
                    }
                }
            } compactLeading: {
                MochiSwap(state: state)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Text(state.compactText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.toneColor)
                    .contentTransition(.interpolate)
                    .animation(.phaseChange, value: state.compactText)
            } minimal: {
                MochiSwap(state: state)
                    .frame(width: 22, height: 22)
            }
            .keylineTint(state.toneColor)
        }
    }
}

struct LockScreenActivityView: View {
    let state: MochiActivityState
    let stale: Bool

    var body: some View {
        HStack(spacing: 14) {
            MochiSwap(state: state)
                .frame(width: 50, height: 50)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(state.agent).font(.headline)
                    if state.others > 0 {
                        Text("+\(state.others)").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                HStack(spacing: 6) {
                    Text(stale ? "Your Mac went quiet" : state.statusText)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(stale ? Color.secondary : state.toneColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.interpolate)
                    // Counts up live, without any push.
                    if let since = state.sinceDate, state.isActive, !stale {
                        Text("·").foregroundStyle(.secondary)
                        Text(since, style: .timer)
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                if let fingerprint = state.approval, state.tone == "waiting", !stale {
                    ApprovalButtons(fingerprint: fingerprint, pillId: state.pillId)
                        .padding(.top, 4)
                        .transition(.phaseIn)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
        // Every change of phase (working, question, waiting, done) moves
        // smoothly instead of jumping.
        .animation(.phaseChange, value: state)
        .animation(.phaseChange, value: stale)
    }
}

/// Mochi with a little pop when his state changes: the old face fades, the
/// new one grows in.
struct MochiSwap: View {
    let state: MochiActivityState

    var body: some View {
        ZStack {
            // Colored like on Botan's screen: blue at work, violet thinking, amber waiting
            // for your OK, green once done; the badge says the same (dots, "!", "?").
            MochiStill(state: state.botState, bodyHex: state.botState.mochiBodyHex)
                .id(state.state)
                .transition(.mochiSwap)
        }
        .animation(.phaseChange, value: state.state)
    }
}

extension Animation {
    /// Mochi's phase changes: a soft spring, inside the 2 s iOS allows.
    static var phaseChange: Animation { .spring(duration: 0.6, bounce: 0.3) }
}

extension AnyTransition {
    /// The old face fades out a little bigger, the new one grows in.
    static var mochiSwap: AnyTransition {
        .asymmetric(insertion: .scale(scale: 0.55).combined(with: .opacity),
                    removal: .scale(scale: 1.15).combined(with: .opacity))
    }

    /// What appears with a new phase (buttons, steps): slides up and fades in.
    static var phaseIn: AnyTransition {
        .asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity)
    }
}

/// Deny answers right away; Allow opens Coucou on the command, where Face ID
/// confirms before anything is sent.
struct ApprovalButtons: View {
    let fingerprint: String
    let pillId: String

    var body: some View {
        HStack(spacing: 8) {
            Button(intent: DenyApprovalIntent(fingerprint: fingerprint, pillId: pillId)) {
                Label("Deny", systemImage: "xmark")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .tint(.red)
            Button(intent: AllowApprovalIntent(fingerprint: fingerprint, pillId: pillId)) {
                Label("Allow", systemImage: "faceid")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
        }
    }
}

/// One segment per step, filled up to the current one.
struct StepsBar: View {
    let index: Int
    let count: Int
    let color: Color

    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<min(count, 12), id: \.self) { step in
                Capsule()
                    .fill(step <= index ? color : Color.white.opacity(0.18))
                    .frame(height: 4)
            }
        }
    }
}

extension MochiActivityState {
    var sinceDate: Date? { since.map { Date(timeIntervalSince1970: TimeInterval($0)) } }

    var toneColor: Color {
        switch tone {
        case "waiting": .orange
        case "question": .cyan
        case "error": .red
        case "done": .green
        default: .white.opacity(0.8)
        }
    }

    /// A word next to the camera: what is going on, not a step count.
    var compactText: String {
        switch tone {
        case "waiting": "OK?"
        case "question": "?"
        case "error": "Error"
        case "done": "Done"
        default: botState == .thinking ? "Thinking" : "Working"
        }
    }
}

extension BotState {
    /// Mochi's body on the Lock Screen and in the Dynamic Island: the state's color, softened
    /// with white (Botan's screen tints him the same way).
    var mochiBodyHex: String {
        let hex: UInt32
        switch self {
        case .working, .searching: hex = 0x3B9EFF
        case .thinking: hex = 0x8B5CF6
        case .approval: hex = 0xF5A524
        case .question: hex = 0x22D3EE
        case .error, .ratelimit, .dizzy: hex = 0xF4505E
        case .finished: hex = 0x34D399
        default: return "#FFFFFF"
        }
        func soft(_ c: UInt32) -> Int { Int((Double(c) * 0.7 + 255 * 0.3).rounded()) }
        return String(format: "#%02X%02X%02X", soft(hex >> 16 & 0xFF), soft(hex >> 8 & 0xFF), soft(hex & 0xFF))
    }
}
