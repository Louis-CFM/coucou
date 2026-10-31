#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/Check.swift" <<'SWIFT'
import Foundation

@main enum Check {
    static func main() throws {
        let home = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("fixture home with spaces")
        let fm = FileManager.default
        try fm.createDirectory(at: home, withIntermediateDirectories: true)
        assert(CodexConnection.installedIDEVersions(home: home).isEmpty)

        func package(_ folder: String, _ directory: String, _ metadata: [String: Any]) throws -> URL {
            let root = home.appendingPathComponent(folder).appendingPathComponent("extensions").appendingPathComponent(directory)
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            let url = root.appendingPathComponent("package.json")
            try JSONSerialization.data(withJSONObject: metadata).write(to: url)
            return url
        }
        for (folder, version) in [(".vscode", "0.11.0"), (".vscode-insiders", "0.12.0"), (".vscode-oss", "0.13.0")] {
            _ = try package(folder, "openai.chatgpt-\(version)", ["publisher": "openai", "name": "chatgpt", "version": version])
        }
        _ = try package(".vscode", "openai.chatgpt-0.9.0", ["publisher": "openai", "name": "chatgpt", "version": "0.9.0"])
        _ = try package(".vscode", "other.extension-9.0.0", ["publisher": "openai", "name": "chatgpt", "version": "9.0.0"])
        _ = try package(".vscode", "openai.chatgpt-8.0.0", ["publisher": "other", "name": "chatgpt", "version": "8.0.0"])
        _ = try package(".vscode", "openai.chatgpt-7.0.0", ["publisher": "openai", "name": "other", "version": "7.0.0"])
        _ = try package(".vscode", "openai.chatgpt-6.0.0", ["publisher": "openai", "name": "chatgpt", "version": "6.0.0\nextra"])
        let malformed = try package(".vscode", "openai.chatgpt-5.0.0", [:])
        try Data("{unfinished".utf8).write(to: malformed)
        let oversized = try package(".vscode", "openai.chatgpt-4.0.0", ["publisher": "openai", "name": "chatgpt", "version": "4.0.0", "padding": String(repeating: "x", count: 65_536)])
        let oversizedSize = try oversized.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        assert(oversizedSize > 65_536)

        let versions = CodexConnection.installedIDEVersions(home: home)
        assert(versions.map { "\($0.name)|\($0.version)" } == ["VS Code|0.11.0", "VS Code Insiders|0.12.0", "VSCodium|0.13.0"],
               "IDE diagnostics did not preserve flavor, numeric version, metadata identity and read bounds")
        print("PASS actual Codex IDE version reader: three local flavors, numeric newest version, missing/malformed/wrong/oversized metadata; fixture home only")
    }
}
SWIFT
swiftc -parse-as-library -swift-version 6 NotchBuddy/Sources/App/CodexConnection.swift "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check" "$task_tmp"
