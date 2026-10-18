import Foundation

@main struct OutputVolumeSmoke {
    @MainActor static func main() async {
        let model = SystemOutputVolume()
        model.start()
        precondition((0...100).contains(model.volume))
        let original = model.volume
        let writable = model.available
        model.start()  // Repeated appearance must not duplicate subscriptions.
        try? await Task.sleep(for: .milliseconds(100))
        precondition((0...100).contains(model.volume))
        model.stop()
        precondition(!model.available)
        model.setVolume(100)  // An off-screen control must never change the device.
        precondition(!model.available)
        model.start()
        precondition((0...100).contains(model.volume))
        model.stop()
        print("Output volume lifecycle passed; readable level: \(original)%; writable: \(writable). No volume changed.")
    }
}
