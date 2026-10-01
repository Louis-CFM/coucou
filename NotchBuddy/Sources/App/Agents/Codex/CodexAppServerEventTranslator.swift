import Foundation

enum CodexAppServerEventTranslator {
    static func translate(
        _ message: [String: Any],
        fallbackTimestamp: Date = Date(),
        sequence: UInt64? = nil
    ) -> AgentEvent? {
        guard let method = message["method"] as? String,
              let params = message["params"] as? [String: Any] else {
            return nil
        }
        let sessionID = params["threadId"] as? String
            ?? string(in: params, path: ["thread", "id"])
        guard let sessionID else {
            return nil
        }

        let timestamp = timestamp(from: params) ?? fallbackTimestamp
        var metadata = jsonObject(params)
        metadata["nativeMethod"] = .string(method)
        if let nativeID = nativeEventID(message: message, params: params) {
            metadata["nativeEventID"] = .string("\(method):\(nativeID)")
        }

        let kind: AgentEventKind
        var title: String?
        var detail: String?
        var tool: AgentToolInfo?
        var approval: AgentApprovalRequest?
        var userInput: AgentUserInputRequest?

        switch method {
        case "thread/started":
            kind = .sessionStarted
            title = string(in: params, path: ["thread", "name"])
        case "thread/status/changed":
            let status = string(in: params, path: ["status", "type"]) ?? "unknown"
            switch status {
            case "active": kind = .activityStarted
            case "idle": kind = .activityCompleted
            case "systemError": kind = .error
            case "notLoaded": kind = .sessionEnded
            default: kind = .providerSpecific(name: "thread-status-\(status)")
            }
            title = "Codex · \(status)"
        case "turn/started":
            kind = .activityStarted
            title = "Codex is working"
        case "turn/completed":
            let status = string(in: params, path: ["turn", "status"]) ?? "unknown"
            switch status {
            case "completed": kind = .completed
            case "failed": kind = .error
            case "interrupted": kind = .cancelled
            default: kind = .providerSpecific(name: "turn-completed-\(status)")
            }
            detail = string(in: params, path: ["turn", "error", "message"])
        case "item/started", "item/completed":
            guard let item = params["item"] as? [String: Any],
                  let itemType = item["type"] as? String else {
                return nil
            }
            let completed = method == "item/completed"
            let status = item["status"] as? String
            switch itemType {
            case "commandExecution":
                kind = completed
                    ? (status == "failed" ? .commandFailed : .commandCompleted)
                    : .commandStarted
                title = item["command"] as? String
                tool = AgentToolInfo(
                    name: "command",
                    summary: title,
                    input: jsonObject(item)
                )
            case "fileChange":
                kind = completed ? .activityCompleted : .fileChanged
                title = "File changes"
                tool = AgentToolInfo(
                    name: "fileChange",
                    summary: title,
                    input: jsonObject(item)
                )
            case "mcpToolCall", "dynamicToolCall":
                kind = completed
                    ? (status == "failed" ? .toolFailed : .toolCompleted)
                    : .toolStarted
                title = item["tool"] as? String ?? item["name"] as? String
                tool = AgentToolInfo(
                    name: title ?? itemType,
                    summary: title,
                    input: jsonObject(item)
                )
            default:
                kind = .providerSpecific(name: "\(method):\(itemType)")
                title = item["text"] as? String
            }
        case "item/commandExecution/requestApproval":
            kind = .approvalRequested
            let command = params["command"] as? String
            let reason = params["reason"] as? String
            let network = params["networkApprovalContext"] as? [String: Any]
            title = network == nil ? "Run command" : "Access network"
            detail = network?["host"] as? String ?? command ?? reason
            tool = AgentToolInfo(
                name: "command",
                summary: command,
                input: jsonObject(params)
            )
            approval = approvalRequest(
                message: message,
                params: params,
                title: title ?? "Run command",
                detail: detail,
                tool: tool
            )
        case "item/fileChange/requestApproval":
            kind = .approvalRequested
            title = "Apply file changes"
            detail = params["reason"] as? String ?? params["grantRoot"] as? String
            tool = AgentToolInfo(
                name: "fileChange",
                summary: detail,
                input: jsonObject(params)
            )
            approval = approvalRequest(
                message: message,
                params: params,
                title: title ?? "Apply file changes",
                detail: detail,
                tool: tool
            )
        case "item/tool/requestUserInput":
            kind = .userInputRequested
            userInput = userInputRequest(message: message, params: params)
            title = userInput?.questions.first?.question ?? "Codex needs input"
            detail = userInput?.questions.first?.header
        case "serverRequest/resolved":
            kind = .approvalResolved
            title = nil
        case "error":
            kind = .error
            title = string(in: params, path: ["error", "message"])
        default:
            return nil
        }

        return AgentEvent(
            id: UUID(),
            sequence: sequence,
            runtime: .codex,
            provider: .openAI,
            sessionID: sessionID,
            timestamp: timestamp,
            kind: kind,
            title: title,
            detail: detail,
            tool: tool,
            approval: approval,
            userInput: userInput,
            metadata: metadata
        )
    }

