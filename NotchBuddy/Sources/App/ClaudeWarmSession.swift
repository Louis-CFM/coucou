import Foundation

// MARK: - Models the subscription can run

enum ClaudeModelCatalog {
    struct Choice: Identifiable, Equatable {
        let id: String
        let name: String
        let detail: String
        let isMain: Bool
    }

    private static let detailKey: [String: String] = [
        "claude-opus-5-5": "The most capable for everyday work",
        "claude-fable-5-1": "The strongest, for the hard problems",
        "claude-sonnet-5-5": "Lighter, for simpler tasks",
        "claude-haiku-4-5-20251001": "The fastest",
        "claude-opus-5": "Previous Opus, one step below 5.5",
        "claude-sonnet-5": "Previous Sonnet",
        "claude-sonnet-4-6": "Older Sonnet",
        "claude-opus-4-8": "Older Opus",
        "claude-opus-4-7": "Older Opus",
        "claude-opus-4-6": "Older Opus",
        "claude-fable-5": "Previous Fable",
    ]

    static func load() -> [Choice] {
        let loaded = readCatalog()
        return loaded.isEmpty ? fallback : loaded
    }

    static func name(for modelId: String) -> String {
        if let match = load().first(where: { $0.id == modelId }) { return match.name }
        if modelId.localizedCaseInsensitiveContains("opus") { return "Opus" }
        if modelId.localizedCaseInsensitiveContains("fable") { return "Fable" }
        if modelId.localizedCaseInsensitiveContains("haiku") { return "Haiku" }
        if modelId.localizedCaseInsensitiveContains("sonnet") { return "Sonnet" }
        return modelId
    }

    /// Turns an old alias ("sonnet") into a real id from the catalog.
    static func resolve(_ saved: String) -> String {
        let models = load()
        if models.contains(where: { $0.id == saved }) { return saved }
        let key = saved.lowercased()
        let family = key.contains("opus") ? "opus"
            : key.contains("fable") ? "fable"
            : key.contains("haiku") ? "haiku"
            : "sonnet"
        let inFamily = models.filter { $0.id.contains(family) }
        return inFamily.first(where: \.isMain)?.id ?? inFamily.first?.id ?? fallback[0].id
    }

    private static let fallback: [Choice] = [
        Choice(id: "claude-opus-5-5", name: "Opus 5.5", detail: detailKey["claude-opus-5-5"] ?? "", isMain: true),
        Choice(id: "claude-fable-5-1", name: "Fable 5.1", detail: detailKey["claude-fable-5-1"] ?? "", isMain: true),
        Choice(id: "claude-sonnet-5-5", name: "Sonnet 5.5", detail: detailKey["claude-sonnet-5-5"] ?? "", isMain: true),
        Choice(id: "claude-haiku-4-5-20251001", name: "Haiku 4.5", detail: detailKey["claude-haiku-4-5-20251001"] ?? "", isMain: true),
        Choice(id: "claude-opus-5", name: "Opus 5", detail: detailKey["claude-opus-5"] ?? "", isMain: false),
        Choice(id: "claude-sonnet-5", name: "Sonnet 5", detail: detailKey["claude-sonnet-5"] ?? "", isMain: false),
        Choice(id: "claude-sonnet-4-6", name: "Sonnet 4.6", detail: detailKey["claude-sonnet-4-6"] ?? "", isMain: false),
    ]

    private static func readCatalog() -> [Choice] {
        let dir = NSHomeDirectory() + "/.claude/cache/model-catalog"
        let urls = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let newest = urls.max { a, b in
            let da = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let db = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return da < db
        }
        guard let newest, let data = try? Data(contentsOf: newest),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let catalog = root["catalog"] as? [String: Any],
              let config = catalog["config"] as? [String: Any],
              let models = config["models"] as? [[String: Any]] else { return [] }
        return models.compactMap(choice(from:))
    }

    private static func choice(from raw: [String: Any]) -> Choice? {
        guard let id = raw["id"] as? String, id.hasPrefix("claude"),
              let name = raw["name"] as? String else { return nil }
        let detail = detailKey[id] ?? (raw["description"] as? String ?? "")
        return Choice(id: id, name: name, detail: detail, isMain: raw["section"] as? String == "main")
    }
}

