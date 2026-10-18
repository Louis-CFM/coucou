import Foundation

@main struct ProtocolTests {
    static func main() throws {
        var decoder = BridgeLineDecoder()
        let bytes = Data(
            "{\"type\":\"snapshot\",\"active\":false}\n{\"type\":\"command\",\"message\":\"Canción 🎵\"}\n".utf8)
        var output: [BridgeEvent] = []
        for byte in bytes { output += try decoder.append(Data([byte])) }
        precondition(output.count == 2 && output[1].message == "Canción 🎵")
        try decoder.finish()
        // A real active event, including artwork followed by metadata-only updates.
        let active: [String: Any] = [
            "type": "snapshot", "active": true, "pid": 123,
            "source": "Chrome", "bundleIdentifier": "com.google.Chrome", "title": "Canción 🎵", "artist": "Canal",
            "duration": 210,
            "position": 42, "timestamp": 1_792_240_000, "rate": 1, "playing": true,
            "identity": "track-1", "artworkRevision": 1, "artwork": "aGVsbG8=",
        ]
        var initial = try JSONSerialization.data(withJSONObject: active)
        initial.append(10)
        var next = active
        next.removeValue(forKey: "artwork")
        next["position"] = 45
        var update = try JSONSerialization.data(withJSONObject: next)
        update.append(10)
        let events = try decoder.append(initial + update)
        precondition(events.count == 2 && events[0].artwork != nil && events[1].artwork == nil)
        precondition(events[0].artworkRevision == events[1].artworkRevision)
        for field in ["duration", "position"] {
            var hostile = active
            hostile[field] = 1e300
            do {
                var invalid = BridgeLineDecoder()
                var line = try JSONSerialization.data(withJSONObject: hostile)
                line.append(10)
                _ = try invalid.append(line)
                preconditionFailure("Unbounded time accepted")
            } catch BridgeProtocolError.invalid {}
        }
        // Source identity is dynamic; dedicated music apps must never duplicate their cards.
        for (source, bundle) in [
            ("Safari", "com.apple.Safari"), ("Firefox", "org.mozilla.firefox"), ("VLC", "org.videolan.vlc"),
        ] {
            var state = active
            state["source"] = source
            state["bundleIdentifier"] = bundle
            let event = try JSONDecoder().decode(BridgeEvent.self, from: JSONSerialization.data(withJSONObject: state))
            try event.validate()
            precondition(PlaybackSnapshot(event)?.bundleIdentifier == bundle)
        }
        for bundle in ["com.apple.Music", "com.spotify.client", ""] {
            var state = active
            state["bundleIdentifier"] = bundle
            let event = try JSONDecoder().decode(BridgeEvent.self, from: JSONSerialization.data(withJSONObject: state))
            do {
                try event.validate()
                preconditionFailure("Excluded player accepted")
            } catch BridgeProtocolError.invalid {}
        }
        let baseline = PlaybackSnapshot(events[0])!
        let ordinaryProgress = PlaybackSnapshot(events[1])!
        precondition(!ordinaryProgress.confirmsNavigation(from: baseline, command: "next"))
        precondition(!ordinaryProgress.confirmsNavigation(from: baseline, command: "previous"))
        func track(_ identity: String, position: Double, pid: Int = 123, bundle: String = "com.google.Chrome") throws
            -> PlaybackSnapshot
        {
            var state = active
            state["identity"] = identity
            state["position"] = position
            state["pid"] = pid
            state["bundleIdentifier"] = bundle
            state["canPrevious"] = false
            state["canNext"] = true
            state["canSeek"] = true
            let decoded = try JSONDecoder().decode(
                BridgeEvent.self, from: JSONSerialization.data(withJSONObject: state))
            try decoded.validate()
            return PlaybackSnapshot(decoded)!
        }
        let nextTrack = try track("track-2", position: 0)
        precondition(nextTrack.confirmsNavigation(from: baseline, command: "next"))
        precondition(nextTrack.canNext && !nextTrack.canPrevious && nextTrack.canSeek)
        let restarted = try track("track-1", position: 0)
        precondition(restarted.confirmsNavigation(from: baseline, command: "previous"))
        precondition(!restarted.confirmsNavigation(from: baseline, command: "next"))
        let changedPlayer = try track("track-2", position: 0, pid: 456)
        precondition(!changedPlayer.confirmsNavigation(from: baseline, command: "next"))
        let reusedPID = try track("track-2", position: 0, bundle: "com.apple.Safari")
        precondition(!reusedPID.confirmsNavigation(from: baseline, command: "next"))
        precondition(!baseline.canPrevious && !baseline.canNext && !baseline.canSeek)
        var rejected = 0
        for payload in [
            "{\"type\":\"unexpected\"}\n", "{\"type\":\"snapshot\",\"active\":true}\n",
            "{\"type\":\"snapshot\",\"duration\":-1}\n", "not json\n",
        ] {
            do {
                var invalid = BridgeLineDecoder()
                _ = try invalid.append(Data(payload.utf8))
            } catch { rejected += 1 }
        }
        precondition(rejected == 4)
        do {
            var invalid = BridgeLineDecoder()
            _ = try invalid.append(Data(repeating: 65, count: BridgeLineDecoder.limit + 1))
            preconditionFailure("Oversize accepted")
        } catch BridgeProtocolError.oversized {}
        do {
            var invalid = BridgeLineDecoder()
            _ = try invalid.append(Data("{\"type\":\"ready\"}".utf8))
            try invalid.finish()
            preconditionFailure("Truncation accepted")
        } catch BridgeProtocolError.truncated {}
        print("Protocol checks passed: split UTF-8, split lines, multiple events, validation, bounds, truncation.")
    }
}
