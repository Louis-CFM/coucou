import AppKit
import SwiftUI

// MARK: - Notch card

struct WeeklyRecapCardView: View {
    @ObservedObject var state: AppState
    @State private var summary: WeeklySummary? = nil

    var body: some View {
        ZStack {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 5) {
                if let s = summary {
                    HStack(spacing: 0) {
                        Text(String(localized: "recap.title"))
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#818CF8"))
                        Spacer(minLength: 6)
                        Text(weekRangeLabel(s))
                            .font(.system(size: 10))
                            .foregroundColor(Color(hex: "#8E939C"))
                            .lineLimit(1)
                    }
                    HStack(spacing: 14) {
                        statChip(formatDuration(s.totalMinutes), label: String(localized: "recap.coding"))
                        statChip("\(s.sessionCount)", label: s.sessionCount == 1 ? String(localized: "recap.session") : String(localized: "recap.sessions"))
                        statChip("\(s.filesChanged)", label: s.filesChanged == 1 ? String(localized: "recap.file") : String(localized: "recap.files"))
                        if s.commandsRun > 0 {
                            statChip("\(s.commandsRun)", label: String(localized: "recap.commands"))
                        }
                        if s.linesAdded + s.linesRemoved > 0 {
                            statChip("+\(s.linesAdded) / -\(s.linesRemoved)", label: "lines")
                        }
                        if s.questionsAnswered > 0 {
                            statChip("\(s.questionsAnswered)", label: s.questionsAnswered == 1 ? "question" : "questions")
                        }
                    }
                    HStack(spacing: 8) {
                        PrimaryButton(verbatim: String(localized: "recap.share-image")) { shareImage(s) }
                        SecondaryButton("OK") {
                            NotificationCenter.default.post(name: .islandCollapse, object: nil)
                        }
                    }
                } else {
                    Text(String(localized: "recap.no-activity"))
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Color(hex: "#F1F2F4"))
                    SecondaryButton("OK") {
                        NotificationCenter.default.post(name: .islandCollapse, object: nil)
                    }
                }
            }
            .padding(.leading, 116)
            .padding(.trailing, 16)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .onAppear { summary = RecapStore.shared.weeklySummary() }
        .onChange(of: state.view) { _, newView in
            if newView == .recap { summary = RecapStore.shared.weeklySummary() }
        }
    }

    private func statChip(_ value: String, label: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.system(size: 17, weight: .bold))
                .foregroundColor(Color(hex: "#F1F2F4"))
            Text(label)
                .font(.system(size: 9))
                .foregroundColor(Color(hex: "#8E939C"))
        }
    }

    private func weekRangeLabel(_ s: WeeklySummary) -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: s.weekStart)) – \(fmt.string(from: s.weekEnd))"
    }

    private func shareImage(_ s: WeeklySummary) {
        RecapSharePanel.show(summary: s, hideProjects: state.recapHideProjects)
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}

// MARK: - Share panel

@MainActor
enum RecapSharePanel {
    private static var window: NSWindow?

    static func show(summary: WeeklySummary, hideProjects: Bool) {
        if let w = window, w.isVisible { w.makeKeyAndOrderFront(nil); return }
        let win = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 440, height: 540),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false
        )
        win.title = String(localized: "recap.title")
        win.titlebarAppearsTransparent = true
        win.isMovableByWindowBackground = true
        let host = NSHostingView(rootView: RecapSharePanelView(summary: summary, hideProjects: hideProjects))
        host.sizingOptions = [.minSize]
        win.contentView = host
        win.isReleasedWhenClosed = false
        win.center()
        window = win
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - Share panel view

private struct RecapSharePanelView: View {
    let summary: WeeklySummary
    let hideProjects: Bool
    @State private var nsImage: NSImage? = nil
    @State private var copied = false

    var body: some View {
        VStack(spacing: 16) {
            Group {
                if let img = nsImage {
                    Image(nsImage: img)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .cornerRadius(12)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                } else {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color(hex: "#141518"))
                        .overlay(ProgressView())
                }
            }
            .frame(maxHeight: 380)

            HStack(spacing: 10) {
                Button(copied ? "Copied!" : "Copy image") {
                    guard let img = nsImage else { return }
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([img])
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                }
                .buttonStyle(.borderedProminent)

                Button("Save…") {
                    guard let img = nsImage else { return }
                    let panel = NSSavePanel()
                    panel.nameFieldStringValue = "coucou-weekly-recap.png"
                    panel.allowedContentTypes = [.png]
                    panel.begin { result in
                        guard result == .OK, let url = panel.url else { return }
                        if let tiff = img.tiffRepresentation,
                           let rep = NSBitmapImageRep(data: tiff),
                           let png = rep.representation(using: .png, properties: [:]) {
                            try? png.write(to: url)
                        }
                    }
                }
                .buttonStyle(.bordered)

                Button("Share…") {
                    guard let img = nsImage else { return }
                    guard let view = NSApp.keyWindow?.contentView else { return }
                    let picker = NSSharingServicePicker(items: [img])
                    picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
                }
                .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .onAppear { renderImage() }
    }

    private func renderImage() {
        let shareView = RecapShareImageView(summary: summary, hideProjects: hideProjects)
        let renderer = ImageRenderer(content: shareView)
        renderer.proposedSize = ProposedViewSize(width: 1080, height: 1920)
        renderer.scale = 1
        if let cgImage = renderer.cgImage {
            nsImage = NSImage(cgImage: cgImage, size: NSSize(width: 1080, height: 1920))
        }
    }
}

// MARK: - Share image (1080×1920)

struct RecapShareImageView: View {
    let summary: WeeklySummary
    let hideProjects: Bool

