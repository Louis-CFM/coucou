#if !APPSTORE
import AVFoundation
import Speech

// MARK: - VoiceSettings

/// Persisted voice feature settings and permission helpers.
enum VoiceSettings {
    static let enabledKey = "voiceEnabled"

    static var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: enabledKey) }
        set { UserDefaults.standard.set(newValue, forKey: enabledKey) }
    }

    // MARK: - Permissions

    enum PermissionStatus { case granted, denied, undetermined }

    static var micStatus: PermissionStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    static var speechStatus: PermissionStatus {
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized:              return .granted
        case .denied, .restricted:     return .denied
        case .notDetermined:           return .undetermined
        @unknown default:              return .undetermined
        }
    }

    /// Request microphone then speech recognition. Returns true if both granted.
    @MainActor
    static func requestPermissions() async -> Bool {
        let mic = await AVAudioApplication.requestRecordPermission()
        guard mic else { return false }
        return await withCheckedContinuation { cont in
            SFSpeechRecognizer.requestAuthorization { status in
                cont.resume(returning: status == .authorized)
            }
        }
    }
}
#endif
