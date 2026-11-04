#if !APPSTORE
import CoreAudio
import Foundation

/// Silences everything the Mac plays while Flow listens (a video, music, a call…), so the
/// microphone hears only your voice; the sound comes back as it was once the listen ends.
///
/// Every output device in use is muted or, when it has no mute, its volume set to 0. Only what
/// Coucou changed is put back: a device that was already muted stays muted. What was changed is
/// also kept in UserDefaults, so a crash in the middle of a dictation is undone at the next launch.
@MainActor
final class SystemMute {
    static let shared = SystemMute()

    /// Coucou Flow → Settings → "Mute the Mac while you dictate". On by default.
    static let enabledKey = "flowMuteMac"
    private static let leftoverKey = "flowMuteLeftover"

    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true
    }

    /// What Coucou changed on one device, to put it back.
    private struct Change: Codable {
        let uid: String
        /// The device was muted with its own mute…
        var muted = false
        /// …or, without one, its volume was set to 0: the volume it had, by element (0 is the
        /// main volume, 1, 2… the channels).
        var volumes: [UInt32: Float32] = [:]
    }

    /// nil while the Mac plays as usual.
    private var changes: [Change]?
    /// A mute or a release waiting for its moment.
    private var pending: Task<Void, Never>?

    private init() {}

    /// Mutes the Mac in `delay` (the time for Coucou's own blip to be heard), unless it already is.
    /// A release still waiting is called off, so a listen that follows another keeps the silence.
    func engage(after delay: Duration = .zero) {
        pending?.cancel(); pending = nil
        guard changes == nil, Self.isEnabled else { return }
        pending = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.muteNow()
        }
    }

    /// Gives the sound back a moment later, so a listen that starts right after (a restart, a
    /// double tap) keeps the Mac quiet instead of letting a note of music through.
    func release(after delay: Duration = .milliseconds(250)) {
        pending?.cancel()
        pending = Task { @MainActor [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled, let self else { return }
            self.pending = nil
            self.restoreNow()
        }
    }

    /// Right away: when Coucou quits.
    func releaseNow() {
        pending?.cancel(); pending = nil
        restoreNow()
    }

    /// At launch: a dictation cut short by a crash or a force quit left the Mac muted. Put it back.
    func restoreLeftover() {
        guard changes == nil,
              let data = UserDefaults.standard.data(forKey: Self.leftoverKey),
              let left = try? JSONDecoder().decode([Change].self, from: data) else { return }
        changes = left
        restoreNow()
    }

    // MARK: - Muting

    private func muteNow() {
        var done: [Change] = []
        for device in Self.devicesToMute() {
            guard let uid = Self.uid(of: device) else { continue }
            var change = Change(uid: uid)
            if Self.canSetMute(device) {
                if Self.isMuted(device) { continue }               // muted by you: left alone
                change.muted = Self.setMute(device, true)
            }
            if !change.muted {
                for element in Self.volumeElements(device) {
                    guard let volume = Self.volume(device, element), volume > 0 else { continue }
                    if Self.setVolume(device, element, 0) { change.volumes[element] = volume }
                }
            }
            if change.muted || !change.volumes.isEmpty { done.append(change) }
        }
        changes = done
        if !done.isEmpty, let data = try? JSONEncoder().encode(done) {
            UserDefaults.standard.set(data, forKey: Self.leftoverKey)
        }
        appendAppLog("nb.log", "[Flow] Mac muted while listening (\(done.count) output(s))")
    }

    private func restoreNow() {
        guard let list = changes else { return }
        changes = nil
        for change in list {
            guard let device = Self.device(uid: change.uid) else { continue }   // unplugged meanwhile
            if change.muted { _ = Self.setMute(device, false) }
            for (element, volume) in change.volumes { _ = Self.setVolume(device, element, volume) }
        }
        UserDefaults.standard.removeObject(forKey: Self.leftoverKey)
    }

    // MARK: - Devices

    /// The device sound goes to, the one for alerts, and every other output something is playing
    /// on (a call app set to its own headset). Aggregate devices, such as the one the notes record
    /// the Mac's sound with, are left alone unless sound goes to them by default.
    private static func devicesToMute() -> [AudioObjectID] {
        var list: [AudioObjectID] = []
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            if let device = systemDevice(selector), !list.contains(device) { list.append(device) }
        }
        for device in allDevices() where !list.contains(device) && hasOutput(device) && isRunning(device) && !isAggregate(device) {
            list.append(device)
        }
        return list
    }

    private static func address(_ selector: AudioObjectPropertySelector,
                                _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    private static func systemDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var where_ = address(selector)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_, 0, nil, &size, &device)
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    private static func allDevices() -> [AudioObjectID] {
        var where_ = address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &where_, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &where_, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func hasOutput(_ device: AudioObjectID) -> Bool {
        var where_ = address(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        return AudioObjectGetPropertyDataSize(device, &where_, 0, nil, &size) == noErr && size > 0
    }

    private static func isRunning(_ device: AudioObjectID) -> Bool {
        (uint32(device, address(kAudioDevicePropertyDeviceIsRunningSomewhere)) ?? 0) != 0
    }

    private static func isAggregate(_ device: AudioObjectID) -> Bool {
        uint32(device, address(kAudioDevicePropertyTransportType)) == kAudioDeviceTransportTypeAggregate
    }

    private static func uid(of device: AudioObjectID) -> String? {
        var where_ = address(kAudioDevicePropertyDeviceUID)
        var uid: CFString = "" as CFString
        var size = UInt32(MemoryLayout<CFString>.stride)
        let status = withUnsafeMutablePointer(to: &uid) { AudioObjectGetPropertyData(device, &where_, 0, nil, &size, $0) }
        return status == noErr ? uid as String : nil
    }

    private static func device(uid: String) -> AudioObjectID? {
        var where_ = address(kAudioHardwarePropertyTranslateUIDToDevice)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &where_,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        return status == noErr && device != AudioObjectID(kAudioObjectUnknown) ? device : nil
    }

    // MARK: - Mute and volume

    private static func uint32(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> UInt32? {
        var where_ = address
        guard AudioObjectHasProperty(object, &where_) else { return nil }
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &where_, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func settable(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress) -> Bool {
        var where_ = address
        guard AudioObjectHasProperty(object, &where_) else { return false }
        var ok: DarwinBoolean = false
        return AudioObjectIsPropertySettable(object, &where_, &ok) == noErr && ok.boolValue
    }

    private static func canSetMute(_ device: AudioObjectID) -> Bool {
        settable(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput))
    }

    private static func isMuted(_ device: AudioObjectID) -> Bool {
        (uint32(device, address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)) ?? 0) != 0
    }

    private static func setMute(_ device: AudioObjectID, _ on: Bool) -> Bool {
        var where_ = address(kAudioDevicePropertyMute, kAudioObjectPropertyScopeOutput)
        var value: UInt32 = on ? 1 : 0
        return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) == noErr
    }

    /// The main volume when the device has one, else each channel's.
    private static func volumeElements(_ device: AudioObjectID) -> [UInt32] {
        func volumeAddress(_ element: UInt32) -> AudioObjectPropertyAddress {
            address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
        }
        if settable(device, volumeAddress(kAudioObjectPropertyElementMain)) { return [kAudioObjectPropertyElementMain] }
        return Array(UInt32(1)...UInt32(8)).filter { settable(device, volumeAddress($0)) }
    }

    private static func volume(_ device: AudioObjectID, _ element: UInt32) -> Float32? {
        var where_ = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(device, &where_, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func setVolume(_ device: AudioObjectID, _ element: UInt32, _ value: Float32) -> Bool {
        var where_ = address(kAudioDevicePropertyVolumeScalar, kAudioObjectPropertyScopeOutput, element)
        var value = value
        return AudioObjectSetPropertyData(device, &where_, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) == noErr
    }
}
#endif
