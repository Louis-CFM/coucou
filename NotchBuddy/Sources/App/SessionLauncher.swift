#if !APPSTORE
import AppKit
import SwiftUI

/// Starts a Claude Code session from the notch: a prompt (typed or dictated), a project, and
/// Coucou opens the terminal there with `claude "<prompt>"`. The session then shows in the notch
/// like any other, through the hooks. GitHub build: the App Store build can't start programs.
@MainActor
final class SessionLauncher: ObservableObject {
    static let shared = SessionLauncher()

    private static let projectsKey = "launcher.recentProjects"
    private static let folderKey = "launcher.folder"
    private static let terminalKey = "launcher.lastTerminal"

    /// The folders sessions ran in, most recent first.
    @Published private(set) var projects: [String]
    /// The folder the next session starts in.
    @Published var folder: String?

    private init() {
        let d = UserDefaults.standard
        projects = d.stringArray(forKey: Self.projectsKey) ?? []
        folder = d.string(forKey: Self.folderKey) ?? projects.first
    }

    /// Each Claude Code session teaches Coucou a project, and the terminal it runs in.
    func remember(folder path: String, terminal bundleId: String) {
        guard !path.isEmpty else { return }
        let list = LaunchScript.remember(path, in: projects, home: NSHomeDirectory())
        if list != projects {
            projects = list
            UserDefaults.standard.set(list, forKey: Self.projectsKey)
        }
        if folder == nil { folder = list.first }
        if !bundleId.isEmpty { UserDefaults.standard.set(bundleId, forKey: Self.terminalKey) }
    }

    func choose(_ path: String) {
        folder = path
        UserDefaults.standard.set(path, forKey: Self.folderKey)
    }

    /// Another folder, picked in an Open panel.
    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = String(localized: "launch.choose")
        if let folder { panel.directoryURL = URL(fileURLWithPath: folder) }
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let list = LaunchScript.remember(url.path, in: projects, home: NSHomeDirectory())
        projects = list
        UserDefaults.standard.set(list, forKey: Self.projectsKey)
        choose(url.path)
    }

    /// The name shown for a folder: its last component.
    static func name(of path: String) -> String {
        let last = (path as NSString).lastPathComponent
        return last.isEmpty ? path : last
    }

    /// Opens the terminal in the project with Claude Code and the prompt. False when it couldn't.
    @discardableResult
    func launch(prompt: String) -> Bool {
        guard let folder, FileManager.default.fileExists(atPath: folder) else { return false }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("CoucouLaunch", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("Claude Code \(UUID().uuidString.prefix(8)).command")
        do {
            try LaunchScript.script(prompt: prompt, folder: folder).write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        } catch {
            appendAppLog("nb.log", "[Launch] couldn't write the script: \(error)")
            return false
        }
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        let terminal = LaunchScript.terminal(lastSession: UserDefaults.standard.string(forKey: Self.terminalKey), running: running)
        guard let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: terminal)
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") else { return false }
        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        switch LaunchScript.way(for: terminal) ?? .open {
        case .open:
            NSWorkspace.shared.open([script], withApplicationAt: app, configuration: config)
        case .args(let args):
            config.createsNewApplicationInstance = true
            config.arguments = args.map { $0 == "%s" ? script.path : $0 }
            NSWorkspace.shared.openApplication(at: app, configuration: config)
        }
        appendAppLog("nb.log", "[Launch] Claude Code in \(Self.name(of: folder)) with \(terminal)")
        return true
    }
}

/// The island's "New session" card: Mochi on the left, the project, what Claude should do.
struct LaunchView: View {
    @ObservedObject var state: AppState
    @ObservedObject private var launcher = SessionLauncher.shared
    @State private var text = ""
    @State private var failed = false
    @FocusState private var focused: Bool
    @State private var dictation = MacDictation()

    var body: some View {
        ZStack(alignment: .leading) {
            CardBackground(wash: .indigo)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("launch.title")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer(minLength: 0)
                    projectMenu
                }
                HStack(spacing: 8) {
                    TextField(String(localized: "launch.placeholder"), text: $text)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .writingToolsBehavior(.disabled)
                        .onSubmit(start)
                    Button {
                        Task {
                            if dictation.isRecording { text = await dictation.finish() }
                            else { await dictation.start(from: text) }
                        }
                    } label: {
                        Image(systemName: dictation.isRecording ? "mic.fill" : "mic")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(dictation.isRecording ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                            .frame(width: 18, height: 18)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(dictation.isRecording ? String(localized: "Stop dictation") : String(localized: "Dictate (right-click to choose the language)"))
                    .contextMenu { DictationLanguageMenu(dictation: dictation) }
                    .onChange(of: dictation.transcript) { _, _ in
                        if dictation.isRecording { text = dictation.text }
                    }
                    Button(action: start) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color(hex: "#0B0C0E"))
                    }
                    .buttonStyle(SendButtonStyle())
                    .disabled(launcher.folder == nil)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(Color.white.opacity(0.07))
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .simultaneousGesture(TapGesture().onEnded { focused = true })
                Text(verbatim: failed ? String(localized: "launch.failed") : String(localized: "launch.hint"))
                    .font(.system(size: 11))
                    .foregroundColor(failed ? Color(hex: "#F4505E") : Color(hex: "#8E939C"))
                    .lineLimit(1)
            }
            .padding(.leading, 98)
            .padding(.trailing, 16)
        }
        .onChange(of: state.view) { _, view in
            if view == .launch { focused = true; failed = false }
        }
    }

    private var projectMenu: some View {
        Menu {
            ForEach(launcher.projects, id: \.self) { path in
                Button {
                    launcher.choose(path)
                } label: {
                    if path == launcher.folder { Label(SessionLauncher.name(of: path), systemImage: "checkmark") }
                    else { Text(verbatim: SessionLauncher.name(of: path)) }
                }
            }
            if !launcher.projects.isEmpty { Divider() }
            Button(String(localized: "launch.choose-folder")) { launcher.chooseFolder() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "folder").font(.system(size: 10))
                Text(verbatim: launcher.folder.map(SessionLauncher.name(of:)) ?? String(localized: "launch.no-project"))
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 8))
            }
            .foregroundColor(Color(hex: "#C9CDD4"))
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.white.opacity(0.06))
            .clipShape(Capsule())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    private func start() {
        if launcher.folder == nil { launcher.chooseFolder(); return }
        if dictation.isRecording { Task { text = await dictation.finish(); go() } } else { go() }
    }

    private func go() {
        guard SessionLauncher.shared.launch(prompt: text) else {
            failed = true
            SoundEngine.shared.play("error")
            return
        }
        text = ""
        SoundEngine.shared.play("send")
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }
}
#endif