    private static func userInputRequest(
        message: [String: Any],
        params: [String: Any]
    ) -> AgentUserInputRequest? {
        guard let nativeQuestions = params["questions"] as? [[String: Any]] else {
            return nil
        }
        let questions = nativeQuestions.compactMap { value -> AgentUserInputQuestion? in
            guard let id = value["id"] as? String,
                  let header = value["header"] as? String,
                  let question = value["question"] as? String else {
                return nil
            }
            let options = (value["options"] as? [[String: Any]] ?? []).compactMap { option -> AgentUserInputOption? in
                guard let label = option["label"] as? String,
                      let description = option["description"] as? String else {
                    return nil
                }
                return AgentUserInputOption(label: label, description: description)
            }
            return AgentUserInputQuestion(
                id: id,
                header: header,
                question: question,
                options: options,
                allowsOther: value["isOther"] as? Bool ?? false,
                isSecret: value["isSecret"] as? Bool ?? false
            )
        }
        guard !questions.isEmpty else { return nil }
        return AgentUserInputRequest(
            id: requestID(message: message, params: params),
            itemID: params["itemId"] as? String ?? "",
            questions: questions,
            isBlocking: params["isBlocking"] as? Bool ?? true
        )
    }

    private static func approvalRequest(
        message: [String: Any],
        params: [String: Any],
        title: String,
        detail: String?,
        tool: AgentToolInfo?
    ) -> AgentApprovalRequest {
        let requestID = requestID(message: message, params: params)
        return AgentApprovalRequest(
            id: requestID,
            title: title,
            detail: detail,
            tool: tool,
            choices: availableChoices(in: params)
        )
    }

    private static func requestID(
        message: [String: Any],
        params: [String: Any]
    ) -> String {
        if let id = message["id"] as? String {
            return id
        } else if let id = message["id"] as? NSNumber {
            return id.stringValue
        }
        return params["itemId"] as? String ?? UUID().uuidString
    }

    private static func nativeEventID(
        message: [String: Any],
        params: [String: Any]
    ) -> String? {
        for value in [
            message["id"],
            params["requestId"],
            params["itemId"],
            (params["item"] as? [String: Any])?["id"],
            (params["turn"] as? [String: Any])?["id"],
        ] {
            if let value = value as? String { return value }
            if let value = value as? NSNumber { return value.stringValue }
        }
        return nil
    }

    private static func availableChoices(in params: [String: Any]) -> [ApprovalDecision] {
        guard let native = params["availableDecisions"] as? [Any] else {
            return [.allow, .allowForSession, .deny]
        }
        let choices = native.compactMap { value -> ApprovalDecision? in
            guard let value = value as? String else { return nil }
            switch value {
            case "accept": return .allow
            case "acceptForSession": return .allowForSession
            case "decline", "cancel": return .deny
            default: return nil
            }
        }
        return choices.isEmpty ? [.allow, .deny] : Array(Set(choices)).sorted {
            approvalOrder($0) < approvalOrder($1)
        }
    }

    private static func approvalOrder(_ decision: ApprovalDecision) -> Int {
        switch decision {
        case .allow: 0
        case .allowForSession: 1
        case .deny: 2
        }
    }

    private static func timestamp(from params: [String: Any]) -> Date? {
        guard let milliseconds = params["startedAtMs"] as? NSNumber else {
            return nil
        }
        return Date(timeIntervalSince1970: milliseconds.doubleValue / 1_000)
    }

    private static func string(
        in object: [String: Any],
        path: [String]
    ) -> String? {
        var value: Any = object
        for key in path {
            guard let dictionary = value as? [String: Any],
                  let next = dictionary[key] else {
                return nil
            }
            value = next
        }
        return value as? String
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
        case let value as [Any]: return .array(value.compactMap(jsonValue))
        case is NSNull: return .null
        default: return nil
        }
    }
}
