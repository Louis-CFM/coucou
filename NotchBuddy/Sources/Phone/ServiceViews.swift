import SwiftUI

/// Every service Mochi, connected on the Mac or not.
struct ServicesList: View {
    let services: [String: ServiceSnapshot]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Services")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.leading, 6)
            VStack(spacing: 0) {
                let ids = PillCatalog.phoneServices
                ForEach(ids, id: \.self) { id in
                    NavigationLink(value: id) {
                        ServiceRow(pillId: id, snapshot: services[id])
                    }
                    .buttonStyle(.plain)
                    if id != ids.last {
                        Divider().padding(.leading, 64)
                    }
                }
            }
            .padding(.vertical, 6)
            .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
        }
    }
}

struct ServiceRow: View {
    let pillId: String
    let snapshot: ServiceSnapshot?

    private var pill: PillDefinition? { PillCatalog.definition(for: pillId) }

    var body: some View {
        HStack(spacing: 12) {
            ServiceMochi(pillId: pillId, tone: snapshot?.tone)
                .frame(width: 40, height: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(pill?.name ?? pillId)
                    .font(.body.weight(.semibold))
                    .lineLimit(1)
                Text(snapshot?.headline ?? "Not connected on your Mac")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if let snapshot {
                VStack(alignment: .trailing, spacing: 2) {
                    HStack(spacing: 5) {
                        Circle().fill(snapshot.tone.color).frame(width: 8, height: 8)
                        Text(snapshot.tone.label)
                            .font(.subheadline)
                            .foregroundStyle(snapshot.tone == .idle ? Color.secondary : snapshot.tone.color)
                    }
                    Text(snapshot.updatedAt, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .opacity(snapshot == nil ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

/// A service Mochi in his own color, like the little ones in the Mac's notch.
struct ServiceMochi: View {
    let pillId: String
    let tone: ServiceTone?
    var corner: CGFloat = 11

    var body: some View {
        let color = PillCatalog.definition(for: pillId)?.color ?? "#C0C4CC"
        MochiLive(state: tone?.botState ?? .sleeping, bodyHex: color, fps: 20)
            .padding(4)
            .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: corner))
    }
}

/// One service: why its dot has that color, then what the Mac last fetched.
struct ServiceDetailView: View {
    let link: PhoneLink
    let pillId: String

    private var snapshot: ServiceSnapshot? { link.services[pillId] }
    private var pill: PillDefinition? { PillCatalog.definition(for: pillId) }
    /// The Mac didn't answer the last request (asleep, sync off, older build).
    @State private var macSilent = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let snapshot {
                    // Why the dot has its color: only worth a card when something needs a look.
                    if snapshot.tone == .error || snapshot.tone == .warning || link.serviceDetails[pillId] == nil {
                        reasonCard(snapshot)
                    }
                    // Read live from the service's API by the Mac, with actions.
                    if let detail = link.serviceDetails[pillId] {
                        ServiceLiveDetail(link: link, pillId: pillId, detail: detail)
                    } else {
                        HStack(spacing: 10) {
                            if macSilent {
                                Image(systemName: "moon.zzz").foregroundStyle(.secondary)
                                Text("Your Mac didn't answer. Is it awake, with the iPhone switch on? Pull down to try again.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            } else {
                                ProgressView()
                                Text("Asking your Mac for everything \(pill?.name ?? "it") has…")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .glassCard()
                        ForEach(Array(snapshot.sections.enumerated()), id: \.offset) { _, section in
                            sectionCard(section)
                        }
                    }
                } else {
                    notConnected
                }
            }
            .padding(16)
        }
        .background(Color.black)
        .navigationTitle(pill?.name ?? "Service")
        .navigationBarTitleDisplayMode(.inline)
        .task { macSilent = !(await link.requestServiceDetail(pillId)) && link.serviceDetails[pillId] == nil }
        .refreshable {
            macSilent = false
            macSilent = !(await link.requestServiceDetail(pillId)) && link.serviceDetails[pillId] == nil
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            ServiceMochi(pillId: pillId, tone: snapshot?.tone, corner: 22)
                .frame(width: 84, height: 84)
            VStack(alignment: .leading, spacing: 4) {
                Text(pill?.name ?? pillId).font(.headline)
                if let snapshot {
                    Text(snapshot.headline)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(snapshot.tone == .idle ? Color.secondary : snapshot.tone.color)
                    Text(snapshot.updatedAt, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not connected").font(.subheadline).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func reasonCard(_ snapshot: ServiceSnapshot) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(snapshot.tone.color)
                .frame(width: 12, height: 12)
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 4) {
                Text(snapshot.tone.label.capitalized)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(snapshot.tone == .idle ? Color.secondary : snapshot.tone.color)
                Text(snapshot.reason)
                    .font(.callout)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .glassCard()
        .overlay {
            if snapshot.tone == .error || snapshot.tone == .warning {
                RoundedRectangle(cornerRadius: 22).strokeBorder(snapshot.tone.color.opacity(0.7), lineWidth: 1.5)
            }
        }
    }

    private func sectionCard(_ section: ServiceSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(section.title).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            ForEach(Array(section.items.enumerated()), id: \.offset) { index, item in
                itemRow(item)
                if index < section.items.count - 1 { Divider() }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
    }

    @ViewBuilder private func itemRow(_ item: ServiceItem) -> some View {
        let row = HStack(alignment: .firstTextBaseline, spacing: 10) {
            Circle()
                .fill(item.tone.color)
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.callout)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 6)
            if let date = item.date {
                Text(date, format: .relative(presentation: .named))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        if let link = item.url.flatMap(URL.init(string:)), link.scheme == "https" {
            Link(destination: link) { row }
        } else {
            row
        }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Connect \(pill?.name ?? "it") on your Mac")
                .font(.subheadline.weight(.semibold))
            Text("Add its key in Coucou's Settings on your Mac and keep the iPhone switch on (Settings → General → iPhone). What the Mac sees shows up here: no key is stored on your iPhone.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 22))
    }
}
