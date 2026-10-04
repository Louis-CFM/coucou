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
                    MochiStill(state: state.botState)
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
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
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
                    if state.stepCount > 0 {
                        StepsBar(index: state.stepIndex, count: state.stepCount, color: state.toneColor)
                            .padding(.horizontal, 4)
                    }
                }
            } compactLeading: {
                MochiStill(state: state.botState)
                    .frame(width: 24, height: 24)
            } compactTrailing: {
                Text(state.compactText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(state.toneColor)
                    .monospacedDigit()
            } minimal: {
                MochiStill(state: state.botState)
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
            MochiStill(state: state.botState)
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
                Text(stale ? "Your Mac went quiet" : state.statusText)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(stale ? Color.secondary : state.toneColor)
                if state.stepCount > 0 && !stale {
                    StepsBar(index: state.stepIndex, count: state.stepCount, color: state.toneColor)
                }
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(16)
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
