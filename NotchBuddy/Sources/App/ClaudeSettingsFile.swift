import Foundation

// MARK: - ClaudeSettingsFile
// Reads and rewrites a settings file Coucou does not own (~/.claude/settings.json).
// The rules are the ones in CLAUDE.md: never start from an empty object when the
// file is there but unusable, always take a backup, and only ever write over the
// exact bytes the user was shown.

enum ClaudeSettingsFile {

    enum Failure: LocalizedError, Equatable {
        case unreadable(String)
        case invalid(String)
        case changed(String)
        case backupFailed(String)
        case writeFailed(String)
        case unexpectedHooks(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name):
                return "\(name) cannot be read — Coucou has not touched it."
            case .invalid(let name):
                return "\(name) is not valid JSON — Coucou has not touched it."
            case .changed(let name):
                return "\(name) changed since the preview. Nothing was written — review it again."
            case .backupFailed(let name):
                return "Could not back up \(name). Nothing was written."
            case .writeFailed(let name):
                return "Could not write \(name). The original is untouched."
            case .unexpectedHooks(let name):
                return "\(name): \"hooks\" has an unexpected type — Coucou has not touched it."
            }
        }
    }

    /// The "hooks" object of a settings file. Absent → empty.
    /// Present but not an object → throws, so it is never replaced.
    static func hooks(in settings: [String: Any], name: String) throws -> [String: Any] {
        guard let value = settings["hooks"] else { return [:] }
        guard let hooks = value as? [String: Any] else { throw Failure.unexpectedHooks(name) }
        return hooks
    }

    /// The hook groups already declared for one event. Absent → empty.
    /// Present but not a list of objects → throws, so it is never replaced.
    static func hookGroups(in hooks: [String: Any], event: String, name: String) throws -> [[String: Any]] {
        guard let value = hooks[event] else { return [] }
        guard let groups = value as? [[String: Any]] else { throw Failure.unexpectedHooks(name) }
        return groups
    }

    /// The settings object and the bytes it was parsed from.
    /// Absent file → empty object and nil bytes. An empty file is an empty object.
    /// Present but unreadable, or anything that is not a JSON object → throws:
    /// not knowing what is in there is not the same as empty.
    static func read(at url: URL) throws -> (object: [String: Any], bytes: Data?) {
        guard FileManager.default.fileExists(atPath: url.path) else { return ([:], nil) }
        let name = url.lastPathComponent
        guard let bytes = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0A || $0 == 0x0D }) {
            return ([:], bytes)
        }
        guard let object = (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] else {
            throw Failure.invalid(name)
        }
        return (object, bytes)
    }

    /// Replaces the file with `data`, after a dated backup.
    ///
    /// `original` is what `read` returned when `data` was computed. If the file
    /// holds anything else by now — another tool, the user's own editor — nothing
    /// is written. Returns the backup, or nil when there was no file to back up.
    @discardableResult
    static func write(_ data: Data, to url: URL, expecting original: Data?) throws -> URL? {
        let fm = FileManager.default
        let name = url.lastPathComponent
        let exists = fm.fileExists(atPath: url.path)

        var current: Data? = nil
        if exists {
            guard let bytes = try? Data(contentsOf: url) else { throw Failure.unreadable(name) }
            current = bytes
        }
        guard current == original else { throw Failure.changed(name) }

        // A dotfiles setup often makes settings.json a symlink: write to the file
        // it points at, so the link survives the rename below.
        let target = url.resolvingSymlinksInPath()

        var backupURL: URL? = nil
        // settings.json can hold API keys in its `env` block: a new file is ours
        // only, and a rewrite keeps the permissions the original had.
        var mode = 0o600
        if exists {
            let backup = freeBackupURL(for: url)
            do { try fm.copyItem(at: target, to: backup) } catch { throw Failure.backupFailed(name) }
            backupURL = backup
            if let found = (try? fm.attributesOfItem(atPath: target.path))?[.posixPermissions] as? NSNumber {
                mode = found.intValue & 0o777
            }
        } else {
            try? fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        // Written beside the target and renamed over it: a crash or a full disk
        // leaves the original intact rather than half a file.
        let temp = target.deletingLastPathComponent()
            .appendingPathComponent("\(target.lastPathComponent).coucou-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: temp)
        guard fm.createFile(atPath: temp.path, contents: data,
                            attributes: [.posixPermissions: NSNumber(value: 0o600)]) else {
            throw Failure.writeFailed(name)
        }
        do {
            try fm.setAttributes([.posixPermissions: NSNumber(value: mode)], ofItemAtPath: temp.path)
        } catch {
            try? fm.removeItem(at: temp)
            throw Failure.writeFailed(name)
        }
        guard rename(temp.path, target.path) == 0 else {
            try? fm.removeItem(at: temp)
            throw Failure.writeFailed(name)
        }
        return backupURL
    }

    /// Down to the second, and never an existing name: installing then
    /// uninstalling in the same second must not lose the first backup.
    private static func freeBackupURL(for url: URL) -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.lastPathComponent).bak-\(formatter.string(from: Date()))"
        let dir = url.deletingLastPathComponent()
        var candidate = dir.appendingPathComponent(base)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)-\(n)")
            n += 1
        }
        return candidate
    }
}
