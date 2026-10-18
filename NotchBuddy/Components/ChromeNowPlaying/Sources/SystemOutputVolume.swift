#if !APPSTORE
import Combine
import CoreAudio
import Foundation

/// Output-device volume, independent of the current player. Never opens an audio stream.
@MainActor
final class SystemOutputVolume: ObservableObject {
    @Published private(set) var volume = 0
    @Published private(set) var available = false
    @Published private(set) var notice: String?

    private struct Observation {
        let object: AudioObjectID
        var address: AudioObjectPropertyAddress
        let block: AudioObjectPropertyListenerBlock
    }
    private var observations: [Observation] = []
    private var device = AudioObjectID(kAudioObjectUnknown)
    private var controls: [AudioObjectPropertyElement] = []
    private var listening = false

    func start() {
        guard !listening else { return }
        listening = true
        observe(AudioObjectID(kAudioObjectSystemObject), address: Self.defaultOutputAddress)
        refresh()
    }

    func stop() {
        removeObservations()
        device = AudioObjectID(kAudioObjectUnknown)
        controls = []
        available = false
        listening = false
    }

    func setVolume(_ percent: Int) {
        guard listening else { return }
        // Resolve the device again: a hot-plug event may still be queued.
        refresh()
        guard available else { return }
        let level = Float32(min(100, max(0, percent))) / 100
        var failed = false
        for element in controls {
            var address = Self.outputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            var value = level
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &value) != noErr
            {
                failed = true
            }
        }
        if level > 0, Self.muted(device) {
            var address = Self.outputAddress(kAudioDevicePropertyMute)
            var value: UInt32 = 0
            if AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value) != noErr
            {
                failed = true
            }
        }
        refresh()
        notice = failed ? "No se pudo ajustar el volumen de salida del Mac." : nil
    }

    private func refresh() {
        let current = Self.defaultOutput()
        if current != device {
            removeObservations(keepingSystem: true)
            device = current
            notice = nil
            if listening, device != kAudioObjectUnknown {
                for element in [AudioObjectPropertyElement(0), 1, 2] {
                    observe(device, address: Self.outputAddress(kAudioDevicePropertyVolumeScalar, element: element))
                }
                observe(device, address: Self.outputAddress(kAudioDevicePropertyMute))
            }
        }
        let levels = Self.levels(device)
        controls = levels.map(\.element)
        let muted = Self.muted(device)
        volume = muted ? 0 : Int(((levels.map(\.value).reduce(0, +) / Double(max(1, levels.count))) * 100).rounded())
        available =
            !levels.isEmpty
            && controls.allSatisfy {
                Self.settable(device, address: Self.outputAddress(kAudioDevicePropertyVolumeScalar, element: $0))
            } && (!muted || Self.settable(device, address: Self.outputAddress(kAudioDevicePropertyMute)))
    }

    private func observe(_ object: AudioObjectID, address: AudioObjectPropertyAddress) {
        var address = address
        guard AudioObjectHasProperty(object, &address) else { return }
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, self.listening else { return }
                self.refresh()
            }
        }
        if AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr {
            observations.append(Observation(object: object, address: address, block: block))
        }
    }

    private func removeObservations(keepingSystem: Bool = false) {
        var retained: [Observation] = []
        for var observation in observations {
            if keepingSystem && observation.object == AudioObjectID(kAudioObjectSystemObject) {
                retained.append(observation)
            } else {
                AudioObjectRemovePropertyListenerBlock(
                    observation.object, &observation.address, .main, observation.block)
            }
        }
        observations = retained
    }

    private static var defaultOutputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
    }

    private static func outputAddress(
        _ selector: AudioObjectPropertySelector, element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioDevicePropertyScopeOutput, mElement: element)
    }

    private static func defaultOutput() -> AudioObjectID {
        var address = defaultOutputAddress
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &result)
                == noErr
        else { return AudioObjectID(kAudioObjectUnknown) }
        return result
    }

    private static func settable(_ device: AudioObjectID, address: AudioObjectPropertyAddress) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = address
        var result: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &result) == noErr && result.boolValue
    }

    private static func muted(_ device: AudioObjectID) -> Bool {
        guard device != kAudioObjectUnknown else { return false }
        var address = outputAddress(kAudioDevicePropertyMute)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(device, &address, 0, nil, &size, &result) == noErr && result != 0
    }

    private static func levels(_ device: AudioObjectID) -> [(element: AudioObjectPropertyElement, value: Double)] {
        guard device != kAudioObjectUnknown else { return [] }
        var result: [(element: AudioObjectPropertyElement, value: Double)] = []
        // Prefer the master scalar; otherwise use the readable left/right controls.
        for element in [AudioObjectPropertyElement(0), 1, 2] {
            var address = outputAddress(kAudioDevicePropertyVolumeScalar, element: element)
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            guard AudioObjectHasProperty(device, &address),
                AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr, value.isFinite
            else { continue }
            let level = min(1, max(0, Double(value)))
            if element == 0 { return [(element, level)] }
            result.append((element, level))
        }
        return result
    }
}
#endif
