#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir/Check.swift" <<'PY'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/App/SessionDrop.swift').read_text()
targets = source[source.index('    static func targets('):source.index('    /// Where each target sits')]
send = source[source.index('    static func send('):source.index('    /// Types the text')]
controller = Path('NotchBuddy/Sources/App/IslandWindowController.swift').read_text()
start = controller.index('                // Dropped on a session: into its prompt.')
end = controller.index('\n            }\n        }', start)
drop = controller[start:end].replace('                #endif\n', '')
fixture = r'''import Foundation
struct AgentTask {
    var id: String
    var isIntegration = false
    var sessionBundleId: String?
    var name = "fixture"
    var pill: String { String(id.split(separator: "#", maxSplits: 1).first ?? "") }
}
@MainActor final class AppState {
    static let shared = AppState()
    var tasks: [AgentTask] = []
    var fileDragOver = true
    var dropSessionTarget: String?
    var noteMessage = ""
}
@MainActor final class FakeApplication {
    let bundleIdentifier: String?
    var activations = 0
    init(_ id: String) { bundleIdentifier = id }
    func activate() -> Bool { activations += 1; return true }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    var runningApplications: [FakeApplication] = []
}
@MainActor final class UploadSequenceEngine {
    static let shared = UploadSequenceEngine()
    var exits = 0
    func exitZone() { exits += 1 }
}
@MainActor final class SoundEngine {
    static let shared = SoundEngine()
    func play(_ name: String) {}
}
enum BotEmote { case happy }
enum IslandView { case note }
extension Notification.Name {
    static let islandCollapse = Notification.Name("islandCollapse")
    static let triggerEmote = Notification.Name("triggerEmote")
    static let hookExpand = Notification.Name("hookExpand")
}
func appendAppLog(_ file: String, _ line: String) {}
@MainActor enum FileDropHandler {
    static var handled: [URL] = []
    static func handle(urls: [URL], state: AppState) async {
        handled += urls
        state.fileDragOver = false
    }
}
@MainActor enum SessionDrop {
    static var pasted: [String] = []
TARGETS
SEND
    private static func paste(_ value: String) -> Bool { pasted.append(value); return true }
}
@MainActor func dispatchDrop(_ urls: [URL]) async {
DROP
}
@main enum Check {
    @MainActor static func main() async {
        let state = AppState.shared
        let claude = AgentTask(id: "integration_claude#2", sessionBundleId: "com.apple.Terminal")
        let native = AgentTask(id: "agent_codex", sessionBundleId: "fr.louisraille.NotchBuddy")
        let desktop = AgentTask(id: "agent_codex#2", sessionBundleId: "com.openai.codex")
        let editor = AgentTask(id: "agent_codex#3", sessionBundleId: "com.microsoft.VSCode")
        state.tasks = [native, desktop, editor, claude]
        assert(SessionDrop.targets(state).map(\.id) == [claude.id])
        let url = URL(fileURLWithPath: "/tmp/file with space.txt")
        let app = FakeApplication("com.apple.Terminal")
        NSWorkspace.shared.runningApplications = [app]
        for id in [native.id, desktop.id, editor.id] { assert(!SessionDrop.send([url], to: id, state: state)) }
        assert(state.fileDragOver && UploadSequenceEngine.shared.exits == 0 && SessionDrop.pasted.isEmpty && app.activations == 0)
        state.dropSessionTarget = native.id
        await dispatchDrop([url])
        assert(FileDropHandler.handled == [url] && state.dropSessionTarget == nil && !state.fileDragOver)
        assert(SessionDrop.pasted.isEmpty && app.activations == 0)
        state.fileDragOver = true
        state.dropSessionTarget = claude.id
        state.tasks = [AgentTask(id: claude.id, isIntegration: true, sessionBundleId: claude.sessionBundleId)]
        await dispatchDrop([url])
        assert(FileDropHandler.handled == [url, url] && state.dropSessionTarget == nil && !state.fileDragOver)
        assert(UploadSequenceEngine.shared.exits == 0 && SessionDrop.pasted.isEmpty && app.activations == 0)
        state.fileDragOver = true
        state.dropSessionTarget = claude.id
        state.tasks = [claude]
        await dispatchDrop([url])
        try? await Task.sleep(for: .milliseconds(400))
        assert(!state.fileDragOver && UploadSequenceEngine.shared.exits == 1 && app.activations == 1)
        assert(FileDropHandler.handled == [url, url] && state.dropSessionTarget == nil)
        assert(SessionDrop.pasted == ["/tmp/file\\ with\\ space.txt "])
        print("PASS actual SessionDrop/caller: Codex and stale targets use original-file fallback; valid Claude keeps terminal route")
    }
}
'''
Path(sys.argv[1]).write_text(fixture.replace('TARGETS', targets).replace('SEND', send).replace('DROP', drop))
PY
swiftc -parse-as-library NotchBuddy/Sources/App/LaunchScript.swift NotchBuddy/Sources/App/TerminalTarget.swift "$test_dir/Check.swift" -o "$test_dir/check"
"$test_dir/check"
