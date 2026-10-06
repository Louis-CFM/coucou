import AVFoundation
import Speech
import SwiftUI

/// Write or dictate an instruction for a Claude Code session; Face ID sends
/// it to the Mac, which continues the conversation in the background.
struct InstructionComposer: View {
    let link: PhoneLink
    let session: SessionItem

    @State private var text = ""
    @State private var sending = false
    @State private var sentAt: Date?
    @State private var error: String?
    @State private var dictation = Dictation()
    @State private var quickReplies = QuickReplies.load()
    @FocusState private var focused: Bool

    /// A bar at the bottom of the session screen, like a chat.
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if session.acceptsInstructions {
                shortcuts
                composer
                status
            } else {
                Label("To write to Claude from here, turn on \"Let my iPhone send instructions to Claude Code\" in Coucou's Settings on your Mac (GitHub version).",
                      systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
        .onChange(of: dictation.transcript) { _, words in
            if dictation.isRecording { text = dictation.prefix + words }
        }
    }

    /// Instructions you send often: a tap puts one in the field (it isn't sent
    /// yet); + keeps what is typed; a long press removes one.
    private var shortcuts: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(quickReplies, id: \.self) { reply in
                    Button {
                        text = reply
                        focused = true
                        Haptics.impact()
                    } label: {
                        Text(reply)
                            .font(.footnote)
                            .lineLimit(1)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color(white: 0.16), in: Capsule())
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button(role: .destructive) {
                            quickReplies.removeAll { $0 == reply }
                            QuickReplies.save(quickReplies)
                        } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                }
                let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !typed.isEmpty && !quickReplies.contains(typed) {
                    Button {
                        quickReplies.append(typed)
                        QuickReplies.save(quickReplies)
                        Haptics.success()
                    } label: {
                        Label("Keep", systemImage: "plus")
                            .font(.footnote.weight(.semibold))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Color.accentColor.opacity(0.25), in: Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField("Tell Claude what to do next…", text: $text, axis: .vertical)
                .lineLimit(1...8)
                .focused($focused)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(white: 0.16), in: RoundedRectangle(cornerRadius: 18))
            Menu {
                Picker("Dictation language", selection: $dictation.localeID) {
                    ForEach(Dictation.languages, id: \.self) { id in
                        Text(Locale.current.localizedString(forIdentifier: id) ?? id).tag(id)
                    }
                }
            } label: {
                Text(Dictation.shortName(dictation.localeID))
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 26, height: 36)
            }
            Button {
                Task { await dictation.toggle(startingFrom: text) }
            } label: {
                Image(systemName: dictation.isRecording ? "stop.circle.fill" : "mic.fill")
                    .font(.title3)
                    .foregroundStyle(dictation.isRecording ? Color.red : Color.secondary)
                    .frame(width: 36, height: 36)
            }
            Button {
                Task { await send() }
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
            }
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
        }
    }

    @ViewBuilder private var status: some View {
        if let error {
            Text(error).font(.caption).foregroundStyle(.red)
        } else if let sentAt {
            if session.updatedAt > sentAt && (session.isWorking || session.state == .thinking) {
                Label("Your Mac started it", systemImage: "checkmark.circle.fill")
                    .font(.caption).foregroundStyle(.green)
            } else {
                Label("Sent. Your Mac picks it up within 15 s.", systemImage: "paperplane.fill")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func send() async {
        let instruction = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return }
        dictation.stop()
        focused = false
        sending = true
        defer { sending = false }
        error = nil
        guard await OwnerCheck.confirm(reason: "Send this instruction to Claude Code on your Mac") else {
            error = "Face ID didn't confirm. Nothing was sent."
            Haptics.warning()
            return
        }
        if await link.sendInstruction(instruction, pillId: session.id) {
            sentAt = .now
            text = ""
            Haptics.success()
        } else {
            error = link.lastPong ?? "Couldn't reach iCloud."
            Haptics.error()
        }
    }
}

/// Speech to text on the iPhone (on-device when available). Not main-actor
/// bound: the audio tap and the recognizer call back on their own threads;
/// the published values are only set on the main actor.
@Observable
final class Dictation: @unchecked Sendable {
    var isRecording = false
    var transcript = ""
    /// The language heard, chosen next to the mic and remembered.
    var localeID: String = UserDefaults.standard.string(forKey: "dictationLocale")
        ?? Locale.preferredLanguages.first ?? "en-US" {
        didSet { UserDefaults.standard.set(localeID, forKey: "dictationLocale") }
    }

    /// The iPhone's languages first, then French and English.
    static var languages: [String] {
        var ids: [String] = []
        for id in Locale.preferredLanguages + ["fr-FR", "en-US"] where !ids.contains(id) {
            if SFSpeechRecognizer(locale: Locale(identifier: id)) != nil { ids.append(id) }
        }
        return ids
    }

    static func shortName(_ id: String) -> String {
        String(Locale(identifier: id).language.languageCode?.identifier.uppercased().prefix(2) ?? "?")
    }
    /// What was typed before dictating, kept in front of the words.
    var prefix = ""

    @ObservationIgnored private let engine = AVAudioEngine()
    @ObservationIgnored private var request: SFSpeechAudioBufferRecognitionRequest?
    @ObservationIgnored private var task: SFSpeechRecognitionTask?

    @MainActor func toggle(startingFrom text: String) async {
        if isRecording { stop(); return }
        guard await Self.authorized() else { return }
        prefix = text.isEmpty || text.hasSuffix(" ") ? text : text + " "
        transcript = ""
        start()
    }

    /// Not main-actor bound, so the audio and speech callbacks made here don't
    /// inherit the main actor (they run on their own threads).
    nonisolated private func start() {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeID)) ?? SFSpeechRecognizer(),
              recognizer.isAvailable else { return }
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { request.requiresOnDeviceRecognition = true }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .measurement, options: .duckOthers)
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            let input = engine.inputNode
            input.installTap(onBus: 0, bufferSize: 1024, format: input.outputFormat(forBus: 0)) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
        } catch {
            engine.inputNode.removeTap(onBus: 0)
            return
        }
        self.request = request
        isRecording = true
        task = recognizer.recognitionTask(with: request) { [weak self] result, error in
            let words = result?.bestTranscription.formattedString
            let done = error != nil || (result?.isFinal ?? false)
            Task { @MainActor in
                guard let self else { return }
                if let words { self.transcript = words }
                if done { self.stop() }
            }
        }
    }

    @MainActor func stop() {
        guard isRecording else { return }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        request = nil
        task = nil
        isRecording = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    private static func authorized() async -> Bool {
        let speech = await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { continuation.resume(returning: $0 == .authorized) }
        }
        guard speech else { return false }
        return await AVAudioApplication.requestRecordPermission()
    }
}

/// The shortcuts above the instruction field, kept on this iPhone.
enum QuickReplies {
    private static let key = "quickReplies"
    static let defaults = ["Continue", "Run the tests", "Fix the errors", "Commit the changes", "Explain what you changed"]

    static func load() -> [String] {
        UserDefaults.standard.stringArray(forKey: key) ?? defaults
    }

    static func save(_ replies: [String]) {
        UserDefaults.standard.set(replies, forKey: key)
    }
}
