import Foundation

/// Pure logic that finds out whether the installed Hermes can use the approval transport (no Process, no disk
/// access of its own: everything goes through injected closures, so it is unit-tested).
///
/// `hermes` may be a python script, or a `#!/bin/sh` wrapper that `exec`s another launcher. Git installs put
/// `~/.local/bin/hermes` -> `~/.hermes/hermes-agent/.hermes/bin/hermes`, and that last launcher is itself a
/// `#!/bin/sh` file ending with `exec <tools python3> -I -c '...sys.path.insert(0, "<install dir>")...' "$@"`:
/// no venv, the interpreter is a Mach-O binary under `~/.hermes/tools/`. That interpreter (not a venv left by an
/// older installer, not the system python3) is the one that must run the import check, with the install directory
/// on `sys.path`.
enum HermesDetect {
    /// Why the approvals toggle can or cannot be used.
    enum Support: Equatable { case supported, hermesNotFound, importFailed }

    /// Run as `<python> -I -c <importCheckScript> <installDir>`: the install directory travels in argv and is never
    /// interpolated into the code string.
    static let importCheckScript =
        "import sys; sys.path.insert(0, sys.argv[1]); from hermes_cli.approval_transport import ApprovalRequest"

    static func importArguments(installDir: String) -> [String] { ["-I", "-c", importCheckScript, installDir] }

    private static let shellNames: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    static func isShell(_ path: String) -> Bool {
        shellNames.contains((path as NSString).lastPathComponent)
    }

    /// The macOS system pythons: the `/usr/bin/python*` stubs (they open the "install developer tools" dialog without
    /// the Command Line Tools), anything under `/System/` and the Command Line Tools themselves.
    static func isSystemPython(_ path: String) -> Bool {
        let p = (path as NSString).standardizingPath
        return p.hasPrefix("/usr/bin/python") || p.hasPrefix("/System/")
            || p.hasPrefix("/Library/Developer/CommandLineTools/")
    }

    /// A python interpreter by name (`python3`, `python3.14`...). It does not need to be readable as text.
    /// Name-prefix match only: a path such as `/x/python-wrapper.sh` also counts. This is acceptable because the
    /// paths come only from the Hermes launcher itself (shebang or `exec` target), never from the environment.
    static func isPython(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.lowercased().hasPrefix("python")
    }

    /// Lines of a text file, LF or CRLF, each trimmed.
    private static func trimmedLines(_ text: String) -> [String] {
        text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    /// The interpreter named by the shebang of `text`, or nil when `text` is not a script or the shebang is
    /// `#!/usr/bin/env name`: env is never resolved (a GUI app's PATH leads to the system python3, which must not
    /// run), the explicit-path candidates cover that case.
    static func shebangInterpreter(in text: String) -> String? {
        guard text.hasPrefix("#!"), let first = trimmedLines(text).first else { return nil }
        let parts = first.dropFirst(2).split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard let exe = parts.first, exe.hasPrefix("/") else { return nil }
        if (exe as NSString).lastPathComponent == "env" { return nil }
        return exe
    }

    /// The absolute path of the first `exec <path> ...` line of a shell wrapper (`exec /x/hermes "$@"`,
    /// `exec "/x/hermes" "$@"`, `exec /x/python3 -I -c '...'`). Bare commands (`exec hermes`), comments and
    /// forms with options (`exec -a name /p`, `exec env X=1 /p`) are ignored.
    static func execTarget(inWrapper text: String) -> String? {
        for line in trimmedLines(text) {
            guard line.hasPrefix("exec ") else { continue }
            let rest = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            guard let c = rest.first else { continue }
            if c == "\"" || c == "'" {
                let body = rest.dropFirst()
                guard let end = body.firstIndex(of: c) else { continue }
                let path = String(body[body.startIndex..<end])
                if path.hasPrefix("/") { return path }
            } else {
                let path = String(rest.prefix(while: { $0 != " " && $0 != "\t" }))
                if path.hasPrefix("/") { return path }
            }
        }
        return nil
    }

    /// The directory of the `sys.path.insert(0, '<dir>')` literal of a launcher (quotes may be shell-escaped).
    static func installDir(inLauncher text: String) -> String? {
        guard let r = text.range(of: "sys.path.insert(0,") else { return nil }
        let rest = text[r.upperBound...].drop(while: { $0 == " " || $0 == "\t" || $0 == "'" || $0 == "\"" })
        let dir = String(rest.prefix(while: { $0 != "'" && $0 != "\"" && $0 != ")" && !$0.isNewline }))
        return dir.hasPrefix("/") ? dir : nil
    }

    /// The install directory implied by the location of a launcher:
    /// `<root>/.hermes/bin/hermes` and `<root>/venv/bin/hermes` -> `<root>`.
    static func installDir(fromLauncherPath path: String) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard parts.count > 3, parts.last == "hermes", parts[parts.count - 2] == "bin",
              parts[parts.count - 3] == ".hermes" || parts[parts.count - 3] == "venv" else { return nil }
        return "/" + parts.dropLast(3).joined(separator: "/")
    }

