import SwiftUI

/// A question Claude asks (AskUserQuestion), with its choices: pick, then
/// Send. The Mac answers Claude with exactly these choices.
struct QuestionCard: View {
    let link: PhoneLink
    let session: SessionItem
    let payload: QuestionPayload

    @State private var picks: [Set<String>] = []
    @State private var other: [String] = []
    @State private var useOther: [Bool] = []
    @State private var sending = false
    @State private var sent = false
    @State private var error: String?

    private var ready: Bool {
        payload.accepts(selections)
    }

    private var selections: [[String]] {
        payload.items.enumerated().map { index, item in
            guard picks.indices.contains(index), other.indices.contains(index), useOther.indices.contains(index) else { return [] }
            if useOther[index] || item.options.isEmpty { return [other[index].trimmingCharacters(in: .whitespacesAndNewlines)] }
            return item.options.map(\.label).filter { picks[index].contains($0) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Question").font(.subheadline.weight(.semibold)).foregroundStyle(.cyan)
            ForEach(Array(payload.items.enumerated()), id: \.offset) { index, item in
                VStack(alignment: .leading, spacing: 8) {
                    if !item.header.isEmpty {
                        Text(item.header.uppercased())
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                    }
                    Text(item.question).font(.callout.weight(.semibold))
                    if item.multiSelect {
                        Text("Pick one or more").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(item.options, id: \.label) { option in
                        optionRow(option, item: item, index: index)
                    }
                    if other.indices.contains(index), useOther.indices.contains(index), item.isOther == true || item.options.isEmpty {
                        if !item.options.isEmpty {
                            Toggle("Other answer", isOn: $useOther[index]).font(.callout)
                        }
                        if useOther[index] || item.options.isEmpty {
                            TextField("Your answer", text: $other[index], axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .disabled(sent || sending)
                        }
                    }
                }
            }
            if sent {
                Label("Answer sent to your Mac", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
            } else {
                Button {
                    Task { await send() }
                } label: {
                    Label("Send answer", systemImage: "paperplane.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(.cyan)
                .controlSize(.large)
                .disabled(!ready || sending)
                Text("Answer while this request is still waiting on your Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(16)
        .glassCard(tint: .cyan)
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(Color.cyan.opacity(0.7), lineWidth: 1.5))
        .onAppear { reset() }
        .onChange(of: payload) { reset() }
    }

    private func optionRow(_ option: QuestionPayload.Option, item: QuestionPayload.Item, index: Int) -> some View {
        let selected = picks.indices.contains(index) && picks[index].contains(option.label)
        return Button {
            guard picks.indices.contains(index), !sent else { return }
            if useOther.indices.contains(index) { useOther[index] = false }
            if item.multiSelect {
                if selected { picks[index].remove(option.label) } else { picks[index].insert(option.label) }
            } else {
                picks[index] = [option.label]
            }
            Haptics.impact()
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: item.multiSelect
                      ? (selected ? "checkmark.square.fill" : "square")
                      : (selected ? "largecircle.fill.circle" : "circle"))
                    .foregroundStyle(selected ? Color.cyan : Color.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.callout).foregroundStyle(.primary)
                    if !option.description.isEmpty {
                        Text(option.description).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(selected ? Color.cyan.opacity(0.16) : Color(white: 0.16), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func reset() {
        picks = Array(repeating: [], count: payload.items.count)
        other = Array(repeating: "", count: payload.items.count)
        useOther = Array(repeating: false, count: payload.items.count)
        sent = false
        error = nil
    }

    private func send() async {
        sending = true
        defer { sending = false }
        error = nil
        if await link.answer(fingerprint: session.questionFingerprint, pillId: session.id, selections: selections) {
            sent = true
            Haptics.success()
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
            Haptics.error()
        }
    }
}
