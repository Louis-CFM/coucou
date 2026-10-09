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
types = Path('NotchBuddy/Sources/CoucouKit/IslandTypes.swift').read_text()
provider = types[types.index('enum ChatProvider:'):types.index('// MARK: - View dimensions')]
service = Path('NotchBuddy/Sources/App/CodexChatService.swift').read_text()
authentication = service[service.index('enum CodexAuthenticationStatus'):service.index('/// Owns Coucou-created')]
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
    var tasks: [AgentTask] = []
    var focusTask: AgentTask?
    var chatProvider: ChatProvider = .anthropic
    var ollamaServerURL = ""
    var lmstudioServerURL = ""
}
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
}
''' + provider + authentication + settings + '''
@main struct Check {
    static func main() async {
        let state = AppState()
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
        state.focusTask = nil
        state.tasks = []
        assert(view.agentStatus.ok == nil)
        print("PASS agent and Chat status independent; Codex login has no API-key read; unknown state retained")
    }
}
''')
PY
swiftc -parse-as-library "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check"
swiftc -D APPSTORE -parse-as-library "$task_tmp/Check.swift" -o "$task_tmp/check-appstore"
"$task_tmp/check-appstore"
