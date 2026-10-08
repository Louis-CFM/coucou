import Foundation

@main
enum ClaudeSettingsFileTests {
    static var fm: FileManager { .default }

    static func failure(_ body: () throws -> Void) -> ClaudeSettingsFile.Failure? {
        do { try body() } catch let error as ClaudeSettingsFile.Failure { return error } catch { return nil }
        return nil
    }

    static func contents(_ url: URL?) -> Data? {
        guard let url else { return nil }
        return try? Data(contentsOf: url)
    }

    static func backups(in dir: URL) -> [String] {
        ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.hasPrefix("settings.json.bak-") }
    }

    static func mode(_ url: URL) -> Int {
        ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }

    static func setMode(_ value: Int, _ url: URL) throws {
        try fm.setAttributes([.posixPermissions: NSNumber(value: value)], ofItemAtPath: url.path)
    }

    static func main() throws {
        let dir = fm.temporaryDirectory
            .appendingPathComponent("coucou-settings-\(ProcessInfo.processInfo.processIdentifier)")
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let name = "settings.json"

        // Absent file: start from nothing, with no bytes to compare against.
        let absent = try ClaudeSettingsFile.read(at: url)
        precondition(absent.object.isEmpty && absent.bytes == nil)

        // Empty and whitespace-only files are an empty object too.
        try Data(" \n\t".utf8).write(to: url)
        let blank = try ClaudeSettingsFile.read(at: url)
        precondition(blank.object.isEmpty && blank.bytes != nil)

        // This is the whole bug: content we cannot use came back as an empty
        // object, and the install then wrote nothing but Coucou's hooks over it.
        for bad in ["{ not json", "[1,2,3]", "\"a string\""] {
            try Data(bad.utf8).write(to: url)
            let refused = failure { _ = try ClaudeSettingsFile.read(at: url) }
            precondition(refused == .invalid(name), "unusable content must refuse, not come back empty: \(bad)")
            precondition(contents(url) == Data(bad.utf8), "a refused file must stay as it was")
        }

        // A valid file reads back whole.
        let original = Data(#"{"model":"opus","hooks":{"PreToolUse":[{"hooks":[{"command":"other-tool"}]}]}}"#.utf8)
        try original.write(to: url)
        let snapshot = try ClaudeSettingsFile.read(at: url)
        precondition(snapshot.object["model"] as? String == "opus")
        precondition(snapshot.bytes == original)

        // No "hooks" at all: start from nothing, as before.
        let noHooks = try ClaudeSettingsFile.hooks(in: ["model": "opus"], name: name)
        precondition(noHooks.isEmpty)
        let noGroups = try ClaudeSettingsFile.hookGroups(in: [:], event: "PreToolUse", name: name)
        precondition(noGroups.isEmpty)

        // The usual shape comes back as it is, other tools' hooks included.
        let hooks = try ClaudeSettingsFile.hooks(in: snapshot.object, name: name)
        let groups = try ClaudeSettingsFile.hookGroups(in: hooks, event: "PreToolUse", name: name)
        precondition(groups.count == 1)
        let emptyList = try ClaudeSettingsFile.hookGroups(in: ["Stop": [Any]()], event: "Stop", name: name)
        precondition(emptyList.isEmpty)

        // "hooks" in a shape we do not know used to be replaced by an empty
        // object and written back. It is refused, and the file stays as it was.
        for bad in [#"{"model":"opus","hooks":[1,2]}"#, #"{"hooks":"off"}"#, #"{"hooks":null}"#] {
            try Data(bad.utf8).write(to: url)
            let parsed = try ClaudeSettingsFile.read(at: url)
            let refused = failure { _ = try ClaudeSettingsFile.hooks(in: parsed.object, name: name) }
            precondition(refused == .unexpectedHooks(name), "an unknown \"hooks\" must refuse: \(bad)")
            precondition(contents(url) == Data(bad.utf8))
        }
        for bad in [#"{"hooks":{"PreToolUse":"x"}}"#, #"{"hooks":{"PreToolUse":[1]}}"#, #"{"hooks":{"PreToolUse":{}}}"#] {
            try Data(bad.utf8).write(to: url)
            let parsed = try ClaudeSettingsFile.read(at: url)
            let hooks = try ClaudeSettingsFile.hooks(in: parsed.object, name: name)
            let refused = failure { _ = try ClaudeSettingsFile.hookGroups(in: hooks, event: "PreToolUse", name: name) }
            precondition(refused == .unexpectedHooks(name), "an unknown event shape must refuse: \(bad)")
            precondition(contents(url) == Data(bad.utf8))
        }
        precondition(backups(in: dir).isEmpty)

        // A file edited after the preview is refused: nothing written, no backup.
        let edited = Data(#"{"model":"someone-else-edited-this"}"#.utf8)
        try edited.write(to: url)
        let next = Data(#"{"model":"opus","hooks":{}}"#.utf8)
        let stale = failure { _ = try ClaudeSettingsFile.write(next, to: url, expecting: snapshot.bytes) }
        precondition(stale == .changed(name))
        precondition(contents(url) == edited)
        precondition(backups(in: dir).isEmpty)

        // A file that appeared after a preview of "no file" is refused as well.
        let appeared = failure { _ = try ClaudeSettingsFile.write(next, to: url, expecting: nil) }
        precondition(appeared == .changed(name))
        precondition(contents(url) == edited)

        // The matching write backs up the exact bytes, then replaces the file.
        try setMode(0o600, url)
        let backup = try ClaudeSettingsFile.write(next, to: url, expecting: edited)
        precondition(backup != nil)
        precondition(contents(backup) == edited)
        precondition(contents(url) == next)
        precondition(mode(url) == 0o600, "a rewrite must not widen the file's permissions")

        // Two writes in the same second keep two backups.
        let third = Data(#"{"model":"sonnet"}"#.utf8)
        let secondBackup = try ClaudeSettingsFile.write(third, to: url, expecting: next)
        precondition(secondBackup != nil && secondBackup != backup)
        precondition(contents(backup) == edited)
        precondition(contents(secondBackup) == next)
        precondition(backups(in: dir).count == 2)

        // Wider permissions the user chose are kept as they were.
        try setMode(0o644, url)
        _ = try ClaudeSettingsFile.write(next, to: url, expecting: third)
        precondition(mode(url) == 0o644)

        // No leftover temporary file beside the settings.
        let leftovers = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".coucou-") }
        precondition(leftovers.isEmpty)

        // No file at all: created in a missing folder, ours only, nothing to back up.
        let fresh = dir.appendingPathComponent("new/settings.json")
        let freshBackup = try ClaudeSettingsFile.write(next, to: fresh, expecting: nil)
        precondition(freshBackup == nil)
        precondition(contents(fresh) == next)
        precondition(mode(fresh) == 0o600)

        // A symlinked settings.json stays a link; the file it points at is rewritten.
        let real = dir.appendingPathComponent("dotfiles-settings.json")
        try original.write(to: real)
        let linkDir = dir.appendingPathComponent("linked")
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        let link = linkDir.appendingPathComponent("settings.json")
        try fm.createSymbolicLink(at: link, withDestinationURL: real)
        let linkBackup = try ClaudeSettingsFile.write(next, to: link, expecting: original)
        let stillALink = (try? fm.destinationOfSymbolicLink(atPath: link.path)) != nil
        precondition(stillALink, "the link was replaced by a file")
        precondition(contents(real) == next)
        precondition(contents(linkBackup) == original)

        print("Claude settings file: all checks passed")
    }
}