// MARK: - One Claude process, kept open

@MainActor
final class ClaudeWarmSession {
    static let shared = ClaudeWarmSession()

    private(set) var hasConversation = false
    private var model = ""
    private var pump: LinePump?
    private var process: Process?
    private var stdin: FileHandle?
    private var boot: Task<Bool, Never>?
    private var starting = false
    private var turn: TurnSlot?
    private var acceptingWarmup = false
    private var generation = 0

    private let instructions = """
    You are Mochi, a small assistant living in the notch of the user's Mac. \
    Answer in the user's language, clearly and completely. \
    Plain text only: no markdown (no **, no #, no bullet dashes), just line breaks. \
    Do not create, edit or delete files.
    """

    func prepare(model: String) {
        if model == self.model, process?.isRunning == true || starting { return }
        generation += 1
        let token = generation
        stop()
        starting = true
        self.model = model
        publish(link: "preparing", note: "")
        boot = Task { await self.launch(model, generation: token) }
    }

    func stop() {
        boot?.cancel()
        boot = nil
        starting = false
        if turn?.continuation != nil {
            finishTurn(LocalCLIChat.Reply(text: CoucouL10n.string("Claude closed."), isError: true))
        }
        turn = nil
        pump?.onLine = nil
        pump?.onClose = nil
        stdin = nil
        process?.terminate()
        process = nil
        pump = nil
        hasConversation = false
        acceptingWarmup = false
        publish(link: "off", note: "")
    }

    func send(_ text: String, onPartial: @escaping (String) -> Void) async -> LocalCLIChat.Reply {
        if process?.isRunning != true && !starting {
            prepare(model: model.isEmpty ? ClaudeModelCatalog.resolve(AppState.shared.claudeModel) : model)
        }
        let ready = await boot?.value ?? false
        guard ready, process?.isRunning == true else {
            return LocalCLIChat.Reply(text: CoucouL10n.string(AppState.shared.claudeLinkNote.isEmpty
                                      ? "Claude isn't ready."
                                      : AppState.shared.claudeLinkNote), isError: true)
        }
        guard turn == nil else {
            return LocalCLIChat.Reply(text: CoucouL10n.string("Still answering the previous message."), isError: true)
        }
        writeUser(text)
        return await waitForTurn(onPartial: onPartial)
    }

    private func launch(_ model: String, generation: Int) async -> Bool {
        let located = await Task.detached(priority: .userInitiated) {
            (LocalCLI.locate("claude"), LocalCLI.childEnvironment())
        }.value
        guard generation == self.generation else { return false }
        guard let path = located.0 else {
            starting = false
            publish(link: "failed", note: "Claude Code isn't installed.")
            return false
        }
        let started = startProcess(path: path, model: model, env: located.1)
        guard started, generation == self.generation else {
            process?.terminate()
            process = nil
            starting = false
            if generation == self.generation {
                publish(link: "failed", note: "Couldn't open Claude.")
            }
            return false
        }
        acceptingWarmup = true
        writeUser("Reply with the single word ready.")
        let reply = await waitForTurn(onPartial: { _ in })
        acceptingWarmup = false
        guard generation == self.generation, !Task.isCancelled else { return false }
        if reply.isError {
            publish(link: "failed", note: reply.text)
            starting = false
            return false
        }
        publish(link: "ready", note: "")
        starting = false
        return true
    }

