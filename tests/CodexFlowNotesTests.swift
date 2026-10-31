import Foundation

@main struct CodexFlowNotesTests {
    static func check(_ value: Bool) { assert(value) }

    @MainActor static func main() async {
        let state = AppState.shared
        let keychain = KeychainStore.shared
        keychain.key = nil
        assert(FlowCleanup.isAvailable)
        CodexTextService.isAvailable = false
        keychain.key = "unrelated-anthropic-key"
        assert(!FlowCleanup.isAvailable)
        CodexTextService.isAvailable = true
        keychain.key = nil
        keychain.reads = 0

        let raw = "um please send ⟦1⟧ tomorrow"
        CodexTextService.reset(["Please send ⟦1⟧ tomorrow."])
        let clean = await FlowCleanup.clean(raw, style: .natural, app: "Mail", words: ["Coucou"])
        assert(clean == "Please send ⟦1⟧ tomorrow.")
        assert(CodexTextService.requests[0].system.contains("Spell these words exactly like this: Coucou"))
        assert(CodexTextService.requests[0].system.contains("Mail"))
        assert(CodexTextService.requests[0].model == "native-model")
        assert(CodexTextService.requests[0].timeout == 4)
        assert(keychain.reads == 0)
        let snippets = ["⟦1⟧": "Exact Signature"]
        assert(FlowText.keepsMarks(clean, snippets))
        assert(FlowText.finish(clean, snippets: snippets) == "Please send Exact Signature tomorrow.")
        let count = CodexTextService.requests.count
        check(await FlowCleanup.clean(raw, style: .verbatim, app: nil, words: []) == raw)
        check(await FlowCleanup.clean("hello", style: .natural, app: nil, words: []) == "hello")
        assert(CodexTextService.requests.count == count)

        let language = FlowLanguage(code: "zh-TW", hint: "Traditional Chinese.")
        CodexTextService.reset(["請明天寄出 ⟦1⟧。"])
        let translated = await FlowCleanup.transform(raw, prompt: false, language: language, style: .natural, app: nil, words: [])
        assert(translated == "請明天寄出 ⟦1⟧。")
        assert(CodexTextService.requests[0].system.contains("Traditional Chinese."))
        assert(CodexTextService.requests[0].timeout == 8)
        CodexTextService.reset(["Goal: Send the message tomorrow.\nConstraints: Keep ⟦1⟧."])
        let shaped = await FlowCleanup.transform(raw, prompt: true, language: nil, style: .polished, app: nil, words: [])
        assert(shaped.hasPrefix("Goal:"))
        assert(CodexTextService.requests[0].timeout == 12)
        for invalid in ["", String(repeating: "invented ", count: 500)] {
            CodexTextService.reset([invalid])
            check(await FlowCleanup.clean(raw, style: .natural, app: nil, words: []) == raw)
            CodexTextService.reset([invalid])
            check(await FlowCleanup.transform(raw, prompt: false, language: language, style: .natural, app: nil, words: []) == raw)
        }
        CodexTextService.reset()
        CodexTextService.failure = CodexServiceError.timeout
        check(await FlowCleanup.clean(raw, style: .natural, app: nil, words: []) == raw)
        check(await FlowCleanup.transform(raw, prompt: true, language: nil, style: .natural, app: nil, words: []) == raw)
        assert(keychain.reads == 0)
        state.chatProvider = .anthropic
        assert(!FlowCleanup.isAvailable)
        CodexTextService.reset()
        check(await FlowCleanup.clean(raw, style: .natural, app: nil, words: []) == raw)
        assert(CodexTextService.requests.isEmpty)
        state.chatProvider = .codex
        keychain.reads = 0

        // The actual persisted property and initialization preserve every saved engine choice.
        for engine in NoteSummaryEngine.allCases {
            UserDefaults.standard.values[NoteTaker.engineKey] = engine.rawValue
            let taker = NoteTaker()
            assert(taker.summaryEngine == engine)
            taker.summaryEngine = .codex
            assert(UserDefaults.standard.values[NoteTaker.engineKey] == "codex")
        }
        UserDefaults.standard.values = [:]
        assert(NoteTaker().summaryEngine == .off) // Existing no-key default, no automatic provider switch.
        let taker = NoteTaker()
        taker.summaryEngine = .codex
        assert(taker.canCorrect && taker.canSummarize)
        CodexTextService.isAvailable = false
        assert(!taker.canCorrect && !taker.canSummarize)
        CodexTextService.isAvailable = true
        keychain.reads = 0
        var original = Note(title: "Original", start: Date(), status: .ready,
                            speakers: [.init(id: "s2", name: "Person 2", color: 1)],
                            lines: [.init(speaker: "s2", start: 0, end: 3, text: "I am Alice and work on UG charging.")])
        let id = original.id
        taker.notes[id] = original
        let summary = #"{"title":"Charging plan","summary":"Alice will review charging.","key_points":["Review"],"todos":[{"text":"Review charging","owner":"Alice","due":null}]}"#
        CodexTextService.reset([summary])
        await taker.summarize(id)
        let summarized = taker.notes[id]!
        assert(summarized.title == "Charging plan" && summarized.summary == "Alice will review charging.")
        assert(summarized.keyPoints == ["Review"] && summarized.todos.first?.owner == "Alice")
        assert(CodexTextService.requests[0].user.contains("Person 2: I am Alice"))
        assert(CodexTextService.requests[0].system == NoteTaker.summaryInstructions)
        assert(keychain.reads == 0 && NoteTaker.otherCalls == 0)

        original.titleEdited = true
        taker.notes[id] = original
        CodexTextService.reset([summary])
        await taker.summarize(id)
        assert(taker.notes[id]!.title == "Original")
        taker.notes[id] = original
        CodexTextService.reset(["not JSON"])
        await taker.summarize(id)
        assert(taker.notes[id] == original && taker.aiErrors[id] != nil)
        CodexTextService.reset()
        CodexTextService.failure = CodexServiceError.timeout
        await taker.summarize(id)
        assert(taker.notes[id] == original && taker.aiErrors[id] != nil)
        let correction = #"{"lines":{"0":"I am Alice and work on EV charging.","999":"invented"},"speakers":{"Person 2":"Alice"}}"#
        CodexTextService.reset([correction])
        await taker.correct(id)
        assert(taker.notes[id]!.lines[0].text == "I am Alice and work on EV charging.")
        assert(taker.notes[id]!.lines[0].raw == original.lines[0].text)
        assert(taker.notes[id]!.speakers[0].name == "Alice")
        assert(CodexTextService.requests[0].user.contains("<vocabulary>"))
        assert(CodexTextService.requests[0].system == NoteTaker.correctionInstructions)

        // Snapshot guards preserve edits, reassignment, speaker renames, deletion and engine changes.
        for action in 0..<6 {
            taker.notes[id] = original
            CodexTextService.reset([summary])
            CodexTextService.onComplete = {
                switch action {
                case 0: taker.notes[id]!.lines[0].text = "Manually edited"
                case 1: taker.notes[id]!.speakers[0].name = "Manual name"
                case 2: taker.notes[id]!.todos = [.init(text: "Manual task", done: true)]
                case 3: taker.notes[id] = nil
                case 4: taker.summaryEngine = .off
                default: taker.notes[id]!.lines[0].speaker = "me"
                }
            }
            await taker.summarize(id)
            assert(taker.notes[id]?.summary == nil)
            taker.summaryEngine = .codex
        }
        for action in 0..<4 {
            taker.notes[id] = original
            CodexTextService.reset([correction])
            CodexTextService.onComplete = {
                switch action {
                case 0: taker.notes[id]!.lines[0].text = "Manual words"
                case 1: taker.notes[id]!.lines[0].speaker = "me"
                case 2: taker.notes[id] = nil
                default: taker.notes[id]!.speakers[0].name = "Chosen name"
                }
            }
            await taker.correct(id)
            if action == 3 { assert(taker.notes[id]!.speakers[0].name == "Chosen name") }
            else { assert(taker.notes[id]?.lines[0].text != "I am Alice and work on EV charging.") }
        }
        taker.notes[id] = original
        CodexTextService.reset(["invalid correction"])
        await taker.correctAgain(id)
        assert(taker.notes[id] == original && taker.aiErrors[id] != nil)
        assert(CodexTextService.requests.count == 1)
        taker.notes[id] = original
        CodexTextService.reset([correction, summary])
        await taker.correctAgain(id)
        assert(taker.notes[id]!.lines[0].raw == original.lines[0].text && taker.notes[id]!.summary != nil)

        // Each batch only accepts its own numbered lines, even if another line is plausible.
        var batched = original
        batched.lines = [
            .init(speaker: "s2", start: 0, end: 5, text: String(repeating: "word ", count: 2_500)),
            .init(speaker: "s2", start: 5, end: 8, text: "I work on UG charging.")
        ]
        taker.notes[id] = batched
        CodexTextService.reset([
            #"{"lines":{"1":"I work on EV charging."},"speakers":{}}"#,
            #"{"lines":{},"speakers":{}}"#
        ])
        await taker.correct(id)
        assert(taker.notes[id] == batched && CodexTextService.requests.count == 2)
        // Cancellation never applies a partial response or records a spurious processing error.
        taker.notes[id] = original
        CodexTextService.reset([summary])
        CodexTextService.delay = 100_000_000
        let cancelled = Task { @MainActor in await taker.summarize(id) }
        while CodexTextService.requests.isEmpty { await Task.yield() }
        cancelled.cancel()
        await cancelled.value
        assert(taker.notes[id] == original && taker.aiErrors[id] == nil && !taker.working.contains(id))

        // A recording's outer work marker survives nested AI work; duplicate clicks are ignored.
        taker.notes[id] = original
        taker.working.insert(id)
        CodexTextService.reset([summary])
        CodexTextService.delay = 30_000_000
        let pending = Task { @MainActor in await taker.summarize(id) }
        while CodexTextService.requests.isEmpty { await Task.yield() }
        await taker.summarize(id)
        await pending.value
        assert(CodexTextService.requests.count == 1 && taker.working.contains(id))
        taker.working.remove(id)
        assert(keychain.reads == 0 && NoteTaker.otherCalls == 0)
        print("Codex Flow/Notetaker caller fixtures passed (no credentials, models or preferences accessed)")
    }
}
