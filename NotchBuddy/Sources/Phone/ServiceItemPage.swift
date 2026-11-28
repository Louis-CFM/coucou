import SwiftUI
import UIKit

/// One item of a service on its own page (a payment, a repo, a project), like a contact in
/// Settings: what it is field by field, the lists inside it, what can be done, and the web link.
/// Everything comes from what the Mac read; nothing here calls the service.
struct ServiceItemPage: View {
    let link: PhoneLink
    let pillId: String
    let item: DetailItem

    @State private var running: ServiceActionDef?
    @State private var confirming: ServiceActionDef?
    @State private var sentFeedback = 0
    @State private var page: DetailItem?
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    if let badge = item.badge, !badge.isEmpty {
                        Label(badge, systemImage: "circle.fill")
                            .labelStyle(BadgeLabelStyle(color: toneColor(item.tone)))
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(toneColor(item.tone))
                    }
                    Text(item.title)
                        .font(.title2.weight(.bold))
                        .textSelection(.enabled)
                    if !item.subtitle.isEmpty {
                        Text(item.subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }

            if let fields = item.fields, !fields.isEmpty {
                Section {
                    ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                        LabeledContent(field.label) {
                            Text(field.value)
                                .foregroundStyle(field.tone == .idle ? Color.secondary : field.tone.color)
                                .multilineTextAlignment(.trailing)
                                .textSelection(.enabled)
                        }
                    }
                }
            }

            ForEach(Array((item.sections ?? []).enumerated()), id: \.offset) { _, section in
                Section {
                    ForEach(Array(section.items.enumerated()), id: \.offset) { _, child in
                        childRow(child)
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let footer = section.footer { Text(footer) }
                }
            }

            if !item.actions.isEmpty {
                Section {
                    ForEach(item.actions, id: \.self) { action in
                        Button(role: action.destructive ? .destructive : nil) {
                            if action.confirm != nil { confirming = action } else { run(action) }
                        } label: {
                            HStack {
                                Label(action.title, systemImage: action.symbol)
                                Spacer()
                                if running == action { ProgressView().controlSize(.small) }
                            }
                        }
                        .disabled(running != nil)
                    }
                }
            }

            if let url = item.url.flatMap(URL.init(string:)), url.scheme == "https" {
                Section {
                    Button { openURL(url) } label: { Label("Open on the web", systemImage: "safari") }
                    Button { UIPasteboard.general.url = url } label: { Label("Copy link", systemImage: "link") }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle(item.title)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: Binding(get: { page != nil }, set: { if !$0 { page = nil } })) {
            if let page { ServiceItemPage(link: link, pillId: pillId, item: page) }
        }
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

    /// A line inside the page: opens its own page, or the web.
    private func childRow(_ child: DetailItem) -> some View {
        HStack(spacing: 10) {
            Circle().fill(toneColor(child.tone)).frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(child.title).font(.callout.weight(.medium)).lineLimit(1)
                    if let badge = child.badge, !badge.isEmpty {
                        Text(badge).font(.caption2.weight(.semibold)).foregroundStyle(toneColor(child.tone)).fixedSize()
                    }
                }
                HStack(spacing: 4) {
                    if !child.subtitle.isEmpty { Text(child.subtitle).lineLimit(1) }
                    if let date = child.date {
                        if !child.subtitle.isEmpty { Text("·") }
                        Text(date, format: .relative(presentation: .named)).lineLimit(1).fixedSize()
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            if child.hasPage || child.url != nil {
                Image(systemName: "chevron.right").font(.caption2.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if child.hasPage {
                page = child
            } else if let url = child.url.flatMap(URL.init(string:)), url.scheme == "https" {
                openURL(url)
            }
        }
    }

    private func toneColor(_ tone: ServiceTone) -> Color {
        tone == .idle ? Color.secondary.opacity(0.6) : tone.color
    }

    private func run(_ action: ServiceActionDef) {
        confirming = nil
        running = action
        Task {
            if await link.runServiceAction(action, pillId: pillId) { sentFeedback += 1 }
            running = nil
        }
    }
}

/// The colored dot before a badge.
private struct BadgeLabelStyle: LabelStyle {
    let color: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.font(.system(size: 6)).foregroundStyle(color)
            configuration.title
        }
    }
}
