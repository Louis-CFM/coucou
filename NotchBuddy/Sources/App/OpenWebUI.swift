import Foundation

// Chat through Open WebUI, so the conversation also lands in its chat history.
//
// The chat is created in Open WebUI first; every turn then goes to its
// completion endpoint with that chat's id, and Open WebUI stores the question
// and the answer itself, the same way its own page does. The model's context
// comes from that stored history, so only the new question is sent.
//
// The address the user connected is the only place this talks to, and the key
// only ever goes there. Same behaviour as windows/src-tauri/src/open_webui.rs.
// Foundation only, so tests/OpenWebUITests.swift can compile it alone.

enum OpenWebUI {

    /// Keychain entry of the API key, stored with the address it was entered for.
    static let keychainKey = "open-webui-key"

    enum Group: String, Sendable { case used, custom }

    struct Model: Sendable, Equatable {
        let id: String
        let label: String
        var group: Group?
    }

    /// The chat Open WebUI keeps this conversation in, and its latest message.
    struct Thread: Sendable, Equatable {
        let id: String
        var last: String?
    }

    /// The chat was deleted in Open WebUI: the next turn starts a new one.
    struct ChatGone: Error {}

    /// A request the server answered with an error.
    struct Failure: LocalizedError {
        let status: Int
        let message: String
        var errorDescription: String? { message }
    }

    private static let answerTimeout: TimeInterval = 300
    private static let quickTimeout: TimeInterval = 15
    /// A model set to stream in Open WebUI answers into the chat, not the
    /// request: the stored chat is read once a second until the answer is done.
    private static let pollRounds = 300
    /// How many of the most used models lead the picker.
    static let mostUsed = 8
    /// "Most used" counts the messages of this many days.
    static let usageDays = 90

    // MARK: Key bound to its address

