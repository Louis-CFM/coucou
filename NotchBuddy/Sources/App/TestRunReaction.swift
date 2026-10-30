import Foundation

/// Mochi reacts when an agent runs the tests: proud when they pass, a cold sweat when they fail.
/// Only the command and what it printed are read, on this Mac, from the PostToolUse hook.
enum TestRunReaction {
    enum Outcome: Equatable {
        case passed, failed
    }

    /// What the test run card shows: the outcome, then the test command and the runner's verdict.
    struct Card: Equatable {
        var outcome: Outcome
        /// "npm test · Tests: 1 failed, 2 passed"
        var line: String
    }

    /// The card for a test run, or nil when the command doesn't run tests.
    static func card(command: String, output: String, toolFailed: Bool) -> Card? {
        guard let test = testCommand(in: command),
              let outcome = outcome(command: command, output: output, toolFailed: toolFailed) else { return nil }
        let verdict = summary(output, outcome: outcome)
        return Card(outcome: outcome, line: verdict.map { "\(test) · \($0)" } ?? test)
    }

    /// The outcome of a test run, or nil when the command doesn't run tests (or was interrupted).
    /// `toolFailed`: the agent reported the command as failed (PostToolUseFailure).
    static func outcome(command: String, output: String, toolFailed: Bool) -> Outcome? {
        guard isTestCommand(command) else { return nil }
        if toolFailed || reportsFailure(output) { return .failed }
        return .passed
    }

    /// The command as a hook gives it: a string, or a list of arguments (Codex).
    static func command(from input: [String: Any]) -> String? {
        if let text = input["command"] as? String { return text }
        if let parts = input["command"] as? [String] { return parts.joined(separator: " ") }
        return nil
    }

    /// What the command printed, or the error the agent reported.
    static func output(from payload: [String: Any]) -> String {
        var parts: [String] = []
        if let error = payload["error"] as? String { parts.append(error) }
        if let response = payload["tool_response"] as? [String: Any] {
            for key in ["stdout", "stderr", "output"] {
                if let text = response[key] as? String, !text.isEmpty { parts.append(text) }
            }
        } else if let response = payload["tool_response"] as? String {
            parts.append(response)
        }
        // The summary of a test run is at its end.
        return String(parts.joined(separator: "\n").suffix(20_000))
    }

    // MARK: The command

    /// Runners whose name alone means tests.
    private static let runners: Set<String> = [
        "pytest", "py.test", "jest", "vitest", "mocha", "rspec", "phpunit", "ctest", "tox", "nextest",
    ]
    /// Tools whose test subcommand is `test` (`go test`, `cargo test`…).
    private static let testSubcommand: Set<String> = [
        "go", "cargo", "swift", "deno", "dotnet", "mix", "rails", "flutter", "dart", "zig",
    ]
    /// Package managers whose script is `test` or `test:something`.
    private static let packageManagers: Set<String> = ["npm", "pnpm", "yarn", "bun"]
    /// Build tools that run tests with a `test…` target or task.
    private static let buildTools: Set<String> = ["make", "gradle", "gradlew", "mvn", "mvnw", "xcodebuild"]

    static func isTestCommand(_ command: String) -> Bool {
        testCommand(in: command) != nil
    }

    /// The part of a shell line that runs the tests ("npm test" in "cd web && npm test | tail").
    static func testCommand(in command: String) -> String? {
        guard let words = segments(of: command).first(where: { isTestSegment($0) }) else { return nil }
        // Up to a redirection (`2>&1`, `> log.txt`): the rest isn't the command.
        let shown = words.prefix { word in !word.contains(">") && !word.contains("<") }
        return shown.joined(separator: " ")
    }

    /// The simple commands of a shell line, quoted text taken out (`git commit -m "fix tests"` runs nothing).
    private static func segments(of command: String) -> [[String]] {
        var unquoted = ""
        var quote: Character?
        for char in command {
            if let open = quote {
                if char == open { quote = nil }
            } else if char == "\"" || char == "'" {
                quote = char
                unquoted.append(" ")
            } else {
                unquoted.append(char)
            }
        }
        let separators = CharacterSet(charactersIn: ";|&\n()")
        return unquoted.components(separatedBy: separators).map { part in
            part.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        }
    }

