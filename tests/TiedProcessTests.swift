import Foundation

@main
struct TiedProcessTests {
    static func main() {
        // Helper mode: start a tied sleep, say its pid, then wait to be killed.
        if CommandLine.arguments.contains("--hold") {
            let (p, _) = TiedProcess.make("/bin/sleep", ["300"])
            p.standardOutput = FileHandle.nullDevice
            try! p.run()
            print(childPid(of: p.processIdentifier))
            fflush(stdout)
            Thread.sleep(forTimeInterval: 300)
            return
        }

        var failures = 0
        func check(_ ok: Bool, _ name: String) {
            if ok { print("  ✓ \(name)") } else { print("  ✗ \(name)"); failures += 1 }
        }

        // Coucou killed outright: the command goes with it
        let holder = Process()
        holder.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        holder.arguments = ["--hold"]
        let out = Pipe()
        holder.standardOutput = out
        try! holder.run()
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
        let sleeper = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        check(sleeper > 0 && alive(sleeper), "the command runs")
        kill(holder.processIdentifier, SIGKILL)
        holder.waitUntilExit()
        check(gone(sleeper), "a hard kill of its parent ends it")

        // Stopped by Coucou
        let (p, _) = TiedProcess.make("/bin/sleep", ["300"])
        p.standardOutput = FileHandle.nullDevice
        try! p.run()
        let child = childPid(of: p.processIdentifier)
        p.terminate()
        p.waitUntilExit()
        check(child > 0 && gone(child), "terminate ends it")

        // Ends by itself: its status and stderr come through
        let (q, _) = TiedProcess.make("/bin/sh", ["-c", "echo why >&2; exit 3"])
        let err = Pipe()
        q.standardError = err
        try! q.run()
        let said = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        q.waitUntilExit()
        check(q.terminationStatus == 3 && said == "why\n", "its exit status and stderr come through")

        if failures > 0 { print("\(failures) failure(s)"); exit(1) }
        print("TiedProcess: all passed")
    }

    /// The tied command's pid: the shell's child that is not its watcher.
    static func childPid(of shell: Int32) -> Int32 {
        for _ in 0..<50 {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
            p.arguments = ["-P", String(shell), "-x", "sleep"]
            let out = Pipe()
            p.standardOutput = out
            try? p.run()
            p.waitUntilExit()
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if let pid = Int32(text.split(separator: "\n").first ?? "") { return pid }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return 0
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    static func gone(_ pid: Int32) -> Bool {
        for _ in 0..<50 where alive(pid) { Thread.sleep(forTimeInterval: 0.05) }
        return !alive(pid)
    }
}
