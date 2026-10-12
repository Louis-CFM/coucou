import Foundation

@main
enum CallSensorsTests {
    static func main() {
        let own = "fr.louisraille.NotchBuddy"
        let line = "2026-10-12 11:09:39.123 Df ControlCenter[898:c13c7] [com.apple.controlcenter:sensor-indicators] Active activity attributions changed to "
        // Another line of the same category is not an update.
        precondition(CallSensors.parse(line.replacingOccurrences(of: "Active", with: "Recent") + "[]", own: own) == nil)
        // Nothing held.
        precondition(CallSensors.parse(line + "[]", own: own) == [])
        // Photo Booth: the camera.
        precondition(CallSensors.parse(line + "[\"cam:com.apple.PhotoBooth\"]", own: own) == ["cam"])
        // A recorder on the screen alone is not a call.
        precondition(CallSensors.parse(line + "[\"scr:teleportlabs.com.Dayflow\"]", own: own) == [])
        // A browser on a call sharing its screen, the recorder still beside it.
        let meet = "[\"scr:com.brave.Browser\", \"cam:com.brave.Browser\", \"scr:teleportlabs.com.Dayflow\", \"mic:com.brave.Browser\"]"
        precondition(CallSensors.parse(line + meet, own: own) == ["cam", "mic", "scr"])
        // Coucou's own voice listening does not count.
        precondition(CallSensors.parse(line + "[\"mic:\(own)\", \"aud:\(own)\"]", own: own) == [])
        print("Call sensors: 6 cases passed")
    }
}
