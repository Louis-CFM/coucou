#if !APPSTORE
import Foundation
import AppKit
import PDFKit
import Combine

enum CodexAuthenticationStatus {
    case disconnected, checking, signingIn, connected, unknown

    var label: String {
        switch self {
        case .disconnected: String(localized: "codex.auth.disconnected", defaultValue: "Not connected")
        case .checking: String(localized: "codex.auth.checking", defaultValue: "Checking connection…")
        case .signingIn: String(localized: "codex.auth.signing-in", defaultValue: "Waiting for ChatGPT sign-in…")
        case .connected: String(localized: "codex.auth.connected", defaultValue: "Connected")
        case .unknown: String(localized: "codex.auth.unknown", defaultValue: "Unable to confirm connection")
        }
    }

    var connected: Bool? {
        switch self {
        case .connected: true
        case .disconnected: false
        default: nil
        }
    }
}

/// Owns Coucou-created threads only. It never resumes a CLI or IDE thread.
@MainActor
final class CodexChatService: ObservableObject {
    static let shared = CodexChatService()
    @Published private(set) var authenticationStatus = CodexAuthenticationStatus.disconnected
    private let connection: CodexConnection
    private var observer: UUID?
    private var lease: UUID?
    private(set) var threadId: String?
    private(set) var turnId: String?
    private(set) var isBusy = false
    private var project = ""
    private var model = ""
    private var resolvedModel = ""
    private var canWrite = false
    private var searchMode = "cached"
    private var revision = UUID()
    private var modalities: [String: Set<String>] = [:]
    private var completion: CheckedContinuation<String, Error>?
    private var completed: Result<String, Error>?
    private var deadline: Task<Void, Never>?
    private var messageOrder: [String] = []
    private var messages: [String: String] = [:]
    private var messageBytes = 0
    private weak var displayState: AppState?
    private var displayMessage: UUID?
    private var temporaryFiles: [URL] = []
    private var attachmentNotice: String?
    private var loginId: String?
    private var loginAttempt: UUID?
    private var completedLogin: Result<Void, Error>?
    private var earlyLoginResults: [String: Result<Void, Error>] = [:]
    private var loginCompletion: CheckedContinuation<Void, Error>?
    private var loginDeadline: Task<Void, Never>?
    private var authenticationGeneration = UUID()
    private var authenticationRefresh: UUID?
    private var explicitlyDisconnected = false
    private enum AttachmentContext: Sendable {
        case window(app: String, title: String, url: String?)
        case file(name: String, url: URL?)
    }
    private struct PreparedInput: Sendable {
        let data: Data
        let files: [URL]
        let notice: String?
    }

    init(connection: CodexConnection = .shared) { self.connection = connection }

    private func installObserver() {
        guard observer == nil else { return }
        observer = connection.observe { [weak self] method, params, _ in self?.receive(method, params: params) }
    }

    func owns(threadId: String) -> Bool { connection.isConnected && self.threadId == threadId }
    func allowsProjectWrites(threadId: String) -> Bool { owns(threadId: threadId) && canWrite }

    func refreshAuthentication() async {
        guard !explicitlyDisconnected, authenticationStatus != .signingIn, authenticationRefresh == nil else { return }
        installObserver()
        let refresh = UUID()
        authenticationRefresh = refresh
        authenticationStatus = .checking
        let accountLease = connection.retainConnection()
        defer {
            if authenticationRefresh == refresh { authenticationRefresh = nil }
            connection.releaseConnection(accountLease)
        }
        for _ in 0..<2 {
            let generation = authenticationGeneration
            do {
                let response = try await connection.request("account/read")
                guard authenticationRefresh == refresh, !explicitlyDisconnected else { return }
                guard !Task.isCancelled else { authenticationStatus = .unknown; return }
                guard generation == authenticationGeneration else { continue }
                authenticationStatus = Self.authentication(from: response)
                return
            } catch {
                guard authenticationRefresh == refresh, !explicitlyDisconnected else { return }
                guard !Task.isCancelled else { authenticationStatus = .unknown; return }
                guard generation == authenticationGeneration else { continue }
                authenticationStatus = .unknown
                return
            }
        }
        if authenticationRefresh == refresh, !explicitlyDisconnected { authenticationStatus = .unknown }
    }

