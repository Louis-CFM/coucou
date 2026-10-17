#if !APPSTORE
import AppKit
import ApplicationServices
import Combine
import Foundation

/// Reads YouTube tabs in browsers with AppleScript JavaScript bridges, and uses
/// macOS media-key events as a playback-control fallback for other browsers.
@MainActor
final class YouTubeController: ObservableObject {
    static let shared = YouTubeController()
    static let pillId = "integration_youtube"
    static let color = "#FF0033"

    @Published private(set) var title: String?
    @Published private(set) var url: URL?
    @Published private(set) var isPlaying = false
    @Published private(set) var browserName: String?
    @Published private(set) var automationDenied = false
    @Published private(set) var browserScriptingUnavailable = false

    private let queue = DispatchQueue(label: "fr.louisraille.coucou.youtube")
    private var timer: Timer?
    private var pollInFlight = false
    private var cancellables = Set<AnyCancellable>()

    private var isPillActive: Bool {
        AppState.shared.activeIntegrations.contains(Self.pillId)
    }

    private init() {
        AppState.shared.$activeIntegrations
            .removeDuplicates()
            .sink { [weak self] integrations in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if integrations.contains(Self.pillId) { self.startPolling() }
                    else { self.stopPolling() }
                }
            }
            .store(in: &cancellables)
    }

    private func startPolling() {
        guard timer == nil else { refresh(); return }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
        pollInFlight = false
        title = nil
        url = nil
        browserName = nil
        setPlaying(false)
        syncTaskName()
    }

    private func refresh() {
        guard isPillActive, !pollInFlight else { return }
        pollInFlight = true
        let runningApps = NSWorkspace.shared.runningApplications
        let running = runningApps.compactMap(\.bundleIdentifier)
        let frontmost = NSWorkspace.shared.frontmostApplication
        let frontmostInfo = (frontmost?.bundleIdentifier, frontmost?.processIdentifier ?? 0,
                             frontmost?.localizedName ?? "Browser")
        let candidates = Self.browserCandidates.filter { running.contains($0.0) }
        guard !candidates.isEmpty else {
            pollInFlight = false
            clearPlayback()
            return
        }

        queue.async { [weak self] in
            var failed = false
            var denied = false
            var result: ScriptResult = .value("")
            for candidate in candidates {
                switch Self.execute(Self.readScript(for: [candidate])) {
                case .value(let raw) where !raw.isEmpty:
                    result = .value(raw)
                    failed = false
                    denied = false
                    break
                case .value:
                    continue
                case .denied:
                    denied = true
                case .failed:
                    failed = true
                }
                if case .value(let raw) = result, !raw.isEmpty { break }
            }
            if case .value(let raw) = result, raw.isEmpty {
                if let bundleID = frontmostInfo.0,
                   Self.browserCandidates.contains(where: { $0.0 == bundleID }),
                   let page = Self.accessibilityYouTubePage(pid: frontmostInfo.1, browser: frontmostInfo.2) {
                    result = .value(page)
                    failed = false
                    denied = false
                } else if denied { result = .denied }
                else if failed { result = .failed }
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.pollInFlight = false
                switch result {
                case .denied:
                    self.automationDenied = true
                    self.browserScriptingUnavailable = false
                    self.clearPlayback()
                case .failed:
                    self.automationDenied = false
                    self.browserScriptingUnavailable = true
                    self.clearPlayback()
                case .value(let raw):
                    self.automationDenied = false
                    self.browserScriptingUnavailable = false
                    self.apply(raw)
                }
            }
        }
    }

    private func apply(_ raw: String) {
        // A browser result is `browser name\nURL\nJSON`.
        let pieces = raw.components(separatedBy: "\n")
        guard pieces.count >= 3,
              let pageURL = URL(string: pieces[1]),
              let data = pieces.dropFirst(2).joined(separator: "\n").data(using: .utf8),
              let state = try? JSONDecoder().decode(PageState.self, from: data),
              pageURL.host?.contains("youtube.com") == true else {
            clearPlayback()
            return
        }

        let wasPlaying = isPlaying
        title = state.title.isEmpty ? "YouTube" : state.title
        url = pageURL
        browserName = pieces[0]
        setPlaying(!state.paused && !state.ended)
        syncTaskName()
        if isPlaying && !wasPlaying {
            AppState.shared.setFocus(Self.pillId)
            NotificationCenter.default.post(name: .musicReveal, object: nil)
        }
    }

    private func clearPlayback() {
        title = nil
        url = nil
        browserName = nil
        setPlaying(false)
        syncTaskName()
    }

    private func setPlaying(_ value: Bool) { isPlaying = value }

    private func syncTaskName() {
        guard let index = AppState.shared.tasks.firstIndex(where: { $0.id == Self.pillId }) else { return }
        AppState.shared.tasks[index].name = title ?? "YouTube"
    }

    func togglePlayback() { control("toggle") }
    func nextVideo() { control("next") }
    func previousVideo() { control("previous") }

    func openVideo() {
        if let url { NSWorkspace.shared.open(url) }
        else { NSWorkspace.shared.open(URL(string: "https://www.youtube.com")!) }
    }

    private func control(_ command: String) {
        guard let url, let browserName else {
            Self.sendMediaKey(for: command)
            return
        }
        let source = Self.controlScript(browserName: browserName, url: url.absoluteString, command: command)
        guard !source.isEmpty else {
            Self.sendMediaKey(for: command)
            return
        }
        queue.async { [weak self] in
            let result = Self.execute(source)
            Task { @MainActor [weak self] in
                guard let self else { return }
                switch result {
                case .denied:
                    self.automationDenied = true
                case .failed:
                    self.browserScriptingUnavailable = true
                    Self.sendMediaKey(for: command)
                case .value(let value):
                    if command == "toggle" {
                        // Show the actual target requested by the page script.
                        // The follow-up poll remains authoritative if play is blocked.
                        if value == "playing" { self.isPlaying = true }
                        if value == "paused" { self.isPlaying = false }
                    }
                }
                self.refreshAfterControl()
            }
        }
    }

    private func refreshAfterControl(retries: Int = 0) {
        guard pollInFlight else { refresh(); return }
        guard retries < 8 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self?.refreshAfterControl(retries: retries + 1)
        }
    }

    private struct PageState: Codable {
        let title: String
        let paused: Bool
        let ended: Bool
    }

    private enum ScriptResult: Sendable { case value(String), denied, failed }

    nonisolated private static let browserCandidates: [(String, String)] = [
        ("com.apple.Safari", "Safari"),
        ("com.google.Chrome", "Google Chrome"),
        ("company.thebrowser.Browser", "Arc"),
        ("com.microsoft.edgemac", "Microsoft Edge"),
        ("org.mozilla.firefox", "Firefox"),
        ("com.brave.Browser", "Brave Browser"),
        ("com.operasoftware.Opera", "Opera"),
        ("com.vivaldi.Vivaldi", "Vivaldi"),
        ("org.chromium.Chromium", "Chromium"),
        ("com.google.Chrome.beta", "Google Chrome Beta"),
        ("com.google.Chrome.canary", "Google Chrome Canary"),
        ("com.microsoft.edgemac.Canary", "Microsoft Edge Canary"),
        ("com.kagi.kagimacos", "Orion")
    ]

    nonisolated private static let jsState = #"(()=>{const v=document.querySelector('video');if(!v)return '';return JSON.stringify({title:document.title.replace(/ - YouTube$/,''),paused:v.paused,ended:v.ended})})()"#
    nonisolated private static let jsToggle = #"(()=>{const v=document.querySelector('video');if(!v)return 'no-video';const b=document.querySelector('.ytp-play-button');if(v.paused){if(b)b.click();const p=v.play();if(p&&p.catch)p.catch(()=>{});return 'playing'}if(b)b.click();v.pause();return 'paused'})()"#
    nonisolated private static let jsNext = #"(()=>{const b=document.querySelector('.ytp-next-button');if(b&&!b.disabled){b.click();return 'ok'}return 'no-next'})()"#
    nonisolated private static let jsPrevious = #"(()=>{const b=document.querySelector('.ytp-prev-button');if(b&&!b.disabled){b.click();return 'ok'}return 'no-previous'})()"#

    nonisolated private static func readScript(for browsers: [(String, String)]) -> String {
        let results = browsers.map { bundle, name -> String in
            let app = "application id \"\(bundle)\""
            if bundle == "org.mozilla.firefox" {
                return ""
            }
            if bundle == "org.chromium.Chromium" || bundle == "com.brave.Browser" ||
                bundle == "com.operasoftware.Opera" || bundle == "com.vivaldi.Vivaldi" ||
                bundle == "company.thebrowser.Browser" || bundle == "com.kagi.kagimacos" ||
                bundle.hasPrefix("com.google.Chrome") || bundle.hasPrefix("com.microsoft.edgemac") {
                return """
                tell \(app)
                    repeat with wi from 1 to count of windows
                        repeat with ti from 1 to count of tabs of window wi
                            set t to tab ti of window wi
                            set u to URL of t
                            if u contains "youtube.com" then
                                set d to execute t javascript \"\(jsState)\"
                                if d is not \"\" then return \"\(name)\" & linefeed & u & linefeed & d
                            end if
                        end repeat
                    end repeat
                end tell
                """
            }
            return """
            tell \(app)
                repeat with wi from 1 to count of windows
                    repeat with t in tabs of window wi
                        set u to URL of t
                        if u contains "youtube.com" then
                            set d to do JavaScript \"\(jsState)\" in t
                            if d is not \"\" then return \"\(name)\" & linefeed & u & linefeed & d
                        end if
                    end repeat
                end repeat
            end tell
            """
        }
        return results.joined(separator: "\n")
    }

    nonisolated private static func controlScript(browserName: String, url: String, command: String) -> String {
        let js: String
        switch command {
        case "toggle": js = jsToggle
        case "next": js = jsNext
        default: js = jsPrevious
        }
        let videoID = URLComponents(string: url)?.queryItems?.first(where: { $0.name == "v" })?.value
        let escapedVideoID = videoID?.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let tabCondition = escapedVideoID.map { "URL of t contains \"\($0)\"" }
            ?? "URL of t contains \"youtube.com\""
        if browserName == "Firefox" { return "" }
        if let bundleID = browserCandidates.first(where: { $0.1 == browserName })?.0,
           bundleID != "com.apple.Safari" {
            return """
            tell application id "\(bundleID)"
                repeat with wi from 1 to count of windows
                    repeat with ti from 1 to count of tabs of window wi
                        set t to tab ti of window wi
                        if \(tabCondition) then
                            return execute t javascript "\(js)"
                        end if
                    end repeat
                end repeat
            end tell
            """
        }
        return """
            tell application id "com.apple.Safari"
                repeat with wi from 1 to count of windows
                    repeat with t in tabs of window wi
                        if \(tabCondition) then
                            return do JavaScript "\(js)" in t
                        end if
                    end repeat
                end repeat
            end tell
        """
    }

    nonisolated private static func execute(_ source: String) -> ScriptResult {
        guard !source.isEmpty else { return .value("") }
        guard let script = NSAppleScript(source: source) else { return .value("") }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error, (error[NSAppleScript.errorNumber] as? Int) == -1743 { return .denied }
        if error != nil { return .failed }
        return .value(result.stringValue ?? "")
    }

    nonisolated private static func accessibilityYouTubePage(pid: pid_t, browser: String) -> String? {
        guard pid > 0 else { return nil }
        let app = AXUIElementCreateApplication(pid)
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString,
                                            &windowValue) == .success,
              let windowValue else { return nil }
        let window = windowValue as! AXUIElement
        var titleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString,
                                            &titleValue) == .success,
              let title = titleValue as? String,
              title.localizedCaseInsensitiveContains("youtube") else { return nil }
        let cleanTitle = title.replacingOccurrences(of: " - YouTube", with: "")
        let payload = PageState(title: cleanTitle, paused: false, ended: false)
        guard let data = try? JSONEncoder().encode(payload),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return "\(browser)\nhttps://www.youtube.com\n\(json)"
    }

    nonisolated private static func sendMediaKey(for command: String) {
        let keyCode: Int
        switch command {
        case "toggle": keyCode = 16 // NX_KEYTYPE_PLAY
        case "next": keyCode = 17 // NX_KEYTYPE_NEXT
        default: keyCode = 18 // NX_KEYTYPE_PREVIOUS
        }
        for state in [0xA, 0xB] {
            let data1 = (keyCode << 16) | (state << 8)
            NSEvent.otherEvent(with: .systemDefined, location: .zero,
                               modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: 0, context: nil, subtype: 8,
                               data1: data1, data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}
#endif
