import Foundation

struct ClaudeHookTranslation: Sendable {
    let event: AgentEvent
    let projectName: String
    let cwd: String
}

enum ClaudeHookTranslator {
    static func translate(
        name: String,
        payload: [String: Any],
        timestamp: Date = Date()
    ) -> ClaudeHookTranslation? {
        let sessionID = payload["session_id"] as? String ?? "unknown"
        let cwd = payload["cwd"] as? String ?? ""
        let rawProjectName = URL(fileURLWithPath: cwd).lastPathComponent
        let projectName = aliasProjectName(
            rawProjectName.isEmpty ? "Session" : rawProjectName
        )
        let toolName = payload["tool_name"] as? String
        let toolInput = payload["tool_input"] as? [String: Any] ?? [:]
        let tool = toolName.map {
            AgentToolInfo(
                name: $0,
                summary: stepLabel(tool: $0, input: toolInput),
                input: jsonObject(toolInput)
            )
        }

        let kind: AgentEventKind
        let title: String?
        let detail: String?
        var approval: AgentApprovalRequest?

        switch name {
        case "SessionStart":
            kind = .sessionStarted
            title = projectName
            detail = nil
        case "UserPromptSubmit":
            kind = .userPrompt
            title = truncated(payload["prompt"] as? String, length: 60)
            detail = nil
        case "PreToolUse":
            kind = .toolStarted
            title = tool?.summary
            detail = nil
        case "PostToolUse":
            kind = .toolCompleted
            title = tool?.summary
            detail = nil
        case "PostToolUseFailure":
            kind = .toolFailed
            title = "⚠ failed"
            detail = payload["error"] as? String
        case "Notification":
            let message = payload["message"] as? String ?? ""
            let lower = message.lowercased()
            if lower.contains("rate limit") || lower.contains("limite d") {
                kind = .rateLimited
            } else if message.hasSuffix("?") {
                kind = .userInputRequested
            } else {
                kind = .providerSpecific(name: "notification")
            }
            title = message.isEmpty ? nil : message
            detail = nil
        case "Stop":
            kind = .completed
            title = truncated(payload["message"] as? String, length: 60)
            detail = nil
        case "StopFailure":
            kind = .error
            title = truncated(payload["message"] as? String, length: 60)
            detail = payload["error"] as? String
        case "SessionEnd":
            kind = .sessionEnded
            title = nil
            detail = nil
        case "SubagentStart":
            kind = .subagentStarted
            title = "+ subagent"
            detail = nil
        case "SubagentStop":
            kind = .subagentCompleted
            title = "• subagent done"
            detail = nil
        case "PermissionRequest":
            let name = toolName ?? "Tool"
            let command = toolInput["command"] as? String ?? name
            kind = .approvalRequested
            title = name
            detail = command
            approval = AgentApprovalRequest(
                id: payload["request_id"] as? String ?? UUID().uuidString,
                title: name,
                detail: command,
                tool: tool,
                choices: [.allow, .allowForSession, .deny]
            )
        default:
            return nil
        }

        var metadata: [String: JSONValue] = [
            "projectName": .string(projectName),
            "cwd": .string(cwd),
            "nativeEventName": .string(name),
        ]
        if let terminal = payload["term_program"] as? String, !terminal.isEmpty {
            metadata["terminal"] = .string(terminal)
        }
        if let nativeID = nativeEventID(in: payload) {
            metadata["nativeEventID"] = .string("\(name):\(nativeID)")
        }

        return ClaudeHookTranslation(
            event: AgentEvent(
                id: UUID(),
                runtime: .claudeCode,
                provider: .anthropic,
                sessionID: sessionID,
                timestamp: timestamp,
                kind: kind,
                title: title,
                detail: detail,
                tool: tool,
                approval: approval,
                userInput: nil,
                metadata: metadata
            ),
            projectName: projectName,
            cwd: cwd
        )
    }

    private static func aliasProjectName(_ name: String) -> String {
        let aliases = [
            "notch-buddy": "Notch Buddy",
            "notchbuddy": "Notch Buddy",
            "notch_buddy": "Notch Buddy",
        ]
        return aliases[name.lowercased()] ?? name
    }

    private static func nativeEventID(in payload: [String: Any]) -> String? {
        for key in ["event_id", "request_id", "tool_use_id"] {
            if let value = payload[key] as? String, !value.isEmpty { return value }
        }
        return nil
    }

    private static func stepLabel(tool: String, input: [String: Any]) -> String {
        let labels = [
            "Bash": "Exécute",
            "Read": "Lit",
            "Write": "Écrit",
            "Edit": "Modifie",
            "Glob": "Cherche",
            "Grep": "Recherche",
            "WebSearch": "Recherche web",
            "WebFetch": "Récupère",
            "TodoWrite": "Tâches",
            "Task": "Agent",
            "LS": "Liste",
            "MultiEdit": "Modifie",
            "NotebookEdit": "Notebook",
        ]
        let label = labels[tool] ?? tool
        if let command = input["command"] as? String {
            return "\(label) · \(command.prefix(40))"
        }
        if let path = input["path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: path).lastPathComponent)"
        }
        if let file = input["file_path"] as? String {
            return "\(label) · \(URL(fileURLWithPath: file).lastPathComponent)"
        }
        if let query = input["query"] as? String {
            return "\(label) · \(query.prefix(40))"
        }
        return label
    }

    private static func truncated(_ value: String?, length: Int) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return String(value.prefix(length))
    }

    private static func jsonObject(_ value: [String: Any]) -> [String: JSONValue] {
        value.reduce(into: [:]) { result, item in
            if let converted = jsonValue(item.value) {
                result[item.key] = converted
            }
        }
    }

    private static func jsonValue(_ value: Any) -> JSONValue? {
        switch value {
        case let value as String: return .string(value)
        case let value as Bool: return .bool(value)
        case let value as NSNumber: return .number(value.doubleValue)
        case let value as [String: Any]: return .object(jsonObject(value))
        case let value as [Any]:
            return .array(value.compactMap(jsonValue))
        case is NSNull: return .null
        default: return nil
        }
    }
}