    private static func authentication(from response: [String: Any]) -> CodexAuthenticationStatus {
        if response["account"] is NSNull { return .disconnected }
        guard let type = (response["account"] as? [String: Any])?["type"] as? String else { return .unknown }
        switch type {
        case "chatgpt": return .connected
        case "apiKey": return .disconnected
        default: return .unknown
        }
    }

    /// Disconnect Coucou without removing the login shared by Codex Desktop and CLI.
    func disconnect() {
        explicitlyDisconnected = true
        authenticationGeneration = UUID()
        authenticationRefresh = nil
        authenticationStatus = .disconnected
        reset()
    }

    func models() async throws -> [(id: String, label: String)] {
        installObserver()
        let temporaryLease = connection.retainConnection()
        defer { connection.releaseConnection(temporaryLease) }
        var models: [(id: String, label: String)] = [], cursor: String?
        for _ in 0..<5 {
            var params: [String: Any] = ["limit": 100, "includeHidden": false]
            if let cursor { params["cursor"] = cursor }
            let result = try await connection.request("model/list", params: params)
            guard let entries = result["data"] as? [[String: Any]] else { throw CodexServiceError.invalidResponse }
            for entry in entries where entry["hidden"] as? Bool != true {
                guard let id = entry["model"] as? String ?? entry["id"] as? String else { continue }
                models.append((id, entry["displayName"] as? String ?? id))
                modalities[id] = Set(entry["inputModalities"] as? [String] ?? ["text"])
            }
            cursor = result["nextCursor"] as? String
            if cursor == nil { break }
        }
        guard !models.isEmpty else { throw CodexServiceError.message(String(localized: "No Codex models are available. Check your login or update the CLI.")) }
        return models
    }

