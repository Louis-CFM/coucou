import Foundation

// Tests mergedHermesConfig from NotchBuddy/Sources/App/HermesConfigMerger.swift.
// Each merged output is validated as YAML by python3 with PyYAML (pip3 install pyyaml).

@main
enum HermesConfigMergerTests {
    static var passed = 0
    static var failed = 0

    /// Find a Python3 that has pyyaml installed.
    static func findPython3() -> String {
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "/usr/bin/python3",
        ]
        for p in candidates {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: p)
            proc.arguments = ["-c", "import yaml"]
            proc.standardOutput = Pipe(); proc.standardError = Pipe()
            if (try? proc.run()) != nil {
                proc.waitUntilExit()
                if proc.terminationStatus == 0 { return p }
            }
        }
        return "/usr/bin/python3"   // fallback
    }

    static let pythonBin = findPython3()

    static func isValidYAML(_ s: String) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonBin)
        proc.arguments = ["-c", "import yaml,sys; yaml.safe_load(sys.stdin)"]
        let inPipe = Pipe(); let errPipe = Pipe()
        proc.standardInput  = inPipe
        proc.standardError  = errPipe
        proc.standardOutput = Pipe()
        try? proc.run()
        inPipe.fileHandleForWriting.write(s.data(using: .utf8)!)
        inPipe.fileHandleForWriting.closeFile()
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    static func check(_ name: String, _ result: String?, contains: [String] = [], notContains: [String] = [],
                      expectNil: Bool = false) {
        if expectNil {
            if result == nil {
                print("  PASS \(name)")
                passed += 1
            } else {
                print("  FAIL \(name): expected nil but got a string")
                failed += 1
            }
            return
        }
        guard let r = result else {
            print("  FAIL \(name): got nil unexpectedly")
            failed += 1
            return
        }
        guard isValidYAML(r) else {
            print("  FAIL \(name): result is not valid YAML\n---\n\(r)\n---")
            failed += 1
            return
        }
        for c in contains {
            guard r.contains(c) else {
                print("  FAIL \(name): missing \(c.debugDescription)\n---\n\(r)\n---")
                failed += 1
                return
            }
        }
        for nc in notContains {
            guard !r.contains(nc) else {
                print("  FAIL \(name): should not contain \(nc.debugDescription)\n---\n\(r)\n---")
                failed += 1
                return
            }
        }
        print("  PASS \(name)")
        passed += 1
    }

    static func main() {
        print("HermesConfigMergerTests")
        print("=======================")

        // 1. Empty file → adds plugins.enabled.coucou
        check("1. empty file → adds plugins/enabled/coucou",
              mergedHermesConfig("", enableApprovals: false),
              contains: ["plugins:", "enabled:", "- coucou"])

        // 2. plugins: exists but no enabled: → adds enabled with coucou
        check("2. plugins without enabled → adds enabled/coucou",
              mergedHermesConfig("plugins:\n  disabled: []\n", enableApprovals: false),
              contains: ["enabled:", "- coucou"])

        // 3. plugins.enabled with other item → adds coucou
        check("3. plugins.enabled other items → adds coucou",
              mergedHermesConfig("plugins:\n  enabled:\n    - other\n", enableApprovals: false),
              contains: ["- other", "- coucou"])

        // 4. coucou already in plugins.enabled → no duplicate
        let case4 = mergedHermesConfig("plugins:\n  enabled:\n    - coucou\n", enableApprovals: false)
        check("4. coucou already present → no duplicate",
              case4,
              contains: ["- coucou"],
              notContains: [])
        // Verify only one occurrence of "- coucou"
        if let r4 = case4 {
            let count = r4.components(separatedBy: "- coucou").count - 1
            if count == 1 { print("  PASS 4b. no duplicate coucou entry"); passed += 1 }
            else { print("  FAIL 4b. got \(count) coucou entries"); failed += 1 }
        }

        // 5. enabled: [] (empty inline list) → expands to block list with coucou
        check("5. enabled: [] → expands to block with coucou",
              mergedHermesConfig("plugins:\n  enabled: []\n", enableApprovals: false),
              contains: ["- coucou"],
              notContains: ["enabled: []"])

        // 6. enabled: [other] inline list → adds coucou to inline list
        check("6. enabled: [other] inline → adds coucou",
              mergedHermesConfig("plugins:\n  enabled: [other]\n", enableApprovals: false),
              contains: ["coucou"])

        // 7. Another section with its own enabled: key → only modifies under plugins:
        let case7 = """
        features:
          enabled: [x]
        plugins:
          enabled:
            - existing
        """
        check("7. another section's enabled: not modified",
              mergedHermesConfig(case7, enableApprovals: false),
              contains: ["features:", "enabled: [x]", "- coucou"])

        // 8. coucou in disabled: → still adds to enabled:
        check("8. coucou in disabled → also adds to enabled",
              mergedHermesConfig("plugins:\n  disabled:\n    - coucou\n  enabled:\n    - other\n", enableApprovals: false),
              contains: ["- coucou", "- other"])

        // 9. security: without approval: → adds approval with transport keys
        check("9. security without approval → adds transport keys",
              mergedHermesConfig("security:\n  allow_private_urls: false\n", enableApprovals: true),
              contains: ["approval:", "transport: coucou", "transport_fallback: builtin"])

        // 10a. Uninstall: removes - coucou from enabled
        let case10a = """
        plugins:
          enabled:
            - coucou
            - other
        security:
          approval:
            transport: coucou
            transport_fallback: builtin
        """
        check("10a. uninstall: removes coucou from enabled, transport keys",
              mergedHermesConfig(case10a, enableApprovals: false),
              notContains: ["transport: coucou", "transport_fallback: builtin"])

        // 10b. After uninstall (disable approvals), transport keys removed
        check("10b. disable approvals: transport keys removed",
              mergedHermesConfig("security:\n  approval:\n    transport: coucou\n    transport_fallback: builtin\n",
                                 enableApprovals: false),
              notContains: ["transport: coucou", "transport_fallback: builtin"])

        // 11. Flow map → returns nil
        check("11. flow map { } → returns nil",
              mergedHermesConfig("{plugins: {enabled: [coucou]}}", enableApprovals: false),
              expectNil: true)

        // 12. 4-space indentation → uses 4 spaces
        let base12 = """
        model: gpt-4
        plugins:
            enabled:
                - other
        """
        check("12. 4-space indent → uses 4 spaces",
              mergedHermesConfig(base12, enableApprovals: false),
              contains: ["        - coucou"])   // 8 spaces = 2 levels of 4

        // 13. Enable approvals: adds both transport keys
        check("13. enableApprovals=true adds both transport keys",
              mergedHermesConfig("", enableApprovals: true),
              contains: ["transport: coucou", "transport_fallback: builtin"])

        // 14. security.approval already has transport → update, not duplicate
        let case14 = """
        security:
          approval:
            transport: terminal
            transport_fallback: deny
        """
        check("14. existing transport → updated, no duplicate",
              mergedHermesConfig(case14, enableApprovals: true),
              contains: ["transport: coucou", "transport_fallback: builtin"],
              notContains: ["transport: terminal", "transport_fallback: deny"])

        print("")
        print("Results: \(passed) passed, \(failed) failed")
        exit(failed > 0 ? 1 : 0)
    }
}
