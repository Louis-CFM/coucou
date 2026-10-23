import Foundation

// Coucou's own releases on GitHub, for "New version" in the notch (GitHub build only; the App
// Store updates its own build). Pure Foundation so tests/MacUpdateTests.swift checks the rules:
// which release is the Mac's, whether it is newer, what to say about it. The Mac's tags are
// `vX.Y.Z` with a `Coucou.zip`; Windows, Linux and Android have their own prefixed tags.

enum MacUpdate {
    static let owner = "Louis-CFM"
    static let repo = "coucou"
    static let releasesURL = URL(string: "https://api.github.com/repos/\(owner)/\(repo)/releases?per_page=20")!
    /// What the downloaded app must be signed as: Coucou's bundle id, Louis's Developer ID team.
    static let bundleId = "fr.louisraille.NotchBuddy"
    static let teamId = "256AUJ9555"
    static var codeRequirement: String {
        "anchor apple generic and identifier \"\(bundleId)\" and certificate leaf[subject.OU] = \"\(teamId)\""
    }

    struct Release: Equatable, Sendable {
        let version: String
        let tag: String
        let zipURL: URL
        let size: Int
        let pageURL: URL
        /// The first "What's new" line, without its Markdown ("WhatsApp in one click").
        let headline: String?
    }

    /// The newest published Mac release in `GET /releases`.
    static func latest(_ data: Data) -> Release? {
        guard let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return nil }
        let releases: [Release] = list.compactMap { r in
            guard r["draft"] as? Bool != true, r["prerelease"] as? Bool != true,
                  let tag = r["tag_name"] as? String, let version = macVersion(tag),
                  let assets = r["assets"] as? [[String: Any]],
                  let zip = assets.first(where: { $0["name"] as? String == "Coucou.zip" }),
                  let s = zip["browser_download_url"] as? String, let url = URL(string: s),
                  let page = (r["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
            return Release(version: version, tag: tag, zipURL: url, size: (zip["size"] as? Int) ?? 0,
                           pageURL: page, headline: headline(r["body"] as? String))
        }
        return releases.max { isNewer($1.version, than: $0.version) }
    }

    /// "v0.5.1" → "0.5.1"; "windows-v0.5.0", "linux-latest", "android-v0.2.0" → nil.
    static func macVersion(_ tag: String) -> String? {
        guard tag.hasPrefix("v") else { return nil }
        let v = String(tag.dropFirst())
        let parts = v.split(separator: ".")
        guard (2...4).contains(parts.count), parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        return v
    }

    /// Numeric comparison: 0.10.0 is newer than 0.9.3, 0.5.1 than 0.5.
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// The bold part of the first bullet under "## What's new", else the bullet's start.
    static func headline(_ body: String?) -> String? {
        guard let body else { return nil }
        let lines = body.components(separatedBy: .newlines)
        guard let start = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("## what") }) else { return nil }
        for line in lines[(start + 1)...] {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("## ") { break }
            guard t.hasPrefix("- ") || t.hasPrefix("* ") else { continue }
            let item = String(t.dropFirst(2))
            if item.hasPrefix("**"), let end = item.range(of: "**", range: item.index(item.startIndex, offsetBy: 2)..<item.endIndex) {
                return String(item[item.index(item.startIndex, offsetBy: 2)..<end.lowerBound])
            }
            let plain = item.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "*", with: "")
            return plain.count > 70 ? String(plain.prefix(68)) + "…" : plain
        }
        return nil
    }

    /// Only GitHub serves the update (its assets redirect to githubusercontent.com).
    static func allowedHost(_ host: String?) -> Bool {
        guard let h = host?.lowercased() else { return false }
        return h == "github.com" || h == "api.github.com" || h.hasSuffix(".githubusercontent.com")
    }

    /// Coucou replaces itself only where it was installed by hand: /Applications or ~/Applications.
    /// A build run from Xcode or DerivedData only points to the release page.
    static func canReplace(bundlePath: String, home: String) -> Bool {
        let parent = (bundlePath as NSString).deletingLastPathComponent
        return bundlePath.hasSuffix(".app") && (parent == "/Applications" || parent == home + "/Applications")
    }

    /// How often Coucou looks, once the user said yes: GitHub's unauthenticated limit is 60 calls an hour.
    static let checkInterval: TimeInterval = 6 * 3600
    /// "Later" hides one version for a day; a newer one shows at once.
    static let snooze: TimeInterval = 24 * 3600

    static func shouldCheck(last: Date?, now: Date) -> Bool {
        guard let last else { return true }
        return now.timeIntervalSince(last) >= checkInterval || now < last
    }

    /// Whether Mochi says "New version": newer than what runs, and not put off a moment ago.
    static func shouldAnnounce(_ release: Release, current: String, snoozedVersion: String?, snoozedAt: Date?, now: Date) -> Bool {
        guard isNewer(release.version, than: current) else { return false }
        if snoozedVersion == release.version, let at = snoozedAt, now.timeIntervalSince(at) < snooze, now >= at { return false }
        return true
    }

    /// Mochi turns blue while a newer Coucou waits (and a click opens the update first): once the
    /// user said yes to looking, until it is installed, except for a day after "Later" on that version.
    static func showsHint(_ release: Release?, current: String, consent: Bool?,
                          laterVersion: String?, laterAt: Date?, now: Date) -> Bool {
        guard consent == true, let release, isNewer(release.version, than: current) else { return false }
        if laterVersion == release.version, let at = laterAt, now >= at, now.timeIntervalSince(at) < snooze { return false }
        return true
    }

    /// The app in the zip is the one announced: right bundle id, the release's version.
    static func matches(infoPlist: [String: Any], version: String) -> Bool {
        infoPlist["CFBundleIdentifier"] as? String == bundleId
            && infoPlist["CFBundleShortVersionString"] as? String == version
    }
}
