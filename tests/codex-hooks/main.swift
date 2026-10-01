import Foundation

func expect(_ value: Bool, _ message: String) {
    if !value { fatalError(message) }
}

let fm = FileManager.default
let directory = fm.temporaryDirectory.appendingPathComponent("coucou-codex-tests-\(UUID().uuidString)")
try fm.createDirectory(at: directory, withIntermediateDirectories: true)
defer { try? fm.removeItem(at: directory) }
let installer = CodexHooks(directory: directory, relayCommand: "/usr/bin/env python3 '/fixture/nb-hook' --codex")
let originalText = #"{"description":"keep","hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"foreign-hook"}]}],"FutureEvent":[]}}"#
var original = Data([0xEF, 0xBB, 0xBF])
original.append(Data(originalText.utf8))
try original.write(to: installer.target)
let config = directory.appendingPathComponent("config.toml")
try Data("model = \"fixture-model\"\n".utf8).write(to: config)

let plan = try installer.preview(install: true)
expect(try Data(contentsOf: installer.target) == original, "preview wrote config")
let backup = try installer.apply(plan)!
expect(try Data(contentsOf: backup) == original, "backup was not byte-preserving")
expect(installer.isInstalled, "installation was not detected")
let installed = try Data(contentsOf: installer.target)
let json = try JSONSerialization.jsonObject(with: installed) as! [String: Any]
let hooks = json["hooks"] as! [String: Any]
expect(Set(hooks.keys) == Set(CodexHooks.events + ["FutureEvent"]), "unsupported events installed")
let interrupt = hooks["Interrupt"] as! [[String: Any]]
expect((interrupt[0]["hooks"] as! [[String: Any]])[0]["timeout"] as? Int == 3, "Interrupt timeout")
let sessionEnd = hooks["SessionEnd"] as! [[String: Any]]
expect((sessionEnd[0]["hooks"] as! [[String: Any]])[0]["timeout"] as? Int == 3, "SessionEnd timeout")
let second = try installer.preview(install: true)
expect(second.replacement == installed, "reinstall is not idempotent")

let remove = try installer.preview(install: false)
_ = try installer.apply(remove)
let restored = try JSONSerialization.jsonObject(with: Data(contentsOf: installer.target)) as! NSDictionary
let before = try JSONSerialization.jsonObject(with: Data(originalText.utf8)) as! NSDictionary
expect(restored == before, "foreign config changed on uninstall")
expect(try String(contentsOf: config, encoding: .utf8) == "model = \"fixture-model\"\n", "config.toml changed")

// A foreign handler in our own matcher group must survive uninstall.
let shared = #"{"hooks":{"Stop":[{"matcher":"*","hooks":[{"type":"command","statusMessage":"Coucou Codex","command":"python3 nb-hook --codex"},{"type":"command","command":"foreign"}]}]}}"#
try Data(shared.utf8).write(to: installer.target)
let sharedRemove = try installer.preview(install: false)
let sharedJSON = try JSONSerialization.jsonObject(with: sharedRemove.replacement) as! [String: Any]
let sharedHooks = sharedJSON["hooks"] as! [String: Any]
let stop = sharedHooks["Stop"] as! [[String: Any]]
expect((stop[0]["hooks"] as! [[String: Any]])[0]["command"] as? String == "foreign", "shared foreign handler removed")

let stale = try installer.preview(install: true)
try Data("{\"description\":\"someone edited\"}".utf8).write(to: installer.target)
do { _ = try installer.apply(stale); fatalError("stale preview was applied") } catch { }
for invalid in ["null", "[]", "{ broken", "{\"hooks\":null}", "{\"hooks\":{\"Stop\":{}}}"] {
    try Data(invalid.utf8).write(to: installer.target)
    do { _ = try installer.preview(install: true); fatalError("invalid JSON was accepted") } catch { }
    expect(try String(contentsOf: installer.target, encoding: .utf8) == invalid, "invalid config was overwritten")
}
print("Codex hook installer: PASS (preview, backup, merge, shared handlers, idempotence, stale preview, uninstall, malformed input)")