    private func startProcess(path: String, model: String, env: [String: String]) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: path)
        proc.arguments = [
            "-p",
            "--input-format", "stream-json",
            "--output-format", "stream-json",
            "--verbose",
            "--include-partial-messages",
            "--model", model,
            "--permission-mode", "dontAsk",
            "--permission-prompts", "none",
            "--restricted",
            "--tools", "WebSearch,WebFetch,Read",
            "--append-system-prompt", instructions,
        ]
        proc.environment = env
        let dir = HookServer.supportDir.appendingPathComponent("chat")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        proc.currentDirectoryURL = dir

        let out = Pipe()
        let err = Pipe()
        let input = Pipe()
        proc.standardOutput = out
        proc.standardError = err
        proc.standardInput = input
        do { try proc.run() } catch { return false }
        let linePump = LinePump()
        linePump.onLine = { [weak self] line in
            Task { @MainActor in self?.consume(line) }
        }
        linePump.onClose = { [weak self] in
            Task { @MainActor in self?.handleClose() }
        }
        let outHandle = out.fileHandleForReading
        let errHandle = err.fileHandleForReading
        DispatchQueue.global(qos: .userInitiated).async {
            while true {
                let data = outHandle.availableData
                if data.isEmpty { break }
                linePump.push(data)
            }
            linePump.onClose?()
        }
        DispatchQueue.global(qos: .utility).async {
            while !errHandle.availableData.isEmpty {}
        }
        process = proc
        stdin = input.fileHandleForWriting
        pump = linePump
        return true
    }

    private func writeUser(_ text: String) {
        let payload: [String: Any] = [
            "type": "user",
            "message": ["role": "user", "content": text],
            "parent_tool_use_id": NSNull(),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let stdin else { return }
        var line = data
        line.append(0x0A)
        try? stdin.write(contentsOf: line)
    }

    private func waitForTurn(onPartial: @escaping (String) -> Void) async -> LocalCLIChat.Reply {
        if let done = turn?.finished {
            turn = nil
            return done
        }
        return await withCheckedContinuation { continuation in
            turn = TurnSlot(onPartial: onPartial, continuation: continuation)
        }
    }

    private func consume(_ line: String) {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { return }
        let type = obj["type"] as? String
        if type == "stream_event", !acceptingWarmup {
            appendDelta(obj)
            return
        }
        guard type == "result" else { return }
        let text = (obj["result"] as? String) ?? ""
        let failed = (obj["is_error"] as? Bool) ?? false
        if !acceptingWarmup { hasConversation = !failed }
        finishTurn(LocalCLIChat.Reply(text: text, isError: failed))
    }

    private func appendDelta(_ obj: [String: Any]) {
        guard let event = obj["event"] as? [String: Any],
              let delta = event["delta"] as? [String: Any],
              let text = delta["text"] as? String, !text.isEmpty,
              var slot = turn else { return }
        slot.partial += text
        slot.onPartial(slot.partial)
        turn = slot
    }

    private func finishTurn(_ reply: LocalCLIChat.Reply) {
        guard let slot = turn else {
            turn = TurnSlot(finished: reply)
            return
        }
        slot.continuation?.resume(returning: reply)
        turn = nil
    }

    private func handleClose() {
        // The read callback can fire with an empty buffer while Claude is still running.
        guard let process, !process.isRunning else { return }
        if turn?.continuation != nil {
            finishTurn(LocalCLIChat.Reply(text: CoucouL10n.string("Claude closed."), isError: true))
        }
        turn = nil
        self.process = nil
        publish(link: "failed", note: "Claude closed.")
    }

    private func publish(link: String, note: String) {
        AppState.shared.claudeLink = link
        AppState.shared.claudeLinkNote = note
    }
}

private struct TurnSlot {
    var partial = ""
    var onPartial: (String) -> Void = { _ in }
    var continuation: CheckedContinuation<LocalCLIChat.Reply, Never>?
    var finished: LocalCLIChat.Reply?
}

private final class LinePump: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    var onLine: (@Sendable (String) -> Void)?
    var onClose: (@Sendable () -> Void)?

    func push(_ data: Data) {
        if data.isEmpty {
            onClose?()
            return
        }
        var lines: [String] = []
        lock.lock()
        buffer.append(data)
        while let range = buffer.firstRange(of: Data([0x0A])) {
            let chunk = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
            buffer.removeSubrange(buffer.startIndex..<range.upperBound)
            if let text = String(data: chunk, encoding: .utf8) {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { lines.append(trimmed) }
            }
        }
        lock.unlock()
        for line in lines { onLine?(line) }
    }
}
