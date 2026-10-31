#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
cat > "$task_tmp/Check.swift" <<'SWIFT'
import Foundation

@main struct Check {
    static func main() throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let bundleURL = root.appendingPathComponent("Fixture.bundle", isDirectory: true)
        let source = bundleURL.appendingPathComponent("Contents/Resources/CodexDesktopPlugin", isDirectory: true)
        try fm.createDirectory(at: source.appendingPathComponent(".agents/plugins"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("scripts"), withIntermediateDirectories: true)
        let info: [String: Any] = ["CFBundleIdentifier": "fixture.coucou.plugin", "CFBundleName": "Fixture", "CFBundlePackageType": "BNDL"]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        let files = [".agents/plugins/marketplace.json": "{\"fixture\":true}", "plugin.json": "{\"name\":\"fixture\"}", "mcp.json": "{\"fixture\":true}", "scripts/server.py": "print('fixture')", "README.md": "fixture setup"]
        for (path, text) in files { try Data(text.utf8).write(to: source.appendingPathComponent(path)) }
        let bundle = Bundle(url: bundleURL)!
        let parent = root.appendingPathComponent("chosen folder", isDirectory: true)
        try fm.createDirectory(at: parent, withIntermediateDirectories: true)
        let output = try CodexDesktopPlugin.export(to: parent, bundle: bundle)
        assert(output == parent.appendingPathComponent("Coucou-Codex-Plugin", isDirectory: true))
        for (path, text) in files {
            let copied = try String(contentsOf: output.appendingPathComponent(path), encoding: .utf8)
            assert(copied == text)
        }
        try Data("preserve user file".utf8).write(to: output.appendingPathComponent("user.txt"))
        do {
            _ = try CodexDesktopPlugin.export(to: parent, bundle: bundle)
            assertionFailure("Existing directory was overwritten")
        } catch { assert((error as NSError).code == 2) }
        let userFile = try String(contentsOf: output.appendingPathComponent("user.txt"), encoding: .utf8)
        assert(userFile == "preserve user file")
        try fm.removeItem(at: output)
        try Data("preserve existing file".utf8).write(to: output)
        do {
            _ = try CodexDesktopPlugin.export(to: parent, bundle: bundle)
            assertionFailure("Existing file was overwritten")
        } catch { assert((error as NSError).code == 2) }
        let existingFile = try String(contentsOf: output, encoding: .utf8)
        assert(existingFile == "preserve existing file")
        try fm.removeItem(at: output)
        let missingTarget = parent.appendingPathComponent("missing-target")
        try fm.createSymbolicLink(at: output, withDestinationURL: missingTarget)
        do {
            _ = try CodexDesktopPlugin.export(to: parent, bundle: bundle)
            assertionFailure("Existing broken symlink was overwritten")
        } catch { }
        let linkTarget = try fm.destinationOfSymbolicLink(atPath: output.path)
        assert(linkTarget == missingTarget.path)
        try fm.removeItem(at: source)
        do {
            _ = try CodexDesktopPlugin.export(to: root, bundle: bundle)
            assertionFailure("Missing bundled resource was accepted")
        } catch { assert((error as NSError).code == 1) }
        assert(!fm.fileExists(atPath: root.appendingPathComponent("Coucou-Codex-Plugin").path))
        print("PASS actual desktop plugin export: complete hidden/nested resources, missing bundle, existing directory/file/symlink never overwritten")
    }
}
SWIFT
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library NotchBuddy/Sources/App/CodexDesktopPlugin.swift "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check" "$task_tmp"
cat > "$task_tmp/Store.swift" <<'SWIFT'
@main struct Store { static func main() {} }
SWIFT
swiftc -DAPPSTORE -swift-version 6 -strict-concurrency=complete -parse-as-library NotchBuddy/Sources/App/CodexDesktopPlugin.swift "$task_tmp/Store.swift" -o "$task_tmp/store"
"$task_tmp/store"
python3 - <<'PY'
from pathlib import Path
targets = Path('NotchBuddy/project.yml').read_text().split('\ntargets:\n', 1)[1]
github, others = targets.split('\n  CoucouAppStore:', 1)
resource = '      - path: Resources/CodexDesktopPlugin\n        buildPhase: resources\n        type: folder\n'
assert resource in github
assert 'Resources/CodexDesktopPlugin' not in others
print('PASS desktop plugin resources target GitHub only; helper compiles out for App Store')
PY
