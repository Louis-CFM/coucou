#if !APPSTORE
import Foundation
import CryptoKit
import Security
import LocalAuthentication
import Darwin

/// Short-lived text requests never share the project chat's process or thread.
@MainActor
enum CodexTextService {
    static let enabledKey = "codexTextToolsEnabled"
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledKey) }
    private static var generation = UUID()
    private static var setupRunning = false
    private static var shuttingDown = false
    private static var connections: [UUID: CodexConnection] = [:]
    private static var contexts: Set<UUID> = []

    static var isAvailable: Bool {
        !shuttingDown && isEnabled && CodexChatService.shared.authenticationStatus == .connected
            && CodexConnection.findExecutable() != nil
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }

    static var unavailableMessage: String {
        if CodexChatService.shared.authenticationStatus != .connected {
            return String(localized: "Sign in to Codex with ChatGPT in Settings → Chat.")
        }
        if !isEnabled { return String(localized: "codex.text.enable-required") }
        if CodexConnection.findExecutable() == nil { return CodexServiceError.unavailable.localizedDescription }
        return credentialMessage
    }

    private static var credentialMessage: String {
        String(localized: "Codex text tools require an accessible native ChatGPT sign-in, Keychain access, and macOS sandbox support. Sign in with the Codex CLI, then try again.")
    }

    private static var nativeHome: URL {
        let path = ProcessInfo.processInfo.environment["CODEX_HOME"]
        return (path.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"))
            .standardizedFileURL
    }

    private static var utilityHome: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NotchBuddy/CodexText", isDirectory: true)
    }

    private static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: enabledKey)
        CodexChatService.shared.objectWillChange.send()
    }

    /// Explicit setup lets macOS grant the native CLI access to this one dedicated Keychain item.
    /// It never creates a thread or sends user text to a model.
    static func enable(timeout: TimeInterval = 120) async throws {
        guard !setupRunning else { throw CodexServiceError.busy }
        guard CodexChatService.shared.authenticationStatus == .connected else {
            throw CodexServiceError.message(String(localized: "Sign in to Codex with ChatGPT in Settings → Chat."))
        }
        guard let executable = CodexConnection.findExecutable() else { throw CodexServiceError.unavailable }
        guard timeout.isFinite, timeout > 0, timeout <= 600 else { throw CodexServiceError.invalidResponse }
        setupRunning = true
        shuttingDown = false
        generation = UUID()
        for connection in connections.values { connection.stop(error: CancellationError()) }
        defer { setupRunning = false }
        let epoch = CodexChatService.shared.authenticationEpoch, currentGeneration = generation
        let isCurrent = { CodexChatService.shared.authenticationStatus == .connected
            && CodexChatService.shared.authenticationEpoch == epoch && generation == currentGeneration }
        let began = ProcessInfo.processInfo.systemUptime
        func remaining() throws -> TimeInterval {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            let value = timeout - (ProcessInfo.processInfo.systemUptime - began)
            guard value > 0 else { throw CodexServiceError.timeout }
            return value
        }
        let config = try await nativeConfiguration(executable: executable, timeout: try remaining())
        let storage = try credentialStorage(config)
        let home = nativeHome
        let credentials = try await CredentialLoad().run(timeout: try remaining()) {
            try Keyring.sourceSystem(home: home, storage: storage, allowInteraction: true)
        }
        _ = try remaining()
        let context = try Context(executable: executable, nativeHome: home, storage: storage,
                                  utilityHome: utilityHome, credentials: credentials,
                                  requestTimeout: try remaining())
        let id = UUID(); connections[id] = context.connection; contexts.insert(id)
        defer { release(context, id: id) }
        let observer = context.connection.observe { _, _, requestId in
            guard let requestId else { return }
            try? context.connection.reject(id: requestId, message: "Text setup cannot use tools or refresh credentials.")
            context.connection.stop(error: CodexServiceError.invalidResponse)
        }
        defer { context.connection.removeObserver(observer) }
        let result: Result<Void, Error>
        do {
            let waitTime = try remaining()
            let deadline = Task { @MainActor in
                try? await Task.sleep(for: .seconds(waitTime))
                guard !Task.isCancelled else { return }
                context.connection.stop(error: CodexServiceError.timeout)
            }
            defer { deadline.cancel() }
            let response = try await withTaskCancellationHandler {
                try await context.connection.request("account/read", params: [:])
            } onCancel: { Task { @MainActor in context.connection.stop(error: CancellationError()) } }
            _ = try remaining()
            guard (response["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                throw CodexServiceError.message(credentialMessage)
            }
            guard let version = context.connection.cliVersion, version.compare("0.163.0", options: .numeric) != .orderedAscending else {
                throw CodexServiceError.message(String(localized: "Update the Codex CLI to use isolated text tools."))
            }
            result = .success(())
        } catch { result = .failure(error) }
        await context.connection.stopAndWait()
        _ = try remaining()
        try result.get()
        setEnabled(true)
    }

    static func disable() { stopOwned(deleteCredentials: true); setEnabled(false) }
    static func shutdown() { shutdown(keyring: .system, home: utilityHome) }

    fileprivate static func shutdown(keyring: Keyring, home: URL) {
        shuttingDown = true
        stopOwned(deleteCredentials: false, keyring: keyring, home: home)
    }

    private static func stopOwned(deleteCredentials: Bool, keyring: Keyring = .system, home: URL? = nil) {
        generation = UUID()
        let stoppedGeneration = generation, owned = Array(connections.values)
        for connection in owned { connection.stop(error: CancellationError()) }
        let account = Keyring.account(for: home ?? utilityHome)
        if deleteCredentials { keyring.delete(account) } else { keyring.clear(account) }
        Task { @MainActor in
            for connection in owned { await connection.stopAndWait() }
            guard generation == stoppedGeneration else { return }
            if deleteCredentials { keyring.delete(account) } else { keyring.clear(account) }
        }
    }

    private static func release(_ context: Context, id: UUID) {
        connections.removeValue(forKey: id); contexts.remove(id)
        if contexts.isEmpty { context.clearCredentials() }
        try? FileManager.default.removeItem(at: context.root)
    }

    private static func credentialStorage(_ config: [String: Any]) throws -> String {
        let storage = config["cli_auth_credentials_store"] as? String ?? "file"
        let encrypted = (config["features"] as? [String: Any])?["secret_auth_storage"] as? Bool == true
        guard ["file", "keyring", "auto"].contains(storage), storage == "file" || !encrypted else {
            throw CodexServiceError.message(credentialMessage)
        }
        return storage
    }

    static func complete(system: String, user: String, model: String = "", timeout: TimeInterval = 60,
                         webSearch: Bool = false, outputSchema: [String: Any]? = nil) async throws -> String {
        guard isAvailable else { throw CodexServiceError.message(unavailableMessage) }
        guard let executable = CodexConnection.findExecutable() else { throw CodexServiceError.unavailable }
        guard timeout.isFinite, timeout > 0, timeout <= 600 else { throw CodexServiceError.invalidResponse }
        let epoch = CodexChatService.shared.authenticationEpoch, currentGeneration = generation
        let isCurrent = { isEnabled && CodexChatService.shared.authenticationStatus == .connected
            && CodexChatService.shared.authenticationEpoch == epoch && generation == currentGeneration }
        let began = ProcessInfo.processInfo.systemUptime
        let config = try await nativeConfiguration(executable: executable, timeout: timeout)
        try Task.checkCancellation()
        guard isCurrent() else { throw CancellationError() }
        guard ProcessInfo.processInfo.systemUptime - began < timeout else { throw CodexServiceError.timeout }
        let storage = try credentialStorage(config)
        let context = try Context(executable: executable, nativeHome: nativeHome, storage: storage, utilityHome: utilityHome)
        let id = UUID(); connections[id] = context.connection; contexts.insert(id)
        defer { release(context, id: id) }
        let request = Request(connection: context.connection, cwd: context.cwd, isCurrent: isCurrent)
        let result: Result<String, Error>
        do {
            let remaining = timeout - (ProcessInfo.processInfo.systemUptime - began)
            guard remaining > 0 else { throw CodexServiceError.timeout }
            result = .success(try await request.run(system: system, user: user, model: model,
                                                   timeout: remaining, webSearch: webSearch, outputSchema: outputSchema))
        } catch { result = .failure(error) }
        await context.connection.stopAndWait()
        guard isCurrent() else { throw CancellationError() }
        return try result.get()
    }

    fileprivate static func nativeConfiguration(executable: URL, timeout: TimeInterval) async throws -> [String: Any] {
        try Task.checkCancellation()
        let metadata = CodexConnection(executable: executable, requestTimeout: min(timeout, 20))
        let id = UUID(); connections[id] = metadata
        defer { connections.removeValue(forKey: id) }
        let metadataDeadline = Task { @MainActor in
            try? await Task.sleep(for: .seconds(timeout))
            guard !Task.isCancelled else { return }
            metadata.stop(error: CodexServiceError.timeout)
        }
        let config: [String: Any]
        do {
            let response = try await withTaskCancellationHandler {
                try await metadata.request("config/read", params: ["includeLayers": false])
            } onCancel: { Task { @MainActor in metadata.stop(error: CancellationError()) } }
            guard let value = response["config"] as? [String: Any] else { throw CodexServiceError.invalidResponse }
            config = value
            metadataDeadline.cancel()
            await metadata.stopAndWait()
        } catch {
            metadataDeadline.cancel()
            await metadata.stopAndWait()
            throw error
        }
        try Task.checkCancellation()
        return config
    }

    /// Only the Data result crosses threads; a blocked system consent prompt never blocks the UI or its deadline.
    @MainActor fileprivate final class CredentialLoad {
        private var completion: CheckedContinuation<Data, Error>?
        private var deadline: Task<Void, Never>?
        func run(timeout: TimeInterval, loader: @escaping @Sendable () throws -> Data) async throws -> Data {
            try Task.checkCancellation()
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    completion = continuation
                    deadline = Task { @MainActor in
                        try? await Task.sleep(for: .seconds(timeout))
                        guard !Task.isCancelled else { return }
                        finish(.failure(CodexServiceError.timeout))
                    }
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Result { try loader() }
                        Task { @MainActor in self.finish(result) }
                    }
                }
            } onCancel: { Task { @MainActor in self.finish(.failure(CancellationError())) } }
        }
        private func finish(_ result: Result<Data, Error>) {
            guard let completion else { return }
            self.completion = nil; deadline?.cancel(); deadline = nil
            completion.resume(with: result)
        }
    }

    @MainActor fileprivate struct Keyring {
        let read: (String) -> Data?
        let save: (String, Data, URL) throws -> Void
        let delete: (String) -> Void
        let clear: (String) -> Void
        private static let label = "Coucou temporary Codex access"

        private static func ownedQuery(_ account: String) -> [String: Any] {
            [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Codex Auth",
             kSecAttrAccount as String: account, kSecAttrLabel as String: label]
        }

        static let system = Keyring(read: { readData(account: $0, allowInteraction: false) }, save: { account, data, executable in
            let context = LAContext(); context.interactionNotAllowed = true
            var query = ownedQuery(account); query[kSecUseAuthenticationContext as String] = context
            // Update only the value: replacing the item would discard the user's one-time native CLI grant.
            let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            if status == errSecSuccess { return }
            guard status == errSecItemNotFound else { throw CodexServiceError.message(CodexTextService.credentialMessage) }
            var access: SecAccess?
            guard CoucouCreateCodexAccess(executable.path as CFString, &access) == errSecSuccess,
                  let access else { throw CodexServiceError.message(CodexTextService.credentialMessage) }
            query[kSecAttrAccess as String] = access
            query[kSecAttrSynchronizable as String] = false
            query[kSecValueData as String] = data
            guard SecItemAdd(query as CFDictionary, nil) == errSecSuccess else {
                throw CodexServiceError.message(CodexTextService.credentialMessage)
            }
        }, delete: { SecItemDelete(ownedQuery($0) as CFDictionary) }, clear: { account in
            var query = ownedQuery(account)
            let context = LAContext(); context.interactionNotAllowed = true
            query[kSecUseAuthenticationContext as String] = context
            SecItemUpdate(query as CFDictionary, [kSecValueData as String: Data("{}".utf8)] as CFDictionary)
        })

        nonisolated static func readData(account: String, allowInteraction: Bool) -> Data? {
            var value: CFTypeRef?
            var query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "Codex Auth",
                kSecAttrAccount as String: account, kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
            if !allowInteraction {
                let context = LAContext(); context.interactionNotAllowed = true
                query[kSecUseAuthenticationContext as String] = context
            }
            guard SecItemCopyMatching(query as CFDictionary, &value) == errSecSuccess else { return nil }
            return value as? Data
        }

        nonisolated static func sourceSystem(home: URL, storage: String, allowInteraction: Bool) throws -> Data {
            if storage != "file", let data = readData(account: account(for: home), allowInteraction: allowInteraction) { return data }
            guard storage != "keyring" else { throw CodexServiceError.message(String(localized: "Codex text tools require an accessible native ChatGPT sign-in, Keychain access, and macOS sandbox support. Sign in with the Codex CLI, then try again.")) }
            if let handle = try? FileHandle(forReadingFrom: home.appendingPathComponent("auth.json")) {
                defer { try? handle.close() }
                if let data = try handle.read(upToCount: 524_289) { return data }
            }
            throw CodexServiceError.message(String(localized: "Codex text tools require an accessible native ChatGPT sign-in, Keychain access, and macOS sandbox support. Sign in with the Codex CLI, then try again."))
        }

        nonisolated static func account(for home: URL) -> String {
            let bytes = Data(canonicalPath(home).utf8)
            return "cli|" + SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined().prefix(16)
        }

        nonisolated static func canonicalPath(_ url: URL) -> String {
            guard let path = realpath(url.path, nil) else {
                let parent = url.deletingLastPathComponent()
                guard parent.path != url.path else { return url.path }
                return URL(fileURLWithPath: canonicalPath(parent), isDirectory: true).appendingPathComponent(url.lastPathComponent).path
            }
            defer { free(path) }
            return String(cString: path)
        }

        static func accessOnly(_ data: Data) throws -> Data {
            guard data.count <= 524_288,
                  let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  value["auth_mode"] as? String == nil || value["auth_mode"] as? String == "chatgpt",
                  let tokens = value["tokens"] as? [String: Any],
                  let access = tokens["access_token"] as? String, !access.isEmpty, access.utf8.count <= 131_072,
                  let id = tokens["id_token"] as? String, !id.isEmpty, id.utf8.count <= 131_072,
                  let account = tokens["account_id"] as? String, !account.isEmpty, account.utf8.count <= 512 else {
                throw CodexServiceError.message(CodexTextService.credentialMessage)
            }
            // No refresh token reaches the utility process, so it cannot rotate the native login.
            return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": ["access_token": access,
                "id_token": id, "account_id": account, "refresh_token": ""], "last_refresh": ISO8601DateFormatter().string(from: Date())])
        }

        static func source(home: URL, keyring: Keyring, storage: String) throws -> Data {
            guard ["file", "keyring", "auto"].contains(storage) else { throw CodexServiceError.message(CodexTextService.credentialMessage) }
            if storage != "file", let data = keyring.read(account(for: home)) { return data }
            guard storage != "keyring" else { throw CodexServiceError.message(CodexTextService.credentialMessage) }
            if let handle = try? FileHandle(forReadingFrom: home.appendingPathComponent("auth.json")) {
                defer { try? handle.close() }
                if let data = try handle.read(upToCount: 524_289) { return data }
            }
            throw CodexServiceError.message(CodexTextService.credentialMessage)
        }
    }

    // Credentials remain in Keychain; the private CLI never inherits native refresh authority or configuration.
    @MainActor fileprivate struct Context {
        let root: URL
        let cwd: URL
        let connection: CodexConnection
        private let keyring: Keyring
        private let account: String

        func removeCredentials() { keyring.delete(account) }
        func clearCredentials() { keyring.clear(account) }

        init(executable: URL, nativeHome: URL, storage: String = "file", keyring: Keyring = .system,
             utilityHome: URL? = nil, credentials: Data? = nil, requestTimeout: TimeInterval = 20) throws {
            let fm = FileManager.default
            let home = URL(fileURLWithPath: Keyring.canonicalPath(nativeHome), isDirectory: true)
            guard fm.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { throw CodexServiceError.message(CodexTextService.credentialMessage) }
            root = URL(fileURLWithPath: Keyring.canonicalPath(fm.temporaryDirectory), isDirectory: true)
                .appendingPathComponent("coucou-text-\(UUID().uuidString)", isDirectory: true)
            cwd = root.appendingPathComponent("work", isDirectory: true)
            let isolatedHome = URL(fileURLWithPath: Keyring.canonicalPath(utilityHome ?? root.appendingPathComponent("codex", isDirectory: true)), isDirectory: true)
            self.keyring = keyring
            account = Keyring.account(for: isolatedHome)
            do {
                try fm.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try fm.createDirectory(at: cwd, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                let marker = isolatedHome.appendingPathComponent(".coucou-text-home")
                if fm.fileExists(atPath: isolatedHome.path) {
                    let values = try isolatedHome.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
                    guard values.isSymbolicLink != true, values.isDirectory == true,
                          fm.fileExists(atPath: marker.path) else { throw CodexServiceError.invalidResponse }
                } else {
                    try fm.createDirectory(at: isolatedHome, withIntermediateDirectories: utilityHome != nil, attributes: [.posixPermissions: 0o700])
                    try Data("Coucou text tools".utf8).write(to: marker, options: .withoutOverwriting)
                }
                try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: isolatedHome.path)
                guard Keyring.canonicalPath(isolatedHome) != Keyring.canonicalPath(home) else { throw CodexServiceError.invalidResponse }
                let native = try Self.nativeExecutable(executable)
                let source = try credentials ?? Keyring.source(home: home, keyring: keyring, storage: storage)
                try keyring.save(account, Keyring.accessOnly(source), native)
                // The private home never imports native MCP servers, plugins, skills, or hooks.
                let config = "cli_auth_credentials_store = \"keyring\"\ncheck_for_update_on_startup = false\n[history]\npersistence = \"none\"\n"
                try Data(config.utf8).write(to: isolatedHome.appendingPathComponent("config.toml"), options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: isolatedHome.appendingPathComponent("config.toml").path)
                var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("CODEX_") && !$0.key.hasPrefix("OPENAI_") }
                env["CODEX_HOME"] = isolatedHome.path
                let quote = { (value: String) in "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
                guard !home.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      !root.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      !isolatedHome.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw CodexServiceError.invalidResponse }
                let profile = "(version 1)(allow default)(deny file-read* file-write* (subpath \(quote(home.path))))(deny file-write* (literal \(quote(isolatedHome.appendingPathComponent("auth.json").path))))"
                var arguments = ["-p", profile, native.path, "app-server", "--stdio"]
                for feature in Self.disabledFeatures { arguments += ["-c", "features.\(feature)=false"] }
                arguments += ["-c", "project_doc_max_bytes=0", "-c", "agents.enabled=false",
                              "-c", "features.skip_host_skill_discovery=true",
                              "-c", "skills.include_instructions=false", "-c", "skills.bundled.enabled=false",
                              "-c", "tools.update_plan.enabled=false", "-c", "tools.experimental_request_user_input.enabled=false",
                              "-c", "log_dir=\(quote(root.appendingPathComponent("logs").path))",
                              "-c", "sqlite_home=\(quote(root.appendingPathComponent("sqlite").path))"]
                connection = CodexConnection(executable: URL(fileURLWithPath: "/usr/bin/sandbox-exec"), arguments: arguments,
                                             requestTimeout: requestTimeout, launchEnvironment: env, workingDirectory: cwd)
            } catch {
                // A persistent item's ACL must survive setup failure so the user can retry consent.
                if utilityHome == nil { keyring.delete(account) }
                else if CodexTextService.contexts.isEmpty { keyring.clear(account) }
                try? fm.removeItem(at: root); throw error
            }
        }

        static func nativeExecutable(_ executable: URL) throws -> URL {
            let resolved = executable.resolvingSymlinksInPath()
            if resolved.pathExtension != "js" { return resolved }
            #if arch(arm64)
            let platforms = [("aarch64-apple-darwin", "arm64"), ("x86_64-apple-darwin", "x64")]
            #else
            let platforms = [("x86_64-apple-darwin", "x64"), ("aarch64-apple-darwin", "arm64")]
            #endif
            let package = resolved.deletingLastPathComponent().deletingLastPathComponent()
            for (platform, arch) in platforms {
                let candidates = [package.appendingPathComponent("vendor/\(platform)/codex/codex"),
                    package.deletingLastPathComponent().appendingPathComponent("codex-darwin-\(arch)/vendor/\(platform)/codex/codex")]
                if let native = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) { return native }
            }
            throw CodexServiceError.unavailable
        }

        static let disabledFeatures = ["shell_tool", "stable_environment_tools", "apps", "plugins", "hooks", "codex_hooks",
            "plugin_hooks", "memories", "multi_agent", "multi_agent_v2", "multi_agent_v2_dynamic_tools", "collab",
            "js_repl", "code_mode", "computer_use", "browser_use", "image_generation", "view_image",
            "request_permissions_tool", "tool_suggest", "deferred_executor", "sleep_tool", "token_budget", "current_time_reminder", "goals",
            "shell_snapshot", "shell_snapshot_v2", "workspace_dependencies", "secret_auth_storage"]

        static func configuration(webSearch: Bool) -> [String: Any] {
            ["features": Dictionary(uniqueKeysWithValues: disabledFeatures.map { ($0, false) }),
             "agents": ["enabled": false], "skills": ["include_instructions": false, "bundled": ["enabled": false]],
             "project_doc_max_bytes": 0, "web_search": webSearch ? AppState.shared.codexSearchMode : "disabled",
             "tools": ["update_plan": ["enabled": false], "experimental_request_user_input": ["enabled": false]]]
        }
    }

    @MainActor fileprivate final class Request {
        let connection: CodexConnection
        let cwd: URL
        private var thread: String?
        private var turn: String?
        private var observer: UUID?
        private var deadline: Task<Void, Never>?
        private var completion: CheckedContinuation<String, Error>?
        private var completed: Result<String, Error>?
        private var messages: [String: String] = [:]
        private var order: [String] = []
        private var byteCount = 0
        private var streamedBytes = 0
        private var phases: [String: String] = [:]
        private let isCurrent: () -> Bool

        init(connection: CodexConnection, cwd: URL, isCurrent: @escaping () -> Bool = { true }) {
            self.connection = connection; self.cwd = cwd; self.isCurrent = isCurrent
        }

        func run(system: String, user: String, model: String, timeout: TimeInterval,
                 webSearch: Bool, outputSchema: [String: Any]?) async throws -> String {
            guard !user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  system.utf8.count + user.utf8.count <= 524_288,
                  timeout.isFinite, timeout > 0, timeout <= 600, model.utf8.count <= 128 else { throw CodexServiceError.oversized }
            if let outputSchema {
                guard JSONSerialization.isValidJSONObject(outputSchema),
                      try JSONSerialization.data(withJSONObject: outputSchema).count <= 65_536 else { throw CodexServiceError.oversized }
            }
            guard ["disabled", "cached", "live"].contains(AppState.shared.codexSearchMode) else { throw CodexServiceError.invalidResponse }
            observer = connection.observe { [weak self] method, params, id in self?.receive(method, params: params, requestId: id) }
            deadline = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.cancel(CodexServiceError.timeout)
            }
            defer {
                deadline?.cancel()
                if let observer { connection.removeObserver(observer) }
            }
            return try await withTaskCancellationHandler {
                try Task.checkCancellation()
                let account = try await connection.request("account/read")
                try checkRunning()
                guard (account["account"] as? [String: Any])?["type"] as? String == "chatgpt" else {
                    throw CodexServiceError.message(CodexTextService.credentialMessage)
                }
                guard let version = connection.cliVersion, version.compare("0.163.0", options: .numeric) != .orderedAscending else {
                    throw CodexServiceError.message(String(localized: "Update the Codex CLI to use isolated text tools."))
                }
                // System-managed additions must fail before a thread can start their processes.
                let effective = try await connection.request("config/read", params: ["includeLayers": false, "cwd": cwd.path])
                try checkRunning()
                guard let config = effective["config"] as? [String: Any],
                      let servers = config["mcp_servers"] as? [String: Any], servers.isEmpty else { throw CodexServiceError.invalidResponse }
                var params: [String: Any] = ["cwd": cwd.path, "ephemeral": true, "approvalPolicy": "never", "sandbox": "read-only", "modelProvider": "openai",
                    "environments": [], "runtimeWorkspaceRoots": [], "selectedCapabilityRoots": [], "dynamicTools": [],
                    "baseInstructions": system, "developerInstructions": "", "config": Context.configuration(webSearch: webSearch)]
                if !model.isEmpty { params["model"] = model }
                let response = try await connection.request("thread/start", params: params)
                try checkRunning()
                guard let value = response["thread"] as? [String: Any], let id = value["id"] as? String,
                      value["ephemeral"] as? Bool == true, let environments = value["environments"] as? [Any], environments.isEmpty,
                      let roots = response["runtimeWorkspaceRoots"] as? [Any], roots.isEmpty,
                      let sources = response["instructionSources"] as? [Any], sources.isEmpty else { throw CodexServiceError.invalidResponse }
                thread = id
                var input: [String: Any] = ["threadId": id, "input": [["type": "text", "text": user]],
                                            "environments": [], "runtimeWorkspaceRoots": []]
                if let outputSchema { input["outputSchema"] = outputSchema }
                try checkRunning()
                let started = try await connection.request("turn/start", params: input)
                guard let value = started["turn"] as? [String: Any], let id = value["id"] as? String,
                      turn == nil || turn == id else { throw CodexServiceError.invalidResponse }
                turn = id
                if let completed { return try completed.get() }
                return try await withCheckedThrowingContinuation { completion = $0 }
            } onCancel: {
                Task { @MainActor [weak self] in self?.cancel(CancellationError()) }
            }
        }

        private func checkRunning() throws {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if let completed {
                if case .failure(let error) = completed { throw error }
                throw CodexServiceError.invalidResponse
            }
        }

        private func receive(_ method: String, params: [String: Any], requestId: Any?) {
            guard isCurrent() else { cancel(CancellationError()); return }
            if let requestId {
                try? connection.reject(id: requestId, message: "Text requests cannot use local tools or refresh credentials.")
                cancel(CodexServiceError.invalidResponse)
                return
            }
            if method == "$connection/disconnected" { finish(.failure(CodexServiceError.disconnected)); return }
            guard params["threadId"] as? String == thread, thread != nil else { return }
            let eventTurn = params["turnId"] as? String ?? (params["turn"] as? [String: Any])?["id"] as? String
            if method == "turn/started", let eventTurn, turn == nil { turn = eventTurn }
            guard let turn, eventTurn == turn else { return }
            if method == "item/started", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
               let id = item["id"] as? String, let phase = item["phase"] as? String {
                guard phases.count < 100 || phases[id] != nil else { cancel(CodexServiceError.oversized); return }
                phases[id] = phase
            } else if method == "item/agentMessage/delta", let delta = params["delta"] as? String {
                streamedBytes += delta.utf8.count
                if streamedBytes > 524_288 { cancel(CodexServiceError.oversized) }
            } else if method == "item/completed", let item = params["item"] as? [String: Any], item["type"] as? String == "agentMessage",
                      let id = item["id"] as? String, let text = item["text"] as? String { store(id: id, text: text, phase: item["phase"] as? String) }
            else if method == "turn/completed", let value = params["turn"] as? [String: Any] {
                guard value["status"] as? String == "completed", value["error"] == nil || value["error"] is NSNull else {
                    let detail = ((value["error"] as? [String: Any])?["message"] as? String ?? "").lowercased()
                    let authentication = ["refresh", "unauthorized", "sign in", "authentication"].contains { detail.contains($0) }
                    finish(.failure(CodexServiceError.message(authentication
                        ? String(localized: "Refresh your ChatGPT sign-in in Codex, then try again. Coucou cannot change the native credentials.")
                        : String(localized: "Codex could not complete this turn.")))); return
                }
                for item in value["items"] as? [[String: Any]] ?? [] where item["type"] as? String == "agentMessage" {
                    if let id = item["id"] as? String, let text = item["text"] as? String { store(id: id, text: text, phase: item["phase"] as? String) }
                }
                let hasFinal = order.contains { phases[$0] == "final_answer" }
                let text = order.filter { !hasFinal || phases[$0] == "final_answer" }.compactMap { messages[$0] }.joined(separator: "\n\n")
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { finish(.failure(CodexServiceError.invalidResponse)); return }
                finish(.success(text))
            }
        }

        private func store(id: String, text: String, phase: String?) {
            guard completed == nil else { return }
            if let phase {
                guard phases.count < 100 || phases[id] != nil else { cancel(CodexServiceError.oversized); return }
                phases[id] = phase
            }
            if let phase = phases[id], phase != "final_answer" { return }
            let next = byteCount - (messages[id]?.utf8.count ?? 0) + text.utf8.count
            guard next <= 524_288, messages[id] != nil || order.count < 100 else { cancel(CodexServiceError.oversized); return }
            if messages[id] == nil { order.append(id) }
            messages[id] = text; byteCount = next
        }

        private func cancel(_ error: Error) { finish(.failure(error)); connection.stop(error: error) }
        private func finish(_ result: Result<String, Error>) {
            guard completed == nil else { return }
            let result = isCurrent() ? result : .failure(CancellationError())
            completed = result; completion?.resume(with: result); completion = nil
        }
    }
}
#endif