    // Static BotEngine for the Mochi snapshot — idle state, no animation needed.
    @StateObject private var mochiEngine = BotEngine()

    var body: some View {
        ZStack {
            Color(hex: "#0B0C0E")
            RadialGradient(
                gradient: Gradient(stops: [
                    .init(color: Color(hex: "#6366F1").opacity(0.30), location: 0),
                    .init(color: Color.clear, location: 0.65)
                ]),
                center: UnitPoint(x: 0.5, y: 0.75),
                startRadius: 0,
                endRadius: 900
            )
            VStack(spacing: 0) {
                Spacer()

                // Mochi character
                Canvas { context, size in
                    mochiEngine.draw(context: context, size: size)
                }
                .frame(width: 200, height: 200)
                .padding(.bottom, 20)

                Text("Coucou")
                    .font(.system(size: 52, weight: .black, design: .rounded))
                    .foregroundColor(Color(hex: "#F1F2F4"))
                Text(String(localized: "recap.title"))
                    .font(.system(size: 30, weight: .medium))
                    .foregroundColor(Color(hex: "#8E939C"))
                    .padding(.top, 6)
                Text(weekRangeLabel)
                    .font(.system(size: 24))
                    .foregroundColor(Color(hex: "#818CF8"))
                    .padding(.top, 14)
                    .padding(.bottom, 80)

                // Primary stat — time
                VStack(spacing: 6) {
                    Text(formatDuration(summary.totalMinutes))
                        .font(.system(size: 100, weight: .black, design: .rounded))
                        .foregroundColor(Color(hex: "#F1F2F4"))
                        .minimumScaleFactor(0.4)
                        .lineLimit(1)
                    Text(String(localized: "recap.image.time-coding"))
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundColor(Color(hex: "#8E939C"))
                        .tracking(3)
                }

                // Secondary stats
                HStack(spacing: 0) {
                    statBlock("\(summary.sessionCount)", label: String(localized: "recap.image.sessions"))
                    statDivider()
                    statBlock("\(summary.filesChanged)", label: String(localized: "recap.image.files"))
                    if summary.commandsRun > 0 {
                        statDivider()
                        statBlock("\(summary.commandsRun)", label: String(localized: "recap.image.commands"))
                    }
                }
                .padding(.top, 56)
                .padding(.horizontal, 40)

                // Lines added / removed
                if summary.linesAdded + summary.linesRemoved > 0 {
                    HStack(spacing: 24) {
                        Text("+\(summary.linesAdded)")
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "#4ADE80"))
                        Text("−\(summary.linesRemoved)")
                            .font(.system(size: 28, weight: .semibold, design: .monospaced))
                            .foregroundColor(Color(hex: "#F87171"))
                    }
                    .padding(.top, 24)
                }

                // Badges
                VStack(spacing: 16) {
                    if let agent = summary.topAgent {
                        recapBadge(String(localized: "recap.image.top-agent"), value: agent)
                    }
                    if !hideProjects, let project = summary.topProject {
                        recapBadge(String(localized: "recap.image.top-project"), value: project)
                    }
                    if let day = summary.busiestDay {
                        recapBadge(String(localized: "recap.image.busiest-day"), value: day)
                    }
                    if summary.longestSessionMinutes > 1 {
                        recapBadge(String(localized: "recap.image.longest-session"), value: formatDuration(summary.longestSessionMinutes))
                    }
                    if summary.permissionsAllowed + summary.permissionsDenied > 0 {
                        HStack(spacing: 16) {
                            recapBadge(String(localized: "recap.image.approved"), value: "\(summary.permissionsAllowed)")
                            recapBadge(String(localized: "recap.image.denied"), value: "\(summary.permissionsDenied)")
                        }
                    }
                }
                .padding(.top, 56)
                .padding(.horizontal, 60)

                Spacer()

                Text("Coucou · github.com/Louis-CFM/coucou")
                    .font(.system(size: 20, weight: .medium, design: .monospaced))
                    .foregroundColor(Color(hex: "#8E939C").opacity(0.6))
                    .padding(.bottom, 60)
            }
        }
        .frame(width: 1080, height: 1920)
    }

    @ViewBuilder
    private func statBlock(_ value: String, label: String) -> some View {
        VStack(spacing: 8) {
            Text(value)
                .font(.system(size: 64, weight: .black, design: .rounded))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(label)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(Color(hex: "#8E939C"))
                .tracking(2)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private func statDivider() -> some View {
        Rectangle()
            .fill(Color.white.opacity(0.08))
            .frame(width: 1, height: 80)
    }

    @ViewBuilder
    private func recapBadge(_ label: String, value: String) -> some View {
        HStack(spacing: 16) {
            Text(label)
                .font(.system(size: 24))
                .foregroundColor(Color(hex: "#8E939C"))
            Spacer()
            Text(value)
                .font(.system(size: 24, weight: .semibold))
                .foregroundColor(Color(hex: "#F1F2F4"))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 18)
        .background(Color.white.opacity(0.05))
        .cornerRadius(18)
    }

    private var weekRangeLabel: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "MMM d"
        return "\(fmt.string(from: summary.weekStart)) – \(fmt.string(from: summary.weekEnd))"
    }

    private func formatDuration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
