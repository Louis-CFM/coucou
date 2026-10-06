import SwiftUI

/// Step 3 check: CoucouKit (Mochi, pills, diff, models) drawn on the iPhone
/// with the Mac's own code.
struct KitPreviewView: View {
    private let poses: [(BotState, EyeShape?, String)] = [
        (.idle, nil, "idle"),
        (.working, nil, "working"),
        (.approval, nil, "approval"),
        (.question, nil, "question"),
        (.finished, .happy, "finished"),
        (.error, nil, "error"),
        (.sleeping, .closed, "sleeping"),
        (.thinking, nil, "thinking"),
    ]

    private let sampleDiff = DiffEngine.fromEdit(
        old: "func greet() {\n    print(\"Hello\")\n}\n",
        new: "func greet(name: String) {\n    print(\"Coucou \\(name)\")\n}\n",
        path: "/coucou/Greeting.swift")

    var body: some View {
        List {
            Section("Mochi — fixed poses") {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 72))], spacing: 12) {
                    ForEach(Array(poses.enumerated()), id: \.offset) { index, pose in
                        VStack(spacing: 4) {
                            MochiStill(state: pose.0, eye: pose.1)
                                .padding(6)
                                .frame(width: 64, height: 64)
                                .background(tileColor(index), in: RoundedRectangle(cornerRadius: 14))
                            Text(pose.2).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(.vertical, 6)
            }

            ForEach(PillCategory.allCases, id: \.self) { category in
                Section(category.title) {
                    ForEach(PillCatalog.all.filter { $0.category == category }, id: \.id) { pill in
                        HStack(spacing: 12) {
                            MochiStill()
                                .padding(3)
                                .frame(width: 30, height: 30)
                                .background(Color.mochiTile(hex: pill.color), in: RoundedRectangle(cornerRadius: 8))
                            VStack(alignment: .leading) {
                                Text(pill.name)
                                Text(pill.id).font(.caption2.monospaced()).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text(pill.subtitle).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Diff — \(sampleDiff.name) +\(sampleDiff.added) −\(sampleDiff.removed)") {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(sampleDiff.hunks.flatMap(\.lines).enumerated()), id: \.offset) { _, line in
                        Text(prefix(line.kind) + line.text)
                            .font(.caption.monospaced())
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                            .background(lineColor(line.kind))
                    }
                }
            }
        }
        .navigationTitle("CoucouKit")
    }

    private func tileColor(_ index: Int) -> Color {
        let pills = PillCatalog.all
        return Color(hex: pills[index % pills.count].color)
    }

    private func prefix(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .added: "+ "
        case .removed: "− "
        case .context: "  "
        }
    }

    private func lineColor(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .added: .green.opacity(0.18)
        case .removed: .red.opacity(0.18)
        case .context: .clear
        }
    }
}
