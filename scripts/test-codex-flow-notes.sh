#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/coucou-codex-flow-notes.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
# Compile actual Flow and Notetaker entry points; only account/model/storage boundaries are in memory.
python3 - "$task_tmp/Callers.swift" <<'PY'
from pathlib import Path
import sys

source = Path('NotchBuddy/Sources/App/NoteTaker.swift').read_text()
def part(start, end):
    return source[source.index(start):source.index(end, source.index(start))]
engine = part('enum NoteSummaryEngine:', '/// The Notetaker:')
properties = part('    @Published var summaryEngine:', '    private var mic:').replace('@Published ', '')
initializer = part('        if let saved = UserDefaults.standard.string(forKey: Self.engineKey)', '        load()')
correction = part('    nonisolated static let correctionInstructions', '    nonisolated private static func claude(')
summary = part('    /// Writes (or writes again) the summary', '    nonisolated private static func claudeSummary')
capability = part('    /// Correct the transcript again', '    // MARK: - Vocabulary')
style_source = Path('NotchBuddy/Sources/App/FlowStore.swift').read_text()
style = style_source[style_source.index('enum FlowStyle:'):style_source.index('/// An app with its own style.')]
# Keep saved choices and automatic/manual entry points wired to the new engine.
assert 'if (summaryEngine == .claude || summaryEngine == .codex), !note.lines.isEmpty' in source
assert 'await correct(id)' in source and 'await summarize(id)' in source
flow_caller = Path('NotchBuddy/Sources/App/FlowDictation.swift').read_text()
assert 'FlowText.keepsMarks(shaped, prepared.snippets)' in flow_caller
assert 'FlowText.keepsMarks(cleaned, prepared.snippets)' in flow_caller
for filename in ('FlowHubSettings.swift', 'FlowHubWords.swift'):
    ui = Path('NotchBuddy/Sources/App/' + filename).read_text()
    assert 'FlowCleanup.isAvailable' in ui and 'FlowCleanup.usesCodex' in ui
    assert '@ObservedObject private var state = AppState.shared' in ui
    assert '@ObservedObject private var codexChat = CodexChatService.shared' in ui
notes_ui = Path('NotchBuddy/Sources/App/FlowHubNotes.swift').read_text()
assert 'taker.canSummarize' in notes_ui and 'taker.aiErrors[note.id]' in notes_ui
assert 'ForEach(NoteSummaryEngine.allCases)' in notes_ui

Path(sys.argv[1]).write_text('''import Foundation
final class KeychainStore {
    static let shared = KeychainStore()
    var key: String?
    var reads = 0
    func get(_ name: String) -> String? { reads += 1; return key }
}
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: String] = [:]
    func set(_ value: String, forKey key: String) { values[key] = value }
    func string(forKey key: String) -> String? { values[key] }
}
enum ChatProvider { case codex, anthropic, openai }
@MainActor final class AppState {
    static let shared = AppState()
    static let defaultClaudeModel = "claude-default"
    var chatProvider = ChatProvider.codex
    var codexModel = "native-model"
    var claudeModel = ""
}
final class FlowStore {
    static let shared = FlowStore()
    var words = ["Codex"]
}
func appendAppLog(_ file: String, _ line: String) {}
enum CodexServiceError: Error { case timeout, invalidResponse }
@MainActor enum CodexTextService {
    static var isAvailable = true
    static var replies: [String] = []
    static var failure: Error?
    static var onComplete: (() -> Void)?
    static var delay: UInt64 = 0
    static var requests: [(system: String, user: String, model: String, timeout: TimeInterval)] = []
    static func reset(_ replies: [String] = []) {
        self.replies = replies; failure = nil; onComplete = nil; delay = 0; requests = []
    }
    static func complete(system: String, user: String, model: String = "", timeout: TimeInterval = 30,
                         webSearch: Bool = false, outputSchema: [String: Any]? = nil) async throws -> String {
        requests.append((system, user, model, timeout))
        if delay > 0 { try await Task.sleep(nanoseconds: delay) }
        let callback = onComplete; onComplete = nil; callback?()
        if let failure { throw failure }
        return replies.isEmpty ? "" : replies.removeFirst()
    }
}
''' + style + engine + '''
@MainActor final class NoteTaker {
    var notes: [UUID: Note] = [:]
    var working: Set<UUID> = []
    var aiErrors: [UUID: String] = [:]
    var aiWorking: Set<UUID> = []
    var vocabulary = ["Alice"]
    static var appleModelAvailable = false
    static var otherCalls = 0
''' + properties + '''
    init() {
''' + initializer + '''
    }
    func note(_ id: UUID) -> Note? { notes[id] }
    func replace(_ note: Note) { notes[note.id] = note }
    nonisolated static func personName(_ number: Int) -> String { "Person \\(number)" }
    static func claude(system: String, user: String, key: String, model: String, maxTokens: Int) async -> String? {
        otherCalls += 1; return nil
    }
    static func claudeSummary(_ transcript: String, key: String, model: String) async -> String? {
        otherCalls += 1; return nil
    }
    static func appleSummary(_ transcript: String) async -> String? { otherCalls += 1; return nil }
''' + correction + summary + capability + '''
}
''')
PY
swiftc -parse-as-library NotchBuddy/Sources/App/FlowText.swift NotchBuddy/Sources/App/FlowLanguages.swift \
  NotchBuddy/Sources/App/FlowCleanup.swift NotchBuddy/Sources/App/NoteModels.swift \
  "$task_tmp/Callers.swift" tests/CodexFlowNotesTests.swift -o "$task_tmp/codex-flow-notes-tests"
"$task_tmp/codex-flow-notes-tests"
