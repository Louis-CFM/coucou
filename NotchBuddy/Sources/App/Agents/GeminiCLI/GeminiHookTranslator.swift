import Foundation

struct GeminiHookTranslation: Sendable {
    let event: AgentEvent
    let projectName: String
    let cwd: String
}

enum GeminiHookTranslator {
    static func translate(payload: [String: Any], timestamp: Date = Date()) -> GeminiHookTranslation? {
        guard let hookName = payload["hook_event_name"] as? String, !hookName.isEmpty else {
            return nil
        }
        let sessionID = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = folder.isEmpty ? "Gemini session" : folder
        let toolName = payload["tool_name"] as? String
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let tool = toolName.map {
            AgentToolInfo(
                name: $0,
                summary: toolSummary(name: $0, input: toolInput),
                input: jsonObject(toolInput)
            )
        }

        let kind: AgentEventKind
        let title: String?
        let detail: String?
        switch hookName {
        case "SessionStart":
            kind = payload["source"] as? String == "resume" ? .sessionResumed : .sessionStarted
            title = projectName
            detail = payload["source"] as? String
        case "SessionEnd":
            kind = .sessionEnded
            title = nil
            detail = payload["reason"] as? String
        case "BeforeAgent":
            kind = .userPrompt
            title = truncated(payload["prompt"] as? String, length: 80)
            detail = nil
        case "AfterAgent":
            kind = .activityCompleted
            title = "Turn completed"
            detail = truncated(payload["prompt_response"] as? String, length: 160)
        case "BeforeTool":
            kind = .toolStarted
            title = tool?.summary ?? toolName
            detail = nil
        case "AfterTool":
            let response = payload["tool_response"] as? [String: Any]
            if response?["error"] != nil {
                kind = .toolFailed
                detail = String(describing: response?["error"] ?? "Tool failed")
            } else {
                kind = .toolCompleted
                detail = nil
            }
            title = tool?.summary ?? toolName
        case "Notification":
            kind = .warning
            title = (payload["message"] as? String)
                ?? (payload["notification_type"] as? String)
                ?? "Gemini CLI notification"
            detail = nil
        case "BeforeModel", "AfterModel", "BeforeToolSelection", "PreCompress":
            kind = .providerSpecific(name: hookName)
            title = nil
            detail = nil
        default:
            return nil
        }

        var metadata: [String: JSONValue] = [
            "cwd": .string(cwd),
            "projectName": .string(projectName),
            "geminiHookName": .string(hookName),
            "nativePayloadVersion": .string("hooks-v1"),
        ]
        if let nativeToolName = toolName {
            metadata["nativeToolName"] = .string(nativeToolName)
        }
        if let nativeTimestamp = payload["timestamp"] as? String {
            metadata["nativeTimestamp"] = .string(nativeTimestamp)
            metadata["nativeEventID"] = .string("\(hookName):\(nativeTimestamp)")
        }

        return GeminiHookTranslation(
            event: AgentEvent(
                id: UUID(),
                runtime: .geminiCLI,
                provider: .google,
                sessionID: sessionID,
                timestamp: timestamp,
                kind: kind,
                title: title,
                detail: detail,
                tool: tool,
                approval: nil,
                userInput: nil,
                metadata: metadata
            ),
            projectName: projectName,
            cwd: cwd
        )
    }

    private static func toolSummary(name: String, input: [String: Any]) -> String {
        for key in ["command", "path", "file_path", "query"] {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(name) · \(value.prefix(48))"
            }
        }
        return name
    }

    private static func truncated(_ value: String?, length: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(length))
    }

    private static func jsonObject(_ value: [String: Any]) -> [String: JSONValue] {
        value.reduce(into: [:]) { result, item in
            if let converted = jsonValue(item.value) { result[item.key] = converted }
        }
    }

    private static func jsonValue(_ value: Any) -> JSONValue? {
        switch value {
        case let value as String: .string(value)
        case let value as Bool: .bool(value)
        case let value as NSNumber: .number(value.doubleValue)
        case let value as [String: Any]: .object(jsonObject(value))
        case let value as [Any]: .array(value.compactMap(jsonValue))
        case is NSNull: .null
        default: nil
        }
    }
}
