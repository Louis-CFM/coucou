#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d)
trap 'rm -rf "$task_tmp"' EXIT
# Compile the actual Dock preference and close decision with in-memory boundaries.
# This never changes the user's preferences or activates an application.
python3 - "$task_tmp/Check.swift" <<'PY'
from pathlib import Path
import sys

hub = Path('NotchBuddy/Sources/App/FlowHub.swift').read_text()
app = Path('NotchBuddy/Sources/App/AppDelegate.swift').read_text()

def block(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

preference = block(hub, '    static var showInDock: Bool {')
close = block(app, '    func applicationShouldTerminateAfterLastWindowClosed(')
show = block(hub, '    func show(_ page: HubPage? = nil) {')
launch = next(line.strip() for line in app.splitlines()
              if 'NSApp.setActivationPolicy(FlowHubController.showInDock' in line)
assert 'win.isReleasedWhenClosed = false' in show
assert 'terminate(' not in show and 'terminate(' not in close
assert 'action: #selector(NSApplication.terminate(_:))' in app, 'Explicit Quit must remain available'

Path(sys.argv[1]).write_text('''
@MainActor final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Bool] = [:]
    func object(forKey key: String) -> Any? { values[key] }
    func set(_ value: Bool, forKey key: String) { values[key] = value }
}
@MainActor final class NSApplication {
    enum ActivationPolicy { case regular, accessory }
    var policy = ActivationPolicy.regular
    var activationCount = 0
    func setActivationPolicy(_ policy: ActivationPolicy) { self.policy = policy }
    func activate(ignoringOtherApps: Bool) { activationCount += 1 }
}
@MainActor let NSApp = NSApplication()
@MainActor final class FlowHubController {
    static let showInDockKey = "coucouShowInDock"
''' + preference + '''
}
@MainActor final class AppDelegate {
''' + close + '''
    func launch() {
''' + launch + '''
    }
}
@main struct Check {
    @MainActor static func main() {
        let defaults = UserDefaults.standard
        let key = FlowHubController.showInDockKey
        let delegate = AppDelegate()
        assert(defaults.values.isEmpty)
        assert(!FlowHubController.showInDock, "Unset preferences must use background mode")
        delegate.launch()
        assert(NSApp.policy == .accessory && NSApp.activationCount == 0)
        assert(defaults.values.isEmpty, "Reading the default must not overwrite user preferences")
        assert(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        defaults.values[key] = true
        assert(FlowHubController.showInDock, "Preserve an existing explicit Dock choice")
        delegate.launch()
        assert(NSApp.policy == .regular)
        assert(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))

        FlowHubController.showInDock = false
        assert(defaults.values[key] == false && !FlowHubController.showInDock)
        assert(NSApp.policy == .accessory && NSApp.activationCount == 0)
        delegate.launch()
        assert(NSApp.policy == .accessory, "The explicit background choice survives launch")

        FlowHubController.showInDock = true
        assert(defaults.values[key] == true && FlowHubController.showInDock)
        assert(NSApp.policy == .regular && NSApp.activationCount == 1)
        delegate.launch()
        assert(NSApp.policy == .regular && NSApp.activationCount == 1)
        assert(!delegate.applicationShouldTerminateAfterLastWindowClosed(NSApp))
        print("Background mode: default, saved choices, toggle, launch and window close passed")
    }
}
''')
PY
swiftc -swift-version 6 -parse-as-library "$task_tmp/Check.swift" -o "$task_tmp/check"
"$task_tmp/check"
