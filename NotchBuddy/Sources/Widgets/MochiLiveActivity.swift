import ActivityKit
import SwiftUI
import WidgetKit

// Mochi's Live Activity: on the Lock Screen and in the Dynamic Island while
// the Mac is locked and an agent is working. The Mac drives it (step 8).

struct MochiLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MochiActivityAttributes.self) { context in
            LockScreenActivityView(state: context.state, stale: context.isStale)
                .activityBackgroundTint(Color(white: 0.08))
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
                    if state.others > 0 {
                        Text("+\(state.others)")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.trailing, 4)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    if let fingerprint = state.approval, state.tone == "waiting" {
                        ApprovalButtons(fingerprint: fingerprint, pillId: state.pillId)
                            .padding(.horizontal, 4)
                            .transition(.phaseIn)
                    } else {
                        HStack(spacing: 10) {
                            if state.stepCount > 0 {
                                StepsBar(index: state.stepIndex, count: state.stepCount, color: state.toneColor)
                            }
                            if let since = state.sinceDate, state.isActive {
                                Text(since, style: .timer)
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                    .frame(width: 52, alignment: .trailing)
                            }
                        }
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
                    .monospacedDigit()
                    .contentTransition(.numericText())
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
                .padding(6)
                .frame(width: 52, height: 52)
                .background(Color.mochiTile(hex: state.color), in: RoundedRectangle(cornerRadius: 14))
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
                } else if state.stepCount > 0 && !stale {
                    StepsBar(index: state.stepIndex, count: state.stepCount, color: state.toneColor)
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
            MochiStill(state: state.botState)
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

    /// A few characters next to the camera.
    var compactText: String {
        switch tone {
        case "waiting": "OK?"
        case "question": "?"
        case "error": "!"
        case "done": "✓"
        default: stepCount > 0 ? "\(min(stepIndex + 1, stepCount))/\(stepCount)" : "…"
        }
    }
}
