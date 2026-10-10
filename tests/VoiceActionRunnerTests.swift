import Foundation

// MARK: - VoiceActionRunner tests with mock implementations

final class MockMusic: MusicControlling, @unchecked Sendable {
    var musicRunning  = true
    var spotifyRunning = false
    var isMusicRunning: Bool  { musicRunning }
    var isSpotifyRunning: Bool { spotifyRunning }

    var calls: [String] = []
    var searchResult  = true   // mock return for playSearch
    var playlistResult = true  // mock return for playPlaylist

    @MainActor func play()                     { calls.append("play") }
    @MainActor func pause()                    { calls.append("pause") }
    @MainActor func nextTrack()                { calls.append("nextTrack") }
    @MainActor func previousTrack()            { calls.append("prevTrack") }
    @MainActor func volumeUp()                 { calls.append("volUp") }
    @MainActor func volumeDown()               { calls.append("volDown") }
    @MainActor func setVolume(_ p: Int)        { calls.append("setVolume:\(p)") }
    @MainActor func playSearch(_ n: String) async -> Bool  { calls.append("search:\(n)"); return searchResult }
    @MainActor func playPlaylist(_ n: String) async -> Bool { calls.append("playlist:\(n)"); return playlistResult }
    @MainActor func launchAndPlay() async      { calls.append("launchAndPlay") }
    @MainActor func launchSpotify() async      { calls.append("launchSpotify") }
    @MainActor func openSearch(_ n: String)    { calls.append("openSearch:\(n)") }
}

@MainActor
final class MockPills: PillControlling {
    var active: Set<String> = ["integration_github", "integration_vercel"]
    var main = "integration_claude"
    var calls: [String] = []

    func activeIds()  -> Set<String> { active }
    func mainPillId() -> String      { main }
    func activeCount() -> Int        { active.count }
    func toggleIntegration(_ id: String) {
        calls.append("toggle:\(id)")
        if active.contains(id) { active.remove(id) } else { active.insert(id) }
    }
    func setMainPill(_ id: String) { calls.append("setMain:\(id)"); main = id }
}

let pills = PillFixture.available

@main
enum VoiceActionRunnerTests {

    static var pass = 0
    static var fail = 0

