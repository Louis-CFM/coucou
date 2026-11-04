#if !APPSTORE
import AppKit
import Foundation
import Security

// "New version" in the notch, and one click to get it (GitHub build only: the App Store updates
// its own build). Coucou looks at its own GitHub releases only once the user said yes, a few
// times a day; nothing about the user goes with the request. The update is downloaded from
// GitHub only, then checked before anything is replaced: the app in the zip must be Coucou
// (bundle id and the announced version), signed with Louis's Developer ID, and accepted by
// Gatekeeper (notarized). Only then does it take the place of the running app, which restarts.

@MainActor
final class MacUpdater: ObservableObject {
    static let shared = MacUpdater()

    enum Phase: Equatable {
        case idle
        /// Asking once whether Coucou may look at GitHub.
        case asking
        case available(MacUpdate.Release)
        case downloading(MacUpdate.Release, fraction: Double)
        case verifying(MacUpdate.Release)
        case installing(MacUpdate.Release)
        case relaunching(MacUpdate.Release)
        /// Coucou can't replace itself here (not in Applications, or not writable): GitHub it is.
        case manual(MacUpdate.Release)
        case failed(MacUpdate.Release, String)
    }

    enum CheckResult: Equatable { case none, checking, upToDate, unreachable }

    @Published private(set) var phase: Phase = .idle {
        didSet { if busy != (oldValue.isBusy) { refreshHint() } }
    }
    /// For "Check now" in Settings.
    @Published private(set) var lastCheck: CheckResult = .none
    /// The newest release found, kept even after "Later" (the menu bar and Settings offer it).
    @Published private(set) var latest: MacUpdate.Release? = nil {
        didSet { refreshHint() }
    }
    /// A newer Coucou waits: Mochi is blue and a click opens the update first (BotCanvasView,
    /// IslandWindowController.defaultView). Off for a day after Later.
    @Published private(set) var hintActive = false

    // Not secrets: UserDefaults.
    /// nil: not asked yet. true: Coucou may look at GitHub. false: never.
    static var consent: Bool? {
        get { UserDefaults.standard.object(forKey: "updateCheckConsent") as? Bool }
        set { UserDefaults.standard.set(newValue, forKey: "updateCheckConsent") }
    }
    private var lastCheckDate: Date? {
        get { UserDefaults.standard.object(forKey: "updateLastCheck") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateLastCheck") }
    }
    private var snoozedVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateSnoozedVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateSnoozedVersion") }
    }
    private var snoozedAt: Date? {
        get { UserDefaults.standard.object(forKey: "updateSnoozedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateSnoozedAt") }
    }
    /// "Later" on the card: no blue Mochi for that version for a day (the announcement has its own snooze).
    private var laterVersion: String? {
        get { UserDefaults.standard.string(forKey: "updateLaterVersion") }
        set { UserDefaults.standard.set(newValue, forKey: "updateLaterVersion") }
    }
    private var laterAt: Date? {
        get { UserDefaults.standard.object(forKey: "updateLaterAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateLaterAt") }
    }
    private var askedAt: Date? {
        get { UserDefaults.standard.object(forKey: "updateConsentAskedAt") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "updateConsentAskedAt") }
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    var busy: Bool { phase.isBusy }

    private func refreshHint() {
        let on = !busy && MacUpdate.showsHint(latest, current: Self.currentVersion, consent: Self.consent,
                                              laterVersion: laterVersion, laterAt: laterAt, now: Date())
        if hintActive != on { hintActive = on }
    }

    /// The island opens on the update while Mochi is blue (a click, a hover, the keyboard).
    func prepareCard() {
        guard let release = latest, !busy else { return }
        if case .available = phase { return }
        phase = .available(release)
    }

