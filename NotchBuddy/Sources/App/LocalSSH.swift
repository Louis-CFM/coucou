import Foundation

/// An ssh already running on this Mac to a remote host, for Open terminal: the same
/// rules as the Linux app's windows/src-tauri/src/remote.rs. Foundation only, so it
/// can be tested without AppKit (see scripts/test-local-ssh.sh).
enum LocalSSH {
    /// Who and where an ssh destination connects to. nil: what ssh's config says.
    struct Destination: Equatable {
        var user: String?
        var host: String
        var port: Int?
    }

    /// One of our processes, as `ps` lists it.
    struct Proc: Equatable {
        var pid: Int32
        var ppid: Int32
        var tty: String
        var age: Int
        var name: String
    }

    /// OpenSSH's options that take a value (its getopt string).
    static let valueOptions = Set("BDEFIJLOPQRSWbceilmopw")
    /// An ssh with one of these holds no terminal session: a tunnel, in the background, a stdio forward, a control command.
    static let noSession = Set("NfWO")

    /// `host`, `user@host` or `ssh://[user@]host[:port]`, read as ssh reads it.
    static func destination(_ text: String) -> Destination? {
        var rest = Substring(text)
        let uri = rest.hasPrefix("ssh://")
        if uri { rest = rest.dropFirst("ssh://".count) }
        var user: String?
        if let at = rest.lastIndex(of: "@") {
            user = String(rest[..<at])
            rest = rest[rest.index(after: at)...]
        }
        var port: Int?
        if uri {
            var tail: Substring = ""
            if rest.hasPrefix("[") {
                guard let close = rest.firstIndex(of: "]") else { return nil }
                tail = rest[rest.index(after: close)...]
                rest = rest[rest.index(after: rest.startIndex)..<close]
            } else if let colon = rest.firstIndex(of: ":") {
                tail = rest[colon...]
                rest = rest[..<colon]
            }
            if tail.hasPrefix(":") { tail = tail.dropFirst() }
            if !tail.isEmpty {
                guard let n = Int(tail), (0...65535).contains(n) else { return nil }
                port = n
            }
        }
        let host = rest.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        guard !host.isEmpty, !host.hasPrefix("-") else { return nil }
        return Destination(user: user, host: host, port: port)
    }

    /// An `ssh` command line: where it connects and its remote command. nil when it holds no session.
    static func call(_ argv: [String]) -> (Destination, String)? {
        var user: String?
        var port: Int?
        var dest: Destination?
        var command: [String] = []
        var options = true
        var i = 1
        while i < argv.count {
            let arg = argv[i]
            i += 1
            if !options || !arg.hasPrefix("-") || arg == "-" {
                if dest != nil {
                    command = Array(argv[(i - 1)...])
                    break
                }
                guard let found = destination(arg) else { return nil }
                user = user ?? found.user
                port = port ?? found.port
                dest = found
                continue
            }
            if arg == "--" {
                options = false
                continue
            }
            let letters = Array(arg.dropFirst())
            for (j, opt) in letters.enumerated() {
                if noSession.contains(opt) { return nil }
                guard valueOptions.contains(opt) else { continue }
                var value = String(letters[(j + 1)...])
                if value.isEmpty {
                    guard i < argv.count else { return nil }
                    value = argv[i]
                    i += 1
                }
                var key = opt == "l" ? "user" : opt == "p" ? "port" : ""
                if opt == "o" {
                    let cut = value.firstIndex(where: { $0 == "=" || $0.isWhitespace }) ?? value.endIndex
                    key = String(value[..<cut])
                    value = String(value[cut...])
                }
                value = String(value.drop(while: { $0 == "=" || $0.isWhitespace }))
                // The first value given wins, as in ssh.
                if key.lowercased() == "user", user == nil {
                    user = value
                } else if key.lowercased() == "port", port == nil {
                    port = Int(value).flatMap { (0...65535).contains($0) ? $0 : nil }
                }
                break
            }
        }
        guard var found = dest else { return nil }
        found.user = user
        found.port = port
        return (found, command.joined(separator: " "))
    }

    /// The same host, and the same port and user where both name one: `localhost:2222` is not `localhost`.
    static func same(_ a: Destination, _ b: Destination) -> Bool {
        a.host == b.host && a.port == b.port && (a.user == nil || b.user == nil || a.user == b.user)
    }

