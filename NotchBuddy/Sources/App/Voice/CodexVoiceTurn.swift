#if !APPSTORE
import Foundation
import CoreFoundation

/// The model proposes only Coucou's existing actions; it never receives native tools.
enum CodexVoiceTurn {
    static func schema(tools: [[String: Any]]) -> [String: Any] {
        ["type": "object", "additionalProperties": false,
         "properties": [
            "text": ["type": "string"],
            "calls": ["type": "array", "maxItems": 8, "items": [
                "type": "object", "additionalProperties": false,
                "properties": ["name": ["type": "string", "enum": tools.compactMap {
                    $0["input_schema"] == nil ? nil : $0["name"] as? String
                }], "arguments": ["type": "string", "description": "JSON object matching the named Coucou tool's input_schema"]],
                "required": ["name", "arguments"]]]],
         "required": ["text", "calls"]]
    }

    static func parse(_ text: String, tools: [[String: Any]]) -> (content: [[String: Any]], stopReason: String)? {
        guard text.utf8.count <= 65_536, let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(value.keys) == ["text", "calls"], let spoken = value["text"] as? String,
              let calls = value["calls"] as? [[String: Any]], calls.count <= 8 else { return nil }
        var content: [[String: Any]] = spoken.isEmpty ? [] : [["type": "text", "text": spoken]]
        for call in calls {
            guard Set(call.keys) == ["name", "arguments"], let name = call["name"] as? String,
                  let tool = tools.first(where: { $0["name"] as? String == name }),
                  let schema = tool["input_schema"] as? [String: Any],
                  let arguments = call["arguments"] as? String,
                  let bytes = arguments.data(using: .utf8),
                  let input = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  valid(input, schema: schema) else { return nil }
            content.append(["type": "tool_use", "id": UUID().uuidString, "name": name, "input": input])
        }
        guard !content.isEmpty else { return nil }
        return (content, calls.isEmpty ? "end_turn" : "tool_use")
    }

    /// Validate the small schema subset used by the existing voice tools, failing closed.
    private static func valid(_ value: Any, schema: [String: Any]) -> Bool {
        if let choices = schema["enum"] as? [String],
           !((value as? String).map { choices.contains($0) } ?? false) { return false }
        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any],
                  let properties = schema["properties"] as? [String: [String: Any]],
                  Set(object.keys).isSubset(of: Set(properties.keys)),
                  (schema["required"] as? [String] ?? []).allSatisfy({ object[$0] != nil }) else { return false }
            return object.allSatisfy { valid($0.value, schema: properties[$0.key]!) }
        case "string": return (value as? String).map { $0.utf8.count <= 16_384 } ?? false
        case "integer":
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return false }
            return number.doubleValue.isFinite && number.doubleValue.rounded() == number.doubleValue
                && abs(number.doubleValue) <= 1_000_000
        case "boolean": return (value as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() } ?? false
        case "array":
            guard let array = value as? [Any], array.count <= 32,
                  let items = schema["items"] as? [String: Any] else { return false }
            return array.allSatisfy { valid($0, schema: items) }
        default: return false
        }
    }

    static func actionKey(name: String, input: [String: Any]) -> String? {
        guard let data = try? JSONSerialization.data(withJSONObject: input, options: .sortedKeys),
              let text = String(data: data, encoding: .utf8) else { return nil }
        return name + ":" + text
    }
}
#endif