    /// A key is only sent over https, or to a server on this Mac.
    static func mayCarryKey(_ url: String) -> Bool {
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return false }
        if u.scheme == "https" { return true }
        return u.scheme == "http" && isLoopback(host)
    }

    /// This Mac, parsed as an address rather than matched as text: "127.evil.example" is not.
    /// Same rule as net.rs is_loopback_host.
    static func isLoopback(_ host: String) -> Bool {
        let h = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        if h == "localhost" || h.hasSuffix(".localhost") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, h, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr)
            return ip >> 24 == 127 || ip == 0
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, h, &v6) == 1 else { return false }
        let b = withUnsafeBytes(of: &v6) { Array($0) }
        let zeros = b[0..<15].allSatisfy { $0 == 0 }
        let mapped = b[0..<10].allSatisfy { $0 == 0 } && b[10] == 0xFF && b[11] == 0xFF
        return (zeros && (b[15] == 1 || b[15] == 0)) || (mapped && b[12] == 127)
    }

    /// What the keychain holds: the key and the address it was entered for.
    static func boundKey(_ key: String, url: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["url": url, "key": key], options: [.sortedKeys])) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// The stored key, only if it was entered for exactly this address.
    static func key(stored: String?, url: String) -> String? {
        guard let data = stored?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String],
              obj["url"] == url, let key = obj["key"], !key.isEmpty else { return nil }
        return key
    }

    // MARK: HTTP

    private static func call(_ base: String, _ path: String, key: String, timeout: TimeInterval, body: [String: Any]? = nil) async throws -> Any? {
        guard let url = URL(string: "\(base)/\(path)") else { throw LocalChatError.serverUnreachable(base) }
        var req = URLRequest(url: url, timeoutInterval: timeout)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw LocalChatError.serverUnreachable(base)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 || status == 403 {
            throw Failure(status: status, message: String(localized: "The server refused the key. Check it, then connect again."))
        }
        guard (200..<300).contains(status) else {
            throw Failure(status: status, message: errorDetail(data) ?? "HTTP \(status)")
        }
        // A streamed turn answers `null`: the answer is in the stored chat.
        if data.isEmpty { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            throw LocalChatError.serverUnreachable(base)
        }
        return json is NSNull ? nil : json
    }

    static func errorDetail(_ data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let detail = obj["detail"] as? String, !detail.isEmpty { return detail }
        if let message = (obj["error"] as? [String: Any])?["message"] as? String { return message }
        return obj["error"] as? String
    }

    // MARK: Models

    static func parseModels(_ json: Any?) -> [Model]? {
        guard let items = (json as? [String: Any])?["data"] as? [[String: Any]] else { return nil }
        return items.compactMap { m in
            guard let id = m["id"] as? String else { return nil }
            let name = (m["name"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? id
            // A model made in Open WebUI's workspace sits on a base model.
            let base = (m["info"] as? [String: Any])?["base_model_id"] as? String
            return Model(id: id, label: name, group: (base?.isEmpty == false) ? .custom : nil)
        }
    }

    /// Messages per model, from Open WebUI's analytics (admin keys only).
    static func parseUsage(_ json: Any?) -> [String: Int] {
        guard let items = (json as? [String: Any])?["models"] as? [[String: Any]] else { return [:] }
        var usage: [String: Int] = [:]
        for m in items {
            if let id = m["model_id"] as? String, let count = m["count"] as? Int { usage[id] = count }
        }
        return usage
    }

    /// The most used models first, then the workspace's own models, then the
    /// rest by name.
    static func rank(_ models: [Model], usage: [String: Int]) -> [Model] {
        var models = models
        let used = models.indices
            .compactMap { i -> (count: Int, index: Int)? in
                guard let n = usage[models[i].id], n > 0 else { return nil }
                return (n, i)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.index < $1.index }
            .prefix(mostUsed)
        for u in used { models[u.index].group = .used }

        func order(_ m: Model) -> (Int, Int, String) {
            switch m.group {
            case .used?:   return (0, -(usage[m.id] ?? 0), "")
            case .custom?: return (1, 0, m.label.lowercased())
            case nil:      return (2, 0, m.label.lowercased())
            }
        }
        return models.enumerated()
            .sorted { a, b in
                let (ka, kb) = (order(a.element), order(b.element))
                return ka != kb ? ka < kb : a.offset < b.offset
            }
            .map(\.element)
    }

    /// `GET /api/models`: the models this account may use.
    static func models(baseURL: String, key: String) async throws -> [Model] {
        guard let models = parseModels(try await call(baseURL, "api/models", key: key, timeout: quickTimeout)) else {
            throw LocalChatError.serverUnreachable(baseURL)
        }
        return models
    }

    /// The models for the picker, ranked; usage is skipped when the key may not read it.
    static func rankedModels(baseURL: String, key: String) async throws -> [Model] {
        let models = try await models(baseURL: baseURL, key: key)
        guard !models.isEmpty else {
            throw LocalChatError.serverError(String(localized: "Open WebUI has no models for this account."))
        }
        let since = Int(Date().timeIntervalSince1970) - usageDays * 24 * 3600
        let usage = parseUsage(try? await call(baseURL, "api/v1/analytics/models?start_date=\(since)", key: key, timeout: quickTimeout))
        return rank(models, usage: usage)
    }

    // MARK: Messages as Open WebUI stores them

    static func newID() -> String { UUID().uuidString.lowercased() }

    /// One message of the chat's history tree.
    static func node(id: String, parent: String?, role: String, content: String, model: String, at: Int) -> [String: Any] {
        var n: [String: Any] = [
            "id": id, "parentId": parent.map { $0 as Any } ?? NSNull(), "childrenIds": [String](),
            "role": role, "content": content, "timestamp": at,
        ]
        if role == "assistant" {
            n["model"] = model
            n["modelName"] = model
            n["modelIdx"] = 0
            n["done"] = true
        } else {
            n["models"] = [model]
        }
        return n
    }

    /// A new chat holding the turns another provider answered before, so Open
    /// WebUI's copy of the conversation is complete. Returns it with the id of
    /// its last message.
    static func newChat(history: [(role: String, content: String)], model: String, at: Int) -> (body: [String: Any], last: String?) {
        var messages: [String: [String: Any]] = [:]
        var list: [[String: Any]] = []
        var last: String?
        for turn in history {
            let id = newID()
            if let parentID = last, var parent = messages[parentID] {
                parent["childrenIds"] = (parent["childrenIds"] as? [String] ?? []) + [id]
                messages[parentID] = parent
            }
            messages[id] = node(id: id, parent: last, role: turn.role, content: turn.content, model: model, at: at)
            list.append(["id": id, "role": turn.role, "content": turn.content, "timestamp": at])
            last = id
        }
        let chat: [String: Any] = [
            "title": "New Chat",
            "models": [model],
            "history": ["messages": messages, "currentId": last.map { $0 as Any } ?? NSNull()],
            "messages": list,
            "tags": [String](),
            "timestamp": at * 1000,
        ]
        return (["chat": chat], last)
    }

    /// The turn: Open WebUI stores `user_message` under the last answer and its
    /// own answer under `answerID`, names the chat after a first exchange, and
    /// searches the web first when asked to. Its search only runs for a turn
    /// whose function calling is `legacy`.
    static func completion(model: String, system: String, thread: Thread, userID: String, answerID: String,
                           text: String, at: Int, webSearch: Bool, variables: [String: String]) -> [String: Any] {
        var body: [String: Any] = [
            "features": ["web_search": webSearch],
            "model": model,
            "stream": false,
            "chat_id": thread.id,
            "id": answerID,
            "parent_id": thread.last.map { $0 as Any } ?? NSNull(),
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": text],
            ],
            "user_message": node(id: userID, parent: thread.last, role: "user", content: text, model: model, at: at),
            "background_tasks": ["title_generation": thread.last == nil],
            "variables": templateVariables(variables),
        ]
        if webSearch { body["params"] = ["function_calling": "legacy"] }
        return body
    }

    /// Only `{{NAME}}` keys with short values go to the server.
    static func templateVariables(_ variables: [String: String]) -> [String: String] {
        variables.filter { key, value in
            guard key.count <= 40, key.hasPrefix("{{"), key.hasSuffix("}}"), value.count <= 100 else { return false }
            let name = key.dropFirst(2).dropLast(2)
            return !name.isEmpty && name.allSatisfy { ("A"..."Z").contains($0) || $0 == "_" }
        }
    }

    /// Local date, time and timezone as Open WebUI's page sends them with every
    /// message, for its filters and prompt templates.
    static func promptVariables(now: Date = Date(), timeZone: TimeZone = .current,
                                language: String = Locale.preferredLanguages.first ?? "en-US") -> [String: String] {
        let format = { (pattern: String) -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: now)
        }
        let date = format("yyyy-MM-dd")
        let time = format("HH:mm:ss")
        return [
            "{{CURRENT_DATETIME}}": "\(date) \(time)",
            "{{CURRENT_DATE}}": date,
            "{{CURRENT_TIME}}": time,
            "{{CURRENT_WEEKDAY}}": format("EEEE"),
            "{{CURRENT_TIMEZONE}}": timeZone.identifier,
            "{{USER_LANGUAGE}}": language,
        ]
    }

    static func answerInReply(_ json: Any?) -> String? {
        let choices = (json as? [String: Any])?["choices"] as? [[String: Any]]
        return (choices?.first?["message"] as? [String: Any])?["content"] as? String
    }

    private static func storedMessage(_ chat: Any?, _ answerID: String) -> [String: Any]? {
        let history = ((chat as? [String: Any])?["chat"] as? [String: Any])?["history"] as? [String: Any]
        return (history?["messages"] as? [String: Any])?[answerID] as? [String: Any]
    }

    /// The answer as the stored chat has it: its text, and whether it is finished.
    static func answerInChat(_ chat: Any?, _ answerID: String) -> (text: String, done: Bool)? {
        guard let m = storedMessage(chat, answerID) else { return nil }
        return (m["content"] as? String ?? "", m["done"] as? Bool ?? false)
    }

    /// What Open WebUI wrote on the answer when a filter or the model failed.
    static func errorInChat(_ chat: Any?, _ answerID: String) -> String? {
        guard let e = storedMessage(chat, answerID)?["error"] else { return nil }
        let text = ((e as? [String: Any])?["content"] as? String) ?? (e as? String)
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: A turn

    /// One question. `thread` is where Open WebUI keeps this conversation, nil
    /// for a new chat, which then gets `history` (the earlier turns) and is
    /// reported through `onThread` at once, so a retry lands in the same chat.
    static func send(
        baseURL: String, key: String, model: String, thread: Thread?,
        history: [(role: String, content: String)], text: String, system: String,
        variables: [String: String], webSearch: Bool,
        onThread: @MainActor @escaping (Thread) -> Void,
        onUpdate: @MainActor @escaping (String) -> Void
    ) async throws -> (answer: String, thread: Thread) {
        let at = Int(Date().timeIntervalSince1970)
        let current: Thread
        if let thread {
            current = thread
        } else {
            let (body, last) = newChat(history: history, model: model, at: at)
            let created = try await call(baseURL, "api/v1/chats/new", key: key, timeout: quickTimeout, body: body)
            guard let id = (created as? [String: Any])?["id"] as? String else { throw LocalChatError.serverUnreachable(baseURL) }
            current = Thread(id: id, last: last)
            await MainActor.run { onThread(current) }
        }

        let (userID, answerID) = (newID(), newID())
        let body = completion(model: model, system: system, thread: current, userID: userID, answerID: answerID,
                              text: text, at: at, webSearch: webSearch, variables: variables)
        let reply: Any?
        do {
            reply = try await call(baseURL, "api/chat/completions", key: key, timeout: answerTimeout, body: body)
        } catch let f as Failure where f.status == 404 {
            // A missing model is a 404 too: only a chat that is gone starts a new one.
            if await chatGone(baseURL, key: key, chatID: current.id) { throw ChatGone() }
            throw f
        }

        var answer = answerInReply(reply)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if answer.isEmpty {
            answer = try await waitForAnswer(baseURL, key: key, chatID: current.id, answerID: answerID, onUpdate: onUpdate)
        }
        answer = LocalChat.filterThinkingBlocks(answer)
        guard !answer.isEmpty else { throw LocalChatError.serverError(String(localized: "No response text.")) }
        return (answer, Thread(id: current.id, last: answerID))
    }

    private static func chatGone(_ base: String, key: String, chatID: String) async -> Bool {
        do {
            _ = try await call(base, "api/v1/chats/\(chatID)", key: key, timeout: quickTimeout)
            return false
        } catch let f as Failure {
            return f.status == 404 || f.status == 401
        } catch {
            return false
        }
    }

    /// Reads the stored chat until the answer is done, showing it as it grows.
    private static func waitForAnswer(_ base: String, key: String, chatID: String, answerID: String,
                                      onUpdate: @MainActor @escaping (String) -> Void) async throws -> String {
        for _ in 0..<pollRounds {
            try await Task.sleep(nanoseconds: 1_000_000_000)
            let stored = try await call(base, "api/v1/chats/\(chatID)", key: key, timeout: quickTimeout)
            guard let found = answerInChat(stored, answerID) else { continue }
            let visible = LocalChat.progressiveFilter(found.text)
            await MainActor.run { onUpdate(visible) }
            guard found.done else { continue }
            if found.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, let error = errorInChat(stored, answerID) {
                throw LocalChatError.serverError(error)
            }
            return found.text
        }
        throw LocalChatError.serverError(String(localized: "No response text."))
    }
}
