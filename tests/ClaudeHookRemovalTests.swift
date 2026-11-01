import Foundation

// Install and uninstall must remove only Coucou's own nb-hook entries, never whole
// groups that merely mention "coucou"/"NotchBuddy" (#854). Tests removeNbHookEntries
// from NotchBuddy/Sources/App/NbHookEntries.swift.

@main
enum ClaudeHookRemovalTests {
    static var passed = 0
    static var failed = 0

    static let nbCmd = "\"$HOME/Library/Application Support/NotchBuddy/nb-hook\""

    static func check(_ name: String, _ groups: [[String: Any]],
                      contains: [String] = [], notContains: [String] = [],
                      expectEmpty: Bool = false) {
        var ok = expectEmpty ? groups.isEmpty : true
        if !expectEmpty {
            let data = (try? JSONSerialization.data(withJSONObject: groups, options: [.sortedKeys])) ?? Data()
            let json = String(data: data, encoding: .utf8) ?? ""
            for needle in contains where !json.contains(needle) { ok = false }
            for needle in notContains where json.contains(needle) { ok = false }
        }
        if ok { passed += 1; print("PASS  \(name)") }
        else { failed += 1; print("FAIL  \(name)") }
    }

    // Mirror of the per-event step in HookServer's buildHooksData (which also reads and
    // writes the settings file): remove Coucou's previous entries, then append a fresh one.
    static func installEvent(_ existing: [[String: Any]], timeout: Int) -> [[String: Any]] {
        var cleaned = removeNbHookEntries(from: existing)
        cleaned.append(["hooks": [["type": "command", "command": nbCmd, "timeout": timeout]]])
        return cleaned
    }

    static func main() {
        // 1. Install keeps a user group whose command only mentions "coucou"
        let userLint = ["matcher": "Bash",
                        "hooks": [["type": "command", "command": "~/dev/coucou/scripts/lint.sh", "timeout": 5]]] as [String: Any]
        let coucouGroup = ["hooks": [["type": "command", "command": nbCmd, "timeout": 10]]] as [String: Any]
        check("1. install keeps the user's ~/dev/coucou lint group",
              installEvent([userLint, coucouGroup], timeout: 10),
              contains: ["~/dev/coucou/scripts/lint.sh", "Bash"])

        // 2. Install replaces Coucou's own previous group without duplicating it
        let installedTwice = installEvent(installEvent([coucouGroup], timeout: 10), timeout: 10)
        let nbPlainCount = installedTwice.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .filter { ($0["command"] as? String) == nbCmd }.count
        if nbPlainCount == 1 { passed += 1; print("PASS  2. reinstall leaves exactly one plain nb-hook entry") }
        else { failed += 1; print("FAIL  2. reinstall leaves exactly one plain nb-hook entry (found \(nbPlainCount))") }

        // 3. Uninstall keeps a user hook that merely mentions "coucou"
        let mixed = [["matcher": "n",
                      "hooks": [["type": "command", "command": "echo coucou", "timeout": 5],
                                ["type": "command", "command": nbCmd, "timeout": 10]]] as [String: Any]]
        check("3. uninstall keeps \"echo coucou\", drops only the nb-hook entry",
              removeNbHookEntries(from: mixed),
              contains: ["echo coucou"],
              notContains: ["nb-hook"])

        // 4. Uninstall drops a group that held only Coucou's hook
        check("4. uninstall drops coucou-only groups entirely",
              removeNbHookEntries(from: [coucouGroup]),
              expectEmpty: true)

        // 5. Uninstall keeps a user hook whose path mentions NotchBuddy but not nb-hook
        let nbish = [["hooks": [["type": "command", "command": "/opt/NotchBuddy/something-else", "timeout": 5]]] as [String: Any]]
        check("5. uninstall keeps a /opt/NotchBuddy path that is not our hook",
              removeNbHookEntries(from: nbish),
              contains: ["/opt/NotchBuddy/something-else"])

        // 6. Legacy flat entries with nb-hook are removed; others are kept
        let legacy = [["command": nbCmd] as [String: Any],
                      ["command": "~/bin/own.sh"] as [String: Any]]
        check("6. legacy flat entries: only the nb-hook one goes",
              removeNbHookEntries(from: legacy),
              contains: ["own.sh"],
              notContains: ["nb-hook"])

        print("")
        print("Results: \(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }
}
