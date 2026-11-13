import SwiftUI
import UIKit

extension TurnSnapshot {
    /// One line for a turn: what you asked, or what woke the agent up.
    var headline: String {
        if prompt.hasPrefix("<task-notification>") {
            if let start = prompt.range(of: "<summary>"), let end = prompt.range(of: "</summary>"),
               start.upperBound <= end.lowerBound {
                return String(prompt[start.upperBound..<end.lowerBound])
            }
            return "A background task finished"
        }
        let line = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        return line.isEmpty ? "Turn without a prompt" : line
    }
}

/// A finished turn as a picture: Mochi, what you asked, what changed, the
/// answer. Made on the iPhone when you tap Share; nothing is sent anywhere else.
struct TurnShareCard: View {
    let turn: TurnSnapshot
    let color: String

    private var added: Int { turn.files.reduce(0) { $0 + $1.added } }
    private var removed: Int { turn.files.reduce(0) { $0 + $1.removed } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 14) {
                MochiStill(state: .finished, bodyHex: color, showBadge: false)
                    .padding(8)
                    .frame(width: 64, height: 64)
                    .background(Color.mochiTile(hex: color), in: RoundedRectangle(cornerRadius: 16))
                VStack(alignment: .leading, spacing: 2) {
                    Text(turn.project.isEmpty ? (PillCatalog.definition(for: turn.pillId)?.name ?? "Agent") : turn.project)
                        .font(.title3.weight(.bold))
                    if let ended = turn.endedAt {
                        Text("Done in \(Self.duration(ended.timeIntervalSince(turn.startedAt)))")
                            .font(.subheadline)
                            .foregroundStyle(.green)
                    }
                }
            }
            Text(turn.headline)
                .font(.body)
                .lineLimit(4)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.accentColor.opacity(0.25), in: RoundedRectangle(cornerRadius: 16))
            HStack(spacing: 18) {
                stat("\(turn.actions.count)", "actions")
                stat("\(turn.files.count)", turn.files.count == 1 ? "file" : "files")
                if !turn.files.isEmpty {
                    HStack(spacing: 8) {
                        Text("+\(added)").foregroundStyle(.green)
                        Text("−\(removed)").foregroundStyle(.red)
                    }
                    .font(.title3.monospacedDigit().weight(.semibold))
                }
            }
            if !turn.files.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(turn.files.prefix(5).enumerated()), id: \.offset) { _, file in
                        HStack {
                            Text(file.name).font(.callout.monospaced()).lineLimit(1)
                            Spacer()
                            Text("+\(file.added) −\(file.removed)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    if turn.files.count > 5 {
                        Text("and \(turn.files.count - 5) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            if !turn.finalMessage.isEmpty {
                Text(turn.finalMessage)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(8)
            }
            HStack(spacing: 6) {
                Spacer()
                MochiStill(state: .idle, showBadge: false).frame(width: 18, height: 18)
                Text("Coucou").font(.footnote.weight(.semibold)).foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .frame(width: 390)
        .foregroundStyle(.white)
        .background(Color(white: 0.07))
        .environment(\.colorScheme, .dark)
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.title3.monospacedDigit().weight(.semibold))
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }

    static func duration(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        formatter.maximumUnitCount = 2
        return formatter.string(from: max(1, seconds)) ?? ""
    }

    @MainActor
    static func render(turn: TurnSnapshot, color: String) -> UIImage? {
        let renderer = ImageRenderer(content: TurnShareCard(turn: turn, color: color))
        renderer.scale = 3
        return renderer.uiImage
    }
}
