#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/coucou-codex-voice-actions.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
# Exercise actual async tool implementations, not a replacement for run()/prepareEmail().
python3 - "$task_tmp/Actions.swift" <<'PY'
from pathlib import Path
import sys
root = Path('NotchBuddy/Sources/App')
source = (root/'Voice/ClaudeVoiceBrain.swift').read_text()
brain = source[source.index('@MainActor\nfinal class ClaudeVoiceBrain'):source.index('    // MARK: Prompt')]
brain += '    private static func systemPrompt() -> String { "fixture" }\n'
brain += source[source.index('    // MARK: Tools'):source.rindex('\n#endif')]
engine = (root/'Voice/VoiceEngine.swift').read_text()
enabled = engine[engine.index('    @Published var isEnabled:'):engine.index('    @Published private(set) var isListeningForCommand:')].replace('@Published ', '')
Path(sys.argv[1]).write_text('''import Foundation
@MainActor final class AppState {
    static let shared = AppState()
    enum Provider { case codex, claude }
    var chatProvider = Provider.codex
    var voiceMailDraft: String?
    var droppedFile: DroppedFile?
}
struct DroppedFile { var url: URL }
@MainActor final class CodexChatService { static let shared = CodexChatService(); var authenticationEpoch = UUID() }
@MainActor enum VoiceSettings {
    static var isEnabled = true
    static let answerLocale = Locale(identifier: "en-US")
}
@MainActor final class VoiceEngine {
    static let shared = VoiceEngine()
''' + enabled + '''
    func handleEnabledChanged() {}
}
@MainActor enum CodexTextService { static let isAvailable = true }
@MainActor final class ClaudeService {
    static let shared = ClaudeService()
    var apiKey: String? { nil }
    var calls: [[String: Any]] = []
    func voiceTurn(system: String, messages: [[String: Any]], tools: [[String: Any]]) async
        -> (content: [[String: Any]], stopReason: String)? {
        let content = calls; calls = []
        return (content, content.isEmpty ? "end_turn" : "tool_use")
    }
}
@MainActor enum PillCatalog { static var available: [PillDefinition] { PillFixture.available } }
@MainActor final class LiveVoiceInfo: VoiceInfoProviding {
    static let shared = LiveVoiceInfo()
    var resolve: (() -> Void)?
    var shown = 0
    var fileLookups = 0
    var webSearchEnabled = false
    var hasWebKey = false
    func answer(_ topic: VoiceTopic, locale: Locale?) async -> String { "fixture" }
    func openApp(_ name: String, locale: Locale?) -> VoiceActionResult { .init(outcome: .success, message: "opened") }
    func resolveEmail(_ recipient: String) async -> String? {
        await Task.yield()
        resolve?()
        return "alice@example.test"
    }
    func findFile(_ name: String, folder: VoiceQuery.MailRequest.Folder?) -> URL? { fileLookups += 1; return nil }
    func draftBody(to recipient: String, about instruction: String) async -> String? { nil }
    func showMailCard(to address: String, subject: String, body: String, file: URL?) { shown += 1 }
    func webAnswer(_ question: String, history: [VoiceWebTurn], french: Bool) async -> String? { nil }
}
func claudeResponseText(fromContent content: [[String: Any]]) -> String? { nil }
''' + brain)
PY
swiftc -parse-as-library tests/VoiceTestStubs.swift tests/PillFixture.swift \
  NotchBuddy/Sources/App/Voice/VoiceIntent.swift NotchBuddy/Sources/App/Voice/IntentParser.swift \
  NotchBuddy/Sources/App/Voice/VoiceQuery.swift NotchBuddy/Sources/App/Voice/EntityResolver.swift \
  NotchBuddy/Sources/App/Voice/VoiceActionRunner.swift NotchBuddy/Sources/App/Voice/CodexVoiceTurn.swift \
  "$task_tmp/Actions.swift" tests/CodexVoiceActionsTests.swift -o "$task_tmp/tests"
"$task_tmp/tests"
