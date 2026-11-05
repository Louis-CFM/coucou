import Foundation

// Where the bytes of a fetched file live: a private folder in the temporary directory, one sub folder per launch and
// per conversation, every name random. The agent's file name never reaches the disk (it is display only). Every file
// carries the quarantine attribute, so the system treats it as downloaded: a file that cannot be quarantined is not
// kept. Foundation only, no flag.
//
// Nothing here is logged, and no path leaves this file except to the code that wrote the file.

final class ChatMediaFiles: @unchecked Sendable {
    /// The folder of the whole app: `<temporary>/CoucouMedia`.
    static let shared = ChatMediaFiles(base: FileManager.default.temporaryDirectory.appendingPathComponent("CoucouMedia", isDirectory: true))

    /// A launch folder whose owner is gone and that nothing touched for this long is what a crashed run left.
    static let staleAge: TimeInterval = 10 * 60
    /// The file in a launch folder that says whose it is: the process id and the time that process started.
    static let ownerFileName = "owner"

    /// The state of a conversation's folder when a download started: a write that finds it changed (the conversation
    /// was cleared meanwhile, or the app is quitting) writes nothing.
    struct Epoch: Equatable, Sendable {
        fileprivate let all: Int
        fileprivate let conversation: Int
    }

    let base: URL
    private let quarantineFile: @Sendable (URL) -> Bool
    private let lock = NSLock()
    private var launch: URL?
    private var folders: [String: URL] = [:]
    private var allEpoch = 0
    private var epochs: [String: Int] = [:]

    init(base: URL, quarantine: @escaping @Sendable (URL) -> Bool = { ChatMediaFiles.quarantine($0) }) {
        self.base = base
        self.quarantineFile = quarantine
    }

    // MARK: Folders

    /// The folder of one launch, made on first use (0700, random name) and made again, with the same name, if something
    /// removed it meanwhile (a second copy of the app sweeping). The caller holds the lock.
    private func launchFolder() -> URL? {
        if let launch, Self.isOurFolder(launch) { return launch }
        guard Self.makePrivateFolder(base) else { return nil }
        let folder = launch ?? base.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard Self.makePrivateFolder(folder) else { return nil }
        Self.writeOwner(in: folder)
        launch = folder
        return folder
    }

    private static func isOurFolder(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    // MARK: Owner

    /// When the process started, in microseconds, or nil when there is no such process. With the id it names a process
    /// for good: an id that was given to another process later has another start time.
    static func startTime(of pid: pid_t) -> Int? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.size
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0, info.kp_proc.p_pid == pid else { return nil }
        let started = info.kp_proc.p_un.__p_starttime
        return Int(started.tv_sec) * 1_000_000 + Int(started.tv_usec)
    }

    private static func writeOwner(in folder: URL) {
        let pid = getpid()
        guard let started = startTime(of: pid) else { return }
        let url = folder.appendingPathComponent(ownerFileName, isDirectory: false)
        FileManager.default.createFile(atPath: url.path, contents: Data("\(pid) \(started)".utf8), attributes: [.posixPermissions: 0o600])
    }

