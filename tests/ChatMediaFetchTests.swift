import Foundation

// The fetch of a file of a sign in agent, against tests/fake_hermes_dashboard.py on 127.0.0.1 (nothing else is
// contacted): the bearer on the request, the path as one encoded query value, one refresh on 401, the caps, no redirect,
// the type from the bytes, and the private files.

@main
enum ChatMediaFetchTests {
    nonisolated(unsafe) static var failures = 0
    nonisolated(unsafe) static var base = ""

    static func check<T: Equatable>(_ label: String, _ got: T, _ expected: T) {
        if got == expected { print("  ok   \(label)") } else { print("  FAIL \(label)\n    got:      \(got)\n    expected: \(expected)"); failures += 1 }
    }
    static func checkTrue(_ label: String, _ value: Bool) {
        if value { print("  ok   \(label)") } else { print("  FAIL \(label)"); failures += 1 }
    }

    static func ctl(_ path: String, _ json: [String: Any] = [:]) async {
        var req = URLRequest(url: URL(string: base + path)!)
        req.httpMethod = "POST"
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        _ = try? await URLSession.shared.data(for: req)
    }

    static func state() async -> [String: Any] {
        guard let (d, _) = try? await URLSession.shared.data(from: URL(string: base + "/_test/state")!),
              let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return [:] }
        return j
    }

    static func downloads(_ s: [String: Any]) -> [[String: Any]] { (s["downloads"] as? [[String: Any]]) ?? [] }
    static func int(_ s: [String: Any], _ k: String) -> Int { (s[k] as? NSNumber)?.intValue ?? -1 }

    final class Mem: @unchecked Sendable {
        let lock = NSLock()
        var v = ""
        var value: String { get { lock.withLock { v } } set { lock.withLock { v = newValue } } }
    }

    static func agent(_ connection: HermesConnection? = .signIn) -> HermesAgent {
        HermesAgent(name: "steve", baseURL: base, profile: "codex", modelName: "", connection: connection)
    }

    static func makeSessions(_ mem: Mem) -> HermesSessions {
        HermesSessions(storage: HermesSessionStorage(load: { mem.value }, save: { mem.value = $0 }))
    }

    static func signedIn(_ sessions: HermesSessions) async -> Bool {
        let r = await HermesSignInNet.signIn(baseURL: base, timeout: 10) { url in
            Task { _ = try? await URLSession.shared.data(from: url) }
        }
        guard case .success(var rec) = r else { return false }
        rec.label = "Test User"
        await sessions.store(rec, name: "steve")
        return true
    }

    static func mode(_ m: String, size: Int? = nil, status401: Int = 0) async {
        await ctl("/_test/config", ["files_mode": m, "files_size": size ?? (1 << 20), "files_401": status401])
    }

    static func tempBase() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("coucou-media-test-" + UUID().uuidString, isDirectory: true)
    }

    static func perms(_ url: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func hasQuarantine(_ url: URL) -> Bool { getxattr(url.path, "com.apple.quarantine", nil, 0, 0, 0) > 0 }

    /// The id of a process that has just ended: nothing runs under it.
    static func deadPid() -> pid_t {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try? p.run()
        p.waitUntilExit()
        return p.processIdentifier
    }

    static func writeOwner(of folder: URL, pid: pid_t, started: Int) {
        FileManager.default.createFile(atPath: folder.appendingPathComponent("owner").path, contents: Data("\(pid) \(started)".utf8))
    }

    static func main() async {
        base = "http://127.0.0.1:\(CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "0")"
        print("ChatMediaFetch")
        let mem = Mem()
        let sessions = makeSessions(mem)
        guard await signedIn(sessions) else { print("  FAIL sign in against the fake"); exit(1) }
        let root = tempBase()
        let files = ChatMediaFiles(base: root)
        defer { try? FileManager.default.removeItem(at: root) }
        let none: @Sendable (Int, Int?) -> Void = { _, _ in }

        // The request
        await ctl("/_test/reset")
        guard await signedIn(sessions) else { print("  FAIL second sign in"); exit(1) }
        let path = "/Users/a/dir with space/her new&photos=1?x#y.ogg"
        let ok = await ChatMediaFetch.download(agent: agent(), path: path, cap: ChatMediaFetch.manualCap, sessions: sessions,
                                               files: files, conversation: "c1", progress: none)
        var file: ChatMediaFetch.Downloaded?
        if case .success(let d) = ok { file = d }
        checkTrue("01 the file arrives and is an ogg by its bytes", file?.format == .ogg && (file?.bytes ?? 0) > 20)
        let s1 = await state()
        let first = downloads(s1).first ?? [:]
        check("02 the bearer is on the request", (first["authorization"] as? String ?? "").hasPrefix("Bearer at-"), true)
        check("03 the path is one query value, nothing else", first["query_keys"] as? [String] ?? [], ["path"])
        check("04 the server reads back the exact path", first["path"] as? String ?? "", path)
        check("05 the raw query holds no space, ampersand, hash or plain slash",
              (first["raw_query"] as? String ?? "").allSatisfy { $0.isLetter || $0.isNumber || "-._~%=".contains($0) }, true)
        check("06 no cookie, no compression", (first["has_cookie"] as? Bool ?? true) == false && first["accept_encoding"] as? String == "identity", true)
        check("07 no token in the query", !(first["raw_query"] as? String ?? "").contains("token"), true)
        if let file {
            let name = file.url.lastPathComponent
            checkTrue("08 the file is private: random name, our extension, 0600, in a 0700 folder, quarantined",
                      name.hasSuffix(".ogg") && !name.contains("photos") && perms(file.url) == 0o600
                        && perms(file.url.deletingLastPathComponent()) == 0o700 && hasQuarantine(file.url))
            checkTrue("08b the launch folder and the base are 0700 too",
                      perms(file.url.deletingLastPathComponent().deletingLastPathComponent()) == 0o700 && perms(root) == 0o700)
        }

        // A refused token is refreshed once
        await ctl("/_test/reset")
        guard await signedIn(sessions) else { exit(1) }
        await mode("ok", status401: 1)
        let refreshed = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        let s2 = await state()
        let bearers = downloads(s2).map { $0["authorization"] as? String ?? "" }
        checkTrue("09 one refresh on a 401, then the file", { if case .success = refreshed { return true }; return false }()
                  && int(s2, "refresh_count") == 1 && bearers.count == 2 && bearers[0] != bearers[1])
        await ctl("/_test/reset")
        guard await signedIn(sessions) else { exit(1) }
        await mode("ok", status401: 2)
        let twice = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        let s3 = await state()
        check("10 a second 401 ends as sign in needed, after one refresh", twice, .failure(.signIn))
        check("10b exactly two requests", downloads(s3).count, 2)

        // Statuses
        await ctl("/_test/reset")
        guard await signedIn(sessions) else { exit(1) }
        for (m, want) in [("403", ChatMediaFetch.Failure.refused), ("404", .notFound), ("413", .tooLarge(nil)), ("415", .refused)] {
            await mode(m)
            let r = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
            check("11 status \(m)", r, .failure(want))
        }

        // Caps
        await mode("declared_big")
        let t0 = Date()
        let declared = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: ChatMediaFetch.autoAudioCap, sessions: sessions, files: files, conversation: "c1", progress: none)
        check("12 a declared size over the cap ends at once", declared, .failure(.tooLarge(200 << 20)))
        checkTrue("12b ...without waiting for the body", Date().timeIntervalSince(t0) < 3)
        await mode("endless")
        let t1 = Date()
        let endless = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        check("13 a body with no length that never ends is cut at the cap", endless, .failure(.tooLarge(nil)))
        checkTrue("13b ...quickly", Date().timeIntervalSince(t1) < 10)
        await mode("big", size: 1 << 20)
        let exact = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.png", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        let under = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.png", cap: (1 << 20) - 1, sessions: sessions, files: files, conversation: "c1", progress: none)
        checkTrue("14 a file of exactly the cap passes, one byte under the cap does not", {
            if case .success(let d) = exact, d.bytes == 1 << 20, d.format == .png, under == .failure(.tooLarge(1 << 20)) { return true }
            return false
        }())
        await mode("short")
        let short = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        check("15 fewer bytes than declared is a failure, no file", short, .failure(.network))

        // Redirect
        await ctl("/_test/reset")
        guard await signedIn(sessions) else { exit(1) }
        await mode("redirect")
        let red = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        let s4 = await state()
        checkTrue("16 a redirect is not followed: nothing reaches the target, no bearer with it", {
            if case .failure = red { return int(s4, "captured_hits") == 0 && int(s4, "captured_with_auth") == 0 }
            return false
        }())

        // The bytes decide
        await mode("html")
        let html = await ChatMediaFetch.download(agent: agent(), path: "/tmp/photo.png", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        checkTrue("17 html behind a png name stays unknown, saved as .bin, never as .png", {
            if case .success(let d) = html { return d.format == .unknown && d.url.pathExtension == "bin" }
            return false
        }())

        // Not a sign in agent: no request
        await ctl("/_test/reset")
        await mode("ok")
        let apiKey = await ChatMediaFetch.download(agent: agent(.apiKey), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        let legacy = await ChatMediaFetch.download(agent: agent(nil), path: "/tmp/a.ogg", cap: 1 << 20, sessions: sessions, files: files, conversation: "c1", progress: none)
        let s5 = await state()
        checkTrue("18 an API key agent (or an old one) makes no request at all", apiKey == .failure(.notAvailable) && legacy == .failure(.notAvailable) && downloads(s5).isEmpty)

        // Signed out
        let empty = makeSessions(Mem())
        let out = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.ogg", cap: 1 << 20, sessions: empty, files: files, conversation: "c1", progress: none)
        let s6 = await state()
        check("19 no session: sign in needed, no request", out, .failure(.signIn))
        check("19b ...none", downloads(s6).count, 0)

        // Progress
        await ctl("/_test/reset")
        guard await signedIn(sessions) else { exit(1) }
        await mode("big", size: 3 << 20)
        final class Seen: @unchecked Sendable { var steps: [Int] = []; let l = NSLock() }
        let seen = Seen()
        _ = await ChatMediaFetch.download(agent: agent(), path: "/tmp/a.png", cap: 5 << 20, sessions: sessions, files: files, conversation: "c1",
                                          progress: { got, _ in seen.l.withLock { seen.steps.append(got) } })
        checkTrue("20 progress is reported at least once, never goes back, never passes the size", seen.l.withLock {
            !seen.steps.isEmpty && zip(seen.steps, seen.steps.dropFirst()).allSatisfy { $0 <= $1 } && (seen.steps.last ?? 0) <= 3 << 20
        })

        // Cleaning
        let c2 = files.write(Data([1, 2, 3]), conversation: "c2", extensionName: "bin")
        let c3 = files.write(Data([1, 2, 3]), conversation: "c3", extensionName: "bin")
        files.removeConversation("c2")
        checkTrue("21 a conversation folder goes away alone", c2.map { !FileManager.default.fileExists(atPath: $0.path) } == true
                  && c3.map { FileManager.default.fileExists(atPath: $0.path) } == true)
        files.removeAll()
        checkTrue("22 everything of the launch goes away", c3.map { !FileManager.default.fileExists(atPath: $0.path) } == true)

        // Round 2: the sweep at launch (Aegis L4)
        let sweepRoot = tempBase()
        defer { try? FileManager.default.removeItem(at: sweepRoot) }
        let fm = FileManager.default
        func makeLaunch(_ name: String, age: TimeInterval) -> URL {
            let launch = sweepRoot.appendingPathComponent(name, isDirectory: true)
            let conv = launch.appendingPathComponent("conv", isDirectory: true)
            try? fm.createDirectory(at: conv, withIntermediateDirectories: true)
            let file = conv.appendingPathComponent("a.bin")
            fm.createFile(atPath: file.path, contents: Data([1]))
            let date = Date().addingTimeInterval(-age)
            for u in [file, conv, launch] { try? fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path) }
            return launch
        }
        let oldLaunch = makeLaunch("old", age: 20 * 60), youngLaunch = makeLaunch("young", age: 60)
        let firstApp = ChatMediaFiles(base: sweepRoot)
        let live = firstApp.write(Data([1, 2, 3]), conversation: "live", extensionName: "bin")
        let second = ChatMediaFiles(base: sweepRoot)
        second.sweepStale()
        checkTrue("23 the sweep removes only a launch folder older than 10 minutes", !fm.fileExists(atPath: oldLaunch.path) && fm.fileExists(atPath: youngLaunch.path))
        checkTrue("23b ...never the base, and never the live file of another copy of the app", fm.fileExists(atPath: sweepRoot.path) && live.map { fm.fileExists(atPath: $0.path) } == true)
        firstApp.sweepStale(now: Date().addingTimeInterval(3600))
        checkTrue("23c ...and never the folder of its own launch, however old the clock says it is", live.map { fm.fileExists(atPath: $0.path) } == true && !fm.fileExists(atPath: youngLaunch.path))

        // A conversation cleared while a file arrives writes nothing (Hera minor 1)
        let epochRoot = tempBase()
        defer { try? FileManager.default.removeItem(at: epochRoot) }
        let epochFiles = ChatMediaFiles(base: epochRoot)
        let before = epochFiles.epoch(of: "c9")
        epochFiles.removeConversation("c9")
        checkTrue("24 a write that started before the conversation was cleared writes nothing", epochFiles.write(Data([1]), conversation: "c9", extensionName: "bin", epoch: before) == nil)
        checkTrue("24b ...a write that started after it does, and the other conversations are not affected", {
            let after = epochFiles.epoch(of: "c9")
            let other = epochFiles.epoch(of: "c10")
            epochFiles.removeConversation("c9")
            return epochFiles.write(Data([1]), conversation: "c10", extensionName: "bin", epoch: other) != nil
                && epochFiles.write(Data([1]), conversation: "c9", extensionName: "bin", epoch: epochFiles.epoch(of: "c9")) != nil
                && after != epochFiles.epoch(of: "c9")
        }())
        let quitting = epochFiles.epoch(of: "c11")
        epochFiles.removeAll()
        checkTrue("24c ...and once the app is quitting, nothing is written either", epochFiles.write(Data([1]), conversation: "c11", extensionName: "bin", epoch: quitting) == nil)

        // A file that cannot be quarantined is not kept (Aegis N4)
        let qRoot = tempBase()
        defer { try? FileManager.default.removeItem(at: qRoot) }
        let noQuarantine = ChatMediaFiles(base: qRoot, quarantine: { _ in false })
        let refused = noQuarantine.write(Data([1, 2]), conversation: "q", extensionName: "bin")
        let leftovers = (try? fm.subpathsOfDirectory(atPath: qRoot.path))?.filter { $0.hasSuffix(".bin") } ?? ["?"]
        checkTrue("25 a file the system cannot quarantine is not kept: no URL, nothing left on disk", refused == nil && leftovers.isEmpty)
        checkTrue("25b the real attribute call reports failure for a path it cannot mark", !ChatMediaFiles.quarantine(URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString)")))

        // A link planted at the base is not followed (Aegis N4)
        let target = tempBase()
        try? fm.createDirectory(at: target, withIntermediateDirectories: true)
        let linkBase = tempBase()
        defer { try? fm.removeItem(at: target); try? fm.removeItem(at: linkBase) }
        try? fm.createSymbolicLink(at: linkBase, withDestinationURL: target)
        let linked = ChatMediaFiles(base: linkBase)
        let written = linked.write(Data([7]), conversation: "l", extensionName: "bin")
        var info = stat()
        let isLink = lstat(linkBase.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK
        checkTrue("26 a symbolic link at the base is replaced by a real folder, and nothing is written through it",
                  written != nil && !isLink && ((try? fm.contentsOfDirectory(atPath: target.path)) ?? ["?"]).isEmpty)

        // Save never deletes a folder, and a copy that cannot be quarantined is removed (Aegis N3, N4)
        let saveRoot = tempBase()
        try? fm.createDirectory(at: saveRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: saveRoot) }
        let source = saveRoot.appendingPathComponent("source.bin")
        fm.createFile(atPath: source.path, contents: Data([1, 2, 3]))
        let folder = saveRoot.appendingPathComponent("a folder", isDirectory: true)
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        fm.createFile(atPath: folder.appendingPathComponent("keep.txt").path, contents: Data([9]))
        checkTrue("27 save onto a folder refuses and the folder and its content stay", {
            !files.save(source, to: folder) && fm.fileExists(atPath: folder.appendingPathComponent("keep.txt").path)
        }())
        let existing = saveRoot.appendingPathComponent("existing.bin")
        fm.createFile(atPath: existing.path, contents: Data([0]))
        checkTrue("27b save onto a file replaces it with a quarantined copy", files.save(source, to: existing)
                  && (try? Data(contentsOf: existing)) == Data([1, 2, 3]) && hasQuarantine(existing))
        let blocked = saveRoot.appendingPathComponent("blocked.bin")
        checkTrue("27c a copy the system cannot quarantine is removed", !noQuarantine.save(source, to: blocked) && !fm.fileExists(atPath: blocked.path))

        // A launch of an earlier run: its owner is not running any more (the owner file names a process that is gone).
        if let leftover = files.write(Data([9]), conversation: "c4", extensionName: "bin") {
            writeOwner(of: leftover.deletingLastPathComponent().deletingLastPathComponent(), pid: deadPid(), started: 1)
        }
        let stale = ChatMediaFiles(base: root)
        stale.sweepStale(now: Date().addingTimeInterval(3600))
        checkTrue("28 an old launch of an earlier run is swept, the base stays", fm.fileExists(atPath: root.path) && ((try? fm.contentsOfDirectory(atPath: root.path)) ?? []).isEmpty)

        // Aegis B4: a launch folder is stale only when its owner is not running AND it is older than 10 minutes.
        let ownRoot = tempBase()
        defer { try? FileManager.default.removeItem(at: ownRoot) }
        let sleeper = Process()
        sleeper.executableURL = URL(fileURLWithPath: "/bin/sleep")
        sleeper.arguments = ["120"]
        try? sleeper.run()
        defer { sleeper.terminate() }
        let livePid = sleeper.processIdentifier
        let liveStart = ChatMediaFiles.startTime(of: livePid) ?? -1
        let gone = deadPid()
        func launch(_ name: String, age: TimeInterval, pid: pid_t?, started: Int = 1) -> URL {
            let folder = ownRoot.appendingPathComponent(name, isDirectory: true)
            let conv = folder.appendingPathComponent("conv", isDirectory: true)
            try? fm.createDirectory(at: conv, withIntermediateDirectories: true)
            fm.createFile(atPath: conv.appendingPathComponent("a.bin").path, contents: Data([1]))
            if let pid { writeOwner(of: folder, pid: pid, started: started) }
            let date = Date().addingTimeInterval(-age)
            for u in [folder.appendingPathComponent("owner"), conv.appendingPathComponent("a.bin"), conv, folder] {
                try? fm.setAttributes([.modificationDate: date], ofItemAtPath: u.path)
            }
            return folder
        }
        let aliveOld = launch("alive-old", age: 3600, pid: livePid, started: liveStart)
        let deadYoung = launch("dead-young", age: 5 * 60, pid: gone)
        let deadOld = launch("dead-old", age: 3600, pid: gone)
        let noOwnerOld = launch("no-owner-old", age: 3600, pid: nil)
        let reusedPid = launch("reused-pid-old", age: 3600, pid: livePid, started: liveStart + 12_345)
        let deadFuture = launch("dead-future", age: -365 * 24 * 3600, pid: gone)
        let aliveFuture = launch("alive-future", age: -365 * 24 * 3600, pid: livePid, started: liveStart)
        checkTrue("29a the process id and start time of a running process say it is alive; a gone process, a reused id, no owner say not", {
            ChatMediaFiles.ownerIsAlive(in: aliveOld) && !ChatMediaFiles.ownerIsAlive(in: deadOld)
                && !ChatMediaFiles.ownerIsAlive(in: reusedPid) && !ChatMediaFiles.ownerIsAlive(in: noOwnerOld)
        }())
        ChatMediaFiles(base: ownRoot).sweepStale()
        func exists(_ u: URL) -> Bool { fm.fileExists(atPath: u.path) }
        checkTrue("29 a launch folder whose owner runs is kept however old it is; one whose owner is gone but is young is kept",
                  exists(aliveOld) && exists(deadYoung) && exists(aliveFuture))
        checkTrue("29b ...a folder whose owner is gone and is old goes (also with no owner file, or a reused process id)",
                  !exists(deadOld) && !exists(noOwnerOld) && !exists(reusedPid))
        checkTrue("29c ...a folder dated in the future counts as old: it goes when its owner is gone, stays when the owner runs",
                  !exists(deadFuture) && exists(aliveFuture))

        // A second copy of the app (the same process here) sweeping 11 minutes later does not take the files of the first;
        // and when a folder is taken anyway, the first makes it again instead of failing for good.
        let twinRoot = tempBase()
        defer { try? FileManager.default.removeItem(at: twinRoot) }
        let firstCopy = ChatMediaFiles(base: twinRoot)
        let kept = firstCopy.write(Data([1, 2, 3]), conversation: "cv", extensionName: "bin")
        ChatMediaFiles(base: twinRoot).sweepStale(now: Date().addingTimeInterval(11 * 60))
        checkTrue("30 an older sweep by another copy at +11 minutes leaves the live files of this one", kept.map { exists($0) } == true)
        if let kept {
            let conversationFolder = kept.deletingLastPathComponent()
            let launchFolder = conversationFolder.deletingLastPathComponent()
            try? fm.removeItem(at: conversationFolder)
            let again = firstCopy.write(Data([4]), conversation: "cv", extensionName: "bin")
            checkTrue("30b a conversation folder that is missing at write time is made again", again.map { exists($0) } == true)
            try? fm.removeItem(at: launchFolder)
            let third = firstCopy.write(Data([5]), conversation: "cv", extensionName: "bin")
            checkTrue("30c ...and so is the launch folder (with its owner file), 0700", {
                guard let third else { return false }
                let launchAgain = third.deletingLastPathComponent().deletingLastPathComponent()
                var st = stat()
                return exists(third) && ChatMediaFiles.ownerIsAlive(in: launchAgain)
                    && stat(launchAgain.path, &st) == 0 && (st.st_mode & 0o777) == 0o700
            }())
        } else {
            checkTrue("30b ...", false)
        }

        // Aegis C4: a save that fails leaves the file that was there, and no copy behind.
        let keepRoot = tempBase()
        try? fm.createDirectory(at: keepRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: keepRoot) }
        let keepSource = keepRoot.appendingPathComponent("source.bin")
        fm.createFile(atPath: keepSource.path, contents: Data([1, 2, 3]))
        let precious = keepRoot.appendingPathComponent("precious.bin")
        fm.createFile(atPath: precious.path, contents: Data([42]))
        let failedSave = noQuarantine.save(keepSource, to: precious)
        checkTrue("31 a save whose copy cannot be quarantined fails and the existing file is intact, with nothing left next to it", {
            !failedSave && (try? Data(contentsOf: precious)) == Data([42])
                && ((try? fm.contentsOfDirectory(atPath: keepRoot.path)) ?? []).sorted() == ["precious.bin", "source.bin"]
        }())
        let missingFolder = keepRoot.appendingPathComponent("nowhere/x.bin")
        checkTrue("31b a save into a folder that does not exist fails, and the existing file elsewhere is untouched",
                  !files.save(keepSource, to: missingFolder) && (try? Data(contentsOf: precious)) == Data([42]))
        checkTrue("31c a save over an existing file replaces it by a quarantined copy and leaves no copy beside it", {
            files.save(keepSource, to: precious) && (try? Data(contentsOf: precious)) == Data([1, 2, 3]) && hasQuarantine(precious)
                && ((try? fm.contentsOfDirectory(atPath: keepRoot.path)) ?? []).sorted() == ["precious.bin", "source.bin"]
        }())

        print(failures == 0 ? "\nAll ChatMediaFetch tests passed." : "\n\(failures) ChatMediaFetch test(s) FAILED.")
        exit(failures == 0 ? 0 : 1)
    }
}
