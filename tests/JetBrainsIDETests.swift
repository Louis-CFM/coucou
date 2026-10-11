import Foundation

@main
enum JetBrainsIDETests {
    static var failures = 0

    static func check(_ label: String, _ got: Bool) {
        if got { print("  ✓ \(label)") }
        else   { print("  ✗ \(label)"); failures += 1 }
    }

    static func main() {
        print("JetBrainsIDE.matches")
        check("WebStorm", JetBrainsIDE.matches(bundleId: "com.jetbrains.WebStorm"))
        check("PyCharm CE", JetBrainsIDE.matches(bundleId: "com.jetbrains.pycharm.ce"))
        check("Android Studio", JetBrainsIDE.matches(bundleId: "com.google.android.studio"))
        check("IDE missing from the table", JetBrainsIDE.matches(bundleId: "com.jetbrains.fleet"))
        check("VS Code → false", !JetBrainsIDE.matches(bundleId: "com.microsoft.VSCode"))
        check("Cursor → false", !JetBrainsIDE.matches(bundleId: "com.todesktop.230313mzl4w4u92"))
        check("Terminal → false", !JetBrainsIDE.matches(bundleId: "com.apple.Terminal"))
        check("empty → false", !JetBrainsIDE.matches(bundleId: ""))

        print("JetBrainsIDE.name")
        check("WebStorm", JetBrainsIDE.name(for: "com.jetbrains.WebStorm") == "WebStorm")
        check("RubyMine", JetBrainsIDE.name(for: "com.jetbrains.rubymine") == "RubyMine")
        check("unknown IDE → JetBrains", JetBrainsIDE.name(for: "com.jetbrains.fleet") == "JetBrains")
        check("nil → JetBrains", JetBrainsIDE.name(for: nil) == "JetBrains")

        print("JetBrainsIDE.projectRoot")
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("jetbrains-ide-\(UUID().uuidString)")
        let project = tmp.appendingPathComponent("project")
        let deeper = project.appendingPathComponent("src/app")
        let bare = tmp.appendingPathComponent("bare/src")
        try? fm.createDirectory(at: project.appendingPathComponent(".idea"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: deeper, withIntermediateDirectories: true)
        try? fm.createDirectory(at: bare, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        check("project folder itself", JetBrainsIDE.projectRoot(for: project.path)?.lastPathComponent == "project")
        check("subfolder → nearest .idea", JetBrainsIDE.projectRoot(for: deeper.path)?.lastPathComponent == "project")
        check("no .idea → nil", JetBrainsIDE.projectRoot(for: bare.path) == nil)
        check("empty → nil", JetBrainsIDE.projectRoot(for: "") == nil)
        check("nil → nil", JetBrainsIDE.projectRoot(for: nil) == nil)

        print("JetBrainsIDE.projectName")
        check("folder name", JetBrainsIDE.projectName(project) == "project")
        try? "Renamed\n".write(to: project.appendingPathComponent(".idea/.name"), atomically: true, encoding: .utf8)
        check(".idea/.name wins", JetBrainsIDE.projectName(project) == "Renamed")

        if failures > 0 {
            print("\n\(failures) test(s) failed."); exit(1)
        }
        print("\nAll tests passed.")
    }
}