    func login(state: AppState) async {
        guard loginAttempt == nil, !isBusy else { return }
        installObserver()
        let attempt = UUID()
        loginAttempt = attempt
        completedLogin = nil; earlyLoginResults = [:]
        explicitlyDisconnected = false
        authenticationGeneration = UUID(); authenticationRefresh = nil
        authenticationStatus = .signingIn
        let loginLease = connection.retainConnection()
        defer {
            loginAttempt = nil; loginId = nil; completedLogin = nil; earlyLoginResults = [:]
            loginDeadline?.cancel(); loginDeadline = nil
            connection.releaseConnection(loginLease)
        }
        do {
            let result = try await connection.request("account/login/start", params: ["type": "chatgpt"])
            try Task.checkCancellation()
            guard !explicitlyDisconnected else { throw CancellationError() }
            guard let id = result["loginId"] as? String, !id.isEmpty, let rawURL = result["authUrl"] as? String,
                  let url = URL(string: rawURL), url.scheme == "https", url.user == nil, url.password == nil,
                  let host = url.host, host == "auth.openai.com" || host.hasSuffix(".openai.com") || host == "chatgpt.com" else {
                throw CodexServiceError.invalidResponse
            }
            loginId = id
            if completedLogin == nil { completedLogin = earlyLoginResults[id] }
            earlyLoginResults = [:]
            guard NSWorkspace.shared.open(url) else { throw CodexServiceError.message(String(localized: "Open the Codex login page in your browser.")) }
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                if let completedLogin { return try completedLogin.get() }
                try await withCheckedThrowingContinuation { continuation in
                    loginCompletion = continuation
                    loginDeadline = Task { @MainActor [weak self] in
                        try? await Task.sleep(for: .seconds(180))
                        guard !Task.isCancelled else { return }
                        self?.finishLogin(.failure(CodexServiceError.timeout))
                    }
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    guard self?.loginAttempt == attempt else { return }
                    self?.finishLogin(.failure(CancellationError()))
                }
            }
            guard !explicitlyDisconnected else { throw CancellationError() }
            reset()
            authenticationStatus = .checking
            await refreshAuthentication()
        } catch {
            if let loginId { _ = try? await connection.request("account/login/cancel", params: ["loginId": loginId]) }
            authenticationStatus = .disconnected
            if !(error is CancellationError) { showError(error.localizedDescription, state: state) }
        }
    }

    func chat(query: String, context: PromptContext?, state: AppState) async {
        guard !isBusy else { showError(CodexServiceError.busy.localizedDescription, state: state); return }
        let current = revision
        isBusy = true
        displayState = state
        state.codexChatBusy = true
        state.stateOverride = .thinking
        defer { finishTurnCleanup(); state.codexChatBusy = false; if revision == current { state.stateOverride = nil } }
        do {
            let cwd = try Self.validatedProject(state.codexProjectPath)
            guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, query.utf8.count <= 100_000 else {
                throw CodexServiceError.message(String(localized: "Enter a question under 100 KB."))
            }
            let chosenModel = state.codexModel
            let chosenCanWrite = state.codexCanWrite
            let chosenSearchMode = state.codexSearchMode
            installObserver()
            _ = CodexAgentsInfo.shared // Consume native usage notifications for managed turns, without polling.
            if lease == nil { lease = connection.retainConnection() }
            guard !explicitlyDisconnected else {
                throw CodexServiceError.message(String(localized: "Sign in to Codex with ChatGPT in Settings → Chat."))
            }
            let accountGeneration = authenticationGeneration
            let account = try await connection.request("account/read")
            if accountGeneration == authenticationGeneration, !explicitlyDisconnected, authenticationStatus != .signingIn {
                authenticationStatus = Self.authentication(from: account)
            }
            guard accountGeneration == authenticationGeneration, revision == current, !explicitlyDisconnected else { throw CancellationError() }
            guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                throw CodexServiceError.message(String(localized: "Sign in to Codex with ChatGPT in Settings → Chat."))
            }
            guard ["disabled", "cached", "live"].contains(chosenSearchMode) else { throw CodexServiceError.invalidResponse }
            if threadId == nil || project != cwd || model != chosenModel || canWrite != chosenCanWrite || searchMode != chosenSearchMode {
                let response = try await connection.request("thread/start", params: Self.threadParameters(
                    cwd: cwd, model: chosenModel, canWrite: chosenCanWrite, searchMode: chosenSearchMode))
                guard revision == current else { throw CancellationError() }
                guard let thread = response["thread"] as? [String: Any], let id = thread["id"] as? String else { throw CodexServiceError.invalidResponse }
                threadId = id; project = cwd; model = response["model"] as? String ?? chosenModel
                CodexEventAdapter.shared.registerThread(thread)
                // An empty picker means the native default. Preserve this choice across turns.
                model = chosenModel; resolvedModel = response["model"] as? String ?? chosenModel
                canWrite = chosenCanWrite; searchMode = chosenSearchMode
                if let nativeModel = response["model"] as? String, modalities[nativeModel] == nil { _ = try await models() }
            }
            guard revision == current, let threadId else { throw CancellationError() }
            let snapshotContext: AttachmentContext?
            switch context {
            case .window(let app, let title, let url): snapshotContext = .window(app: app, title: title, url: url)
            case .file(let name, let url): snapshotContext = .file(name: name, url: url)
            case nil: snapshotContext = nil
            }
            let imageModel = modalities[resolvedModel]?.contains("image") == true
            let prepared = try await Task.detached(priority: .userInitiated) {
                try Self.makeInput(query: query, context: snapshotContext, imageModel: imageModel)
            }.value
            temporaryFiles = prepared.files; attachmentNotice = prepared.notice
            guard revision == current, !Task.isCancelled else { throw CancellationError() }
            guard let input = try JSONSerialization.jsonObject(with: prepared.data) as? [[String: Any]] else { throw CodexServiceError.invalidResponse }
            if let attachmentNotice { state.chatHistory.append(ChatMessage(role: .assistant, content: attachmentNotice)) }
            let placeholder = ChatMessage(role: .assistant, content: "")
            state.chatHistory.append(placeholder); displayState = state; displayMessage = placeholder.id
            let result = try await runTurn(threadId: threadId, input: input, current: current)
            guard revision == current, state.chatProvider == .codex, (try? Self.validatedProject(state.codexProjectPath)) == cwd else { return }
            if let index = state.chatHistory.firstIndex(where: { $0.id == placeholder.id }) { state.chatHistory[index].content = result }
            state.view = .prompt
            NotificationCenter.default.post(name: .triggerEmote, object: BotEmote.happy)
        } catch {
            if let id = displayMessage, let index = state.chatHistory.firstIndex(where: { $0.id == id }), state.chatHistory[index].content.isEmpty {
                state.chatHistory.remove(at: index)
            }
            if revision == current, !(error is CancellationError) { showError(error.localizedDescription, state: state) }
        }
    }

    /// Phone instructions may continue only a thread still owned by this exact connection.
    func sendManagedInstruction(threadId expectedThread: String, text: String, expectedCwd: String) async throws {
        guard owns(threadId: expectedThread), try Self.validatedProject(expectedCwd) == project else {
            throw CodexServiceError.message(String(localized: "This Codex session is no longer connected to Coucou. Open its original session."))
        }
        guard !isBusy else { throw CodexServiceError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 100_000 else { throw CodexServiceError.oversized }
        isBusy = true
        AppState.shared.codexChatBusy = true
        defer { finishTurnCleanup(); AppState.shared.codexChatBusy = false }
        _ = try await runTurn(threadId: expectedThread, input: [["type": "text", "text": text]], current: revision)
    }

    static func validatedProject(_ path: String) throws -> String {
        guard path.hasPrefix("/"), !path.contains("\0") else { throw CodexServiceError.message(String(localized: "Choose a project folder before using Codex Chat.")) }
        let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw CodexServiceError.message(String(localized: "The project folder is missing. Choose it again."))
        }
        return url.path
    }

    static func threadParameters(cwd: String, model: String, canWrite: Bool, searchMode: String) -> [String: Any] {
        var result: [String: Any] = ["cwd": cwd, "sandbox": canWrite ? "workspace-write" : "read-only",
            "approvalPolicy": "on-request", "approvalsReviewer": "user", "config": ["web_search": searchMode],
            "developerInstructions": "You are Mochi, the user's assistant in Coucou. Reply in the user's language. Use concise Markdown when helpful. Cite sources when searching the web."]
        if !model.isEmpty { result["model"] = model }
        return result
    }

    private func runTurn(threadId: String, input: [[String: Any]], current: UUID) async throws -> String {
        guard revision == current else { throw CancellationError() }
        turnId = nil; completed = nil; messageOrder = []; messages = [:]; messageBytes = 0
        deadline = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(300))
            guard !Task.isCancelled else { return }
            self?.cancel(error: CodexServiceError.timeout)
        }
        let id: String
        do {
            let response = try await connection.request("turn/start", params: ["threadId": threadId, "input": input, "cwd": project])
            guard let turn = response["turn"] as? [String: Any], let nativeId = turn["id"] as? String else { throw CodexServiceError.invalidResponse }
            guard revision == current else {
                _ = try? await connection.request("turn/interrupt", params: ["threadId": threadId, "turnId": nativeId]); throw CancellationError()
            }
            if let turnId, turnId != nativeId { throw CodexServiceError.invalidResponse }
            id = nativeId
        } catch {
            // A started notification can precede a failed RPC reply. Its native
            // turn may still be running, so never retain this thread for reuse.
            if revision == current, self.threadId == threadId { cancel(error: error) }
            throw error
        }
        turnId = id
        if let completed { return try completed.get() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { completion = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        revision = UUID()
        cancel(error: CancellationError())
    }
    private func cancel(error: Error) {
        let cancelledThread = threadId, cancelledTurn = turnId
        if let cancelledThread { HookServer.shared.resolveCodexRequests(threadId: cancelledThread) }
        // The interrupt may still be awaiting its reply when the next Chat begins.
        // Relinquish this thread now, and reset the visible conversation with it.
        threadId = nil; turnId = nil; project = ""; model = ""; resolvedModel = ""
        canWrite = false; searchMode = "cached"
        if let state = displayState, state.chatProvider == .codex { state.chatHistory = []; state.stateOverride = nil }
        displayState = nil; displayMessage = nil
        finish(.failure(error))
        finishLogin(.failure(error))
        if isBusy, cancelledTurn == nil {
            // No native turn ID exists yet, so close the owner before a queued start can run.
            connection.stop(error: error)
        }
        if let cancelledThread, let cancelledTurn {
            let interruptLease = connection.retainConnection()
            Task { @MainActor [connection] in
                defer { connection.releaseConnection(interruptLease) }
                _ = try? await connection.request("turn/interrupt", params: ["threadId": cancelledThread, "turnId": cancelledTurn])
            }
        }
        if !isBusy, let lease { connection.releaseConnection(lease); self.lease = nil }
    }

    func reset() { cancel() }

    private func finishTurnCleanup() {
        deadline?.cancel(); deadline = nil; isBusy = false; turnId = nil
        displayMessage = nil
        if threadId == nil { displayState = nil }
        for file in temporaryFiles { try? FileManager.default.removeItem(at: file) }
        temporaryFiles.removeAll()
        if threadId == nil, let lease { connection.releaseConnection(lease); self.lease = nil }
    }

    private func receive(_ method: String, params: [String: Any]) {
        if method == "$connection/disconnected" {
            if let threadId { HookServer.shared.resolveCodexRequests(threadId: threadId) }
            if let state = displayState, state.chatProvider == .codex { state.chatHistory = []; state.stateOverride = nil }
            threadId = nil; turnId = nil; displayState = nil; displayMessage = nil
            // The connection is already stopped; only finish local waiters here.
            finish(.failure(CodexServiceError.disconnected)); finishLogin(.failure(CodexServiceError.disconnected)); return
        }
        if method == "account/login/completed", loginAttempt != nil, let id = params["loginId"] as? String {
            let result: Result<Void, Error> = params["success"] as? Bool == true ? .success(()) : .failure(CodexServiceError.message(params["error"] as? String ?? String(localized: "Codex sign-in failed.")))
            if let loginId {
                if id == loginId { finishLogin(result) }
            } else {
                // Native completion can arrive in the same read as the start RPC reply.
                guard earlyLoginResults.count < 8 || earlyLoginResults[id] != nil else {
                    finishLogin(.failure(CodexServiceError.invalidResponse)); return
                }
                earlyLoginResults[id] = result
            }
            return
        }
        if method == "account/updated" {
            authenticationGeneration = UUID()
            if !explicitlyDisconnected, authenticationStatus != .signingIn {
                authenticationStatus = .checking
                if authenticationRefresh == nil { Task { await self.refreshAuthentication() } }
            }
            if threadId != nil, loginAttempt == nil {
                // Account changes invalidate the managed conversation before another turn.
                reset()
            }
            return
        }
        guard isBusy, params["threadId"] as? String == threadId else { return }
        if method == "turn/started", let turn = params["turn"] as? [String: Any], let id = turn["id"] as? String {
            guard turnId == nil || turnId == id else { return }
            turnId = id
        }
        let eventTurn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
        guard turnId == nil || eventTurn == turnId else { return }
        if method == "item/agentMessage/delta", let id = params["itemId"] as? String, let delta = params["delta"] as? String {
            if messages[id] == nil { messageOrder.append(id) }
            let next = (messages[id] ?? "") + delta
            guard messageBytes + delta.utf8.count <= 524_288, messageOrder.count <= 100 else { cancel(error: CodexServiceError.oversized); return }
            messageBytes += delta.utf8.count
            messages[id] = next; updateVisibleText()
        } else if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                  let id = item["id"] as? String, let text = item["text"] as? String {
            let previousBytes = messages[id]?.utf8.count ?? 0
            guard messageBytes - previousBytes + text.utf8.count <= 524_288, messageOrder.count <= 100 else { cancel(error: CodexServiceError.oversized); return }
            messageBytes += text.utf8.count - previousBytes
            if messages[id] == nil { messageOrder.append(id) }; messages[id] = text; updateVisibleText()
        } else if method == "turn/completed", let turn = params["turn"] as? [String: Any] {
            for item in turn["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "agentMessage" {
                guard let id = item["id"] as? String, let text = item["text"] as? String else { continue }
                let previousBytes = messages[id]?.utf8.count ?? 0
                guard messageBytes - previousBytes + text.utf8.count <= 524_288, messageOrder.count <= 100 else {
                    finish(.failure(CodexServiceError.oversized)); return
                }
                messageBytes += text.utf8.count - previousBytes
                if messages[id] == nil { messageOrder.append(id) }; messages[id] = text
            }
            updateVisibleText()
            if turn["status"] as? String == "completed" { finish(.success(visibleText)) }
            else if turn["status"] as? String == "interrupted" { finish(.failure(CancellationError())) }
            else { finish(.failure(CodexServiceError.message((turn["error"] as? [String: Any])?["message"] as? String ?? String(localized: "Codex could not complete this turn.")))) }
        }
    }

    private var visibleText: String { messageOrder.compactMap { messages[$0] }.joined(separator: "\n\n") }
    private func updateVisibleText() {
        guard let state = displayState, state.chatProvider == .codex, (try? Self.validatedProject(state.codexProjectPath)) == project,
              let id = displayMessage, let index = state.chatHistory.firstIndex(where: { $0.id == id }) else { return }
        state.chatHistory[index].content = visibleText
        if !visibleText.isEmpty { state.stateOverride = nil }
    }
    private func finish(_ result: Result<String, Error>) {
        guard completed == nil else { return }
        completed = result; completion?.resume(with: result); completion = nil
    }
    private func finishLogin(_ result: Result<Void, Error>) {
        guard loginAttempt != nil, completedLogin == nil else { return }
        completedLogin = result
        loginCompletion?.resume(with: result); loginCompletion = nil; loginDeadline?.cancel()
    }
    private func showError(_ message: String, state: AppState) {
        state.stateOverride = nil; state.view = .prompt
        state.chatHistory.append(ChatMessage(role: .assistant, content: message))
    }

    nonisolated private static func makeInput(query: String, context: AttachmentContext?, imageModel: Bool) throws -> PreparedInput {
        var attachmentNotice: String?
        var temporaryFiles: [URL] = []
        var didReturn = false
        defer { if !didReturn { for file in temporaryFiles { try? FileManager.default.removeItem(at: file) } } }
        var input: [[String: Any]] = []
        if let context {
            switch context {
            case .window(let app, let title, let url):
                input.append(["type": "text", "text": "Context — App: \(app), Window: \(title)" + (url.map { ", URL: \($0)" } ?? "")])
            case .file(let name, let fileURL):
                guard let fileURL, fileURL.isFileURL else { throw CodexServiceError.message(String(localized: "The attached file is no longer available. Drop it again.")) }
                let values = try fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true, let size = values.fileSize, size <= 20 * 1_048_576 else { throw CodexServiceError.message(String(localized: "Attach a regular file smaller than 20 MB.")) }
                let ext = fileURL.pathExtension.lowercased()
                if ["png", "jpg", "jpeg", "gif", "webp"].contains(ext) {
                    guard imageModel else { throw CodexServiceError.message(String(localized: "Choose a Codex model that supports images, then attach this file again.")) }
                    input.append(["type": "text", "text": "Attached image: \(name)"])
                    input.append(["type": "localImage", "path": fileURL.path])
                } else if ext == "pdf" {
                    guard let document = PDFDocument(url: fileURL), !document.isLocked else { throw CodexServiceError.message(String(localized: "This PDF cannot be read. Unlock it or attach another file.")) }
                    let limit = min(document.pageCount, 10)
                    var text = "PDF: \(name) — pages 1–\(limit) of \(document.pageCount).\n"
                    var processedPages = 0
                    for pageIndex in 0..<limit {
                        guard let page = document.page(at: pageIndex) else { continue }
                        processedPages += 1
                        let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                        if !pageText.isEmpty { text += "\nPage \(pageIndex + 1):\n" + String(pageText.prefix(24_000)) + (pageText.count > 24_000 ? "\n[Page text truncated at 24,000 characters]" : "") }
                        if imageModel {
                            // A text-bearing page can still contain charts. Include its native page image too.
                            let image = page.thumbnail(of: NSSize(width: 1200, height: 1600), for: .mediaBox)
                            guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                                  let data = bitmap.representation(using: .png, properties: [:]) else { throw CodexServiceError.invalidResponse }
                            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("coucou-codex-\(UUID().uuidString).png")
                            try data.write(to: temporary, options: .atomic)
                            temporaryFiles.append(temporary)
                            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                            input.append(["type": "localImage", "path": temporary.path])
                            text += "\nPage \(pageIndex + 1): attached as an image."
                        } else if pageText.isEmpty {
                            throw CodexServiceError.message(String(localized: "This PDF has scanned pages. Choose a Codex model that supports images."))
                        }
                        if text.count > 96_000 { text = String(text.prefix(96_000)) + "\n[PDF text truncated at 96,000 characters]"; break }
                    }
                    if document.pageCount > limit { text += "\n[Remaining PDF pages were not attached]" }
                    input.insert(["type": "text", "text": text], at: 0)
                    attachmentNotice = String(format: String(localized: "PDF attachment: first %lld of %lld pages; text limited to 96,000 characters."), processedPages, document.pageCount)
                    if !imageModel { attachmentNotice! += " " + String(localized: "Text only: PDF charts and images were not attached.") }
                } else {
                    let handle = try FileHandle(forReadingFrom: fileURL); defer { try? handle.close() }
                    let data = try handle.read(upToCount: 200_001) ?? Data()
                    let prefix = Data(data.prefix(200_000))
                    var decoded = String(data: prefix, encoding: .utf8)
                    // The byte limit can split a valid UTF-8 character. Drop only that incomplete tail.
                    if decoded == nil, size > prefix.count {
                        for tail in 1...3 where decoded == nil { decoded = String(data: prefix.dropLast(tail), encoding: .utf8) }
                    }
                    guard !prefix.contains(0), let text = decoded else { throw CodexServiceError.message(String(localized: "Attach UTF-8 text, an image, or a PDF. This file format is unsupported.")) }
                    let truncated = size > 200_000
                    if truncated || text.count > 48_000 { attachmentNotice = String(localized: "Attachment truncated: first 48,000 characters / 200 KB only.") }
                    input.append(["type": "text", "text": "File: \(name)\n\n" + String(text.prefix(48_000)) + (truncated || text.count > 48_000 ? "\n[Attachment truncated: first 48,000 characters / 200 KB only]" : "")])
                }
            }
        }
        input.append(["type": "text", "text": query])
        let encoded = try JSONSerialization.data(withJSONObject: input)
        didReturn = true
        return PreparedInput(data: encoded, files: temporaryFiles, notice: attachmentNotice)
    }
}
#endif