    /// Of the ssh processes to a host, with their remote commands: the one running
    /// the session's tmux session, else the newest.
    static func pick(_ found: [(Proc, String)], tmux: String) -> Proc? {
        func namesTmux(_ command: String) -> Bool {
            !tmux.isEmpty && command.split(whereSeparator: { !($0.isASCII && ($0.isLetter || $0.isNumber) || "._-".contains($0)) })
                .contains { $0 == tmux }
        }
        return found.max { a, b in
            let (ta, tb) = (namesTmux(a.1), namesTmux(b.1))
            return ta != tb ? !ta : a.0.age > b.0.age
        }?.0
    }

    /// `ps -o pid=,ppid=,tty=,etime=,ucomm=` lines. A process with no terminal ("??") is left out.
    static func processes(ps text: String) -> [Proc] {
        text.split(separator: "\n").compactMap { line in
            let f = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard f.count >= 5, let pid = Int32(f[0]), let ppid = Int32(f[1]), f[2] != "??",
                  let age = seconds(etime: f[3]) else { return nil }
            return Proc(pid: pid, ppid: ppid, tty: "/dev/" + f[2], age: age, name: f[4...].joined(separator: " "))
        }
    }

    /// `ps`'s elapsed time, `[[dd-]hh:]mm:ss`, in seconds.
    static func seconds(etime: String) -> Int? {
        let parts = etime.split(separator: "-")
        guard (1...2).contains(parts.count), let clock = parts.last else { return nil }
        let days = parts.count == 2 ? Int(parts[0]) : 0
        let fields = clock.split(separator: ":").compactMap { Int($0) }
        guard let days, (2...3).contains(fields.count), fields.count == clock.split(separator: ":").count else { return nil }
        return fields.reduce(0) { $0 * 60 + $1 } + days * 86_400
    }

    /// The arguments in a KERN_PROCARGS2 buffer: argc, the executable's path, padding, then argv.
    static func argv(procArgs bytes: [UInt8]) -> [String] {
        guard bytes.count >= 4 else { return [] }
        let argc = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16 | Int(bytes[3]) << 24
        var i = 4
        while i < bytes.count, bytes[i] != 0 { i += 1 }
        while i < bytes.count, bytes[i] == 0 { i += 1 }
        var out: [String] = []
        while out.count < argc, i < bytes.count {
            let end = bytes[i...].firstIndex(of: 0) ?? bytes.count
            out.append(String(decoding: bytes[i..<end], as: UTF8.self))
            i = end + 1
        }
        return out
    }

    /// The parents of `pid`, nearest first, up to launchd.
    static func ancestors(of pid: Int32, in all: [Proc]) -> [Int32] {
        let parent = Dictionary(all.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { first, _ in first })
        var out: [Int32] = []
        var current = pid
        while let up = parent[current], up > 1, !out.contains(up), out.count < 32 {
            out.append(up)
            current = up
        }
        return out
    }

    /// Our processes, and among them the ssh to `host` on a terminal to bring forward,
    /// Coucou's own left out. nil when there is none.
    static func find(host: String, tmux: String) -> (ssh: Proc, all: [Proc])? {
        guard let want = destination(host) else { return nil }
        let all = processes(ps: run("/bin/ps", ["-U", String(getuid()), "-o", "pid=,ppid=,tty=,etime=,ucomm="]))
        let me = ProcessInfo.processInfo.processIdentifier
        let found: [(Proc, String)] = all.compactMap { p in
            guard p.name == "ssh", !ancestors(of: p.pid, in: all).contains(me),
                  let c = call(argv(procArgs: procArgs(p.pid))), same(c.0, want) else { return nil }
            return (p, c.1)
        }
        guard let ssh = pick(found, tmux: tmux) else { return nil }
        return (ssh, all)
    }

    private static func procArgs(_ pid: Int32) -> [UInt8] {
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        var argmax: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctl(&mib, 2, &argmax, &size, nil, 0) == 0, argmax > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: Int(argmax))
        size = buffer.count
        mib = [CTL_KERN, KERN_PROCARGS2, pid]
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return [] }
        return Array(buffer.prefix(size))
    }

    private static func run(_ exe: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