    private static func isTestSegment(_ words: [String]) -> Bool {
        var words = words[...]
        // Leading `FOO=bar`, sudo, time, env, `bundle exec`, `uv run`, `poetry run`…
        while let first = words.first {
            if first.contains("="), !first.hasPrefix("-") { words = words.dropFirst(); continue }
            if ["sudo", "time", "env", "exec", "command", "nice"].contains(first) { words = words.dropFirst(); continue }
            if ["bundle", "uv", "poetry", "pipenv", "hatch", "pdm"].contains(first), words.count > 1,
               ["exec", "run"].contains(words[words.startIndex + 1]) {
                words = words.dropFirst(2); continue
            }
            if ["npx", "bunx", "pnpx"].contains(first) || (first == "pnpm" && words.dropFirst().first == "dlx") {
                words = words.dropFirst(first == "pnpm" ? 2 : 1)
                while words.first?.hasPrefix("-") == true { words = words.dropFirst() }
                continue
            }
            break
        }
        guard let first = words.first else { return false }
        let tool = (first as NSString).lastPathComponent
        let args = Array(words.dropFirst())

        if runners.contains(tool) { return true }
        // `./test.sh`, `bash scripts/test-flow-text.sh`
        if isTestScript(tool) { return true }
        if ["bash", "sh", "zsh"].contains(tool), let script = args.first(where: { !$0.hasPrefix("-") }) {
            return isTestScript((script as NSString).lastPathComponent)
        }
        if tool.hasPrefix("python"), let module = args.firstIndex(of: "-m").map({ args.index(after: $0) }),
           module < args.count {
            return ["pytest", "unittest", "nose2", "tox"].contains(args[module])
        }
        if testSubcommand.contains(tool) { return args.first == "test" || (tool == "cargo" && args.first == "nextest") }
        if packageManagers.contains(tool) {
            let script = args.first == "run" ? args.dropFirst().first : args.first
            guard let script else { return false }
            return script == "t" || script == "test" || script.hasPrefix("test:")
        }
        if tool == "node" { return args.contains("--test") }
        if tool == "playwright" || tool == "cypress" { return args.first == "test" || args.first == "run" }
        if buildTools.contains(tool) {
            return args.contains { $0 == "test" || $0 == "tests" || $0 == "check" || $0.hasPrefix("test-") || $0.hasPrefix("test:") }
        }
        return false
    }

    private static func isTestScript(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.hasSuffix(".sh") && (lower.hasPrefix("test-") || lower.hasPrefix("test_") || lower == "test.sh"
                                          || lower == "tests.sh" || lower.hasPrefix("run-tests") || lower.hasPrefix("run_tests"))
    }

    // MARK: The output

    /// What test runners print when something failed, even when the command still exits 0.
    private static let failurePatterns: [NSRegularExpression] = [
        #"\b[1-9][0-9]* (failed|failing|failures?|errors?)\b"#,         // pytest, jest, mocha, rspec
        #"\b(failures|failed|errors): *[1-9]"#,                          // JUnit, Maven, Gradle
        #"(?m)(?-i)^(FAIL|FAILED)\b"#,                                   // go test, jest, unittest
        #"(?m)^not ok\b"#,                                               // TAP (node --test)
        #"test result: FAILED"#,                                         // cargo
        #"\*\* TEST FAILED \*\*"#,                                       // xcodebuild
        #"✗"#,
    ].compactMap { try? NSRegularExpression(pattern: $0, options: [.caseInsensitive]) }

    /// The runner's verdict in one line: the line that says what failed, or the last line of a
    /// passing run ("5 passed in 0.12s"). Nil when there is nothing short enough to show.
    static func summary(_ output: String, outcome: Outcome) -> String? {
        let lines = output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != "…" }
        let pick: String?
        if outcome == .failed {
            pick = lines.last { line in
                let range = NSRange(line.startIndex..., in: line)
                return failurePatterns.contains { $0.firstMatch(in: line, range: range) != nil }
            } ?? lines.last
        } else {
            pick = lines.last
        }
        guard let pick, pick.count <= 120 else { return nil }
        return pick
    }

    static func reportsFailure(_ output: String) -> Bool {
        let range = NSRange(output.startIndex..., in: output)
        return failurePatterns.contains { $0.firstMatch(in: output, range: range) != nil }
    }
}
