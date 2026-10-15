#if !APPSTORE
import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// The key that you hold to dictate.
enum FlowKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption:  return UInt16(kVK_RightOption)
        case .rightCommand: return UInt16(kVK_RightCommand)
        case .rightControl: return UInt16(kVK_RightControl)
        case .fn:           return UInt16(kVK_Function)
        }
    }

    /// Whether this very key is down, from a flagsChanged event's flags. The device-dependent bits
    /// tell the right key from the left one, so holding the left ⌥ never keeps the right one "down".
    func isDown(_ flags: NSEvent.ModifierFlags) -> Bool {
        let raw = flags.rawValue
        switch self {
        case .rightOption:  return raw & 0x0000_0040 != 0   // NX_DEVICERALTKEYMASK
        case .rightCommand: return raw & 0x0000_0010 != 0   // NX_DEVICERCMDKEYMASK
        case .rightControl: return raw & 0x0000_2000 != 0   // NX_DEVICERCTLKEYMASK
        case .fn:           return flags.contains(.function)
        }
    }

    var symbol: String {
        switch self {
        case .rightOption:  return "⌥"
        case .rightCommand: return "⌘"
        case .rightControl: return "⌃"
        case .fn:           return "fn"
        }
    }

    var label: String {
        switch self {
        case .fn: return String(localized: "flow.key-fn")
        default:  return String(format: String(localized: "flow.key-right %@"), symbol)
        }
    }
}

/// Flow dictation, like Wispr Flow (GitHub build): hold a key anywhere on the Mac, speak, let go,
/// and the words are pasted where you type. A small pill at the bottom of the screen shows that
/// Coucou listens, its dots moving with the graves and the aigus of your voice.
///
/// Speech is recognised by the Mac (on-device when it can, see MacDictation); pasting goes
/// through the clipboard and ⌘V, then the clipboard gets back what it held. Watching the key and
/// pasting both need the Accessibility permission. Off by default; nothing listens until you hold the key.
@MainActor
final class FlowDictation: ObservableObject {
    static let shared = FlowDictation()

