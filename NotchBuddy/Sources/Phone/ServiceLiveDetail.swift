import SwiftUI

/// What the Mac just read from a service's API: figures, lists, and the
/// actions it offers on each item (Face ID, then the Mac does it).
struct ServiceLiveDetail: View {
    let link: PhoneLink
    let pillId: String
    let detail: ServiceDetail

    @State private var running: ServiceActionDef?
    @State private var confirming: ServiceActionDef?
    @State private var sentFeedback = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let result = detail.lastAction, Date().timeIntervalSince(result.date) < 10 * 60 {
                resultBanner(result)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
            if let error = detail.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .glassCard()
            }
            if !detail.stats.isEmpty { stats }
            ForEach(Array(detail.sections.enumerated()), id: \.offset) { _, section in
                sectionCard(section)
            }
            Text("Read from your Mac · \(detail.fetchedAt.formatted(.relative(presentation: .named)))")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity)
        }
        .animation(.spring(duration: 0.45, bounce: 0.2), value: detail.lastAction)
        .sensoryFeedback(.success, trigger: sentFeedback)
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil },
                                                                         set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            if let action = confirming {
                Button(action.title, role: action.destructive ? .destructive : nil) { run(action) }
            }
        } message: {
            Text(confirming?.confirm ?? "")
        }
    }

    // MARK: Figures

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(Array(detail.stats.enumerated()), id: \.offset) { _, stat in
                VStack(alignment: .leading, spacing: 4) {
                    Text(stat.value)
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(stat.tone == .idle ? Color.primary : stat.tone.color)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .contentTransition(.numericText())
                    Text(stat.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(14)
                .glassCard(cornerRadius: 18)
            }
        }
    }

    // MARK: Lists

    private func sectionCard(_ section: DetailSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                itemRow(item)
                if index < section.items.count - 1 { Divider() }
            }
            if let footer = section.footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .glassCard()
    }

    private func itemRow(_ item: DetailItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Circle().fill(item.tone.color).frame(width: 8, height: 8)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 6)
                VStack(alignment: .trailing, spacing: 3) {
                    if let badge = item.badge, !badge.isEmpty {
                        Text(badge)
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(item.tone == .idle ? Color.secondary : item.tone.color)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background((item.tone == .idle ? Color.white : item.tone.color).opacity(0.14), in: Capsule())
                    }
                    if let date = item.date {
                        Text(date, format: .relative(presentation: .named))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            if !item.actions.isEmpty || item.url != nil {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(item.actions, id: \.self) { action in
                            actionButton(action)
                        }
                        if let url = item.url.flatMap(URL.init(string:)), url.scheme == "https" {
                            Link(destination: url) {
                                Label("Open", systemImage: "arrow.up.right")
                                    .font(.footnote.weight(.semibold))
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 7)
                                    .glassPill(Capsule(), interactive: true)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                    }
                    .padding(.leading, 18)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func actionButton(_ action: ServiceActionDef) -> some View {
        Button {
            if action.confirm != nil { confirming = action } else { run(action) }
        } label: {
            HStack(spacing: 6) {
                if running == action {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: action.symbol)
                }
                Text(action.title)
            }
            .font(.footnote.weight(.semibold))
            .foregroundStyle(action.destructive ? Color.red : Color.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .glassPill(Capsule(), interactive: true, tint: action.destructive ? .red : nil)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(running != nil)
    }

    private func run(_ action: ServiceActionDef) {
        confirming = nil
        running = action
        Task {
            if await link.runServiceAction(action, pillId: pillId) { sentFeedback += 1 }
            running = nil
        }
    }

    // MARK: Result

    private func resultBanner(_ result: ServiceActionResult) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if result.ok {
                DrawnCheckmark(size: 30)
            } else {
                Image(systemName: "xmark.circle.fill").font(.title2).foregroundStyle(.red)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(result.title).font(.subheadline.weight(.semibold))
                Text(result.message).font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Text(result.date, format: .relative(presentation: .named))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
        .glassCard(tint: result.ok ? .green : .red)
    }
}