    static func main() async {
        let runner = VoiceActionRunner()
        let music  = MockMusic()
        let pills_ = MockPills()
        runner.music = music
        runner.pills = pills_

        // ── Music: no app running → launch ───────────────────────────────────
        music.musicRunning   = false
        music.spotifyRunning = false
        music.calls = []
        let noApp = await runner.run(.musicPlay(target: nil), availablePills: pills)
        check("no music app → launch",   noApp.outcome, .success)
        check("no music app → launchAndPlay called", music.calls.contains("launchAndPlay"), true)

        // ── Music: target spotify → launchSpotify ────────────────────────────
        music.musicRunning   = false
        music.spotifyRunning = false
        music.calls = []
        let spotifyNoApp = await runner.run(.musicPlay(target: .spotify), availablePills: pills)
        check("spotify no app → launch",   spotifyNoApp.outcome, .success)
        check("spotify no app → launchSpotify", music.calls.contains("launchSpotify"), true)

        // ── Music: target appleMusic → launchAndPlay ─────────────────────────
        music.musicRunning   = false
        music.spotifyRunning = false
        music.calls = []
        let amNoApp = await runner.run(.musicPlay(target: .appleMusic), availablePills: pills)
        check("appleMusic no app → launch",   amNoApp.outcome, .success)
        check("appleMusic no app → launchAndPlay", music.calls.contains("launchAndPlay"), true)

        // ── Music commands with app running ───────────────────────────────────
        music.musicRunning = true
        music.calls = []

        let play = await runner.run(.musicPlay(target: nil), availablePills: pills)
        check("play → success",       play.outcome, .success)
        check("play → play called",   music.calls.last, "play")
        music.calls = []

        let pause_ = await runner.run(.musicPause, availablePills: pills)
        check("pause → success",      pause_.outcome, .success)
        check("pause → pause called", music.calls.last, "pause")
        music.calls = []

        let next = await runner.run(.musicNext, availablePills: pills)
        check("next → success",       next.outcome, .success)
        check("next → nextTrack",     music.calls.last, "nextTrack")
        music.calls = []

        let prev = await runner.run(.musicPrevious, availablePills: pills)
        check("previous → success",   prev.outcome, .success)
        check("previous → prevTrack", music.calls.last, "prevTrack")
        music.calls = []

        let vup = await runner.run(.musicVolumeUp, availablePills: pills)
        check("volUp → success",      vup.outcome, .success)
        check("volUp → volUp",        music.calls.last, "volUp")
        music.calls = []

        let vdn = await runner.run(.musicVolumeDown, availablePills: pills)
        check("volDown → success",    vdn.outcome, .success)
        check("volDown → volDown",    music.calls.last, "volDown")
        music.calls = []

        let vol50 = await runner.run(.musicSetVolume(50), availablePills: pills)
        check("setVolume(50) → success", vol50.outcome, .success)
        check("setVolume(50) → setVolume:50", music.calls.last, "setVolume:50")
        music.calls = []

        let search = await runner.run(.musicPlaySearch(name: "Daft Punk"), availablePills: pills)
        check("search → success",     search.outcome, .success)
        check("search → search:Daft Punk", music.calls.last, "search:Daft Punk")
        music.calls = []

        // Search not found → Apple Music search opened → success
        music.searchResult = false
        let searchFail = await runner.run(.musicPlaySearch(name: "XYZ"), availablePills: pills)
        check("search not found → failure", searchFail.outcome, .success)
        music.searchResult = true
        music.calls = []

        let pl = await runner.run(.musicPlayPlaylist(name: "Workout"), availablePills: pills)
        check("playlist → success",   pl.outcome, .success)
        check("playlist → playlist:Workout", music.calls.last, "playlist:Workout")
        music.calls = []

        // ── Pills: add ────────────────────────────────────────────────────────
        pills_.active = ["integration_github"]
        pills_.calls  = []
        let addNotion = await runner.run(.pillAdd(id: "integration_notion"), availablePills: pills)
        check("pillAdd → success",    addNotion.outcome, .success)
        check("pillAdd → toggle",     pills_.calls.first, "toggle:integration_notion")

        // Already active → success no-op
        pills_.active = ["integration_github", "integration_notion"]
        let addAgain  = await runner.run(.pillAdd(id: "integration_github"), availablePills: pills)
        check("pillAdd already active → success", addAgain.outcome, .success)

        // Limit → question
        pills_.active = Set(["integration_github","integration_vercel","integration_notion","integration_resend"])
        pills_.calls  = []
        let addLimit  = await runner.run(.pillAdd(id: "agent_cursor"), availablePills: pills)
        if case .question(_) = addLimit.outcome { print("✓  pillAdd limit → question"); pass += 1 }
        else { print("✗  pillAdd limit — got \(addLimit.outcome)"); fail += 1 }
        check("pillAdd limit sets pendingQuestion", runner.pendingQuestion != nil, true)

        // ── Follow-up answer after question ──────────────────────────────────
        // pills_ has 4 active: github, vercel, notion, resend. Pending: add agent_cursor.
        // User says "Stripe" → resolve to integration_stripe? But stripe is not active...
        // Let's use "GitHub" as the answer (it's active, will be removed, cursor added)
        pills_.active = Set(["integration_github","integration_vercel","integration_notion","integration_resend"])
        pills_.calls  = []
        // Re-set pending (it was consumed if we ran again, so re-trigger):
        _ = await runner.run(.pillAdd(id: "agent_cursor"), availablePills: pills)
        check("pending question set before answer", runner.pendingQuestion != nil, true)
        pills_.calls = []
        let answer = await runner.handleAnswer("GitHub", availablePills: pills)
        check("question answer → success", answer.outcome, .success)
        check("question answer → github removed", pills_.calls.contains("toggle:integration_github"), true)
        check("question answer → cursor added",   pills_.calls.contains("toggle:agent_cursor"), true)
        check("pending question cleared after answer", runner.pendingQuestion == nil, true)

        // Answer given as a sentence (real transcript from a test on the Mac)
        pills_.active = Set(["integration_github","integration_vercel","integration_stripe","integration_resend"])
        _ = await runner.run(.pillAdd(id: "agent_gemini"), availablePills: pills)
        pills_.calls = []
        let sentence = await runner.handleAnswer("Je retire la pilule Stripe", availablePills: pills)
        check("sentence answer → success", sentence.outcome, .success)
        check("sentence answer → stripe removed", pills_.calls.contains("toggle:integration_stripe"), true)
        check("sentence answer → gemini added",   pills_.calls.contains("toggle:agent_gemini"), true)

        // Unclear answer → asked once more, then given up
        pills_.active = Set(["integration_github","integration_vercel","integration_stripe","integration_resend"])
        _ = await runner.run(.pillAdd(id: "agent_gemini"), availablePills: pills)
        let unclear1 = await runner.handleAnswer("on s en fout c est", availablePills: pills)
        if case .question = unclear1.outcome { print("✓  unclear answer → asked again"); pass += 1 }
        else { print("✗  unclear answer — got \(unclear1.outcome)"); fail += 1 }
        check("unclear answer keeps the question", runner.pendingQuestion != nil, true)
        let unclear2 = await runner.handleAnswer("bof", availablePills: pills)
        check("second unclear answer → failure", unclear2.outcome, .failure)
        check("question dropped after second miss", runner.pendingQuestion == nil, true)

        // Incomplete phrase → asks which pill, then uses the answer
        pills_.active = ["integration_github"]
        pills_.calls  = []
        let incomplete = runner.askIfIncomplete("Modifie-moi les piles je veux que tu ajoutes")
        if case .question = incomplete?.outcome { print("✓  incomplete add → question"); pass += 1 }
        else { print("✗  incomplete add — got \(String(describing: incomplete))"); fail += 1 }
        let pick = await runner.handleAnswer("Gemini", availablePills: pills)
        check("which pill answer → success", pick.outcome, .success)
        check("which pill answer → gemini added", pills_.calls.contains("toggle:agent_gemini"), true)
        check("no question for a phrase without verb", runner.askIfIncomplete("ouais ça va") == nil, true)
        let incompleteRemove = runner.askIfIncomplete("enlève-moi la")
        if case .question = incompleteRemove?.outcome { print("✓  incomplete remove → question"); pass += 1 }
        else { print("✗  incomplete remove"); fail += 1 }
        runner.pendingQuestion = nil

        // Playlist without a name → asks which one
        let noName = await runner.run(.musicPlayPlaylist(name: ""), availablePills: pills)
        if case .question = noName.outcome { print("✓  playlist without name → question"); pass += 1 }
        else { print("✗  playlist without name — got \(noName.outcome)"); fail += 1 }
        check("playlist question pending", runner.pendingQuestion != nil, true)
        runner.pendingQuestion = nil

        // ── Pills: add multiple ───────────────────────────────────────────────
        pills_.active = ["integration_github"]
        pills_.calls  = []
        let addMulti = await runner.run(.pillAddMultiple(ids: ["integration_vercel", "integration_stripe"]), availablePills: pills)
        check("pillAddMultiple → success",  addMulti.outcome, .success)
        check("pillAddMultiple → vercel",   pills_.calls.contains("toggle:integration_vercel"), true)
        check("pillAddMultiple → stripe",   pills_.calls.contains("toggle:integration_stripe"), true)

        // ── Pills: remove ─────────────────────────────────────────────────────
        pills_.active = ["integration_github", "integration_vercel"]
        pills_.calls  = []
        let rem = await runner.run(.pillRemove(id: "integration_github"), availablePills: pills)
        check("pillRemove → success", rem.outcome, .success)
        check("pillRemove → toggle",  pills_.calls.first, "toggle:integration_github")

        pills_.active = ["integration_vercel"]
        let remAbsent = await runner.run(.pillRemove(id: "integration_github"), availablePills: pills)
        check("pillRemove not active → failure", remAbsent.outcome, .failure)

        // ── Pills: remove multiple ────────────────────────────────────────────
        pills_.active = ["integration_stripe", "integration_notion", "integration_github"]
        pills_.calls  = []
        let remMulti = await runner.run(.pillRemoveMultiple(ids: ["integration_stripe", "integration_notion"]), availablePills: pills)
        check("pillRemoveMultiple → success", remMulti.outcome, .success)
        check("pillRemoveMultiple → stripe",  pills_.calls.contains("toggle:integration_stripe"), true)
        check("pillRemoveMultiple → notion",  pills_.calls.contains("toggle:integration_notion"), true)

        // ── Pills: setMain ────────────────────────────────────────────────────
        pills_.main  = "integration_claude"
        pills_.calls = []
        let setMain = await runner.run(.pillSetMain(id: "agent_cursor"), availablePills: pills)
        check("pillSetMain → success", setMain.outcome, .success)
        check("pillSetMain → setMain", pills_.calls.first, "setMain:agent_cursor")

        // ── Pills: replace ────────────────────────────────────────────────────
        pills_.active = ["integration_n8n", "integration_github"]
        pills_.calls  = []
        let rep = await runner.run(.pillReplace(old: "integration_n8n", new: "integration_vercel"), availablePills: pills)
        check("pillReplace → success",           rep.outcome, .success)
        check("pillReplace → toggle old off",    pills_.calls.contains("toggle:integration_n8n"),    true)
        check("pillReplace → toggle new on",     pills_.calls.contains("toggle:integration_vercel"), true)

        // ── Pills: only ───────────────────────────────────────────────────────
        pills_.active = ["integration_github", "integration_n8n", "integration_notion"]
        pills_.calls  = []
        let only = await runner.run(.pillOnly(["integration_github", "integration_vercel"]), availablePills: pills)
        check("pillOnly → success", only.outcome, .success)
        check("pillOnly → removed n8n",    pills_.calls.contains("toggle:integration_n8n"),    true)
        check("pillOnly → removed notion", pills_.calls.contains("toggle:integration_notion"), true)
        check("pillOnly → added vercel",   pills_.calls.contains("toggle:integration_vercel"), true)

        // ── Follow-up: empty transcript cancels question ─────────────────────
        pills_.active = Set(["integration_github","integration_vercel","integration_notion","integration_resend"])
        _ = await runner.run(.pillAdd(id: "agent_cursor"), availablePills: pills)
        check("pending set before empty answer", runner.pendingQuestion != nil, true)
        let emptyAnswer = await runner.handleAnswer("", availablePills: pills)
        check("empty answer → success (cancelled)", emptyAnswer.outcome, .success)
        check("empty answer clears pendingQuestion", runner.pendingQuestion == nil, true)

        // ── Unknown ───────────────────────────────────────────────────────────
        let unk = await runner.run(.unknown, availablePills: pills)
        check("unknown → failure", unk.outcome, .failure)

        let unkTx = await runner.run(.unknown, availablePills: pills, rawTranscript: "blabla")
        check("unknown with transcript → failure", unkTx.outcome, .failure)

        let total = pass + fail
        if fail == 0 { print("\n\(total)/\(total) passed.") }
        else { print("\n\(fail) FAILED / \(total) total"); exit(1) }
    }

    static func check<T: Equatable>(_ label: String, _ got: T, _ want: T) {
        if got == want { print("✓  \(label)"); pass += 1 }
        else { print("✗  \(label) — got \(got), want \(want)"); fail += 1 }
    }
}
