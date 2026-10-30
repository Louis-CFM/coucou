import Foundation

@main
enum TestRunReactionTests {

    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func isTest(_ command: String) -> Bool { TestRunReaction.isTestCommand(command) }

    static func main() {
        print("\nTest commands")
        for command in [
            "npm test", "npm run test", "npm run test:unit", "pnpm test", "yarn test:e2e", "bun test", "npm t",
            "pytest -q tests/", "python3 -m pytest", "python -m unittest discover", "uv run pytest",
            "go test ./...", "cargo test", "cargo nextest run", "swift test", "deno test", "dotnet test", "mix test",
            "bundle exec rspec", "rails test", "./gradlew test", "mvn test", "make test", "make check",
            "xcodebuild -scheme App test", "npx jest --watchAll=false", "npx vitest run", "npx playwright test",
            "node --test tests/", "bash scripts/test-flow-text.sh", "./test.sh", "cd web && npm test",
            "CI=1 npm test", "npm install && npm test 2>&1 | tail -20", "/usr/local/bin/pytest",
        ] {
            check(command, isTest(command))
        }

        print("\nNot test commands")
        for command in [
            "npm install", "npm run build", "git commit -m \"fix the tests\"", "cat test.txt", "ls tests",
            "grep -rn test src", "echo 'npm test'", "go build ./...", "cargo build", "make", "python3 script.py",
            "swift build", "node index.js", "rm -rf test-results", "yarn testing-library", "",
        ] {
            check(command.isEmpty ? "(empty)" : command, !isTest(command))
        }

        print("\nOutcomes")
        check("passes", TestRunReaction.outcome(command: "pytest", output: "5 passed in 0.12s", toolFailed: false) == .passed)
        check("0 failed still passes",
              TestRunReaction.outcome(command: "npm test", output: "Tests: 0 failed, 12 passed", toolFailed: false) == .passed)
        check("the agent says it failed",
              TestRunReaction.outcome(command: "cargo test", output: "", toolFailed: true) == .failed)
        check("pytest failures", TestRunReaction.outcome(command: "pytest", output: "1 failed, 4 passed", toolFailed: false) == .failed)
        check("jest", TestRunReaction.outcome(command: "npm test", output: "Tests:       2 failed, 10 passed, 12 total",
                                              toolFailed: false) == .failed)
        check("mocha", TestRunReaction.outcome(command: "npx mocha", output: "  3 passing\n  1 failing", toolFailed: false) == .failed)
        check("go test", TestRunReaction.outcome(command: "go test ./...", output: "--- FAIL: TestX\nFAIL\texample 0.1s",
                                                 toolFailed: false) == .failed)
        check("cargo", TestRunReaction.outcome(command: "cargo test", output: "test result: FAILED. 3 passed; 1 failed",
                                               toolFailed: false) == .failed)
        check("JUnit", TestRunReaction.outcome(command: "mvn test", output: "Tests run: 5, Failures: 1, Errors: 0",
                                               toolFailed: false) == .failed)
        check("JUnit all green", TestRunReaction.outcome(command: "mvn test", output: "Tests run: 5, Failures: 0, Errors: 0",
                                                         toolFailed: false) == .passed)
        check("TAP", TestRunReaction.outcome(command: "node --test", output: "ok 1 - a\nnot ok 2 - b", toolFailed: false) == .failed)
        check("xcodebuild", TestRunReaction.outcome(command: "xcodebuild test", output: "** TEST FAILED **", toolFailed: false) == .failed)
        check("a line starting with Failed in lowercase passes",
              TestRunReaction.outcome(command: "pytest", output: "Failed attempts are retried\n3 passed", toolFailed: false) == .passed)
        check("not a test: no reaction", TestRunReaction.outcome(command: "npm run build", output: "1 error", toolFailed: true) == nil)

        print("\nThe output from a hook")
        check("stdout and stderr", TestRunReaction.output(from: ["tool_response": ["stdout": "a", "stderr": "b"]]) == "a\nb")
        check("the error", TestRunReaction.output(from: ["error": "Exit code 1"]) == "Exit code 1")
        check("a plain string", TestRunReaction.output(from: ["tool_response": "ok"]) == "ok")

        print("\nThe command from a hook")
        check("a string", TestRunReaction.command(from: ["command": "npm test"]) == "npm test")
        check("a list (Codex)", TestRunReaction.command(from: ["command": ["cargo", "test"]]) == "cargo test")
        check("no command", TestRunReaction.command(from: ["file_path": "/a"]) == nil)

        print(failures == 0 ? "\nAll good." : "\n\(failures) failure(s).")
        exit(failures == 0 ? 0 : 1)
    }
}
