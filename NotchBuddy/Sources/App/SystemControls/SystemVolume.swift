#if !APPSTORE
import AudioToolbox
import CoreAudio

/// The Mac's output volume and mute, through CoreAudio (public API).
///
/// Works on the current default output device. Some devices (HDMI, a few USB DACs) have
/// no software volume: then every call returns nil/false and the key goes on to macOS.
@MainActor
enum SystemVolume {
    /// The device sound goes to right now (it changes with headphones, AirPods…).
    static func defaultOutputDevice() -> AudioObjectID? {
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, 0, nil, &size, &device)
        guard status == noErr, device != kAudioObjectUnknown else { return nil }
        return device
    }

    /// 0…1, the level the volume keys move (the "virtual main volume" of all channels).
    static func volume(of device: AudioObjectID) -> Double? {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return Double(value)
    }

    /// Returns false when the device has no settable volume or refuses the change.
    static func setVolume(_ level: Double, of device: AudioObjectID) -> Bool {
        var address = outputAddress(kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        guard isSettable(device, &address) else { return false }
        var value = Float32(min(max(level, 0), 1))
        let size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    static func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = outputAddress(kAudioDevicePropertyMute)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var value = UInt32(0)
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    static func setMuted(_ muted: Bool, of device: AudioObjectID) -> Bool {
        var address = outputAddress(kAudioDevicePropertyMute)
        guard isSettable(device, &address) else { return false }
        var value = UInt32(muted ? 1 : 0)
        let size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectSetPropertyData(device, &address, 0, nil, size, &value) == noErr
    }

    private static func outputAddress(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioDevicePropertyScopeOutput,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func isSettable(_ device: AudioObjectID,
                                   _ address: inout AudioObjectPropertyAddress) -> Bool {
        guard AudioObjectHasProperty(device, &address) else { return false }
        var settable = DarwinBoolean(false)
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }
}
#endif
