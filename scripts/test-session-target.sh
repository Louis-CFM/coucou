#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/Check.swift" <<'SWIFT'
import Foundation

struct AgentTask {
    var id = ""
    var codexManaged = false
    var sessionBundleId: String?
    var sessionCwd: String?
}
enum ChatProvider { case codex }
enum IslandView { case prompt, note }
@MainActor final class AppState {
    static let shared = AppState()
    var chatProvider = ChatProvider.codex
    var view = IslandView.note
    var noteMessage = ""
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    class OpenConfiguration { var activates = false }
    var apps = ["com.openai.codex": URL(fileURLWithPath: "/Applications/Renamed Codex.app"),
                "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Code.app"),
                "com.anthropic.claudefordesktop": URL(fileURLWithPath: "/Applications/Claude.app"),
                "com.todesktop.230313mzl4w4u92": URL(fileURLWithPath: "/Applications/Cursor.app")]
    var opened: URL?
    var project: URL?
    func urlForApplication(withBundleIdentifier id: String) -> URL? { apps[id] }
    func openApplication(at url: URL, configuration: OpenConfiguration, completionHandler: (Any?, Error?) -> Void) {
        opened = url; completionHandler(nil, nil)
    }
    func open(_ urls: [URL], withApplicationAt url: URL, configuration: OpenConfiguration, completionHandler: (Any?, Error?) -> Void) {
        opened = url; project = urls.first; completionHandler(nil, nil)
    }
}
@main struct Check {
    @MainActor static func main() {
        let desktop: [String: Any] = ["coucou_agent": "codex", "originator": "Codex Desktop", "term_program": "", "bundle_id": ""]
        assert(SessionTarget.bundleId(payload: desktop) == "com.openai.codex")
        var inherited = desktop; inherited["bundle_id"] = "com.microsoft.VSCode"
        assert(SessionTarget.bundleId(payload: inherited) == "com.openai.codex")
        assert(SessionTarget.bundleId(payload: ["coucou_agent":"codex", "originator":"codex_cli_rs"]) == nil)
        assert(SessionTarget.bundleId(payload: ["coucou_agent":"claude", "originator":"Codex Desktop"]) == nil)
        assert(SessionTarget.bundleId(payload: ["coucou_agent":"codex", "term_program":"vscode"]) == "com.microsoft.VSCode")
        assert(SessionTarget.bundleId(payload: ["coucou_agent":"codex", "term_program":"warpterminal"]) == "dev.warp.Warp-Stable")
        assert(SessionTarget.bundleId(payload: ["coucou_agent":"claude", "bundle_id":"com.cmuxterm.app", "term_program":"ghostty"]) == "com.cmuxterm.app")
        let workspace = NSWorkspace.shared
        SessionTarget.open(AgentTask(sessionBundleId: SessionTarget.bundleId(payload: desktop)))
        assert(workspace.opened == workspace.apps["com.openai.codex"] && workspace.project == nil)
        SessionTarget.open(AgentTask(sessionBundleId: "com.microsoft.VSCode", sessionCwd: "/project with spaces"))
        assert(workspace.opened == workspace.apps["com.microsoft.VSCode"] && workspace.project?.path == "/project with spaces")
        SessionTarget.open(AgentTask(id: "agent_claude-desktop"))
        assert(workspace.opened == workspace.apps["com.anthropic.claudefordesktop"])
        SessionTarget.open(AgentTask(id: "agent_cursor"))
        assert(workspace.opened == workspace.apps["com.todesktop.230313mzl4w4u92"])
        SessionTarget.open(AgentTask(id: "integration_claude"))
        assert(workspace.opened == workspace.apps["com.microsoft.VSCode"])
        workspace.opened = nil
        SessionTarget.open(AgentTask(codexManaged: true))
        assert(AppState.shared.view == .prompt && workspace.opened == nil)
        SessionTarget.open(AgentTask())
        assert(AppState.shared.view == .note && !AppState.shared.noteMessage.isEmpty)
        print("PASS actual session target: Desktop originator, renamed app, IDE project, upstream Claude Desktop, managed Chat and unknown host")
    }
}
SWIFT
# Exercise the shipped host table, excluding its unrelated AppKit activation method.
python3 - "$task_tmp/ClaudeHost.swift" <<'HOSTPY'
from pathlib import Path
import sys
source = Path("NotchBuddy/Sources/App/ClaudeHost.swift").read_text()
pure = source.split("    /// Brings the session's terminal forward", 1)[0]
Path(sys.argv[1]).write_text(pure.replace("import AppKit", "import Foundation", 1) + "}\n")
HOSTPY
swiftc -parse-as-library NotchBuddy/Sources/App/SessionTarget.swift "$task_tmp/ClaudeHost.swift" "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check"

# Compile the real Swift string literals, then exercise both relays without a socket or user configuration.
python3 - "$task_tmp" <<'PY'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
start = source.index('private let nbHookPythonGitHub =')
swift = 'import Foundation\n' + source[start:] + '\ntry nbHookPythonGitHub.write(toFile: CommandLine.arguments[1], atomically: true, encoding: .utf8)\ntry nbHookPythonAppStore.write(toFile: CommandLine.arguments[2], atomically: true, encoding: .utf8)\n'
Path(sys.argv[1], 'Relay.swift').write_text(swift)
PY
swift "$task_tmp/Relay.swift" "$task_tmp/github.py" "$task_tmp/appstore.py"
python3 - "$task_tmp" <<'PY'
import io, json, os, runpy, sys
from pathlib import Path
from unittest.mock import patch
task_root = sys.argv[1]
captured = []
class Socket:
    def settimeout(self, value): pass
    def connect(self, path): pass
    def sendall(self, data): captured.append(json.loads(data))
    def close(self): pass
for name in ['github.py', 'appstore.py']:
    for provided, expected in [(None, 'Codex Desktop'), ('Codex IDE', 'Codex IDE')]:
        payload = {'hook_event_name':'UserPromptSubmit', 'cwd':'/fixture', 'session_id':'fixture'}
        if provided is not None: payload['originator'] = provided
        with patch.dict(os.environ, {'CODEX_INTERNAL_ORIGINATOR_OVERRIDE':'Codex Desktop'}, clear=True), patch('socket.socket', return_value=Socket()), patch.object(sys, 'argv', [name, '--agent', 'codex']), patch.object(sys, 'stdin', io.TextIOWrapper(io.BytesIO(json.dumps(payload).encode()))):
            try: runpy.run_path(str(Path(task_root, name)))
            except SystemExit as error: assert error.code == 0
        assert captured[-1]['originator'] == expected and captured[-1]['coucou_agent'] == 'codex'
print('PASS actual GitHub and App Store hook relays forward Desktop originator and preserve explicit source')
PY