    /// Whether the process that made a launch folder is still running. A folder with no readable owner has none.
    static func ownerIsAlive(in folder: URL) -> Bool {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(ownerFileName), options: []),
              data.count < 64, let text = String(data: data, encoding: .utf8) else { return false }
        let parts = text.split(separator: " ")
        guard parts.count == 2, let pid = Int32(parts[0]), let started = Int(parts[1]), pid > 0 else { return false }
        return startTime(of: pid) == started
    }

    /// A folder that is really a folder of ours: a link planted at that name is removed (the link, never what it points
    /// to) and replaced, and the result is checked again without following links.
    private static func makePrivateFolder(_ url: URL) -> Bool {
        let fm = FileManager.default
        var info = stat()
        if lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) != S_IFDIR { try? fm.removeItem(at: url) }
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // An existing folder keeps its mode: set it again.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        } catch {
            return false
        }
        return lstat(url.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR && info.st_uid == getuid()
    }

    private func folder(for conversation: String, epoch: Epoch?) -> URL? {
        lock.lock(); defer { lock.unlock() }
        if let epoch, epoch != currentEpoch(conversation) { return nil }
        // A folder that was swept away from under us is made again.
        if let known = folders[conversation], Self.isOurFolder(known) { return known }
        guard let launch = launchFolder() else { return nil }
        let folder = folders[conversation] ?? launch.appendingPathComponent(UUID().uuidString, isDirectory: true)
        guard Self.makePrivateFolder(folder) else { return nil }
        folders[conversation] = folder
        return folder
    }

    private func currentEpoch(_ conversation: String) -> Epoch { Epoch(all: allEpoch, conversation: epochs[conversation] ?? 0) }

    /// Taken before a download starts, handed to `write` when it ends.
    func epoch(of conversation: String) -> Epoch {
        lock.lock(); defer { lock.unlock() }
        return currentEpoch(conversation)
    }

    // MARK: Writing

    /// Writes `data` to a new file of that conversation: random name, `extensionName` from our own list, mode 0600,
    /// quarantined. Returns nil when the disk refuses, when the file cannot be quarantined, or when `epoch` is no
    /// longer the one of the conversation (it was cleared while the bytes arrived). The epoch is checked when the folder
    /// is taken, and the lock is not held while the file is written: a clear that comes in between leaves a file that
    /// the caller removes (`remove`) when it sees its fetch was cancelled, which is what keeps the folder empty.
    func write(_ data: Data, conversation: String, extensionName: String, epoch: Epoch? = nil) -> URL? {
        guard let folder = folder(for: conversation, epoch: epoch) else { return nil }
        let url = folder.appendingPathComponent(UUID().uuidString + "." + extensionName, isDirectory: false)
        guard FileManager.default.createFile(atPath: url.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return nil }
        guard quarantineFile(url) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return url
    }

    /// Deletes a file this object wrote (a fetch that was cancelled after the bytes arrived). Anything outside the base
    /// is left alone.
    func remove(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(base.standardizedFileURL.path + "/") else { return }
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: Cleaning

    /// Deletes the files of one conversation (it was cleared, or its agent was removed).
    func removeConversation(_ conversation: String) {
        lock.lock()
        let folder = folders.removeValue(forKey: conversation)
        epochs[conversation, default: 0] += 1
        lock.unlock()
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    /// Deletes everything of this launch (the app quits).
    func removeAll() {
        lock.lock()
        let launch = self.launch
        self.launch = nil
        folders = [:]
        allEpoch += 1
        lock.unlock()
        if let launch { try? FileManager.default.removeItem(at: launch) }
    }

    /// At launch: what an earlier run left behind (a crash) goes away. A launch folder is removed only when its owner
    /// process is gone (its `owner` file names a process that does not run, or is missing) and nothing touched it for
    /// `staleAge` (a folder dated in the future counts as old), so a second copy of the app (a Debug build next to the
    /// installed one) never loses the files it is showing. This launch's own folder is never removed. The base stays.
    func sweepStale(olderThan age: TimeInterval = ChatMediaFiles.staleAge, now: Date = Date()) {
        lock.lock()
        let current = launch?.standardizedFileURL.path
        lock.unlock()
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]
        guard let children = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: keys, options: []) else { return }
        for child in children {
            guard child.standardizedFileURL.path != current,
                  let values = try? child.resourceValues(forKeys: Set(keys)),
                  values.isSymbolicLink != true, values.isDirectory == true,
                  !Self.ownerIsAlive(in: child) else { continue }
            // The folder of a launch changes when a conversation folder is made; a conversation folder, when a file is.
            var newest = values.contentModificationDate ?? .distantFuture
            for grandchild in (try? fm.contentsOfDirectory(at: child, includingPropertiesForKeys: [.contentModificationDateKey], options: [])) ?? [] {
                if let date = (try? grandchild.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate, date > newest {
                    newest = date
                }
            }
            let idle = now.timeIntervalSince(newest)
            if idle > age || idle < 0 { try? fm.removeItem(at: child) }
        }
    }

    /// The `com.apple.quarantine` attribute, as a download from the web has it (flags 0083: downloaded, not yet opened).
    /// False when the file system refuses it.
    static func quarantine(_ url: URL) -> Bool {
        let value = "0083;\(String(Int(Date().timeIntervalSince1970), radix: 16));Coucou;"
        return value.withCString { setxattr(url.path, "com.apple.quarantine", $0, strlen($0), 0, XATTR_NOFOLLOW) } == 0
    }

    /// Copies a verified file to where the person chose, and quarantines the copy too. The copy is made next to the
    /// destination first and only then put in its place, so a save that fails at any step leaves the file that was there
    /// as it was (and no copy behind). A file already there is replaced, since the save panel asked; a folder is never
    /// deleted.
    func save(_ source: URL, to destination: URL) -> Bool {
        let fm = FileManager.default
        var isFolder: ObjCBool = false
        let exists = fm.fileExists(atPath: destination.path, isDirectory: &isFolder)
        if exists && isFolder.boolValue { return false }
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".coucou-" + UUID().uuidString + ".tmp", isDirectory: false)
        guard (try? fm.copyItem(at: source, to: temp)) != nil else { return false }
        guard quarantineFile(temp) else {
            try? fm.removeItem(at: temp)
            return false
        }
        do {
            if exists {
                _ = try fm.replaceItemAt(destination, withItemAt: temp)
            } else {
                try fm.moveItem(at: temp, to: destination)
            }
        } catch {
            try? fm.removeItem(at: temp)
            return false
        }
        return true
    }
}
