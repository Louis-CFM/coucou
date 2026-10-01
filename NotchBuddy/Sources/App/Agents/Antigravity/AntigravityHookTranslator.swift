import Foundation

struct AntigravityHookTranslation: Sendable {
    let event: AgentEvent
    let projectName: String
    let cwd: String
}

enum AntigravityHookTranslator {
    static func translate(payload: [String: Any], timestamp: Date = Date()) -> AntigravityHookTranslation? {
        guard let hookName = payload["hook_event_name"] as? String,
              !hookName.isEmpty,
              let conversationID = payload["conversationId"] as? String,
              !conversationID.isEmpty else {
            return nil
        }

        let workspacePaths = payload["workspacePaths"] as? [String] ?? []
        let cwd = workspacePaths.first ?? ""
        let folder = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = folder.isEmpty ? "Antigravity" : folder
        let toolCall = payload["toolCall"] as? [String: Any]
        let toolName = toolCall?["name"] as? String
        let toolInput = toolCall?["args"] as? [String: Any] ?? [:]
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
        case "PreInvocation":
            if (payload["invocationNum"] as? NSNumber)?.intValue == 0 {
                kind = .sessionStarted
                title = projectName
            } else {
                kind = .activityStarted
                title = "Thinking"
            }
            detail = nil
        case "PostInvocation":
            kind = .activityUpdated
            title = "Model responded"
            detail = nil
        case "PreToolUse":
            kind = .toolStarted
            title = tool?.summary ?? toolName
            detail = nil
        case "PostToolUse":
            if let error = nonEmptyString(payload["error"]) {
                kind = .toolFailed
                detail = truncated(error, length: 240)
            } else {
                kind = .toolCompleted
                detail = nil
            }
            title = tool?.summary ?? toolName
        case "Stop":
            let reason = nonEmptyString(payload["terminationReason"])
            let error = nonEmptyString(payload["error"])
            if error != nil || reason == "error" {
                kind = .error
                title = "Antigravity stopped with an error"
                detail = truncated(error ?? reason, length: 240)
            } else if payload["fullyIdle"] as? Bool == true {
                kind = .completed
                title = "Turn completed"
                detail = reason
            } else {
                kind = .activityCompleted
                title = "Execution paused"
                detail = reason
            }
        default:
            return nil
        }

        var metadata: [String: JSONValue] = [
            "cwd": .string(cwd),
            "projectName": .string(projectName),
            "antigravityHookName": .string(hookName),
            "nativePayloadVersion": .string("antigravity-hooks-v1"),
        ]
        if let modelName = nonEmptyString(payload["modelName"]) {
            metadata["modelName"] = .string(modelName)
        }
        if !workspacePaths.isEmpty {
            metadata["workspacePaths"] = .array(workspacePaths.map(JSONValue.string))
        }
        if let nativeToolName = toolName {
            metadata["nativeToolName"] = .string(nativeToolName)
        }
        if let nativeEventID = nativeEventID(hookName: hookName, payload: payload, toolName: toolName) {
            metadata["nativeEventID"] = .string(nativeEventID)
        }

        return AntigravityHookTranslation(
            event: AgentEvent(
                id: UUID(),
                runtime: .antigravity,
                provider: .google,
                sessionID: conversationID,
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

    private static func nativeEventID(
        hookName: String,
        payload: [String: Any],
        toolName: String?
    ) -> String? {
        for key in ["stepIdx", "invocationNum", "executionNum"] {
            if let number = payload[key] as? NSNumber {
                return [hookName, toolName, String(number.intValue)]
                    .compactMap { $0 }
                    .joined(separator: ":")
            }
        }
        return nil
    }

    private static func toolSummary(name: String, input: [String: Any]) -> String {
        for key in ["CommandLine", "TargetFile", "AbsolutePath", "DirectoryPath", "query", "Url"] {
            if let value = input[key] as? String, !value.isEmpty {
                return "\(name) · \(value.prefix(48))"
            }
        }
        return name
    }

    private static func nonEmptyString(_ value: Any?) -> String? {
        guard let value = value as? String, !value.isEmpty else { return nil }
        return value
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