    private var timer: Timer?
    private var downloadTask: URLSessionDownloadTask?

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config, delegate: UpdateGitHubOnly(), delegateQueue: nil)
    }()

    // MARK: - Schedule

    /// At launch: a first look 30 s in, then every hour (a GitHub call only every 6 h).
    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.tick(launch: true) }
        timer?.invalidate()
        let t = Timer(timeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in MacUpdater.shared.tick() }
        }
        t.tolerance = 300
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick(launch: Bool = false) {
        refreshHint()   // a day after Later, Mochi turns blue again
        switch Self.consent {
        case nil:
            askIfFree()
        case true?:
            if launch || MacUpdate.shouldCheck(last: lastCheckDate, now: Date()) { Task { await check(manual: false) } }
            else { announceIfFree() }
        case false?:
            break
        }
    }

    /// The question comes once a day at most, when nothing else waits in the notch.
    private func askIfFree() {
        if let at = askedAt, Date().timeIntervalSince(at) < 24 * 3600, Date() >= at { return }
        guard islandFree else { return }
        askedAt = Date()
        phase = .asking
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.update)
    }

    private var islandFree: Bool {
        let s = AppState.shared
        return s.pendingApproval == nil && s.pendingQuestion == nil && !(s.mode == .expanded && s.view != .update)
    }

    func answer(_ yes: Bool) {
        Self.consent = yes
        phase = .idle
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
        if yes { Task { await check(manual: false) } }
    }

    /// Settings: the toggle.
    func setEnabled(_ on: Bool) {
        Self.consent = on
        refreshHint()
        if on { Task { await check(manual: false) } }
        else if case .asking = phase { phase = .idle }
    }

    // MARK: - Check

    func check(manual: Bool) async {
        guard !busy, lastCheck != .checking else { return }
        lastCheck = .checking
        var req = URLRequest(url: MacUpdate.releasesURL)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        do {
            let (data, response) = try await session.data(for: req)
            lastCheckDate = Date()
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { lastCheck = .unreachable; return }
            guard let release = MacUpdate.latest(data), MacUpdate.isNewer(release.version, than: Self.currentVersion) else {
                latest = nil
                lastCheck = .upToDate
                if case .available = phase { phase = .idle }
                return
            }
            latest = release
            lastCheck = .none
            appendAppLog("nb.log", "[Update] \(release.version) is out (running \(Self.currentVersion))")
            if manual {
                show(release)
            } else {
                announceIfFree()
            }
        } catch {
            lastCheck = .unreachable
        }
    }

    /// Mochi says it once a day at most for a version, until it is installed; in between, the
    /// menu bar and Settings keep offering it.
    private func announceIfFree() {
        guard let release = latest, !busy, islandFree,
              MacUpdate.shouldAnnounce(release, current: Self.currentVersion, snoozedVersion: snoozedVersion,
                                       snoozedAt: snoozedAt, now: Date()) else { return }
        snoozedVersion = release.version
        snoozedAt = Date()
        show(release)
        NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.surprised)
        SoundEngine.shared.play("peek")
    }

    /// Opens the card on this release (menu bar, Settings, the timer).
    func show(_ release: MacUpdate.Release? = nil) {
        guard let release = release ?? latest else { return }
        if !busy { phase = .available(release) }
        NotificationCenter.default.post(name: .hookExpand, object: IslandView.update)
    }

    func later() {
        if case .available(let r) = phase {
            snoozedVersion = r.version
            snoozedAt = Date()
            laterVersion = r.version
            laterAt = Date()
            refreshHint()
        }
        if !busy { phase = .idle }
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    func openReleasePage() {
        let release: MacUpdate.Release?
        switch phase {
        case .available(let r), .downloading(let r, _), .verifying(let r), .installing(let r),
             .relaunching(let r), .manual(let r), .failed(let r, _): release = r
        default: release = latest
        }
        let url = release?.pageURL ?? URL(string: "https://github.com/\(MacUpdate.owner)/\(MacUpdate.repo)/releases/latest")!
        NSWorkspace.shared.open(url)
    }

    func dismiss() {
        if !busy { phase = latest.map { Phase.available($0) } ?? .idle }
        NotificationCenter.default.post(name: .islandCollapse, object: nil)
    }

    // MARK: - Install

    func install() {
        guard case .available(let release) = phase else { return }
        let bundle = Bundle.main.bundleURL
        let parent = bundle.deletingLastPathComponent().path
        let fm = FileManager.default
        guard MacUpdate.canReplace(bundlePath: bundle.path, home: NSHomeDirectory()),
              fm.isWritableFile(atPath: parent), fm.isWritableFile(atPath: bundle.path) else {
            phase = .manual(release)
            return
        }
        phase = .downloading(release, fraction: 0)
        Task { await run(release) }
    }

    private func run(_ release: MacUpdate.Release) async {
        let bundle = Bundle.main.bundleURL
        do {
            // 1. Download, from GitHub only.
            let zip = try await download(release.zipURL, release: release)

            // 2. Unzip next to the app (same volume, so the swap is atomic), then check it.
            phase = .verifying(release)
            let newApp = try await Task.detached { () throws -> URL in
                try Self.unpackAndVerify(zip: zip, next: bundle, version: release.version)
            }.value

            // 3. Swap the bundles, then restart into the new one.
            phase = .installing(release)
            try await Task.detached {
                _ = try FileManager.default.replaceItemAt(bundle, withItemAt: newApp, backupItemName: nil,
                                                          options: [.usingNewMetadataOnly])
                try? FileManager.default.removeItem(at: newApp.deletingLastPathComponent())
            }.value
            appendAppLog("nb.log", "[Update] installed \(release.version), restarting")
            phase = .relaunching(release)
            relaunch(bundle, release: release)
        } catch let failure as UpdateFailure {
            phase = .failed(release, failure.message)
            appendAppLog("nb.log", "[Update] failed: \(failure.message)")
        } catch {
            phase = .failed(release, String(localized: "update.error.download"))
            appendAppLog("nb.log", "[Update] failed: \(error.localizedDescription)")
        }
    }

    private func download(_ url: URL, release: MacUpdate.Release) async throws -> URL {
        let progress = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self, let task = self.downloadTask, case .downloading = self.phase else { continue }
                self.phase = .downloading(release, fraction: task.progress.fractionCompleted)
            }
        }
        defer { progress.cancel(); downloadTask = nil }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            let task = session.downloadTask(with: url) { tmp, response, error in
                if let error { cont.resume(throwing: error); return }
                guard let tmp, (response as? HTTPURLResponse)?.statusCode == 200 else {
                    cont.resume(throwing: UpdateFailure(String(localized: "update.error.download"))); return
                }
                // The temporary file goes away when this returns: keep it.
                let kept = FileManager.default.temporaryDirectory
                    .appendingPathComponent("coucou-update-\(UUID().uuidString).zip")
                do { try FileManager.default.moveItem(at: tmp, to: kept); cont.resume(returning: kept) }
                catch { cont.resume(throwing: error) }
            }
            downloadTask = task
            task.resume()
        }
    }

    /// Unzips with macOS's own ditto and checks the app before it may replace this one.
    nonisolated private static func unpackAndVerify(zip: URL, next bundle: URL, version: String) throws -> URL {
        let fm = FileManager.default
        defer { try? fm.removeItem(at: zip) }
        let staging = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: bundle, create: true)
        func fail(_ key: String.LocalizationValue) -> UpdateFailure {
            try? fm.removeItem(at: staging)
            return UpdateFailure(String(localized: key))
        }
        guard run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path]) else { throw fail("update.error.unzip") }
        guard let app = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
            .first(where: { $0.pathExtension == "app" }) else { throw fail("update.error.unzip") }

        // The announced Coucou, not another app or another version.
        guard let info = NSDictionary(contentsOf: app.appendingPathComponent("Contents/Info.plist")) as? [String: Any],
              MacUpdate.matches(infoPlist: info, version: version) else { throw fail("update.error.not-coucou") }

        // Signed by Coucou's developer, every architecture and nested binary intact.
        var code: SecStaticCode?
        var requirement: SecRequirement?
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(MacUpdate.codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, flags, requirement) == errSecSuccess else { throw fail("update.error.signature") }

        // Notarized: Gatekeeper accepts it as it would a download from the browser.
        guard run("/usr/sbin/spctl", ["--assess", "--type", "execute", app.path]) else { throw fail("update.error.signature") }

        removexattr(app.path, "com.apple.quarantine", 0)
        return app
    }

    nonisolated private static func run(_ tool: String, _ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    /// A small shell waits for this Coucou to quit, then opens the new one.
    private func relaunch(_ bundle: URL, release: MacUpdate.Release) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "while kill -0 \(pid) 2>/dev/null; do sleep 0.2; done; /usr/bin/open \"$0\"", bundle.path]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
        } catch {
            // Already installed: the next launch is the new version.
            phase = .failed(release, String(localized: "update.error.restart"))
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
    }
}

extension MacUpdater.Phase {
    var isBusy: Bool {
        switch self {
        case .downloading, .verifying, .installing, .relaunching: return true
        default: return false
        }
    }
}

private struct UpdateFailure: Error, Sendable {
    let message: String
    init(_ m: String) { message = m }
}

/// The download follows GitHub's redirect to its asset storage, and nothing else.
private final class UpdateGitHubOnly: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(MacUpdate.allowedHost(request.url?.host) ? request : nil)
    }
}
#endif