    /// The directory printed by `hermes --version` ("Install directory: /path").
    static func installDir(versionOutput: String) -> String? {
        let key = "Install directory:"
        for line in trimmedLines(versionOutput) where line.hasPrefix(key) {
            let dir = line.dropFirst(key.count).trimmingCharacters(in: .whitespaces)
            if dir.hasPrefix("/") { return dir }
        }
        return nil
    }

    /// Ordered, de-duplicated interpreters and install directories to try.
    struct Plan: Equatable {
        var pythons: [String]
        var installDirs: [String]
    }

    /// - hermesPath: the `hermes` executable found on the Mac.
    /// - text: the head of that file (nil when unreadable or not text).
    /// - readFile: reads the head of a file as text; returns nil for unreadable files and binaries.
    ///
    /// Python order: (a) the shebang of `hermes`; (b) when it is a shell wrapper, follow up to two `exec <path>`
    /// levels: a python target is a candidate even though a binary has no readable shebang, any other target is read
    /// for its own shebang; (c) legacy venv (`~/.hermes/hermes-agent/venv/bin`), kept only as a fallback for
    /// installs made by the older installer. A shell or a system python (`isSystemPython`) is never a candidate.
    static func plan(hermesPath: String, text: String?, home: String,
                     readFile: (String) -> String?) -> Plan {
        var pythons: [String] = [], dirs: [String] = []
        func addPython(_ p: String) { if !p.isEmpty, !isSystemPython(p), !pythons.contains(p) { pythons.append(p) } }
        func addDir(_ d: String?) { if let d, !d.isEmpty, !dirs.contains(d) { dirs.append(d) } }

        var paths = [hermesPath]
        var texts: [String] = []
        if let text { texts.append(text) }

        if let shebang = text.flatMap({ shebangInterpreter(in: $0) }) {
            if isPython(shebang) {
                addPython(shebang)
            } else if isShell(shebang) {
                var current = text
                for _ in 0..<2 {
                    guard let t = current, let target = execTarget(inWrapper: t) else { break }
                    paths.append(target)
                    if isPython(target) { addPython(target); break }
                    guard let body = readFile(target) else { break }
                    texts.append(body)
                    if let inner = shebangInterpreter(in: body), isPython(inner) { addPython(inner); break }
                    current = body
                }
            }
        }

        let root = "\(home)/.hermes/hermes-agent"
        addPython("\(root)/venv/bin/python3")
        addPython("\(root)/venv/bin/python")
        if let body = readFile("\(root)/venv/bin/hermes"),
           let inner = shebangInterpreter(in: body), isPython(inner) { addPython(inner) }

        for t in texts { addDir(installDir(inLauncher: t)) }
        for p in paths { addDir(installDir(fromLauncherPath: p)) }
        addDir(root)
        return Plan(pythons: pythons, installDirs: dirs)
    }

    /// The decision behind the Settings toggle. Fails closed: `.supported` only when an import check passed.
    /// - exists: is the file an executable.
    /// - runImport: runs `python` with `importArguments(installDir:)` and says whether it exited 0.
    /// - versionOutput: stdout of `hermes --version`, asked only when nothing found so far passed.
    ///
    /// Worst case: about 4 pythons x 3 install dirs import attempts plus the `--version` call, each capped at 3 s by
    /// the caller. The caller runs this off the main thread.
    static func decide(hermesPath: String?, home: String,
                       readFile: (String) -> String?,
                       exists: (String) -> Bool,
                       runImport: (_ python: String, _ installDir: String) -> Bool,
                       versionOutput: () -> String?) -> Support {
        guard let hermesPath else { return .hermesNotFound }
        var tried = Set<String>()
        func attempt(_ python: String, _ dir: String) -> Bool {
            guard tried.insert("\(python)\u{0}\(dir)").inserted, exists(python) else { return false }
            return runImport(python, dir)
        }
        var candidates = plan(hermesPath: hermesPath, text: readFile(hermesPath), home: home, readFile: readFile)
        for python in candidates.pythons {
            for dir in candidates.installDirs where attempt(python, dir) { return .supported }
        }
        // Last resort: ask hermes where it is installed.
        if let out = versionOutput(), let dir = installDir(versionOutput: out) {
            if !candidates.pythons.contains("\(dir)/venv/bin/python3") { candidates.pythons.append("\(dir)/venv/bin/python3") }
            for python in candidates.pythons where attempt(python, dir) { return .supported }
        }
        return .importFailed
    }
}
