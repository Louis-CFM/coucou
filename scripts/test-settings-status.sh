#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Compile the actual badge decisions with in-memory configuration boundaries.
# No credentials, user preferences, hooks, or Codex processes are accessed.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import re
import sys

source = Path('NotchBuddy/Sources/App/IslandViewContent.swift').read_text()
start = source.index('struct SettingsIslandView: View {')
end = source.index('\n    var body: some View {', start)
settings = source[start:end].replace('struct SettingsIslandView: View {', 'final class SettingsIslandView {')
settings = re.sub(r'@(ObservedObject|State)\s+', '', settings).replace('private ', '')
settings += '\n    init(state: AppState) { self.state = state }\n}\n'
start = source.index('    private var isChatStreaming: Bool {')
end = source.index('\n    var body: some View {', start)
streaming = 'final class PromptView {\n    let state: AppState\n    init(state: AppState) { self.state = state }\n' + source[start:end].replace('private ', '') + '\n}\n'
types = Path('NotchBuddy/Sources/CoucouKit/IslandTypes.swift').read_text()
provider = types[types.index('enum ChatProvider:'):types.index('// MARK: - View dimensions')]
service = Path('NotchBuddy/Sources/App/CodexChatService.swift').read_text()
streaming_property = next(line.strip() for line in service.splitlines() if 'var isChatStreaming: Bool {' in line)
authentication = service[service.index('enum CodexAuthenticationStatus'):service.index('/// Owns Coucou-created')]
hub_source = Path('NotchBuddy/Sources/App/FlowHub.swift').read_text()
hub = hub_source[hub_source.index('enum HubPage:'):hub_source.index('\n/// The colors')]
hub += hub_source[hub_source.index('extension HubPage {'):hub_source.index('\n@MainActor\nfinal class HubRouter')]
assert 'HubPage.notchSubtitle(router.page, chatProvider: state.chatProvider)' in hub_source
assert '@ObservedObject private var state = AppState.shared' in hub_source
capture_source = Path('NotchBuddy/Sources/App/CaptureCardView.swift').read_text()
assert '@ObservedObject private var state = AppState.shared' in capture_source
assert 'SecondaryButton(verbatim: askLabel) { capture.askClaude() }' in capture_source
capture = 'final class CaptureCardView {\n    let state: AppState\n    let flow = CaptureFlow()\n    init(state: AppState) { self.state = state }\n'
capture += capture_source[capture_source.index('    private var askLabel:'):capture_source.rindex('\n}')].replace('private ', '') + '\n}\n'
capture_source = Path('NotchBuddy/Sources/App/ScreenCapture.swift').read_text()
start = capture_source.index('    func askClaude() {')
end = capture_source.index('\n    // MARK: - With Flow', start)
capture += 'final class ScreenCaptureFixture {\n    var url: URL?\n' + capture_source[start:end] + '\n}\n'
shortcut_logic = Path('NotchBuddy/Sources/App/ShortcutLogic.swift').read_text()
assert 'AppState' not in shortcut_logic, 'ShortcutLogic gained an application-state dependency'
shortcuts = shortcut_logic[shortcut_logic.index('enum ShortcutAction:'):shortcut_logic.index('// MARK: - Shortcut Spec')]
shortcut_source = Path('NotchBuddy/Sources/App/ShortcutsSettingsView.swift').read_text()
assert '@ObservedObject private var state = AppState.shared' in shortcut_source
assert 'Text(actionLabel(action))' in shortcut_source
start = shortcut_source.index('    private var globalActions:')
end = shortcut_source.index('\n    @ViewBuilder', start)
shortcuts += 'final class ShortcutsSettingsView {\n    let state: AppState\n    init(state: AppState) { self.state = state }\n'
shortcuts += shortcut_source[start:end].replace('private ', '') + '\n}\n'
Path(sys.argv[1]).write_text('''import Foundation
enum AgentSource { case claudeCode, n8n, agent }
struct AgentTask {
    var id: String
    var name: String
    var source: AgentSource
    var lastEventAt: Date?
}
enum PillCatalog {
    struct Definition { var name: String }
    static func definition(for id: String) -> Definition? {
        id == "agent_codex" ? Definition(name: "Codex") : nil
    }
}
final class AppState {
    static let shared = AppState()
    var tasks: [AgentTask] = []
    var focusTask: AgentTask?
    var chatProvider: ChatProvider = .anthropic
    var ollamaServerURL = ""
    var lmstudioServerURL = ""
    var stateOverride: String?
    var codexChatBusy = false
    var droppedFile: DroppedFile?
    var promptContext: PromptContext?
    var view = IslandView.home
}
struct DroppedFile { let url: URL; let name: String }
enum PromptContext { case file(name: String, fileURL: URL?) }
enum IslandView { case home, prompt }
final class CaptureFlow {
    var isEnabled = false
    var key = (label: "fn", code: 0)
}
struct Animation {
    static func spring(response: Double, dampingFraction: Double) -> Animation { Animation() }
}
func withAnimation(_ animation: Animation, _ body: () -> Void) { body() }
final class UserDefaults {
    static let standard = UserDefaults()
    var installed = true
    func bool(forKey: String) -> Bool { installed }
}
final class KeychainStore {
    static let shared = KeychainStore()
    var keys = ["anthropic-api-key": "configured", "google-api-key": "configured"]
    var reads: [String] = []
    func get(_ key: String) -> String? { reads.append(key); return keys[key] }
}
enum HookServer {
    static var installed = true
    static func claudeHooksInstalled() -> Bool { installed }
    static func geminiHooksInstalled() -> Bool { installed }
    static func agyHooksInstalled() -> Bool { installed }
    static func copilotHooksInstalled() -> Bool { installed }
    static func museHooksInstalled() -> Bool { installed }
    static func openCodePluginInstalled() -> Bool { installed }
    static func ampPluginInstalled() -> Bool { installed }
}
enum CodexHooksStatus { case done, unknown, untrusted }
final class CodexAgentsInfo {
    static let shared = CodexAgentsInfo()
    var hooksStatus: CodexHooksStatus = .unknown
}
final class CodexChatService {
    static let shared = CodexChatService()
    var authenticationStatus = CodexAuthenticationStatus.disconnected
    var isBusy = false
    var displayMessage: UUID?
''' + streaming_property + '''
}
''' + provider + authentication + settings + streaming + hub + capture + shortcuts + '''
@main struct Check {
    static func main() async {
        let state = AppState()
        assert(HubPage.notchSubtitle(.chat, chatProvider: .codex) == "codex.chat.title")
        for provider in ChatProvider.allCases where provider != .codex {
            assert(HubPage.notchSubtitle(.chat, chatProvider: provider) == "hub.notch.chat")
        }
        assert(HubPage.notchSubtitle(.agents, chatProvider: .codex) == "hub.notch.agents")
        assert(HubPage.notchSubtitle(.dictation, chatProvider: .codex) == nil)
        let capture = CaptureCardView(state: state)
        let shortcuts = ShortcutsSettingsView(state: state)
        for provider in ChatProvider.allCases {
            state.chatProvider = provider
            for action in ShortcutAction.allCases {
                let expected = action == .captureScreen && provider == .codex ? "shortcut.capture-codex" : action.displayName
                assert(shortcuts.actionLabel(action) == expected)
            }
            assert(capture.askLabel == (provider == .codex ? "capture.ask-codex" : "capture.ask"))
            assert(capture.hint == (provider == .codex ? "capture.hint-codex" : "capture.hint"))
            capture.flow.isEnabled = true
            assert(capture.hint == "capture.flow-hint fn", "Flow capture hint changed with the Chat provider")
            capture.flow.isEnabled = false
        }
        #if APPSTORE
        assert(!shortcuts.globalActions.contains(.captureScreen), "App Store exposed the unsupported capture shortcut")
        #else
        assert(shortcuts.globalActions.contains(.captureScreen))
        #endif
        let screen = ScreenCaptureFixture()
        let image = URL(fileURLWithPath: "/tmp/coucou-capture-fixture.png")
        screen.url = image
        AppState.shared.chatProvider = .codex
        screen.askClaude()
        assert(AppState.shared.chatProvider == .codex, "Capture switched away from the selected Chat provider")
        assert(AppState.shared.droppedFile?.url == image)
        if case .file(let name, let url) = AppState.shared.promptContext {
            assert(name == "capture.name" && url == image)
        } else { assertionFailure("Capture lost its shared image attachment") }
        assert(AppState.shared.view == .prompt)
        state.chatProvider = .anthropic
        state.focusTask = AgentTask(id: "integration_claude", name: "VS Code", source: .claudeCode)
        let view = SettingsIslandView(state: state)
        assert(view.agentStatus.label == "Agent · Claude Code" && view.agentStatus.ok == true)
        assert(view.chatStatus.label == "Chat · Anthropic API" && view.chatStatus.ok == true)
        KeychainStore.shared.keys.removeValue(forKey: "anthropic-api-key")
        assert(view.chatStatus.ok == false)
        state.focusTask = AgentTask(id: "agent_codex", name: "project-coucou", source: .agent)
        assert(view.agentStatus.label == "Agent · Codex" && view.agentStatus.ok == nil)
        #if !APPSTORE
        CodexAgentsInfo.shared.hooksStatus = .done
        assert(view.agentStatus.ok == true)
        CodexAgentsInfo.shared.hooksStatus = .untrusted
        assert(view.agentStatus.ok == false)
        #endif
        // The agent and the separately chosen Chat provider must stay independent.
        state.chatProvider = .google
        assert(view.agentStatus.label == "Agent · Codex")
        assert(view.chatStatus.label == "Chat · Google API" && view.chatStatus.ok == true)
        state.chatProvider = .openai
        assert(view.chatStatus.label == "Chat · OpenAI API" && view.chatStatus.ok == false)
        state.chatProvider = .ollama
        assert(view.chatStatus.label == "Chat · Ollama server" && view.chatStatus.ok == false)
        state.ollamaServerURL = "http://localhost:11434"
        assert(view.chatStatus.ok == true)
        state.chatProvider = .lmstudio
        assert(view.chatStatus.label == "Chat · LM Studio server" && view.chatStatus.ok == false)
        state.chatProvider = .codex
        let reads = KeychainStore.shared.reads.count
        assert(KeychainStore.shared.reads.count == reads)
        #if APPSTORE
        assert(view.chatStatus.label == "Chat · ChatGPT login" && view.chatStatus.ok == nil)
        #else
        let chat = CodexChatService.shared
        assert(view.chatStatus.label == "Chat · ChatGPT · Not connected" && view.chatStatus.ok == false)
        chat.authenticationStatus = .checking
        assert(view.chatStatus.label == "Chat · ChatGPT · Checking connection…" && view.chatStatus.ok == nil)
        chat.authenticationStatus = .signingIn
        assert(view.chatStatus.label == "Chat · ChatGPT · Waiting for ChatGPT sign-in…" && view.chatStatus.ok == nil)
        chat.authenticationStatus = .connected
        assert(view.chatStatus.label == "Chat · ChatGPT · Connected" && view.chatStatus.ok == true)
        chat.authenticationStatus = .disconnected
        assert(view.chatStatus.ok == false)
        chat.authenticationStatus = .unknown
        assert(view.chatStatus.label == "Chat · ChatGPT · Unable to confirm connection" && view.chatStatus.ok == nil)
        assert(KeychainStore.shared.reads.count == reads)
        #endif
        let prompt = PromptView(state: state)
        state.stateOverride = nil
        state.codexChatBusy = true
        CodexChatService.shared.isBusy = true
        assert(!prompt.isChatStreaming, "Phone instruction animated the previous Chat answer")
        CodexChatService.shared.displayMessage = UUID()
        #if APPSTORE
        assert(!prompt.isChatStreaming)
        #else
        assert(prompt.isChatStreaming, "Codex cursor disappeared after the first visible token")
        #endif
        state.codexChatBusy = false
        assert(!prompt.isChatStreaming, "Completed Codex response retained a streaming cursor")
        state.chatProvider = .deepseek
        state.codexChatBusy = true
        assert(!prompt.isChatStreaming, "Codex busy state affected another provider")
        state.stateOverride = "thinking"
        assert(prompt.isChatStreaming)
        state.stateOverride = nil
        assert(!prompt.isChatStreaming)
        state.focusTask = nil
        state.tasks = []
        assert(view.agentStatus.ok == nil)
        print("PASS independent agent/Chat status, capture labels and image route; no Codex API-key read; unknown state and provider streaming retained")
    }
}
''')
PY
swiftc -parse-as-library "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check"
swiftc -D APPSTORE -parse-as-library "$task_tmp/Check.swift" -o "$task_tmp/check-appstore"
"$task_tmp/check-appstore"