    static let enabledKey = "flowDictationEnabled"
    /// How long the microphone stays open after the key comes up.
    static let tailMilliseconds = 600
    static let keyKey = "flowDictationKey"

    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: FlowDictation.enabledKey) {
        didSet {
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled && !AXIsProcessTrusted() { askForAccessibility() }
            refresh()
        }
    }
    @Published var key: FlowKey = FlowKey(rawValue: UserDefaults.standard.string(forKey: FlowDictation.keyKey) ?? "") ?? .rightOption {
        didSet {
            UserDefaults.standard.set(key.rawValue, forKey: Self.keyKey)
            cancelAll()
        }
    }
    /// Whether macOS lets Coucou watch the key and paste (System Settings → Privacy & Security → Accessibility).
    @Published private(set) var trusted: Bool = AXIsProcessTrusted()

    private var logic = FlowKeyLogic()
    private var monitors: [Any] = []
    private var current: Listen?
    private var startTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var trustTask: Task<Void, Never>?
    private let bands: FlowAudioBands
    /// The system's Accessibility prompt is shown at most once per launch, when a paste could not happen.
    private var promptedThisRun = false
    let pill: FlowPillController

    private init() {
        let bands = FlowAudioBands()
        self.bands = bands
        pill = FlowPillController(bands: bands)
    }

    /// At launch: listens for the key if Flow dictation is on.
    func start() { refresh() }

    func refresh() {
        removeMonitors()
        trusted = AXIsProcessTrusted()
        pill.setEnabled(isEnabled)
        guard isEnabled else {
            cancelAll()
            trustTask?.cancel(); trustTask = nil
            return
        }
        installMonitors()
        if !trusted { waitForTrust() }
    }

    func askForAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        trusted = AXIsProcessTrustedWithOptions(options)
    }

    /// Reads the permission again (Settings shows it; a new build of Coucou loses it, see flow.accessibility).
    /// Once it is there, the monitors are reinstalled so the global one starts getting Esc and the other keys.
    func recheckTrust() {
        let now = AXIsProcessTrusted()
        guard now != trusted else { return }
        trusted = now
        guard isEnabled else { return }
        removeMonitors()
        installMonitors()
        if !now { waitForTrust() }
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - The key

    private func installMonitors() {
        // A global monitor sees the key in other apps, a local one while Coucou itself is in front.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2) }
            return event
        }) { monitors.append(local) }
    }

    private func removeMonitors() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// Until macOS trusts Coucou, the global monitor gets nothing: check again every 2 s and
    /// reinstall the monitors once it does.
    private func waitForTrust() {
        trustTask?.cancel()
        trustTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard let self, self.isEnabled else { return }
                if AXIsProcessTrusted() {
                    self.trusted = true
                    self.removeMonitors()
                    self.installMonitors()
                    return
                }
            }
        }
    }

    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown:
            if keyCode == UInt16(kVK_Escape) { apply(logic.escape()) }
            else { apply(logic.otherKey()) }
        case .flagsChanged where keyCode == key.keyCode:
            apply(key.isDown(flags) ? logic.keyDown(at: now) : logic.keyUp(at: now))
        default:
            break
        }
    }

    private func apply(_ action: FlowKeyLogic.Action) {
        switch action {
        case .none:    break
        case .start:   begin()
        case .restart: abort(); begin()
        case .lock:    pill.model.phase = .locked
        case .finish:  finish()
        case .cancel:  abort()
        }
        if case .tapWait(let until) = logic.phase { scheduleTick(at: until) }
    }

    private func scheduleTick(at until: Double) {
        tickTask?.cancel()
        let wait = max(0, until - ProcessInfo.processInfo.systemUptime) + 0.02
        tickTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard !Task.isCancelled, let self else { return }
            self.apply(self.logic.tick(at: ProcessInfo.processInfo.systemUptime))
        }
    }

    // MARK: - Listening

    /// One listen, from the key press to the paste. Cancelling it drops its words.
    private final class Listen {
        let dictation = MacDictation()
        var cancelled = false
    }

    private func begin() {
        // After this key event is handled: a permission granted meanwhile reinstalls the monitors.
        Task { @MainActor [weak self] in self?.recheckTrust() }
        let listen = Listen()
        current = listen
        bands.reset()
        listen.dictation.bands = bands
        pill.listen()
        SoundEngine.shared.play("blip")
        startTask = Task { @MainActor [weak self] in
            await listen.dictation.start(from: "")
            guard let self else { return }
            if listen.cancelled { listen.dictation.stop(); return }      // cancelled while the mic opened
            if !listen.dictation.isRecording, self.current === listen {
                // No permission, no recognizer for these languages, or no microphone.
                self.logic.reset()
                self.current = nil
                self.pill.flash(.failed)
            }
        }
    }

    private func finish() {
        guard let listen = current else { pill.rest(); return }
        pill.model.phase = .thinking
        let opening = startTask
        Task { @MainActor [weak self] in
            await opening?.value
            // The key often comes up while the last word is still being said: keep listening a
            // moment so it makes it in.
            try? await Task.sleep(for: .milliseconds(Self.tailMilliseconds))
            guard !listen.cancelled else { return }
            let text = await listen.dictation.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !listen.cancelled else { return }
            // A new listen may have begun meanwhile: its pill is left alone, but these words still go in.
            let latest = self.current === listen
            if latest { self.current = nil }
            guard !text.isEmpty else { if latest { self.pill.rest() }; return }
            let pasted = FlowPaste.insert(text)
            if !pasted {
                // No Accessibility: the words wait on the clipboard, and macOS is asked once.
                self.trusted = false
                if !self.promptedThisRun { self.promptedThisRun = true; self.askForAccessibility() }
                self.waitForTrust()
            }
            guard latest else { return }
            if pasted { self.pill.rest() } else { self.pill.flash(.copied) }
        }
    }

    private func abort() {
        tickTask?.cancel()
        if let listen = current {
            listen.cancelled = true
            listen.dictation.stop()
        }
        current = nil
        pill.rest()
    }

    private func cancelAll() {
        logic.reset()
        abort()
    }
}

// MARK: - Paste

/// Puts the words where the cursor is: on the clipboard, then ⌘V, then the clipboard gets back what it held.
enum FlowPaste {
    @MainActor static func insert(_ text: String) -> Bool {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        board.setString(text, forType: .string)
        guard AXIsProcessTrusted() else { return false }

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // Give the app time to read the clipboard, then put back what was there, unless something
        // else was copied meanwhile.
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard board.changeCount == count else { return }
            restore(saved, to: board)
        }
        return true
    }

    private static func snapshot(_ board: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (board.pasteboardItems ?? []).map { item in
            var out: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types { if let data = item.data(forType: type) { out[type] = data } }
            return out
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to board: NSPasteboard) {
        board.clearContents()
        guard !items.isEmpty else { return }
        let objects: [NSPasteboardItem] = items.map { entry in
            let item = NSPasteboardItem()
            for (type, data) in entry { item.setData(data, forType: type) }
            return item
        }
        board.writeObjects(objects)
    }
}
#endif
