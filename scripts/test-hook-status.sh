#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
test_dir=$(mktemp -d)
trap 'rm -rf "$test_dir"' EXIT
python3 - "$test_dir" <<'PY'
from pathlib import Path
import sys

source = Path('NotchBuddy/Sources/App/HookServer.swift').read_text()
start = source.index('    static func claudeHooksInstalled(')
end = source.index('\n    /// Returns true if settings.json', start)
helper = source[start:end]
Path(sys.argv[1], 'main.swift').write_text('''import Foundation
enum HookServer {
    static var hookScriptPath = ""
''' + helper + '''
}
let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: folder) }
let script = folder.appendingPathComponent("nb-hook")
try "#!/bin/sh\\nexit 0\\n".write(to: script, atomically: true, encoding: .utf8)
try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
HookServer.hookScriptPath = script.path
let settings = folder.appendingPathComponent("settings.json")
let events = ["SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse",
              "PostToolUseFailure", "PermissionRequest", "Notification", "Stop", "StopFailure",
              "SubagentStart", "SubagentStop"]
var hooks: [String: [[String: Any]]] = [:]
for event in events {
    hooks[event] = [["hooks": [["type": "command", "command": "\\"\\(script.path)\\"", "timeout": event == "PermissionRequest" ? 120 : 10]]]]
}
hooks["PreToolUse"]!.append(["matcher": "AskUserQuestion", "hooks": [["type": "command", "command": "\\"\\(script.path)\\" --ask", "timeout": 130]]])
func write(_ value: [String: [[String: Any]]]) throws {
    try JSONSerialization.data(withJSONObject: ["hooks": value]).write(to: settings)
}
try write(hooks)
assert(HookServer.claudeHooksInstalled(settingsURL: settings))
var missing = hooks; missing.removeValue(forKey: "Stop")
try write(missing)
assert(!HookServer.claudeHooksInstalled(settingsURL: settings))
var noQuestion = hooks; noQuestion["PreToolUse"]!.removeLast()
try write(noQuestion)
assert(!HookServer.claudeHooksInstalled(settingsURL: settings))
var wrongCommand = hooks
wrongCommand["Stop"] = [["hooks": [["type": "command", "command": "echo \\"\\(script.path)\\"", "timeout": 10]]]]
try write(wrongCommand)
assert(!HookServer.claudeHooksInstalled(settingsURL: settings))
var shortTimeout = hooks
shortTimeout["PermissionRequest"] = [["hooks": [["type": "command", "command": "\\"\\(script.path)\\"", "timeout": 5]]]]
try write(shortTimeout)
assert(!HookServer.claudeHooksInstalled(settingsURL: settings))
try write(hooks)
try FileManager.default.removeItem(at: script)
assert(!HookServer.claudeHooksInstalled(settingsURL: settings))
print("PASS: hook Done requires every event, question matcher, timeout, and executable relay.")
''')
PY
swiftc "$test_dir/main.swift" -o "$test_dir/check"
"$test_dir/check"
