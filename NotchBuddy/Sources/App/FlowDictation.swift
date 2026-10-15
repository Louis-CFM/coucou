#if !APPSTORE
import AppKit
import ApplicationServices
import Carbon

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
            pill.model.keyLabel = key.label
            cancelAll()
        }
    }
    /// Where the pill lives: centred along the bottom, or on the left or right edge.
    @Published var pillEdge: FlowPillEdge = FlowPillEdge(rawValue: UserDefaults.standard.string(forKey: "flowPillEdge") ?? "") ?? .bottom {
        didSet {
            UserDefaults.standard.set(pillEdge.rawValue, forKey: "flowPillEdge")
            pill.setEdge(pillEdge)
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
        // The pill's buttons, under the pointer.
        pill.setEdge(pillEdge)
        pill.model.keyLabel = key.label
        pill.model.dictate = { [weak self] in self?.startHandsFree() }
        pill.model.finishDictation = { [weak self] in self?.finishFromPill() }
        pill.model.cancelDictation = { [weak self] in self?.cancelAll() }
        pill.model.toggleNote = { NoteTaker.shared.toggleFromPill() }
        pill.model.openHub = { FlowHubController.shared.show() }
    }

    /// The pill's microphone: hands-free, as after a double tap, until ✓ or the key.
    func startHandsFree() {
        guard isEnabled, logic.phase == .idle, current == nil else { return }
        logic.lock()
        begin()
        pill.model.phase = .locked
    }

    /// The pill's ✓: stop listening and paste.
    func finishFromPill() {
        guard logic.phase == .locked else { return }
        logic.reset()
        finish()
    }

    /// At launch: listens for the key if Flow dictation is on.
    func start() {
        refresh()
        if isEnabled, FlowStore.shared.engine == .parakeet { Parakeet.shared.preload() }
    }

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
            let info = (event.type, event.keyCode, event.modifierFlags,
                        event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2, characters: info.3) }
        }) { monitors.append(global) }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown], handler: { [weak self] event in
            let info = (event.type, event.keyCode, event.modifierFlags,
                        event.type == .keyDown ? event.charactersIgnoringModifiers : nil)
            MainActor.assumeIsolated { self?.handle(type: info.0, keyCode: info.1, flags: info.2, characters: info.3) }
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

    /// ⌃⌘V: the last dictation, pasted again.
    static func isPasteAgain(characters: String?, flags: NSEvent.ModifierFlags) -> Bool {
        let mods = flags.intersection([.command, .control, .option, .shift])
        return mods == [.command, .control] && characters?.lowercased() == "v"
    }

    /// Pastes the last dictation again (⌃⌘V, or the button of the history).
    func pasteAgain(_ text: String? = nil) {
        guard let text = text ?? FlowStore.shared.lastText, !text.isEmpty else { return }
        switch FlowPaste.insert(text) {
        case .pasted:   pill.flash(.pastedAgain)
        case .noAccess: announceNoAccess()
        case .noField:  announceNoField()
        }
    }

    private func handle(type: NSEvent.EventType, keyCode: UInt16, flags: NSEvent.ModifierFlags, characters: String?) {
        let now = ProcessInfo.processInfo.systemUptime
        switch type {
        case .keyDown:
            if keyCode == UInt16(kVK_Escape) { apply(logic.escape()) }
            else if logic.phase == .idle, Self.isPasteAgain(characters: characters, flags: flags) { pasteAgain() }
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
    @MainActor private final class Listen {
        /// The Mac's recognizer, or Parakeet when it is chosen and downloaded.
        let apple: MacDictation?
        let parakeet: ParakeetDictation?
        var cancelled = false
        /// The app the words go to, seen when the key went down.
        let app = NSWorkspace.shared.frontmostApplication
        let startedAt = Date()
        var stoppedAt: Date?

        init(useParakeet: Bool) {
            apple = useParakeet ? nil : MacDictation()
            parakeet = useParakeet ? ParakeetDictation() : nil
        }

        var isRecording: Bool { apple?.isRecording ?? parakeet?.isRecording ?? false }

        func start(bands: FlowAudioBands) async {
            if let apple {
                apple.bands = bands
                await apple.start(from: "")
            } else if let parakeet {
                parakeet.bands = bands
                await parakeet.start()
            }
        }

        func finish() async -> String {
            if let apple { return await apple.finish() }
            if let parakeet { return await parakeet.finish() }
            return ""
        }

        func stop() {
            apple?.stop()
            parakeet?.stop()
        }
    }

    private func begin() {
        // After this key event is handled: a permission granted meanwhile reinstalls the monitors.
        Task { @MainActor [weak self] in self?.recheckTrust() }
        let listen = Listen(useParakeet: FlowStore.shared.engine == .parakeet && Parakeet.shared.isReady)
        current = listen
        bands.reset()
        pill.listen()
        SoundEngine.shared.play("blip")
        let bands = self.bands
        startTask = Task { @MainActor [weak self] in
            await listen.start(bands: bands)
            guard let self else { return }
            if listen.cancelled { listen.stop(); return }      // cancelled while the mic opened
            if !listen.isRecording, self.current === listen {
                // No permission, no recognizer for these languages, or no microphone.
                self.logic.reset()
                self.current = nil
                self.pill.flash(.failed)
                self.pill.announce(FlowAnnouncement(symbol: "mic.slash.fill", tint: "#FF6B6B", text: String(localized: "flow.ann.mic"),
                                                    action: String(localized: "flow.ann.settings"))) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
        }
    }

    private func finish() {
        guard let listen = current else { pill.rest(); return }
        pill.model.phase = .thinking
        listen.stoppedAt = Date()
        let opening = startTask
        Task { @MainActor [weak self] in
            await opening?.value
            // The key often comes up while the last word is still being said: keep listening a
            // moment so it makes it in.
            try? await Task.sleep(for: .milliseconds(Self.tailMilliseconds))
            guard !listen.cancelled else { return }
            let heard = await listen.finish().trimmingCharacters(in: .whitespacesAndNewlines)
            guard let self, !listen.cancelled else { return }
            // Replacements and the dictionary, then Claude's clean-up when it is on, then the snippets.
            let store = FlowStore.shared
            let prepared = store.prepare(heard)
            var body = prepared.text
            if store.cleanupEnabled, !body.isEmpty {
                let cleaned = await FlowCleanup.clean(body, style: store.style(for: listen.app?.bundleIdentifier),
                                                      app: listen.app?.localizedName, words: store.words)
                guard !listen.cancelled else { return }
                if FlowText.keepsMarks(cleaned, prepared.snippets) { body = cleaned }
            }
            let text = FlowText.finish(body, snippets: prepared.snippets)
            if !text.isEmpty {
                let spoken = (listen.stoppedAt ?? Date()).timeIntervalSince(listen.startedAt)
                store.record(text: text, app: listen.app?.localizedName, seconds: spoken)
            }
            // A new listen may have begun meanwhile: its pill is left alone, but these words still go in.
            let latest = self.current === listen
            if latest { self.current = nil }
            guard !text.isEmpty else { if latest { self.pill.rest() }; return }
            let result = FlowPaste.insert(text)
            if latest { self.pill.rest() }
            switch result {
            case .pasted:
                break
            case .noAccess:
                // No Accessibility: the words wait on the clipboard, and macOS is asked once.
                self.trusted = false
                if !self.promptedThisRun { self.promptedThisRun = true; self.askForAccessibility() }
                self.waitForTrust()
                self.announceNoAccess()
            case .noField:
                self.announceNoField()
            }
        }
    }

    /// The words could not be pasted: they are on the clipboard, and the pill says how to get them in.
    private func announceNoAccess() {
        pill.announce(FlowAnnouncement(symbol: "lock.fill", text: String(localized: "flow.ann.no-access"),
                                       action: String(localized: "flow.ann.allow"))) { [weak self] in
            self?.openAccessibilitySettings()
        }
    }

    private func announceNoField() {
        pill.announce(FlowAnnouncement(symbol: "doc.on.clipboard.fill", text: String(localized: "flow.ann.no-field")))
    }

    private func abort() {
        tickTask?.cancel()
        if let listen = current {
            listen.cancelled = true
            listen.stop()
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
    /// Marks the words as passing through, so clipboard managers leave them out of their history
    /// (the nspasteboard.org convention).
    static let transientType = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    static let autoGeneratedType = NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")

    enum Result {
        /// ⌘V was sent where you type.
        case pasted
        /// No Accessibility permission: the words are only on the clipboard.
        case noAccess
        /// Nothing seems to take text where the focus is: ⌘V was sent anyway, and the words stay on
        /// the clipboard for you to paste.
        case noField
    }

    @MainActor static func insert(_ text: String) -> Result {
        let board = NSPasteboard.general
        let saved = snapshot(board)
        board.clearContents()
        board.declareTypes([.string, transientType, autoGeneratedType], owner: nil)
        board.setString(text, forType: .string)
        board.setData(Data(), forType: transientType)
        board.setData(Data(), forType: autoGeneratedType)
        guard AXIsProcessTrusted() else { return .noAccess }
        let field = focusTakesText()

        let source = CGEventSource(stateID: .combinedSessionState)
        let v = vKeyCode()
        let down = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: v, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        // No text field: the words stay on the clipboard.
        if field == false { return .noField }
        // Give the app time to read the clipboard, then put back what was there, unless something
        // else was copied meanwhile.
        let count = board.changeCount
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard board.changeCount == count else { return }
            restore(saved, to: board)
        }
        return .pasted
    }

    /// Whether the focused element takes text: true for a text field, false when the focus is on
    /// something else (the desktop, a list…) or nowhere, nil when the app does not say (then the
    /// paste is trusted).
    @MainActor static func focusTakesText() -> Bool? {
        let system = AXUIElementCreateSystemWide()
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &value)
        if status == .noValue { return false }
        guard status == .success, let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        let element = value as! AXUIElement
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &role)
        let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField", "AXWebArea"]
        if let role = role as? String, textRoles.contains(role) { return true }
        var settable: DarwinBoolean = false
        if AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue {
            return true
        }
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &range) == .success { return true }
        return role == nil ? nil : false
    }

    /// The key that types "v" with ⌘ held in the current keyboard layout: the same key on QWERTY
    /// and AZERTY, another one on Dvorak. Layouts with no "v" (Russian, Greek…) fall back to the
    /// QWERTY key, which macOS uses for shortcuts there.
    @MainActor static func vKeyCode() -> CGKeyCode {
        let fallback = CGKeyCode(kVK_ANSI_V)
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        let commandState = UInt32((cmdKey >> 8) & 0xFF)
        let found: CGKeyCode? = data.withUnsafeBytes { bytes in
            guard let layout = bytes.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            for code in 0..<128 {
                var dead: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), commandState,
                                            UInt32(LMGetKbdType()), OptionBits(1 << kUCKeyTranslateNoDeadKeysBit),
                                            &dead, 4, &length, &chars)
                if status == noErr, length == 1, chars[0] == 0x76 { return CGKeyCode(code) }   // "v"
            }
            return nil
        }
        return found ?? fallback
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
