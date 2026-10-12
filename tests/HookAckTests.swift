import Foundation

@main
enum HookAckTests {
    static func main() throws {
        func payload(_ json: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
        }
        precondition(HookAck.wanted(try payload(#"{"hook_event_name":"PermissionRequest","coucou_ack":1}"#)))
        // A relay written before the ack existed never asks, and gets no line it would take for an answer.
        precondition(!HookAck.wanted(try payload(#"{"hook_event_name":"PermissionRequest"}"#)))
        precondition(!HookAck.wanted(try payload(#"{"coucou_ack":"1"}"#)))
        precondition(!HookAck.wanted(try payload(#"{"coucou_ack":0}"#)))
        precondition(HookAck.line == #"{"ack":true}"#)
        print("HookAck tests passed")
    }
}
