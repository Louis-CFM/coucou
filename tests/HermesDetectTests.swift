import Foundation

// Pure tests of the Hermes detection: shebangs, shell wrappers, the real launcher shape, install directory, and
// the decision (candidate order, dedup, status mapping) with injected closures. No Process, no disk.

@main
enum HermesDetectTests {
    nonisolated(unsafe) static var failures = 0
    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ✓ \(label)") }
        else { print("  ✗ \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }

    static let home = "/Users/x"
    static let root = "/Users/x/.hermes/hermes-agent"
    static let venv = "/Users/x/.hermes/hermes-agent/venv/bin"
    static let toolsPython = "/Users/x/.hermes/tools/python-3.14.9+20261021-darwin-arm64/bin/python3"
    static let pathHermes = "/Users/x/.local/bin/hermes"
    static let launcherPath = "/Users/x/.hermes/hermes-agent/.hermes/bin/hermes"

    static let wrapper = "#!/bin/sh\nexec /Users/x/.hermes/hermes-agent/.hermes/bin/hermes \"$@\"\n"
    /// The real launcher (~/.hermes/hermes-agent/.hermes/bin/hermes), relevant lines, home replaced by /Users/x.
    static let realLauncher = #"""
    #!/bin/sh
    exec /Users/x/.hermes/tools/python-3.14.9+20261021-darwin-arm64/bin/python3 -I -c 'import os, re, sys
    import contextlib, hashlib, io, pathlib, shutil, subprocess
    os.environ.pop('"'"'PYTHONHOME'"'"', None)
    os.environ.pop('"'"'PYTHONPATH'"'"', None)
    sys.path.insert(0, '"'"'/Users/x/.hermes/hermes-agent'"'"')
    def _hermes_closure_repair():
        pass
    from hermes_cli.main import main
    sys.exit(main())
    ' "$@"

    """#
    static let venvHermes = "#!/Users/x/.hermes/hermes-agent/venv/bin/python3\n# -*- coding: utf-8 -*-\n"

    static func main() {
        print("execTarget")
        check("exec path \"$@\"", HermesDetect.execTarget(inWrapper: wrapper), launcherPath)
        check("exec quoted", HermesDetect.execTarget(inWrapper: "#!/bin/sh\nexec \"/a b/hermes\" \"$@\"\n"), "/a b/hermes")
        check("exec single quoted", HermesDetect.execTarget(inWrapper: "#!/bin/sh\nexec '/a/hermes' \"$@\"\n"), "/a/hermes")
        check("no exec line", HermesDetect.execTarget(inWrapper: "#!/bin/sh\necho hi\n"), nil)
        check("exec of a bare command is ignored", HermesDetect.execTarget(inWrapper: "#!/bin/sh\nexec hermes \"$@\"\n"), nil)
        check("commented exec ignored", HermesDetect.execTarget(inWrapper: "#!/bin/sh\n# exec /x/hermes\n"), nil)
        check("real launcher: python target", HermesDetect.execTarget(inWrapper: realLauncher), toolsPython)
        check("CRLF exec target", HermesDetect.execTarget(inWrapper: "#!/bin/sh\r\nexec /x/hermes \"$@\"\r\n"), "/x/hermes")
        check("CRLF exec target, no args", HermesDetect.execTarget(inWrapper: "#!/bin/sh\r\nexec /x/hermes\r\n"), "/x/hermes")

        print("shebangInterpreter")
        check("plain", HermesDetect.shebangInterpreter(in: venvHermes), "\(venv)/python3")
        check("env shebang yields nothing (never resolved through PATH)",
              HermesDetect.shebangInterpreter(in: "#!/usr/bin/env python3\n"), nil)
        check("env with tab yields nothing", HermesDetect.shebangInterpreter(in: "#!/usr/bin/env\tpython3\n"), nil)
        check("not a script", HermesDetect.shebangInterpreter(in: "MZ binary"), nil)
        check("shebang with args", HermesDetect.shebangInterpreter(in: "#!/x/python3 -u\n"), "/x/python3")
        check("tab separated args", HermesDetect.shebangInterpreter(in: "#!/x/python3\t-u\n"), "/x/python3")
        check("CRLF shebang", HermesDetect.shebangInterpreter(in: "#!/x/python3\r\nimport os\r\n"), "/x/python3")
        check("CRLF shebang with args", HermesDetect.shebangInterpreter(in: "#!/x/python3 -u\r\nimport os\r\n"), "/x/python3")
        check("relative interpreter ignored", HermesDetect.shebangInterpreter(in: "#!python3\n"), nil)

        print("install directory")
        check("sys.path.insert literal (shell-escaped quotes)", HermesDetect.installDir(inLauncher: realLauncher), root)
        check("sys.path.insert plain quotes", HermesDetect.installDir(inLauncher: "sys.path.insert(0, \"/a/b\")\n"), "/a/b")
        check("sys.path.insert of a non-path", HermesDetect.installDir(inLauncher: "sys.path.insert(0, sys.argv[1])\n"), nil)
        check("from launcher path .hermes/bin", HermesDetect.installDir(fromLauncherPath: launcherPath), root)
        check("from venv launcher path", HermesDetect.installDir(fromLauncherPath: "\(venv)/hermes"), root)
        check("from an unrelated path", HermesDetect.installDir(fromLauncherPath: "/usr/local/bin/hermes"), nil)
        check("parses --version output",
              HermesDetect.installDir(versionOutput: "Hermes Agent v0.22.7\nInstall directory: /Users/x/.hermes/hermes-agent\nInstall method: git\n"), root)
        check("--version CRLF",
              HermesDetect.installDir(versionOutput: "Hermes\r\nInstall directory: /Users/x/h\r\n"), "/Users/x/h")
        check("no install directory line", HermesDetect.installDir(versionOutput: "Hermes Agent v1\n"), nil)

        print("importArguments")
        let args = HermesDetect.importArguments(installDir: "/a b/\"; import os #")
        check("isolated mode, dir only in argv", args.prefix(2).map { $0 }, ["-I", "-c"])
        check("script never contains the dir", args[2].contains("/a b/"), false)
        check("dir is the last argv", args.last, "/a b/\"; import os #")

        print("plan")
        let files: [String: String] = [pathHermes: wrapper, launcherPath: realLauncher, "\(venv)/hermes": venvHermes]
        let read: (String) -> String? = { files[$0] }
        let real = HermesDetect.plan(hermesPath: pathHermes, text: wrapper, home: home, readFile: read)
        check("real launcher: launcher python first, then legacy venv",
              real.pythons, [toolsPython, "\(venv)/python3", "\(venv)/python"])
        check("real launcher: install dir once (literal and dirname agree)", real.installDirs, [root])
        let noVenvFiles: (String) -> String? = { [pathHermes: wrapper, launcherPath: realLauncher][$0] }
        check("fresh install without venv: launcher python still first",
              HermesDetect.plan(hermesPath: pathHermes, text: wrapper, home: home, readFile: noVenvFiles).pythons.first, toolsPython)
        check("python target is a candidate even when its content is unreadable",
              HermesDetect.plan(hermesPath: launcherPath, text: realLauncher, home: home, readFile: { _ in nil }).pythons.first, toolsPython)
        check("python shebang first",
              HermesDetect.plan(hermesPath: "/o/hermes", text: "#!/opt/py/bin/python3.12\n", home: home, readFile: { _ in nil }).pythons,
              ["/opt/py/bin/python3.12", "\(venv)/python3", "\(venv)/python"])
        check("env shebang: only the explicit venv candidates",
              HermesDetect.plan(hermesPath: "/o/hermes", text: "#!/usr/bin/env python3\n", home: home, readFile: { _ in nil }).pythons,
              ["\(venv)/python3", "\(venv)/python"])
        check("shell shebang, unreadable target: venv only",
              HermesDetect.plan(hermesPath: pathHermes, text: wrapper, home: home, readFile: { _ in nil }).pythons,
              ["\(venv)/python3", "\(venv)/python"])
        check("shell is never a candidate",
              HermesDetect.plan(hermesPath: pathHermes, text: wrapper, home: home, readFile: read).pythons.contains("/bin/sh"), false)
        let deep: (String) -> String? = { ["/l1": "#!/bin/sh\nexec /l2 \"$@\"\n", "/l2": "#!/z/python3\n"][$0] }
        check("two exec levels deep",
              HermesDetect.plan(hermesPath: "/h", text: "#!/bin/sh\nexec /l1 \"$@\"\n", home: home, readFile: deep).pythons.first, "/z/python3")
        check("non-python shebang is skipped",
              HermesDetect.plan(hermesPath: "/h", text: "#!/usr/bin/node\n", home: home, readFile: { _ in nil }).pythons.contains("/usr/bin/node"), false)
        check("venv hermes shebang is a candidate when it differs",
              HermesDetect.plan(hermesPath: "/h", text: nil, home: home,
                                readFile: { $0 == "\(venv)/hermes" ? "#!/other/venv/bin/python3\n" : nil }).pythons,
              ["\(venv)/python3", "\(venv)/python", "/other/venv/bin/python3"])
        let crlf = HermesDetect.plan(hermesPath: pathHermes, text: wrapper.replacingOccurrences(of: "\n", with: "\r\n"), home: home,
                                     readFile: { $0 == launcherPath ? realLauncher.replacingOccurrences(of: "\n", with: "\r\n") : nil })
        check("CRLF wrapper chain still finds the launcher python", crlf.pythons.first, toolsPython)
        check("CRLF launcher still gives the install dir", crlf.installDirs.first, root)

        check("shebang /usr/bin/python3 is not a candidate",
              HermesDetect.plan(hermesPath: "/h", text: "#!/usr/bin/python3\n", home: home, readFile: { _ in nil }).pythons.contains("/usr/bin/python3"), false)
        check("exec target /usr/bin/python3 is not a candidate",
              HermesDetect.plan(hermesPath: "/h", text: "#!/bin/sh\nexec /usr/bin/python3 -m hermes \"$@\"\n", home: home, readFile: { _ in nil }).pythons.contains("/usr/bin/python3"), false)

        print("decide")
        var ran: [String] = []
        let exists: (String) -> Bool = { _ in true }
        let okAll: (String, String) -> Bool = { py, dir in ran.append("\(py)|\(dir)"); return true }
        check("no hermes -> hermesNotFound",
              HermesDetect.decide(hermesPath: nil, home: home, readFile: read, exists: exists, runImport: { _, _ in true }, versionOutput: { nil }),
              .hermesNotFound)
        check("real launcher shape -> supported",
              HermesDetect.decide(hermesPath: pathHermes, home: home, readFile: read, exists: exists, runImport: okAll, versionOutput: { nil }),
              .supported)
        check("... and the first import ran with the launcher python and the install dir", ran, ["\(toolsPython)|\(root)"])
        ran = []
        check("fresh install (no venv on disk) -> supported with the launcher python",
              HermesDetect.decide(hermesPath: pathHermes, home: home, readFile: noVenvFiles,
                                  exists: { $0 == toolsPython }, runImport: okAll, versionOutput: { nil }),
              .supported)
        check("... only the launcher python was tried", ran, ["\(toolsPython)|\(root)"])
        var attempts: [String] = []
        check("hermes found, every import fails -> importFailed",
              HermesDetect.decide(hermesPath: pathHermes, home: home, readFile: read, exists: exists,
                                  runImport: { py, dir in attempts.append("\(py)|\(dir)"); return false }, versionOutput: { nil }),
              .importFailed)
        check("... the launcher python, then both legacy venv pythons",
              attempts, ["\(toolsPython)|\(root)", "\(venv)/python3|\(root)", "\(venv)/python|\(root)"])
        attempts = []
        check("--version install dir is tried last",
              HermesDetect.decide(hermesPath: pathHermes, home: home, readFile: read, exists: exists,
                                  runImport: { py, dir in attempts.append("\(py)|\(dir)"); return dir == "/Users/x/other" },
                                  versionOutput: { "Install directory: /Users/x/other\n" }),
              .supported)
        check("... after the chain candidates, never repeating a pair",
              attempts, ["\(toolsPython)|\(root)", "\(venv)/python3|\(root)", "\(venv)/python|\(root)",
                         "\(toolsPython)|/Users/x/other"])
        attempts = []
        check("--version dir equal to a tried dir does not repeat the pair",
              HermesDetect.decide(hermesPath: pathHermes, home: home, readFile: read, exists: exists,
                                  runImport: { py, dir in attempts.append("\(py)|\(dir)"); return false },
                                  versionOutput: { "Install directory: \(root)\n" }),
              .importFailed)
        check("... pairs are unique", attempts.count, Set(attempts).count)
        attempts = []
        check("non-executable candidates are skipped without running",
              HermesDetect.decide(hermesPath: pathHermes, home: home, readFile: read, exists: { _ in false },
                                  runImport: { py, dir in attempts.append(py); return true }, versionOutput: { nil }),
              .importFailed)
        check("... nothing ran", attempts, [])

        if failures > 0 { print("\n\(failures) failure(s)"); exit(1) }
        print("\nAll Hermes detect tests passed")
    }
}
