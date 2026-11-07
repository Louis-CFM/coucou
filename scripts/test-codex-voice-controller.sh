#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/coucou-codex-voice-controller.XXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
# Compile the actual controller decision; all voice/UI/storage boundaries are in memory.
python3 - "$task_tmp/Controller.swift" <<'PY'
from pathlib import Path
import sys
source = Path('NotchBuddy/Sources/App/IslandWindowController.swift').read_text()
start = source.index('    private func handleWithClaude(')
end = source.index('\n    /// A file dropped', start)
method = source[start:end].replace('    private func ', '    func ', 1)
assert 'if await handleWithClaude(transcript, commandID: commandID) { return }' in source
Path(sys.argv[1]).write_text('''import Foundation
@MainActor final class VoiceCaptionManager {
 static let shared = VoiceCaptionManager()
 var userLine = ""
 var responses: [String] = []
 func setUserLine(_ text: String) { userLine = text }
 func appendResponse(_ text: String) { responses.append(text) }
}
@MainActor final class VoiceSpeaker {
 static let shared = VoiceSpeaker()
 var onDidFinish: (() -> Void)?
}
@MainActor final class ClaudeVoiceBrain {
 struct Reply { var text = ""; var acted = false; var failed = false; var discarded = false }
 static let shared = ClaudeVoiceBrain()
 var reply: Reply?
 var afterWait: (() -> Void)?
 func respond(to transcript: String) async -> Reply? {
  await Task.yield()
  afterWait?()
  return reply
 }
}
@MainActor enum VoiceSettings { static var language = "en" }
@MainActor final class VoiceTranscriptHistory {
 static let shared = VoiceTranscriptHistory()
 enum Origin { case brain }
 var count = 0
 func record(transcript: String, note: String, origin: Origin) { count += 1 }
}
struct VoiceActionResult: Equatable {
 enum Outcome { case success }
 var outcome: Outcome
 var message: String
}
@MainActor final class AppState {
 static let shared = AppState()
 var voiceResult = VoiceActionResult(outcome: .success, message: "newer result")
}
@MainActor final class NotificationCenter {
 static let `default` = NotificationCenter()
 enum Name { case triggerEmote }
 var posts = 0
 func post(name: Name, object: BotEmote) { posts += 1 }
}
enum BotEmote { case happy }
func appendAppLog(_ file: String, _ line: String) {}
@MainActor final class IslandWindowController {
 var voiceCommandID = UUID()
 var consecutiveFailures = 3
 var closes = 0
 var continues = 0
 func closeVoiceTurn() { closes += 1 }
 func speakAndContinueConversation(_ result: VoiceActionResult) { continues += 1 }
''' + method + '''
}
@main struct Tests {
 @MainActor static func main() async {
  let brain = ClaudeVoiceBrain.shared
  let caption = VoiceCaptionManager.shared
  let history = VoiceTranscriptHistory.shared
  let state = AppState.shared
  let notifications = NotificationCenter.default
  func check(_ value: Bool) { assert(value) }
  // Current discarded work closes its own voice UI and suppresses parser fallback.
  let current = IslandWindowController()
  brain.reply = .init(discarded: true)
  check(await current.handleWithClaude("cancelled", commandID: current.voiceCommandID))
  assert(current.closes == 1 && current.continues == 0 && history.count == 0)
  // Nil or failed current requests permit the existing parser fallback.
  let failed = IslandWindowController()
  brain.reply = nil
  check(await !failed.handleWithClaude("offline", commandID: failed.voiceCommandID))
  brain.reply = .init(failed: true)
  check(await !failed.handleWithClaude("unusable", commandID: failed.voiceCommandID))
  assert(failed.closes == 0 && failed.continues == 0)
  // Old success/discard/failure/nil replies cannot close or mutate a newer command.
  let variants: [ClaudeVoiceBrain.Reply?] = [nil, .init(discarded: true), .init(failed: true), .init(text: "old", acted: true)]
  for reply in variants {
   let controller = IslandWindowController()
   let oldID = controller.voiceCommandID
   brain.reply = reply
   brain.afterWait = {
    controller.voiceCommandID = UUID()
    caption.setUserLine("newer command")
   }
   check(await controller.handleWithClaude("old command", commandID: oldID))
   assert(controller.closes == 0 && controller.continues == 0 && controller.consecutiveFailures == 3)
   assert(caption.userLine == "newer command" && caption.responses.isEmpty)
   assert(history.count == 0 && notifications.posts == 0 && state.voiceResult.message == "newer result")
  }
  // A usable current response still uses the established history/caption/result path.
  brain.afterWait = nil
  brain.reply = .init(text: "Finished", acted: true)
  let success = IslandWindowController()
  VoiceSpeaker.shared.onDidFinish = { assertionFailure("stale speaker handler") }
  check(await success.handleWithClaude("do it", commandID: success.voiceCommandID))
  assert(VoiceSpeaker.shared.onDidFinish == nil)
  assert(success.closes == 0 && success.continues == 1 && success.consecutiveFailures == 0)
  assert(history.count == 1 && notifications.posts == 1 && caption.responses == ["Finished"])
  assert(state.voiceResult.message == "Finished")
  print("PASS actual voice controller: current discard closes UI, stale replies suppress fallback and preserve newer commands")
 }
}
''')
PY
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library "$task_tmp/Controller.swift" -o "$task_tmp/tests"
"$task_tmp/tests"
