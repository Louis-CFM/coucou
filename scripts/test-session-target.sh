#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/Check.swift" <<'SWIFT'
import Foundation

enum AgentSource { case claudeCode, n8n, agent }
struct AgentTask {
    var id = ""
    var name = "Project"
    var codexManaged = false
    var sessionBundleId: String?
    var sessionCwd: String?
    var hostApp: String?
    var source = AgentSource.agent
}
enum ChatProvider { case codex }
enum IslandView { case prompt, note, finished, error }
struct AskQuestion {
    var pillId: String?
    var isCodexPlugin = false
    var projectName: String?
    var requestId: String?
}
@MainActor final class AppState {
    static let shared = AppState()
    var chatProvider = ChatProvider.codex
    var view = IslandView.note
    var noteMessage = ""
    var focusTask: AgentTask?
    var tasks: [AgentTask] = []
}
@MainActor final class HookServer {
    static let shared = HookServer()
    var onAsk: (() -> Void)?
    var requestId: String?
    func sendQuestionAsk(for id: String?) { requestId = id; onAsk?() }
}
enum FixtureNotificationName { case islandCollapse }
@MainActor final class NotificationCenter {
    static let `default` = NotificationCenter()
    var collapseCount = 0
    func post(name: FixtureNotificationName, object: Any?) { collapseCount += 1 }
}
@MainActor final class NSWorkspace {
    static let shared = NSWorkspace()
    class OpenConfiguration { var activates = false }
    var apps = ["com.openai.codex": URL(fileURLWithPath: "/Applications/Renamed Codex.app"),
                "com.openai.chat": URL(fileURLWithPath: "/Applications/Renamed ChatGPT.app"),
                "com.microsoft.VSCode": URL(fileURLWithPath: "/Applications/Code.app"),
                "com.anthropic.claudefordesktop": URL(fileURLWithPath: "/Applications/Claude.app"),
                "com.apple.Terminal": URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"),
                "com.mitchellh.ghostty": URL(fileURLWithPath: "/Applications/Ghostty.app"),
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
        let desktopTask = AgentTask(id: "agent_codex", sessionBundleId: SessionTarget.bundleId(payload: desktop))
        assert(SessionTarget.actionLabel(for: desktopTask) == "Open Codex")
        assert(desktopTask.sessionOriginLabel == "Codex Desktop")
        SessionTarget.open(desktopTask)
        assert(workspace.opened == workspace.apps["com.openai.codex"] && workspace.project == nil)
        workspace.apps.removeValue(forKey: "com.openai.codex")
        SessionTarget.open(desktopTask)
        assert(workspace.opened == workspace.apps["com.openai.chat"] && workspace.project == nil)
        let chatGPTHost = AgentTask(id: "agent_codex", sessionBundleId: "com.openai.chat")
        assert(SessionTarget.actionLabel(for: chatGPTHost) == "Open Codex" && chatGPTHost.sessionOriginLabel == "Codex Desktop")
        assert(AgentTask(id: "ai_openai", sessionBundleId: "com.openai.chat").sessionOriginLabel == "ChatGPT")
        assert(SessionTarget.actionLabel(for: AgentTask(id: "ai_openai", sessionBundleId: "com.openai.chat")) == "Open session source")
        workspace.opened = nil
        SessionTarget.open(AgentTask(id: "integration_claude", sessionBundleId: "com.openai.codex"))
        assert(workspace.opened == nil && AppState.shared.view == .note)
        workspace.apps.removeValue(forKey: "com.openai.chat")
        SessionTarget.open(desktopTask)
        assert(workspace.opened == nil && AppState.shared.view == .note)
        assert(SessionTarget.actionLabel(for: AgentTask(id: "agent_codex")) == "Open session source")
        assert(SessionTarget.actionLabel(for: AgentTask(sessionBundleId: "com.microsoft.VSCode")) == "Open editor")
        SessionTarget.open(AgentTask(sessionBundleId: "com.microsoft.VSCode", sessionCwd: "/project with spaces"))
        assert(workspace.opened == workspace.apps["com.microsoft.VSCode"] && workspace.project?.path == "/project with spaces")
        SessionTarget.open(AgentTask(id: "agent_claude-desktop"))
        assert(workspace.opened == workspace.apps["com.anthropic.claudefordesktop"])
        SessionTarget.open(AgentTask(id: "agent_cursor"))
        assert(workspace.opened == workspace.apps["com.todesktop.230313mzl4w4u92"])
        SessionTarget.open(AgentTask(id: "integration_claude"))
        assert(workspace.opened == workspace.apps["com.microsoft.VSCode"])
        let terminalTask = AgentTask(id: "integration_claude", hostApp: "com.mitchellh.ghostty")
        assert(SessionTarget.actionLabel(for: terminalTask) == "Open terminal")
        SessionTarget.open(terminalTask)
        assert(workspace.opened == workspace.apps["com.mitchellh.ghostty"])
        workspace.opened = nil
        assert(SessionTarget.actionLabel(for: AgentTask(codexManaged: true)) == "Continue chat")
        SessionTarget.open(AgentTask(codexManaged: true))
        assert(AppState.shared.view == .prompt && workspace.opened == nil)
        assert(SessionTarget.actionLabel(for: AgentTask()) == "Open session source")
        assert(SessionTarget.actionLabel(for: nil) == "Open session source")
        SessionTarget.open(AgentTask())
        assert(AppState.shared.view == .note && !AppState.shared.noteMessage.isEmpty && workspace.opened == nil)
        SessionTarget.open(AgentTask(id: "integration_claude", sessionBundleId: ""))
        assert(AppState.shared.view == .note && workspace.opened == nil)
        SessionTarget.open(AgentTask(sessionBundleId: "unknown.source"))
        assert(AppState.shared.view == .note && workspace.opened == nil)
        let state = AppState.shared
        state.view = .finished; state.focusTask = AgentTask(codexManaged: true)
        finishAction(state: state)
        assert(state.view == .prompt && NotificationCenter.default.collapseCount == 0)
        state.view = .finished; state.focusTask = AgentTask(sessionBundleId: "unknown.source")
        finishAction(state: state)
        assert(state.view == .note && NotificationCenter.default.collapseCount == 0)
        state.view = .finished; state.focusTask = AgentTask(sessionBundleId: "com.microsoft.VSCode")
        finishAction(state: state)
        assert(workspace.opened == workspace.apps["com.microsoft.VSCode"] && NotificationCenter.default.collapseCount == 1)
        workspace.apps["com.openai.chat"] = URL(fileURLWithPath: "/Applications/Renamed ChatGPT.app")
        let errors = ErrorSourceFixture(state: state)
        state.focusTask = AgentTask(id: "agent_codex", sessionBundleId: "com.openai.chat")
        assert(errors.kind == "Codex")
        state.view = .error
        errors.openAction()
        assert(workspace.opened == workspace.apps["com.openai.chat"] && NotificationCenter.default.collapseCount == 2)
        state.view = .error; state.focusTask = AgentTask(codexManaged: true)
        errors.openAction()
        assert(state.view == .prompt && NotificationCenter.default.collapseCount == 2)
        state.view = .error; state.focusTask = AgentTask(sessionBundleId: "unknown.source")
        errors.openAction()
        assert(state.view == .note && NotificationCenter.default.collapseCount == 2)
        for (source, expected) in [(AgentSource.claudeCode, "Claude Code"), (.n8n, "n8n"), (.agent, "Agent")] {
            state.focusTask = AgentTask(source: source)
            assert(errors.kind == expected)
        }
        let pluginQuestion = AskQuestion(pillId: "agent_codex", isCodexPlugin: true, projectName: "Plugin project", requestId: "plugin-request")
        let nativeOwner = AgentTask(id: "agent_codex", name: "Native project", codexManaged: true)
        let ideOwner = AgentTask(id: "agent_codex", name: "IDE project", sessionBundleId: "com.microsoft.VSCode")
        let questionView = QuestionSourceFixture(state: state)
        for owner in [nativeOwner, ideOwner] {
            state.tasks = [owner]
            let source = questionView.questionSource(for: pluginQuestion)!
            assert(!source.codexManaged && source.sessionBundleId == "com.openai.codex"
                && source.name == "Plugin project" && source.sessionOriginLabel == "Codex Desktop")
            assert(state.tasks[0].name == owner.name && state.tasks[0].codexManaged == owner.codexManaged
                && state.tasks[0].sessionBundleId == owner.sessionBundleId)
        }
        state.tasks = [nativeOwner]
        let nativeQuestion = AskQuestion(pillId: "agent_codex")
        assert(questionView.questionSource(for: nativeQuestion)!.codexManaged)
        workspace.apps["com.openai.chat"] = URL(fileURLWithPath: "/Applications/Renamed ChatGPT.app")
        workspace.opened = nil
        HookServer.shared.onAsk = { state.tasks = [nativeOwner] }
        state.tasks = [ideOwner]
        questionView.replyAction(q: pluginQuestion)
        assert(HookServer.shared.requestId == "plugin-request" && state.tasks[0].codexManaged
            && workspace.opened == workspace.apps["com.openai.chat"])
        HookServer.shared.onAsk = nil
        print("PASS actual session target: source labels, old/renamed Codex, ChatGPT host fallback, IDE project, upstream Claude Desktop, managed Chat and unknown host")
        print("PASS actual completion/error actions: continue chat and unknown-source note stay open, external source collapses; errors identify Codex")
        print("PASS actual question source/reply action: plugin returns to captured Desktop with native/IDE pill owners, original tasks unchanged")
    }
}
SWIFT
# Exercise the shipped host table, excluding its unrelated AppKit activation method.
python3 - "$task_tmp/ClaudeHost.swift" <<'HOSTPY'
from pathlib import Path
import re
import sys
source = Path("NotchBuddy/Sources/App/ClaudeHost.swift").read_text()
pure = source.split("    /// Brings the session's terminal forward", 1)[0]
Path(sys.argv[1]).write_text(pure.replace("import AppKit", "import Foundation", 1) + "}\n")
models = Path("NotchBuddy/Sources/CoucouKit/IslandTypes.swift").read_text()
label = models.split("    var sessionOriginLabel: String {", 1)[1].split("    var finalLine:", 1)[0]
Path(sys.argv[1]).with_name("OriginLabel.swift").write_text("extension AgentTask {\n    var sessionOriginLabel: String {" + label + "}\n")
view = Path("NotchBuddy/Sources/App/IslandViewContent.swift").read_text().split("struct FinishedView: View {", 1)[1]
action = view.split("PrimaryButton(SessionTarget.actionLabel(for: state.focusTask)) {", 1)[1].split("\n                        }\n                        #endif", 1)[0]
Path(sys.argv[1]).with_name("FinishAction.swift").write_text("@MainActor func finishAction(state: AppState) {" + action + "\n}\n")
errors = Path("NotchBuddy/Sources/App/IslandViewContent.swift").read_text().split("struct ErrorView: View {", 1)[1].split("/// Brings the Claude desktop app forward", 1)[0]
kind = errors.split("    private var kind: String {", 1)[1].split("\n    /// What went wrong", 1)[0]
action = errors.split("PrimaryButton(SessionTarget.actionLabel(for: task)) {", 1)[1].split("\n                        }\n                        #endif", 1)[0]
Path(sys.argv[1]).with_name("ErrorSource.swift").write_text("@MainActor struct ErrorSourceFixture {\nlet state: AppState\nvar task: AgentTask? { state.focusTask }\nvar kind: String {" + kind + "\nfunc openAction() {" + action + "\n}\n}\n")
question = Path("NotchBuddy/Sources/App/IslandViewContent.swift").read_text().split("struct QuestionView: View {", 1)[1].split("// MARK: - Confused", 1)[0]
helper = question.split("    private func questionSource(", 1)[1].split("    private func resetQuestionState()", 1)[0]
reply = re.split(r"\n\s*}\n\s*\.buttonStyle", question.split('String(localized: "Reply in terminal")) {', 1)[1], maxsplit=1)[0]
Path(sys.argv[1]).with_name("QuestionSource.swift").write_text("@MainActor struct QuestionSourceFixture {\nlet state: AppState\nfunc questionSource(" + helper + "\nfunc replyAction(q: AskQuestion) {" + reply + "\n}\n}\n")
assert "AgentWho(task: questionSource(for: q)," in question
descriptions = re.split(r"} else \{\s*ChipFlowLayout", question.split("} else if item.hasDescriptions {", 1)[1], maxsplit=1)[0]
assert re.search(r'if item\.isOther \{\s*SecondaryButton\("Other…"\)', descriptions)
assert descriptions.count('SecondaryButton("Other…")') == 1
assert "ScrollView {\n                    VStack(alignment: .leading, spacing: 4)" in question
scroll = question.split("                ScrollView {\n", 1)[1].split("\n                }", 1)[0]
assert scroll.splitlines()[-1] == "                    .frame(maxWidth: .infinity, alignment: .leading)"
print("PASS actual question layouts: description choices honor isOther before offering typed input")
HOSTPY
swiftc -parse-as-library NotchBuddy/Sources/App/SessionTarget.swift "$task_tmp/ClaudeHost.swift" "$task_tmp/OriginLabel.swift" "$task_tmp/FinishAction.swift" "$task_tmp/ErrorSource.swift" "$task_tmp/QuestionSource.swift" "$task_tmp/Check.swift" -o "$task_tmp/check"
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
