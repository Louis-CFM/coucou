#if !APPSTORE
import AppKit
import AudioToolbox
import Combine
import CoreAudio

/// The system volume in the notch (GitHub build only).
///
/// Watches the default output device with Core Audio and shows the volume HUD when
/// its volume or mute changes. Once Coucou is allowed in Accessibility it also takes
/// the volume keys from macOS (an event tap), sets the volume itself and so keeps
/// macOS's own volume popup away. Off in Settings: no listener, no tap.
@MainActor
final class SystemVolume: ObservableObject {
    static let shared = SystemVolume()

    /// The volume keys come to Coucou: setting on and Accessibility allowed.
    @Published private(set) var handlesKeys = false

    /// How long the HUD stays after the last change.
    private static let hudDuration: TimeInterval = 1.6

    private var device = AudioDeviceID(kAudioObjectUnknown)
    private var level: Double = 0
    private var muted = false
    private var bump = 0
    private var hideWork: DispatchWorkItem?
    private var listening = false
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var accessPoll: Timer?
    private var accessPollUntil = Date.distantPast
    private var settingSubscription: AnyCancellable?
    private var loggedFirstKey = false
    private var lastTrusted: Bool?
    private var triedTapUntrusted = false

    private lazy var deviceListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.defaultDeviceChanged() }
    }
    private lazy var volumeListener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
        MainActor.assumeIsolated { self?.volumeChanged() }
    }

    private init() {
        settingSubscription = AppState.shared.$volumeInNotch
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] on in self?.setEnabled(on) }
    }

    // MARK: - Accessibility

    /// Asks macOS for Accessibility (the system prompt adds Coucou to the list), then
    /// watches for the switch for five minutes so the keys are taken as soon as it is on.
    func requestKeyAccess() {
        guard AppState.shared.volumeInNotch else { return }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if AXIsProcessTrustedWithOptions(options) {
            installTap()
            return
        }
        Self.log("Accessibility not allowed yet: asked macOS")
        accessPollUntil = Date().addingTimeInterval(300)
        guard accessPoll == nil else { return }
        accessPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.pollAccess() }
        }
    }

    /// Takes the keys if Accessibility was allowed since; never prompts.
    func refreshAccess() {
        guard AppState.shared.volumeInNotch, tap == nil else { return }
        let trusted = AXIsProcessTrusted()
        if trusted != lastTrusted {
            lastTrusted = trusted
            Self.log("Accessibility allowed: \(trusted) (\(Bundle.main.bundlePath))")
        }
        // The tap itself is the real test: try it once even when macOS says no.
        if trusted || !triedTapUntrusted {
            if !trusted { triedTapUntrusted = true }
            installTap()
        }
    }

    private func pollAccess() {
        refreshAccess()
        if tap != nil || Date() > accessPollUntil || !AppState.shared.volumeInNotch {
            accessPoll?.invalidate()
            accessPoll = nil
        }
    }

    // MARK: - On / off

    private func setEnabled(_ on: Bool) {
        if on {
            startListening()
            // The setting is on from the first launch: ask for Accessibility once, by
            // itself; later the Settings button asks again.
            let asked = "volumeKeysAccessAsked"
            if !AXIsProcessTrusted() && !UserDefaults.standard.bool(forKey: asked) {
                UserDefaults.standard.set(true, forKey: asked)
                requestKeyAccess()
            } else {
                refreshAccess()
            }
        } else {
            removeTap()
            stopListening()
            accessPoll?.invalidate()
            accessPoll = nil
            hideWork?.cancel()
            AppState.shared.volumeHUD = nil
        }
    }

    // MARK: - Core Audio

    private static let defaultDeviceAddress = address(kAudioHardwarePropertyDefaultOutputDevice,
                                                      kAudioObjectPropertyScopeGlobal)
    private static let volumeAddress = address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
    private static let muteAddress = address(kAudioDevicePropertyMute)
    /// Watched too: some devices only report the change on their channels.
    private static let channelVolumeAddresses: [AudioObjectPropertyAddress] = [0, 1, 2].map {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioDevicePropertyScopeOutput, mElement: $0)
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioDevicePropertyScopeOutput)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func defaultOutputDevice() -> AudioDeviceID? {
        var addr = defaultDeviceAddress
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let err = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &id)
        return err == noErr && id != kAudioObjectUnknown ? id : nil
    }

    private static func has(_ id: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        return AudioObjectHasProperty(id, &addr)
    }

    private static func settable(_ id: AudioDeviceID, _ address: AudioObjectPropertyAddress) -> Bool {
        var addr = address
        var settable: DarwinBoolean = false
        return AudioObjectHasProperty(id, &addr)
            && AudioObjectIsPropertySettable(id, &addr, &settable) == noErr
            && settable.boolValue
    }

    private static func readVolume(_ id: AudioDeviceID) -> Double? {
        var addr = volumeAddress
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return Double(min(1, max(0, value)))
    }

    private static func readMute(_ id: AudioDeviceID) -> Bool? {
        var addr = muteAddress
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectHasProperty(id, &addr),
              AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    private static func writeVolume(_ id: AudioDeviceID, _ level: Double) {
        var addr = volumeAddress
        var value = Float32(level)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &value)
    }

    private static func writeMute(_ id: AudioDeviceID, _ muted: Bool) {
        var addr = muteAddress
        var value = UInt32(muted ? 1 : 0)
        AudioObjectSetPropertyData(id, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
    }

    private func startListening() {
        guard !listening else { return }
        listening = true
        var addr = Self.defaultDeviceAddress
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                            DispatchQueue.main, deviceListener)
        attach(to: Self.defaultOutputDevice())
    }

    private func stopListening() {
        guard listening else { return }
        listening = false
        var addr = Self.defaultDeviceAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &addr,
                                               DispatchQueue.main, deviceListener)
        detach()
    }

    private var watchedAddresses: [AudioObjectPropertyAddress] {
        [Self.volumeAddress, Self.muteAddress] + Self.channelVolumeAddresses
    }

    /// New output device (headphones plugged in, AirPods…): its volume is read quietly,
    /// the HUD only answers changes.
    private func attach(to id: AudioDeviceID?) {
        detach()
        guard let id else { return }
        device = id
        for a in watchedAddresses where Self.has(id, a) {
            var addr = a
            AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, volumeListener)
        }
        level = Self.readVolume(id) ?? 0
        muted = Self.readMute(id) ?? false
    }

    private func detach() {
        guard device != kAudioObjectUnknown else { return }
        for a in watchedAddresses where Self.has(device, a) {
            var addr = a
            AudioObjectRemovePropertyListenerBlock(device, &addr, DispatchQueue.main, volumeListener)
        }
        device = AudioDeviceID(kAudioObjectUnknown)
    }

    private func defaultDeviceChanged() {
        attach(to: Self.defaultOutputDevice())
    }

    /// Volume changed by anything: the keys, Control Center, the menu bar…
    private func volumeChanged() {
        guard device != kAudioObjectUnknown else { return }
        let newLevel = Self.readVolume(device) ?? level
        let newMuted = Self.readMute(device) ?? muted
        guard abs(newLevel - level) > 0.001 || newMuted != muted else { return }
        level = newLevel
        muted = newMuted
        refreshAccess()
        present()
    }

    // MARK: - HUD

    private func present() {
        bump += 1
        AppState.shared.volumeHUD = VolumeHUDState(level: level, muted: muted, bump: bump)
        hideWork?.cancel()
        let work = DispatchWorkItem {
            AppState.shared.volumeHUD = nil
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hudDuration, execute: work)
    }

    // MARK: - Volume keys

    private enum MediaKey {
        static let soundUp = 0     // NX_KEYTYPE_SOUND_UP
        static let soundDown = 1   // NX_KEYTYPE_SOUND_DOWN
        static let mute = 7        // NX_KEYTYPE_MUTE
    }

    private func installTap() {
        guard tap == nil else { return }
        let mask = CGEventMask(1) << 14   // NX_SYSDEFINED: media and volume keys
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                           options: .defaultTap, eventsOfInterest: mask,
                                           callback: volumeKeyTapCallback,
                                           userInfo: Unmanaged.passUnretained(self).toOpaque())
        else {
            Self.log("event tap refused")
            return
        }
        let source = CFMachPortCreateRunLoopSource(nil, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        tap = port
        tapSource = source
        handlesKeys = true
        Self.log("volume keys taken from macOS")
    }

    private static func log(_ message: String) {
        appendAppLog("volume.log", message)
    }

    private func removeTap() {
        if let port = tap {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
        if let source = tapSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        tap = nil
        tapSource = nil
        handlesKeys = false
    }

    /// What the tap needs from a system-defined event, read before hopping to the main actor.
    fileprivate struct KeyEvent: Sendable {
        let subtype: Int16
        let data1: Int
        let flags: NSEvent.ModifierFlags
    }

    /// True when Coucou handled the key and macOS must not see it.
    fileprivate func handleTap(type: CGEventType, key event: KeyEvent?) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Self.log("event tap disabled by macOS (\(type.rawValue)): enabled again")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return false
        }
        guard let event, event.subtype == 8, AppState.shared.volumeInNotch else { return false }
        let key = (event.data1 & 0xFFFF0000) >> 16
        guard key == MediaKey.soundUp || key == MediaKey.soundDown || key == MediaKey.mute else { return false }
        // The open island has no room for the HUD: macOS shows its own.
        guard AppState.shared.mode != .expanded else { return false }
        // ⌥ + a volume key opens Sound settings: leave it to macOS.
        let flags = event.flags
        if flags.contains(.option) && !flags.contains(.shift) { return false }
        guard let id = Self.defaultOutputDevice() else { return false }
        if key == MediaKey.mute {
            guard Self.settable(id, Self.muteAddress) else { return false }
        } else {
            guard Self.settable(id, Self.volumeAddress) else { return false }
        }
        let isDown = (event.data1 & 0xFF00) >> 8 == 0x0A
        if !loggedFirstKey {
            loggedFirstKey = true
            Self.log("first volume key handled in the notch")
        }
        if isDown {
            press(key, fine: flags.contains(.option) && flags.contains(.shift), device: id)
        }
        return true
    }

    /// Steps like macOS: sixteenths, quarter steps with ⇧⌥.
    private func press(_ key: Int, fine: Bool, device id: AudioDeviceID) {
        if id != device { attach(to: id) }
        var newLevel = Self.readVolume(id) ?? level
        var newMuted = Self.readMute(id) ?? muted
        let steps: Double = fine ? 64 : 16
        switch key {
        case MediaKey.mute:
            newMuted.toggle()
            Self.writeMute(id, newMuted)
        default:
            let delta: Double = key == MediaKey.soundUp ? 1 : -1
            newLevel = min(1, max(0, ((newLevel * steps).rounded() + delta) / steps))
            if newMuted, Self.settable(id, Self.muteAddress) {
                newMuted = false
                Self.writeMute(id, false)
            }
            Self.writeVolume(id, newLevel)
        }
        // Recorded first, so the listener that follows sees no change and stays quiet.
        level = newLevel
        muted = newMuted
        present()
    }
}

/// Event tap callback (main run loop).
private func volumeKeyTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                  refcon: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    let controller = Unmanaged<SystemVolume>.fromOpaque(refcon).takeUnretainedValue()
    var key: SystemVolume.KeyEvent? = nil
    if type.rawValue == 14, let ns = NSEvent(cgEvent: event) {   // NX_SYSDEFINED
        key = SystemVolume.KeyEvent(subtype: ns.subtype.rawValue, data1: ns.data1, flags: ns.modifierFlags)
    }
    let handled = MainActor.assumeIsolated { controller.handleTap(type: type, key: key) }
    return handled ? nil : Unmanaged.passUnretained(event)
}
#endif
