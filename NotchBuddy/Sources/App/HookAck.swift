import Foundation

// The relay asks the app to confirm that a held request is on screen: its
// payload carries "coucou_ack": 1, and without the line {"ack":true} within
// 1.5 s it lets the agent ask in its own terminal. A relay written before this
// existed (an App Store nb-hook.py from an older build) never asks, and gets
// no ack line it would mistake for an answer.
enum HookAck {
    static let line = #"{"ack":true}"#

    static func wanted(_ payload: [String: Any]) -> Bool {
        (payload["coucou_ack"] as? NSNumber)?.intValue == 1
    }
}
