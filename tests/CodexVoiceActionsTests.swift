import Foundation

final class BoundaryMusic: MusicControlling, @unchecked Sendable {
    var isMusicRunning = false
    var isSpotifyRunning = false
    var calls: [String] = []
    @MainActor var afterLaunch: (() -> Void)?
    @MainActor var afterSearch: (() -> Void)?
    @MainActor func play() { calls.append("play") }
    @MainActor func pause() { calls.append("pause") }
    @MainActor func nextTrack() { calls.append("next") }
    @MainActor func previousTrack() { calls.append("previous") }
    @MainActor func volumeUp() { calls.append("up") }
    @MainActor func volumeDown() { calls.append("down") }
    @MainActor func setVolume(_ pct: Int) { calls.append("volume") }
    @MainActor func playSearch(_ name: String) async -> Bool {
        calls.append("search"); await Task.yield(); afterSearch?(); return false
    }
    @MainActor func playPlaylist(_ name: String) async -> Bool { calls.append("playlist"); return false }
    @MainActor func launchAndPlay() async { calls.append("launch"); await Task.yield(); afterLaunch?() }
    @MainActor func launchSpotify() async { calls.append("spotify") }
    @MainActor func openSearch(_ name: String) { calls.append("openSearch") }
}

@MainActor final class BoundaryPills: PillControlling {
    var active: Set<String> = []
    var calls: [String] = []
    var afterToggle: (() -> Void)?
    func activeIds() -> Set<String> { active }
    func mainPillId() -> String { "agent_codex" }
    func activeCount() -> Int { active.count }
    func toggleIntegration(_ id: String) {
        calls.append(id); active.insert(id); afterToggle?()
    }
    func setMainPill(_ id: String) { calls.append(id) }
}

@main struct CodexVoiceActionsTests {
    @MainActor static func main() async {
        let brain = ClaudeVoiceBrain.shared
        let service = ClaudeService.shared
        let info = LiveVoiceInfo.shared
        let runner = VoiceActionRunner.shared
        let music = BoundaryMusic()
        let pills = BoundaryPills()
        runner.music = music
        runner.pills = pills
        runner.info = info
        func tool(_ name: String, _ input: [String: Any]) -> [String: Any] {
            ["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input]
        }
        func consentCycle() {
            // Disabling and immediately re-enabling must still invalidate the old turn.
            VoiceEngine.shared.isEnabled = false
            VoiceEngine.shared.isEnabled = true
        }
        let email = tool("prepare_email", ["recipient": "Alice", "subject": "Check", "body": "Body", "attachment_file": "private.txt"])
        brain.reset(); service.calls = [email]; info.resolve = consentCycle
        let staleMail = await brain.respond(to: "Draft a note to Alice")
        assert(staleMail?.discarded == true && info.shown == 0 && info.fileLookups == 0)
        brain.reset(); service.calls = [email]; info.resolve = nil
        let goodMail = await brain.respond(to: "Draft a note to Alice")
        assert(goodMail?.acted == true && info.shown == 1 && info.fileLookups == 1)

        brain.reset()
        pills.afterToggle = consentCycle
        service.calls = [tool("pills", ["action": "add", "names": ["GitHub", "Stripe"]])]
        let interruptedPills = await brain.respond(to: "Add GitHub and Stripe")
        assert(interruptedPills?.discarded == true && interruptedPills?.acted == true)
        assert(pills.calls == ["integration_github"] && pills.active.contains("integration_github"))

        // Launching was already requested; cancellation prevents the following search operation.
        for action in ["play_search", "play_playlist"] {
            brain.reset(); music.calls = []; music.afterLaunch = consentCycle
            service.calls = [tool("music", ["action": action, "query": "Example"])]
            let cancelled = await brain.respond(to: "Play Example")
            assert(cancelled?.discarded == true && music.calls == ["launch"])
        }
        // A failed async library search must not open a new search window after consent is revoked.
        brain.reset(); music.calls = []; music.isMusicRunning = true; music.afterSearch = consentCycle
        service.calls = [tool("music", ["action": "play_search", "query": "Example"])]
        let cancelledSearch = await brain.respond(to: "Play Example")
        assert(cancelledSearch?.discarded == true && music.calls == ["search"])
        print("PASS actual voice tool boundaries: stale Contacts lookup, pill batch, launch/search cancellation and consent ABA")
    }
}
