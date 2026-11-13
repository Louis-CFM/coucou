#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
python3 - "$task_tmp/main.swift" <<'PY'
import pathlib,sys
root=pathlib.Path('NotchBuddy/Sources/App')
brain=(root/'Voice/ClaudeVoiceBrain.swift').read_text()
# Compile the production orchestration/history and allowlist; only action I/O is stubbed.
body=brain[brain.index('@MainActor\nfinal class ClaudeVoiceBrain'):brain.index('    // MARK: Prompt')]
tools=brain[brain.index('    private static let tools:'):brain.index('    // MARK: Running a tool')]
service=(root/'ClaudeService.swift').read_text()
turn=service[service.index('    func voiceTurn('):service.index('    // MARK: - Voice answer')]
pre='''import Foundation
@MainActor final class AppState {
 static let shared = AppState()
 enum Provider { case codex, claude }
 var chatProvider = Provider.codex
 var codexModel = "fixture-model"
 var codexSearchMode = "disabled"
}
@MainActor final class CodexChatService { static let shared = CodexChatService(); var authenticationEpoch = UUID() }
@MainActor enum VoiceSettings { static var isEnabled = true }
@MainActor enum CodexTextService {
 static var isAvailable = true
 static var output = ""
 static var afterWait: (() -> Void)?
 static var calls = 0
 static func complete(system: String, user: String, model: String = "", timeout: TimeInterval = 30,
                      webSearch: Bool = false, outputSchema: [String:Any]? = nil) async throws -> String {
  calls += 1
  assert(model == "fixture-model" && !webSearch && outputSchema != nil)
  await Task.yield()
  if let callback = afterWait { afterWait = nil; callback() }
  return output
 }
}
@MainActor enum Boundary {
 static var keyReads = 0
 static var actions = 0
 static var onAction: (() -> Void)?
}
enum FixtureError: Error { case unavailable }
@MainActor func appendAppLog(_ file: String, _ line: String) {}
@MainActor final class ClaudeService {
 static let shared = ClaudeService()
 static let voiceModel = "fixture-claude"
 var model = "fixture"
 var apiKey: String? { Boundary.keyReads += 1; return nil }
 func callAPI(body: [String:Any], key: String, beta: String?) async throws -> Data { throw FixtureError.unavailable }
'''+turn+'''}
enum VoiceTopic: String, CaseIterable { case music, agents, weather }
enum VoiceQuery { static func spokenText(_ value: String) -> String { value } }
func claudeResponseText(fromContent content: [[String:Any]]) -> String? { content.first { $0["type"] as? String == "text" }?["text"] as? String }
'''
end='''    private static func systemPrompt() -> String { "fixture prompt" }
'''+tools+'''    private func run(tool: String, input: [String:Any], isCurrent: () -> Bool) async -> (String,Bool) {
 guard isCurrent() else { return ("cancelled",false) }
 Boundary.actions += 1
 await Task.yield()
 if let callback = Boundary.onAction { Boundary.onAction = nil; callback() }
 return ("success",true)
 }
}
@MainActor func fixture(_ value: Any) -> String { String(data:try! JSONSerialization.data(withJSONObject:value),encoding:.utf8)! }
@MainActor func result(_ text: String = "", calls: [[String:Any]] = []) -> String { fixture(["text":text,"calls":calls]) }
@MainActor func call(_ name: String, _ input: [String:Any]) -> [String:Any] { ["name":name,"arguments":fixture(input)] }
@main struct Tests {
 @MainActor static func main() async {
  let tools: [[String:Any]] = [["name":"music", "input_schema":["type":"object", "properties":[
   "action":["type":"string","enum":["next","set_volume"]],"volume":["type":"integer"]],"required":["action"]]],
   ["name":"mail","input_schema":["type":"object","properties":["ok":["type":"boolean"],"names":["type":"array","items":["type":"string"]]],"required":["ok"]]]]
  func parse(_ text: String) -> Bool { CodexVoiceTurn.parse(text,tools:tools) != nil }
  assert(parse(result("spoken")))
  assert(parse(result(calls:[call("music",["action":"next"])])))
  assert(parse(result(calls:[call("mail",["ok":true,"names":["one"]])])) )
  assert(!parse(result()))
  assert(!parse(result(calls:[call("exec_command",["command":"touch canary"])])))
  assert(!parse(result(calls:[call("music",["action":"bad"])])))
  assert(!parse(result(calls:[call("music",["volume":3])])) )
  assert(!parse(result(calls:[call("music",["action":"next","extra":"x"])])))
  assert(!parse(result(calls:[call("music",["action":"set_volume","volume":true])])) )
  assert(!parse(result(calls:[call("music",["action":"set_volume","volume":0.5])])) )
  assert(!parse(result(calls:[call("mail",["ok":1])])) )
  assert(!parse(result(calls:[call("mail",["ok":true,"names":[false]])])) )
  assert(!parse(result(calls:Array(repeating:call("music",["action":"next"]),count:9))))
  assert(!parse("```json\\n{}\\n```"))
  assert(!parse(String(repeating:"x",count:65_537)))
  let key = CodexVoiceTurn.actionKey(name:"mail", input:["a":1,"b":2])
  assert(key == CodexVoiceTurn.actionKey(name:"mail",input:["b":2,"a":1]))
  let brain = ClaudeVoiceBrain.shared
  CodexTextService.output = result("hello")
  assert(ClaudeVoiceBrain.isActive)
  let hello = await brain.respond(to:"hello")
  assert(hello?.text == "hello" && hello?.failed == false && Boundary.keyReads == 0)
  // The fixture repeats one action for all five rounds: it executes once.
  brain.reset(); CodexTextService.output = result(calls:[call("music",["action":"next"])])
  let acted = await brain.respond(to:"next")
  assert(acted?.acted == true && Boundary.actions == 1 && Boundary.keyReads == 0)
  brain.reset(); CodexTextService.afterWait = { brain.reset() }
  let reset = await brain.respond(to:"old")
  assert(reset?.discarded == true && Boundary.actions == 1)
  CodexTextService.afterWait = { AppState.shared.chatProvider = .claude }
  let switched = await brain.respond(to:"old")
  assert(switched?.discarded == true && Boundary.actions == 1)
  AppState.shared.chatProvider = .codex; brain.reset()
  CodexTextService.afterWait = { VoiceSettings.isEnabled = false }
  let disabled = await brain.respond(to:"old")
  assert(disabled?.discarded == true && Boundary.actions == 1)
  VoiceSettings.isEnabled = true; brain.reset()
  CodexTextService.afterWait = { CodexTextService.isAvailable = false }
  let disconnected = await brain.respond(to:"old")
  assert(disconnected?.discarded == true && Boundary.actions == 1)
  CodexTextService.isAvailable = true; brain.reset()
  CodexTextService.afterWait = { CodexChatService.shared.authenticationEpoch = UUID() }
  let accountChanged = await brain.respond(to:"old")
  assert(accountChanged?.discarded == true && Boundary.actions == 1)
  brain.reset()
  Boundary.onAction = { brain.reset() }
  CodexTextService.output = result(calls:[call("music",["action":"next"]),call("open_app",["name":"Safari"])])
  let duringAction = await brain.respond(to:"two")
  assert(duringAction?.discarded == true && Boundary.actions == 2)
  CodexTextService.isAvailable = false
  assert(!ClaudeVoiceBrain.isActive)
  let unavailable = await brain.respond(to:"offline")
  assert(unavailable == nil && Boundary.keyReads == 0)
  print("PASS Codex voice strict allowlist/arguments, no API fallback, duplicate actions and stale/reset/provider/consent guards")
 }
}
'''
pathlib.Path(sys.argv[1]).write_text(pre+body+end)
PY
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
 NotchBuddy/Sources/App/Voice/CodexVoiceTurn.swift "$task_tmp/main.swift" -o "$task_tmp/tests"
"$task_tmp/tests"
