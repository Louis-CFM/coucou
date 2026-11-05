import Foundation
import Darwin
import Security

#if !APPSTORE

/// Pure logic for Claude Code sessions that run inside the cmux terminal:
/// task ids, labels, the in-memory surface registry and the queue of waiting cards.
enum CmuxRouting {
    static let bundleId = "com.cmuxterm.app"
    static let taskPrefix = "agent_cmux_"
    /// Pills (cmux workspaces) kept at once.
    static let maxTasks = 12
    /// Agent surfaces (sessions) kept per pill. A workspace that fans out helpers reached 10 live sessions and the
    /// ninth and tenth were dropped with all their events; 24 leaves room. The global bounds stay: `maxTasks` pills,
    /// `CmuxCardQueue` (16 cards, 6 per pill) and `maxFileSessions` for the session file.
    static let maxSurfacesPerTask = 24
    static let maxKeyLength = 36
    /// A registry entry (and its task) not seen for this long is dropped.
    static let staleAfter: TimeInterval = 30 * 60
    /// After a card is shown through promotion, answers are ignored for this long.
    static let promotionLock: TimeInterval = 0.7
    /// A card shown for longer than this has been closed by the hook's own timeout (118 s).
    static let lateCardAge: TimeInterval = 115
    /// Requirement the cmux app bundle must satisfy before its CLI is run (team id of Manaflow, Inc.).
    static let codeRequirement =
        "anchor apple generic and identifier \"com.cmuxterm.app\" and certificate leaf[subject.OU] = \"7WLXT3NR37\""

    static func isCmuxTaskId(_ id: String?) -> Bool {
        guard let id else { return false }
        return id.hasPrefix(taskPrefix)
    }

    static func sanitize(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let filtered = raw.lowercased().filter { allowed.contains($0) }
        return String(filtered.prefix(maxKeyLength))
    }

    /// Key of a cmux session (surface level): the surface id, else the session id. nil when neither is usable.
    static func sessionKey(surfaceId: String, sessionId: String) -> String? {
        let surface = sanitize(surfaceId)
        if !surface.isEmpty { return surface }
        if sessionId.lowercased() == "unknown" { return nil }
        let session = sanitize(sessionId)
        return session.isEmpty ? nil : session
    }

    /// Key of a workspace (pill level): its lowercased UUID. nil for anything that is not a UUID.
    static func workspaceKey(_ id: String) -> String? {
        isUUID(id) ? id.lowercased() : nil
    }

    /// Surface key of a payload that comes from cmux. nil when it does not (or has no usable key).
    static func surfaceKey(payload: [String: Any]) -> String? {
        let surface = (payload["cmux_surface_id"] as? String) ?? ""
        let bundle = ((payload["bundle_id"] as? String) ?? "").lowercased()
        guard !surface.isEmpty || bundle == bundleId else { return nil }
        let session = (payload["session_id"] as? String)
            ?? (payload["conversation_id"] as? String) ?? ""
        return sessionKey(surfaceId: surface, sessionId: session)
    }

    /// Pill id of a payload: one pill per cmux workspace (`agent_cmux_<workspace uuid>`). A payload without
    /// a usable workspace id keeps the surface (else session) key: one pill per session. nil when the
    /// payload does not come from cmux.
    static func taskId(payload: [String: Any]) -> String? {
        guard let surface = surfaceKey(payload: payload) else { return nil }
        let workspace = (payload["cmux_workspace_id"] as? String).flatMap(workspaceKey)
        return taskPrefix + (workspace ?? surface)
    }

    // MARK: validation of the fields the hook relay sends

    /// One alphanumeric, then up to 63 of alphanumeric, colon, underscore, dash.
    static func isValidId(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...64).contains(u.count) else { return false }
        func alnum(_ c: UInt8) -> Bool {
            (c >= 0x30 && c <= 0x39) || (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        }
        guard alnum(u[0]) else { return false }
        return u.dropFirst().allSatisfy { alnum($0) || $0 == 0x3A || $0 == 0x5F || $0 == 0x2D }
    }

    /// Printable ASCII without spaces, at most 512 characters.
    static func isValidCapability(_ s: String) -> Bool {
        let u = Array(s.utf8)
        return (1...512).contains(u.count) && u.allSatisfy { $0 >= 0x21 && $0 <= 0x7E }
    }

    /// Absolute, at most 103 bytes (sockaddr_un), ends with .sock, printable ASCII, no `..` component.
    static func isValidSocketPath(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard u.count <= 103, s.hasPrefix("/"), s.hasSuffix(".sock") else { return false }
        guard u.allSatisfy({ $0 >= 0x21 && $0 <= 0x7E }) else { return false }
        return !s.split(separator: "/").contains("..")
    }

    /// The four fields travel as one unit: all valid, or none is used.
    static func isValidContext(surfaceId: String, workspaceId: String,
                               socketPath: String, capability: String) -> Bool {
        isValidId(surfaceId) && isValidId(workspaceId)
            && isValidSocketPath(socketPath) && isValidCapability(capability)
    }

    /// File type and owner check of the socket path (pure part, fed by lstat).
    static func isTrustedSocket(mode: UInt32, owner: UInt32, currentUid: UInt32) -> Bool {
        (mode & UInt32(S_IFMT)) == UInt32(S_IFSOCK) && owner == currentUid
    }

    /// lstat never follows a symlink, so a link reports S_IFLNK and fails the socket check.
    static func socketFileIsTrusted(path: String) -> Bool {
        var st = stat()
        guard lstat(path, &st) == 0 else { return false }
        return isTrustedSocket(mode: UInt32(st.st_mode), owner: UInt32(st.st_uid), currentUid: UInt32(getuid()))
    }

    /// Weekly recap: every cmux workspace counts as one agent ("cmux"), not one agent per workspace.
    static func recapAgentKey(_ pillId: String) -> String {
        isCmuxTaskId(pillId) ? taskPrefix : pillId
    }

    // MARK: timing and lifecycle decisions

    /// True while a card shown through promotion must not take clicks yet.
    static func inputLocked(promotedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let at = promotedAt else { return false }
        return now >= at && now - at < promotionLock
    }

    /// True when the card on screen is old enough that the hook has already given up on it.
    static func isLateCard(arrivedAt: TimeInterval, now: TimeInterval) -> Bool {
        now - arrivedAt > lateCardAge
    }

    /// Events after which a task exists (processEvent and the request paths upsert it).
    static func eventCreatesTask(_ event: String) -> Bool {
        ["SessionStart", "UserPromptSubmit", "PreToolUse", "PermissionRequest", "AskUserQuestion"].contains(event)
    }

    /// A registry entry is created only by an event that creates a task, or for a task that is live.
    static func mayRegister(event: String, taskIsLive: Bool) -> Bool {
        taskIsLive || eventCreatesTask(event)
    }

    /// Project folder name, suffixed ` 2`, ` 3`… when another live cmux task already shows it.
    static func displayName(base: String, taskId: String,
                            existing: [(id: String, name: String)]) -> String {
        let taken = Set(existing.filter { $0.id != taskId }.map { $0.name })
        if let own = existing.first(where: { $0.id == taskId })?.name, !taken.contains(own) {
            if own == base { return own }
            if own.hasPrefix(base + " "), Int(own.dropFirst(base.count + 1)) != nil { return own }
        }
        if !taken.contains(base) { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Short label for the pill: the title cut before the first space that is followed by `(` or `[`
    /// ("Proteus (Swift Implementer) [names]" gives "Proteus"). Without that pattern the whole title.
    static func pillLabel(_ title: String) -> String {
        let chars = Array(title)
        guard chars.count > 2 else { return title }
        for i in 1..<(chars.count - 1) where chars[i] == " " && (chars[i + 1] == "(" || chars[i + 1] == "[") {
            let head = String(chars[..<i])
            return head.trimmingCharacters(in: .whitespaces).isEmpty ? title : head
        }
        return title
    }
}

// MARK: reply, new chat and icons

extension CmuxRouting {
    static let hubPillId = "integration_cmux"
    /// A task that is mid turn may be silent for hours; it is dropped only after this long.
    static let busyStaleAfter: TimeInterval = 6 * 3600
    static let launchTimeout: TimeInterval = 90
    static let maxPromptLength = 8000
    static let maxRecentFolders = 8
    static let palette = PillLook.palette
    /// Raw values of EyeShape; `pill` means no override.
    static let eyes = PillLook.eyes

    /// FNV-1a 64 bit. Stable across launches, unlike hashValue.
    static func fnv1a(_ s: String) -> UInt64 { PillLook.fnv1a(s) }

    /// Colour and eye of a session pill, derived from its surface key. The colour is probed linearly
    /// so two live sessions never share one while fewer than 8 are live.
    static func appearance(key: String, takenColors: Set<String>) -> (color: String, eye: String) {
        PillLook.appearance(key: key, takenColors: takenColors)
    }

    /// Control characters become spaces (newline, tab, ESC, Ctrl-C…), trimmed, capped. nil when empty.
    static func preparePrompt(_ raw: String) -> String? {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            if u.value < 0x20 || (u.value >= 0x7F && u.value <= 0x9F) { out.append(" ") } else { out.append(u) }
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxPromptLength))
    }

    /// 1 to 120 chars of `A-Z a-z 0-9 space _ . / = : -`, first a letter or `/`. No shell syntax can pass.
    /// The first token (the program) holds no `=`: `NAME=value claude` would be an environment prefix.
    static func isValidLaunchCommand(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (1...120).contains(u.count) else { return false }
        func letter(_ c: UInt8) -> Bool { (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) }
        guard letter(u[0]) || u[0] == 0x2F else { return false }
        guard !u.prefix(while: { $0 != 0x20 }).contains(0x3D) else { return false }
        return u.allSatisfy {
            letter($0) || ($0 >= 0x30 && $0 <= 0x39) || [0x20, 0x5F, 0x2E, 0x2F, 0x3D, 0x3A, 0x2D].contains($0)
        }
    }

    /// Absolute, at most 1024 bytes, no control character (C0, DEL, C1), no `..` component.
    /// Existence is the caller's check.
    static func isValidFolder(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path.utf8.count <= 1024 else { return false }
        guard path.unicodeScalars.allSatisfy({ $0.value >= 0x20 && !($0.value >= 0x7F && $0.value <= 0x9F) }) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    /// A folder is worth remembering only when it is valid and the directory exists.
    static func isExistingFolder(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return isValidFolder(path) && FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Chip labels: the last path component, plus the parent folder name when two chips share one.
    static func chipLabels(for folders: [String]) -> [String] {
        let last = folders.map { ($0 as NSString).lastPathComponent }
        return folders.enumerated().map { i, f in
            guard last.filter({ $0 == last[i] }).count > 1 else { return last[i] }
            let parent = ((f as NSString).deletingLastPathComponent as NSString).lastPathComponent
            return parent.isEmpty || parent == "/" ? last[i] : parent + "/" + last[i]
        }
    }

    /// Params of `surface.send_text`. nil when an id is not valid.
    static func rpcParams(workspaceId: String, surfaceId: String, text: String) -> [String: String]? {
        guard isValidId(workspaceId), isValidId(surfaceId) else { return nil }
        return ["workspace_id": workspaceId, "surface_id": surfaceId, "text": text]
    }

    /// Params of `surface.send_key`. nil when an id is not valid.
    static func rpcParams(workspaceId: String, surfaceId: String, key: String) -> [String: String]? {
        guard isValidId(workspaceId), isValidId(surfaceId) else { return nil }
        return ["workspace_id": workspaceId, "surface_id": surfaceId, "key": key]
    }

    /// A new session takes focus only when the hub is Main, focus is nobody or the hub, and the view allows it.
    static func shouldFocusNewSession(mainPillId: String, focusId: String?, viewAllowsSteal: Bool) -> Bool {
        guard mainPillId == hubPillId, viewAllowsSteal else { return false }
        return focusId == nil || focusId == hubPillId
    }

    /// Where focus goes when a cmux task goes away: the most recent remaining session when the hub is
    /// Main, else Main.
    static func nextFocus(afterRemoving removed: String, mainPillId: String,
                          candidates: [(id: String, lastSeen: TimeInterval)]) -> String {
        guard mainPillId == hubPillId else { return mainPillId }
        let best = candidates.filter { $0.id != removed }.max { $0.lastSeen < $1.lastSeen }
        return best?.id ?? mainPillId
    }

    /// Send is off while the session waits on a dialog: Enter would answer it. `dialogMayBeOpen` is the
    /// per task marker of a request Coucou gave back to the terminal (see `dialogResolved`).
    static func canSend(state: String, holdsCard: Bool, dialogMayBeOpen: Bool = false) -> Bool {
        !(holdsCard || dialogMayBeOpen || state == "approval" || state == "question")
    }

    /// The marker of a permission or question dialog that may still be open in the terminal. `inputKey`
    /// is nil for a question (any PostToolUse of the tool resolves it).
    struct DialogMark: Equatable {
        var tool: String
        var inputKey: String?
    }

    /// True when `event` of the same session proves the dialog is gone: the matching tool call finished,
    /// or the turn / prompt / session moved on (a session that starts again on the surface included).
    static func dialogResolved(mark: DialogMark, event: String, tool: String, inputKey: String) -> Bool {
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            return mark.tool == tool && (mark.inputKey == nil || mark.inputKey == inputKey)
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "SessionStart":
            return true
        default:
            return false
        }
    }

    /// A card or question that reads EOF (the hook went away) before the late age was answered in the
    /// terminal: the dialog is gone. Only an older one, or the 115 s timer, leaves a dialog that may be open.
    static func eofLeavesDialogOpen(arrivedAt: TimeInterval, now: TimeInterval) -> Bool {
        isLateCard(arrivedAt: arrivedAt, now: now)
    }

    /// Tasks the stale prune must keep: those holding a card, and the one whose reply view is open.
    static func pruneProtected(holdingCard: Set<String>, openReplyTask: String?) -> Set<String> {
        guard let openReplyTask else { return holdingCard }
        return holdingCard.union([openReplyTask])
    }

    /// Idle tasks eviction may remove: never the one whose reply view is open.
    static func evictableIdle(_ idle: Set<String>, openReplyTask: String?) -> Set<String> {
        guard let openReplyTask else { return idle }
        return idle.subtracting([openReplyTask])
    }

    /// True when the answer of a session should appear in the open reply view instead of switching views.
    /// With several surfaces, only the one the reply view targets (`surfaceKey == targetKey`) stays in place.
    static func answerStaysInReply(prompt: CmuxPromptMode?, taskId: String, viewIsPrompt: Bool,
                                   surfaceKey: String? = nil, targetKey: String? = nil) -> Bool {
        guard viewIsPrompt, prompt == .reply(taskId: taskId) else { return false }
        if let surfaceKey, let targetKey { return surfaceKey == targetKey }
        return true
    }

    /// A matched new chat moves focus only while the user is still in the New chat view and no approval
    /// or question card is on screen.
    static func launchMayTakeFocus(cardOpen: Bool, promptIsNewChat: Bool) -> Bool {
        !cardOpen && promptIsNewChat
    }

    static func recentFolders(adding folder: String, to list: [String]) -> [String] {
        var out = [folder]
        for f in list where f != folder { out.append(f) }
        return Array(out.prefix(maxRecentFolders))
    }

    /// 8-4-4-4-12 hex groups, 36 characters.
    static func isUUID(_ s: String) -> Bool {
        let hex = Set("0123456789abcdefABCDEF")
        let chars = Array(s)
        guard chars.count == 36 else { return false }
        return chars.enumerated().allSatisfy { i, c in
            [8, 13, 18, 23].contains(i) ? c == "-" : hex.contains(c)
        }
    }

    /// `workspace:N` out of the stdout of `new-workspace` (`OK workspace:10`): the first token is `OK`
    /// and the second is the ref, nothing else counts (a folder name echoed later cannot match).
    static func workspaceRef(inNewWorkspaceOutput text: String) -> String? {
        let tokens = text.split(whereSeparator: { $0.isWhitespace })
        guard tokens.count >= 2, tokens[0] == "OK", tokens[1].hasPrefix("workspace:") else { return nil }
        let digits = tokens[1].dropFirst("workspace:".count)
        guard !digits.isEmpty, digits.count <= 9, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return String(tokens[1])
    }

    /// `--id-format` values tried, in order, for the `workspace.list` that resolves a new workspace.
    /// `uuids` is not among them: since cmux 0.64.25 it drops `ref`, which is the only thing that can be
    /// matched safely. `both` keeps the UUID id and adds the ref; nil is the default form (same fields).
    static let workspaceListIdFormats: [String?] = ["both", nil]

    static func workspaceListArguments(idFormat: String?) -> [String] {
        (idFormat.map { ["--id-format", $0] } ?? []) + ["rpc", "workspace.list", "{}"]
    }

    /// UUID of the workspace with this `ref` in the JSON of the rpc `workspace.list`
    /// (`{"workspaces":[{"id":…,"ref":"workspace:10",…}]}`, optionally under `result`).
    static func workspaceId(forRef ref: String, inListJSON json: String) -> String? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let list = (root["workspaces"] as? [[String: Any]])
            ?? ((root["result"] as? [String: Any])?["workspaces"] as? [[String: Any]]) ?? []
        for item in list where (item["ref"] as? String) == ref {
            if let id = item["id"] as? String, isUUID(id) { return id }
        }
        return nil
    }
}

// MARK: launchers (which agent a new chat starts)

/// An agent the New chat view can start in a new cmux workspace. The command is the only part of the
/// launch line the user types (validated by `isValidLaunchCommand`); the prompt of a launcher that
/// does not report back to Coucou travels in a private file, see `CmuxLaunchFiles`.
struct CmuxLauncher: Equatable, Identifiable, Sendable {
    enum Id: String, CaseIterable, Sendable { case claude, codex, grok, agy }

    let id: Id
    let name: String
    let defaultCommand: String
    /// Flag that introduces the first prompt on the command line, "" when it is a positional argument.
    let promptFlag: String
    /// True for the launcher whose SessionStart hook reports the new surface: its prompt is typed
    /// afterwards. The others get the prompt on the command line and nothing is awaited.
    let reportsSessionStart: Bool
    /// Prompts that a positional prompt slot would read as a subcommand of the CLI (exact match).
    let reservedPrompts: Set<String>

    /// Claude, the default, then the command line launchers. Names are product names, not translated.
    static let all: [CmuxLauncher] = [
        CmuxLauncher(id: .claude, name: "Claude", defaultCommand: "claude --dangerously-skip-permissions",
                     promptFlag: "", reportsSessionStart: true, reservedPrompts: []),
        // codex-cli 0.155.1 `codex --help`: `codex [OPTIONS] [PROMPT]`, [PROMPT] "Optional user prompt to start the session".
        CmuxLauncher(id: .codex, name: "Codex", defaultCommand: "codex",
                     promptFlag: "", reportsSessionStart: false,
                     reservedPrompts: ["agents", "exec", "e", "review", "login", "logout", "mcp", "plugin", "app-server",
                                       "remote-control", "app", "completion", "update", "doctor", "sandbox", "debug",
                                       "apply", "a", "resume", "queue", "archive", "delete", "migrate-rollouts",
                                       "unarchive", "fork", "cloud", "exec-server", "features", "help"]),
        // grok 1.0.46 `grok --help`: `grok [OPTIONS] [PROMPT] [COMMAND]`, [PROMPT] "Initial prompt for the interactive session".
        CmuxLauncher(id: .grok, name: "Grok", defaultCommand: "grok",
                     promptFlag: "", reportsSessionStart: false,
                     reservedPrompts: ["agent", "clone", "completions", "cursor-worker", "dashboard", "doctor", "du",
                                       "disk-usage", "export", "help", "inspect", "leader", "login", "logout", "mcp",
                                       "memory", "models", "plugin", "sessions", "setup", "trace", "update", "usage",
                                       "version", "v", "worktree", "wrap"]),
        // `agy --help`: `-i`, alias of `--prompt-interactive`: "Run an initial prompt interactively and continue the session".
        CmuxLauncher(id: .agy, name: "Agy", defaultCommand: "agy",
                     promptFlag: "-i", reportsSessionStart: false, reservedPrompts: []),
    ]

    static let claude = all[0]

    static func launcher(_ id: Id) -> CmuxLauncher { all.first { $0.id == id } ?? claude }

    /// UserDefaults key of this launcher's command. The old single key is read for migration only.
    var defaultsKey: String { "cmuxLaunchCommand.\(id.rawValue)" }
    static let legacyDefaultsKey = "cmuxLaunchCommand"

    /// The command to use from what is stored. A stored valid value wins, `claude` included. Claude with
    /// nothing stored takes the legacy single command when it is valid, else the new default: only a user who
    /// never stored a command gets `--dangerously-skip-permissions`.
    func resolvedCommand(stored: String?, legacy: String?) -> String {
        if let stored, CmuxRouting.isValidLaunchCommand(stored) { return stored }
        if id == .claude, let legacy, CmuxRouting.isValidLaunchCommand(legacy) { return legacy }
        return defaultCommand
    }

    /// False for a prompt a command line launcher would read as an option (a leading dash, tested on the
    /// first byte: none of the three helps documents `--`) or as a subcommand (the whole prompt is a
    /// subcommand name). The prompt is still one argv word for the CLI, see `CmuxLaunchFiles.wrapperScript`.
    func acceptsPrompt(_ prompt: String) -> Bool {
        guard !reportsSessionStart else { return true }
        return prompt.utf8.first != 0x2D && !reservedPrompts.contains(prompt)
    }

    /// The line the terminal types for a launcher that takes its prompt on the command line: `/bin/sh`, the
    /// wrapper, the prompt file, the validated command, then the prompt flag when there is one. It holds no
    /// user text, only the charset of `isValidLaunchCommand`, so sh, bash, zsh and fish read it the same way.
    /// nil for an invalid command or path, or for Claude.
    func launchLine(command: String, wrapperPath: String, promptFile: String) -> String? {
        guard !reportsSessionStart, CmuxRouting.isValidLaunchCommand(command),
              CmuxLaunchFiles.isSafePath(wrapperPath), CmuxLaunchFiles.isSafePath(promptFile)
        else { return nil }
        return "/bin/sh " + wrapperPath + " " + promptFile + " " + command + (promptFlag.isEmpty ? "" : " " + promptFlag)
    }
}

// MARK: private launch files (the prompt never travels in the typed line)

/// The prompt of Codex, Grok and Agy goes through a file in a private per user directory, read and removed by
/// a fixed `/bin/sh` wrapper that the app owns, which then `exec`s the agent with the prompt as ONE argument.
enum CmuxLaunchFiles {
    static let directoryName = "coucou-launch"
    static let wrapperName = "launch.sh"
    static let staleAfter: TimeInterval = 600

    /// POSIX sh. `$1` is the prompt file, the rest is the agent command. The `x` guard keeps trailing
    /// newlines through the command substitution. All expansions are quoted, nothing is evaluated.
    static let wrapperScript = """
    #!/bin/sh
    # Coucou launch wrapper. Usage: launch.sh PROMPT_FILE COMMAND [ARG...]
    f=$1
    [ $# -ge 2 ] && [ -f "$f" ] || exit 1
    shift
    p=$(cat -- "$f" && printf x) || exit 1
    rm -f -- "$f"
    p=${p%x}
    exec "$@" "$p"

    """

    /// Absolute path of at most 400 bytes made only of `A-Z a-z 0-9 _ . / = : -`, no `..` component.
    /// No space, so it is one word in every shell.
    static func isSafePath(_ s: String) -> Bool {
        let u = Array(s.utf8)
        guard (2...400).contains(u.count), u[0] == 0x2F else { return false }
        let ok = u.allSatisfy {
            ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || ($0 >= 0x30 && $0 <= 0x39)
                || [0x5F, 0x2E, 0x2F, 0x3D, 0x3A, 0x2D].contains($0)
        }
        return ok && !s.split(separator: "/").contains("..")
    }

    struct Prepared: Equatable { let wrapperPath: String; let promptFile: String }

    /// Creates (or checks) the private directory, drops stale files, writes the wrapper and the prompt file.
    /// nil, with nothing left behind, when anything is off: the directory is not ours and private, a path is
    /// not safe, a write fails. `baseDirectory` is the per user temporary directory.
    static func prepare(prompt: String, baseDirectory: URL = FileManager.default.temporaryDirectory,
                        now: Date = Date()) -> Prepared? {
        guard !prompt.isEmpty, let dir = privateDirectory(under: baseDirectory) else { return nil }
        removeStale(in: dir, now: now)
        let wrapper = dir + "/" + wrapperName
        let file = dir + "/prompt-" + randomHex(16) + ".txt"
        guard isSafePath(wrapper), isSafePath(file),
              writeAtomically(Array(wrapperScript.utf8), to: wrapper, dir: dir, mode: 0o700),
              writeNew(Array(prompt.utf8), to: file, mode: 0o600) else { return nil }
        return Prepared(wrapperPath: wrapper, promptFile: file)
    }

    static func discard(_ promptFile: String) { unlink(promptFile) }

    /// `<base>/coucou-launch`, mode 0700, a real directory owned by this user with no group or other
    /// permission (lstat: a symlink fails). nil otherwise.
    static func privateDirectory(under base: URL) -> String? {
        let path = base.standardizedFileURL.path + "/" + directoryName
        guard isSafePath(path) else { return nil }
        if mkdir(path, 0o700) != 0 && errno != EEXIST { return nil }
        var st = stat()
        guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == getuid(), (st.st_mode & 0o077) == 0 else { return nil }
        return path
    }

    /// Deletes regular files older than `staleAfter` (by modification time). Never follows a link.
    static func removeStale(in dir: String, now: Date) {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
        for name in names {
            let path = dir + "/" + name
            var st = stat()
            guard lstat(path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            if now.timeIntervalSince1970 - TimeInterval(st.st_mtimespec.tv_sec) > staleAfter { unlink(path) }
        }
    }

    private static func randomHex(_ bytes: Int) -> String {
        var b = [UInt8](repeating: 0, count: bytes)
        if SecRandomCopyBytes(kSecRandomDefault, bytes, &b) != errSecSuccess { b = b.map { _ in UInt8.random(in: 0...255) } }
        return b.map { String(format: "%02x", $0) }.joined()
    }

    /// O_CREAT | O_EXCL | O_NOFOLLOW, then the exact bytes. The file is removed again on a short write.
    private static func writeNew(_ bytes: [UInt8], to path: String, mode: mode_t) -> Bool {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard fd >= 0 else { return false }
        var ok = fchmod(fd, mode) == 0
        var written = 0
        while ok && written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n <= 0 { ok = false } else { written += n }
        }
        if close(fd) != 0 { ok = false }
        if !ok { unlink(path) }
        return ok
    }

    /// A new random file next to the target, then rename over it.
    private static func writeAtomically(_ bytes: [UInt8], to path: String, dir: String, mode: mode_t) -> Bool {
        let tmp = dir + "/tmp-" + randomHex(8)
        guard writeNew(bytes, to: tmp, mode: mode) else { return false }
        if rename(tmp, path) != 0 { unlink(tmp); return false }
        return true
    }
}

// MARK: draft notice and socket peer check

extension CmuxRouting {
    /// Notice of the folder fallback: names the session the draft will go to.
    static func folderDraftNotice(sessionName: String) -> String {
        guard let name = cleanLabel(sessionName) else {
            return String(localized: "claude started in the new session. Check the prompt and press Send.")
        }
        return String(localized: "claude started in \(name). Check the prompt and press Send.")
    }

    /// Connected, non-blocking-then-blocking probe socket to the unix socket at `path`. The caller closes it.
    /// nil when it cannot connect within `timeout`.
    private static func connectedProbe(path: String, timeout: TimeInterval) -> Int32? {
        guard isValidSocketPath(path) else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        var ok = false
        defer { if !ok { close(fd) } }
        var noSigPipe: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return nil }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            for (i, b) in bytes.enumerated() { raw[i] = b }
            raw[bytes.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if rc != 0 {
            guard errno == EINPROGRESS || errno == EAGAIN else { return nil }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) == 1 else { return nil }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len) == 0, err == 0 else { return nil }
        }
        ok = true
        return fd
    }

    /// Audit token (32 bytes) of the process that listens on the unix socket at `path`, read with
    /// LOCAL_PEERTOKEN on a probe connection that is closed without writing anything. Unlike a pid it
    /// carries the pid version, so it does not survive an exec or a pid reuse. nil when it cannot be read.
    static func socketPeerAuditToken(path: String, timeout: TimeInterval = 1) -> Data? {
        guard let fd = connectedProbe(path: path, timeout: timeout) else { return nil }
        defer { close(fd) }
        var token = audit_token_t()
        var len = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &len) == 0,
              Int(len) == MemoryLayout<audit_token_t>.size else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// pid held in an audit token (field 5). nil when the data is not a token.
    static func pid(ofAuditToken token: Data) -> pid_t? {
        guard token.count == MemoryLayout<audit_token_t>.size else { return nil }
        let v = token.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: 5 * 4, as: UInt32.self) }
        return pid_t(bitPattern: v)
    }

    /// True when the process with this audit token satisfies the cmux code requirement.
    static func processIsCmux(auditToken: Data) -> Bool {
        guard auditToken.count == MemoryLayout<audit_token_t>.size else { return false }
        var code: SecCode?
        let attrs = [kSecGuestAttributeAudit as String: auditToken] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess, let code else { return false }
        var requirement: SecRequirement?
        guard SecRequirementCreateWithString(codeRequirement as CFString, [], &requirement) == errSecSuccess,
              let requirement else { return false }
        return SecCodeCheckValidity(code, [], requirement) == errSecSuccess
    }

    /// The listener of the socket is the cmux app. Run before a token leaves the process.
    /// Fails closed: no connection, no audit token, no code object or a failed requirement all give false.
    static func socketPeerIsCmux(path: String) -> Bool {
        guard let token = socketPeerAuditToken(path: path) else { return false }
        return processIsCmux(auditToken: token)
    }

    /// The title lookup may reuse a successful verification for this long; sends never do.
    static let verificationReuseInterval: TimeInterval = 60

    /// `verifiedAt` and `now` come from the same monotonic clock. A clock that went backwards is not fresh.
    static func verificationIsFresh(verifiedAt: TimeInterval?, now: TimeInterval) -> Bool {
        guard let verifiedAt, now >= verifiedAt else { return false }
        return now - verifiedAt < verificationReuseInterval
    }
}

// MARK: session name (cmux tab title) and folder / branch line

extension CmuxRouting {
    static let maxTitleLength = 60
    static let metaRefreshInterval: TimeInterval = 5

    static let maxTitleScalars = 120

    /// Untrusted text: control characters (C0, DEL, C1, line and paragraph separators, bidi overrides)
    /// and every format character (Unicode category Cf: zero width, direction marks, tags) removed,
    /// trimmed, capped at `maxTitleLength` characters and `maxTitleScalars` unicode scalars.
    /// nil when nothing is left.
    static func cleanLabel(_ raw: String) -> String? {
        var out = String.UnicodeScalarView()
        for u in raw.unicodeScalars {
            let v = u.value
            if v < 0x20 || (v >= 0x7F && v <= 0x9F) || v == 0x2028 || v == 0x2029
                || (v >= 0x202A && v <= 0x202E) || (v >= 0x2066 && v <= 0x2069)
                || u.properties.generalCategory == .format { continue }
            out.append(u)
        }
        let trimmed = String(out).trimmingCharacters(in: .whitespacesAndNewlines)
        var result = ""
        var scalars = 0
        for ch in trimmed.prefix(maxTitleLength) {
            let n = ch.unicodeScalars.count
            if scalars + n > maxTitleScalars { break }
            result.append(ch)
            scalars += n
        }
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
    }

    /// Auto titled tabs start with a status glyph and a space: leading characters that are not a letter
    /// or a digit are dropped.
    static func stripLeadingGlyphs(_ s: String) -> String {
        let rest = s.unicodeScalars.drop { !CharacterSet.alphanumerics.contains($0) }
        return String(String.UnicodeScalarView(rest))
    }

    /// At most one refresh every `metaRefreshInterval` seconds per task.
    static func metaRefreshDue(last: TimeInterval?, now: TimeInterval) -> Bool {
        guard let last else { return true }
        return now < last || now - last >= metaRefreshInterval
    }

    /// Branch out of the content of a HEAD file: `ref: refs/heads/NAME` gives NAME, a detached HEAD gives
    /// the first 7 characters of the hash, anything else nil.
    static func branchName(fromHEAD content: String) -> String? {
        let line = (content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("ref:") {
            let ref = line.dropFirst(4).trimmingCharacters(in: .whitespaces)
            let prefix = "refs/heads/"
            guard ref.hasPrefix(prefix) else { return nil }
            return cleanLabel(String(ref.dropFirst(prefix.count)))
        }
        let hex = Set("0123456789abcdefABCDEF")
        guard (40...64).contains(line.count), line.allSatisfy({ hex.contains($0) }) else { return nil }
        return String(line.prefix(7))
    }

    /// Target of a `.git` file (`gitdir: PATH`), relative paths resolved against `base`. nil when it is
    /// not a pointer.
    static func gitDirectory(fromPointer content: String, base: String) -> String? {
        let line = (content.split(whereSeparator: { $0.isNewline }).first.map(String.init) ?? "")
            .trimmingCharacters(in: .whitespaces)
        guard line.hasPrefix("gitdir:") else { return nil }
        let path = line.dropFirst(7).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty, !path.unicodeScalars.contains(where: { $0.value < 0x20 }) else { return nil }
        return path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path)
    }

    /// Up to 4 KB of a regular file, opened without following a symlink and without blocking (a FIFO
    /// named HEAD would otherwise hang the reader). nil for anything that is not a regular file.
    static func smallFile(_ path: String) -> String? {
        let fd = open(path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { return nil }
        var buf = [UInt8](repeating: 0, count: 4096)
        let n = read(fd, &buf, buf.count)
        guard n >= 0 else { return nil }
        return String(data: Data(buf.prefix(n)), encoding: .utf8)
    }

    /// A `gitdir:` target is plausible when it is a `.git` folder (or a `*.git` one) or lies inside one.
    static func isPlausibleGitDir(_ path: String) -> Bool {
        let comps = (path as NSString).standardizingPath.split(separator: "/")
        guard let last = comps.last else { return false }
        return last.hasSuffix(".git") || comps.contains(".git")
    }

    /// Branch of the repository that holds `cwd`, without running a process: walks up to the first `.git`,
    /// follows a `gitdir:` pointer once (worktrees), reads HEAD. nil when there is no repository.
    static func gitBranch(cwd: String) -> String? {
        guard isValidFolder(cwd) else { return nil }
        var dir = (cwd as NSString).standardizingPath
        for _ in 0..<64 {
            let dotGit = (dir as NSString).appendingPathComponent(".git")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: dotGit, isDirectory: &isDir) {
                var gitDir = dotGit
                if !isDir.boolValue {
                    guard let pointer = smallFile(dotGit),
                          let target = gitDirectory(fromPointer: pointer, base: dir),
                          isPlausibleGitDir(target) else { return nil }
                    gitDir = target
                }
                guard let head = smallFile((gitDir as NSString).appendingPathComponent("HEAD")) else { return nil }
                return branchName(fromHEAD: head)
            }
            let parent = (dir as NSString).deletingLastPathComponent
            if parent == dir || parent.isEmpty { return nil }
            dir = parent
        }
        return nil
    }

    /// Second line of a cmux session: `folder (branch)`, the folder alone without a repository.
    static func folderLine(cwd: String, branch: String?) -> String? {
        let folder = (cwd as NSString).lastPathComponent
        guard !cwd.isEmpty, !folder.isEmpty, folder != "/",
              let name = cleanLabel(folder) else { return nil }
        guard let branch, !branch.isEmpty else { return name }
        return "\(name) (\(branch))"
    }
}

// MARK: workspaces: folded state, main surface, discovery (cmux tree and session file)

/// A surface of the cmux tree (`system.tree`). Untrusted input, validated by `parseTree`.
struct CmuxTreeSurface: Equatable {
    var id: String
    var title: String
    var type: String
    var index: Int
}

struct CmuxTreeWorkspace: Equatable {
    var id: String
    var title: String
    var index: Int
    var selected: Bool
    var surfaces: [CmuxTreeSurface]
}

/// The session a surface holds, from the cmux session file (`claude-hook-sessions.json`). Untrusted input.
struct CmuxFileSession: Equatable {
    var sessionId: String
    var surfaceId: String
    var workspaceId: String
    var cwd: String
    var lifecycle: String
    var pid: Int32
    var pidStart: Int
    var startedAt: TimeInterval
}

/// What one discovery run found. `tree` is nil without a credential (or when the tree could not be read),
/// `sessions` nil when the session file could not be read. `startedAt` is when the run began: a surface
/// heard through a hook after that moment is newer than the tree and is never removed by it.
struct CmuxSnapshot: Equatable {
    var tree: [CmuxTreeWorkspace]?
    var sessions: [CmuxFileSession]?
    var socketPath: String
    var startedAt: TimeInterval
    /// True when `parseTree` cut the tree at one of its caps: it no longer says what does not exist.
    var treeTruncated: Bool = false
}

/// A parsed `system.tree`: the workspaces kept, and whether a cap cut something off.
struct CmuxParsedTree: Equatable {
    var workspaces: [CmuxTreeWorkspace]
    var truncated: Bool
}

/// One agent session of a workspace as the reply header and the card show it.
struct CmuxSurfaceInfo: Equatable {
    var key: String
    var label: String
    var isMain: Bool
}

struct CmuxSurfacePlan: Equatable {
    var key: String
    var surfaceId: String
    var title: String?
    var index: Int?
    var sessionId: String
    var cwd: String
    var startedAt: TimeInterval?
    /// `agentLifecycle` of the session file, nil for a surface known only through a hook.
    var lifecycle: String?
}

struct CmuxWorkspacePlan: Equatable {
    var taskId: String
    var workspaceId: String
    var title: String?
    var index: Int
    /// In tree order (lowest index first).
    var surfaces: [CmuxSurfacePlan]

    /// Folder of the first surface that has one.
    var cwd: String { surfaces.first { !$0.cwd.isEmpty }?.cwd ?? "" }
}

struct CmuxReconcilePlan: Equatable {
    /// Pills that must exist, in workspace order.
    var workspaces: [CmuxWorkspacePlan] = []
    /// Registry entries to drop (surface keys).
    var removeKeys: [String] = []
    /// Pills left with no surface.
    var removeTasks: [String] = []
}

extension CmuxRouting {
    static let maxWorkspaces = 64
    static let maxTreeSurfaces = 32
    static let maxFileSessions = 256
    static let maxSessionFileBytes = 8 * 1024 * 1024
    static let discoveryInterval: TimeInterval = 5

    /// Priority of a pill's state over its surfaces (first wins).
    static let foldOrder = ["approval", "question", "working", "searching", "thinking",
                            "error", "ratelimit", "finished", "idle"]

    /// The state a pill shows for the states of its surfaces. Empty or unknown values give idle.
    static func foldedState(_ states: [String]) -> String {
        var best = "idle"
        var rank = foldOrder.count - 1
        for s in states {
            if let r = foldOrder.firstIndex(of: s), r < rank { rank = r; best = s }
        }
        return best
    }

    /// States that mean a session is mid turn. A session in `error` or `ratelimit` (sticky until its next
    /// prompt), `approval`, `question` or `finished` is not busy.
    static let busyStates: Set<String> = ["working", "searching", "thinking"]

    /// True when the Stop of a session adds a step and nothing else (no sound, no finished view, no badge): a
    /// helper that stops while another session of the workspace is mid turn. The main session is never silent
    /// (its answer is the one the user waits for), and a sibling stuck in an old state does not silence anybody.
    /// `states` is the raw state of every session of the pill by surface key.
    static func stopIsSilent(stoppingKey: String, mainKey: String?, states: [String: String]) -> Bool {
        guard stoppingKey != mainKey else { return false }
        return states.contains { $0.key != stoppingKey && busyStates.contains($0.value) }
    }

    /// True for the Notification of Claude Code that says a session is idle and waits for the user (`idle_prompt`,
    /// "Claude is waiting for your input"): cmux turns it into its own "Waiting" notification. `type` is the
    /// payload's `notification_type` when there is one; without it the message decides. A permission request is
    /// answered by its card, a message ending with `?` is a question: neither is this.
    static func isWaitingNotification(type: String?, message: String) -> Bool {
        if let type, !type.isEmpty { return type.lowercased() == "idle_prompt" }
        let m = message.lowercased()
        return m.contains("waiting for your input") || m.contains("waiting for your next prompt")
    }

    /// States of a session that failed (sticky until its next prompt): the finished badge is not for them.
    static let failedStates: Set<String> = ["error", "ratelimit"]

    /// Whether a waiting notification of a session gives its pill the badge of a finished turn. Only for a session
    /// whose last Stop told nobody (`CmuxStopRecord`), while the pill is not the one on screen, carries no badge
    /// already and holds no card, and the session is neither mid turn nor failed. A badge only: no sound, no view, so
    /// never more than the finished turn itself.
    static func waitingNeedsBadge(stopToldNobody: Bool, pillFocused: Bool, pillHasBadge: Bool, pillHoldsCard: Bool,
                                  sessionState: String?) -> Bool {
        guard stopToldNobody, !pillFocused, !pillHasBadge, !pillHoldsCard else { return false }
        let state = sessionState ?? ""
        return !busyStates.contains(state) && !failedStates.contains(state)
    }

    /// Where the Stop of a silent session (a helper finishing while a sibling works) shows itself: the finished badge
    /// of its pill at once, no sound, no view, no card, no final line. Not for the focused pill, whose row the pill
    /// grid does not draw (the badge would only appear once the focus moves away), nor over a card or an existing
    /// badge. Never `.view`.
    static func silentStopPlacement(pillFocused: Bool, cardOfPillOnScreen: Bool, pillHoldsCard: Bool,
                                    pillHasBadge: Bool) -> AlertPlacement {
        if pillFocused || pillHasBadge { return .none }
        return alertPlacement(focused: false, cardOfPillOnScreen: cardOfPillOnScreen, pillHoldsCard: pillHoldsCard)
    }

    /// Where a finished or error alert of a cmux session goes.
    enum AlertPlacement: Equatable {
        /// The island shows the finished / error view.
        case view
        /// Only the pill badge.
        case badge
        /// Sound only: a card holds the screen and the badge of the pill.
        case none
    }

    /// `focused`: the pill is focused and the event may take the view. A card of this pill on screen belongs to
    /// another session than the event (its own session's events dismiss it first): the alert must neither replace
    /// it (a question card would be handed back to the terminal) nor overwrite the approval badge.
    static func alertPlacement(focused: Bool, cardOfPillOnScreen: Bool, pillHoldsCard: Bool) -> AlertPlacement {
        if cardOfPillOnScreen { return .none }
        if focused { return .view }
        return pillHoldsCard ? .none : .badge
    }

    /// True when the time rule (`staleAfter`, `busyStaleAfter`) may drop a registry entry. `liveKeys` are the
    /// surface keys of the sessions the last discovery found with a live process in the cmux session file, nil
    /// when that file could not be read. A live process keeps its entry whatever the hooks say (an idle
    /// workspace stays); an entry without one expires, so a session that died without a SessionEnd does not
    /// stay an agent for as long as its terminal tab exists. With no file to ask, a known tree speaks only for
    /// entries that have a surface id.
    static func timeRuleApplies(entry: CmuxSurface, treeKnown: Bool, liveKeys: Set<String>?) -> Bool {
        if let liveKeys { return !liveKeys.contains(entry.key) }
        return !treeKnown || entry.surfaceId.isEmpty
    }

    /// Name of a pill with no workspace title yet: the cleaned folder name, else `fallback`.
    static func folderPillName(cwd: String, fallback: String) -> String {
        let folder = (cwd as NSString).lastPathComponent
        return (folder.isEmpty || folder == "/" ? nil : cleanLabel(folder)) ?? fallback
    }

    /// Lowest tree index first, then oldest start, then smallest key. A missing index or start comes last.
    static func surfaceOrder(_ aKey: String, _ aIndex: Int?, _ aStart: TimeInterval?,
                             _ bKey: String, _ bIndex: Int?, _ bStart: TimeInterval?) -> Bool {
        let ai = aIndex ?? Int.max, bi = bIndex ?? Int.max
        if ai != bi { return ai < bi }
        let at = aStart ?? .infinity, bt = bStart ?? .infinity
        if at != bt { return at < bt }
        return aKey < bKey
    }

    /// Main surface of a pill: `current` while it is still a candidate and no other candidate sits at a lower tree
    /// index (a main without an index yields to a surface that has one, since the first hook event of a workspace
    /// can come from a helper; and a main that re-registered after `/clear` gets its place back as soon as the
    /// tree gives it an index). Else the first by `surfaceOrder`. nil without candidates.
    static func mainSurfaceKey(current: String?,
                               candidates: [(key: String, index: Int?, startedAt: TimeInterval?)]) -> String? {
        guard !candidates.isEmpty else { return nil }
        if let current, let c = candidates.first(where: { $0.key == current }) {
            let best = candidates.compactMap { $0.index }.min()
            if let mine = c.index {
                if let best, mine <= best { return current }
            } else if best == nil {
                return current
            }
        }
        return candidates.min { surfaceOrder($0.key, $0.index, $0.startedAt, $1.key, $1.index, $1.startedAt) }?.key
    }

    /// One discovery at a time, at most one every `discoveryInterval` seconds. A clock that went backwards
    /// does not hold a run back.
    static func discoveryDue(last: TimeInterval?, now: TimeInterval, inFlight: Bool) -> Bool {
        guard !inFlight else { return false }
        guard let last else { return true }
        return now < last || now - last >= discoveryInterval
    }

    /// A surface Coucou never heard from (no hook event with a valid token) may sit on an open permission dialog:
    /// typing Enter would answer it. Every such surface is marked, whatever the session file says (its
    /// `agentLifecycle` is user writable and was seen saying `running` after a Stop). Only a turn level hook
    /// event of that surface or the "Answered" click clears the mark.
    static func needsDialogMark(heard: Bool) -> Bool { !heard }

    /// Chip / line labels of the surfaces of one pill: the short tab title, "Session" without one, and
    /// ` 2`, ` 3`… when two share a label.
    static func surfaceLabels(titles: [String?], fallback: String) -> [String] {
        var seen: [String: Int] = [:]
        return titles.map { t in
            let base = t.map { pillLabel($0) } ?? fallback
            let n = (seen[base] ?? 0) + 1
            seen[base] = n
            return n == 1 ? base : "\(base) \(n)"
        }
    }

    // MARK: tree

    private static func cleanTitle(_ raw: Any?) -> String? {
        (raw as? String).flatMap { cleanLabel(stripLeadingGlyphs($0)) }
    }

    /// `windows[].workspaces[]{id,title,index,selected,panes[].surfaces[]{id,type,index,title}}` of the rpc
    /// `system.tree`, at the root or under `result`. Ids must be UUIDs, titles are cleaned, at most
    /// `maxWorkspaces` workspaces and `maxTreeSurfaces` surfaces each. The index of a workspace is its
    /// position in the traversal (windows in order, then the workspace index). `truncated` is true when a cap
    /// cut something off: such a tree cannot say that a surface does not exist. nil for anything else.
    static func parseTreeChecked(_ json: String) -> CmuxParsedTree? {
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let body = root["windows"] != nil ? root : ((root["result"] as? [String: Any]) ?? root)
        guard let windows = body["windows"] as? [[String: Any]] else { return nil }
        var out: [CmuxTreeWorkspace] = []
        var seen = Set<String>()
        var truncated = false
        for window in windows {
            let list = ((window["workspaces"] as? [[String: Any]]) ?? [])
                .sorted { ($0["index"] as? Int ?? Int.max) < ($1["index"] as? Int ?? Int.max) }
            for ws in list {
                guard let id = ws["id"] as? String, isUUID(id), seen.insert(id.lowercased()).inserted else { continue }
                guard out.count < maxWorkspaces else { truncated = true; continue }
                var surfaces: [CmuxTreeSurface] = []
                var seenSurfaces = Set<String>()
                for pane in (ws["panes"] as? [[String: Any]]) ?? [] {
                    for sf in (pane["surfaces"] as? [[String: Any]]) ?? [] {
                        guard let sid = sf["id"] as? String, isUUID(sid),
                              seenSurfaces.insert(sid.lowercased()).inserted else { continue }
                        guard surfaces.count < maxTreeSurfaces else { truncated = true; continue }
                        let rawType = (sf["type"] as? String) ?? ""
                        let type = !rawType.isEmpty && rawType.utf8.count <= 24
                            && rawType.utf8.allSatisfy({ ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x5F }) ? rawType : "other"
                        surfaces.append(CmuxTreeSurface(id: sid, title: cleanTitle(sf["title"]) ?? "", type: type,
                                                        index: sf["index"] as? Int ?? surfaces.count))
                    }
                }
                surfaces.sort { $0.index < $1.index }
                out.append(CmuxTreeWorkspace(id: id, title: cleanTitle(ws["title"]) ?? "", index: out.count,
                                             selected: ws["selected"] as? Bool ?? false, surfaces: surfaces))
            }
        }
        return CmuxParsedTree(workspaces: out, truncated: truncated)
    }

    static func parseTree(_ json: String) -> [CmuxTreeWorkspace]? {
        parseTreeChecked(json)?.workspaces
    }

    // MARK: session file

    /// The sessions of `claude-hook-sessions.json` that are the CURRENT session of their surface
    /// (`activeSessionsBySurface`), with valid UUID ids, a live process (`isLive(pid, pidStartSeconds)`) and
    /// a cwd that passes `isValidFolder` (else ""). At most `maxFileSessions`. nil when the file does not
    /// have the expected maps. Nothing in it is a credential.
    static func parseSessionFile(_ data: Data,
                                 isLive: (Int32, Int) -> Bool = { _, _ in true }) -> [CmuxFileSession]? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = root["sessions"] as? [String: Any],
              let active = root["activeSessionsBySurface"] as? [String: Any] else { return nil }
        var out: [CmuxFileSession] = []
        for (surfaceKeyRaw, value) in active.sorted(by: { $0.key < $1.key }) {
            guard out.count < maxFileSessions else { break }
            guard isUUID(surfaceKeyRaw), let a = value as? [String: Any],
                  let sid = a["sessionId"] as? String, isValidId(sid),
                  let s = sessions[sid] as? [String: Any], (s["sessionId"] as? String) == sid,
                  let surface = s["surfaceId"] as? String, isUUID(surface),
                  surface.caseInsensitiveCompare(surfaceKeyRaw) == .orderedSame,
                  let workspace = s["workspaceId"] as? String, isUUID(workspace),
                  let pidValue = s["pid"] as? Int, pidValue > 0, pidValue <= Int(Int32.max),
                  let pidStart = s["pidStartSeconds"] as? Int else { continue }
            let pid = Int32(pidValue)
            guard isLive(pid, pidStart) else { continue }
            let cwd = (s["cwd"] as? String).flatMap { isValidFolder($0) ? $0 : nil } ?? ""
            let rawLifecycle = (s["agentLifecycle"] as? String) ?? ""
            let lifecycle = rawLifecycle.utf8.count <= 24 && rawLifecycle.unicodeScalars.allSatisfy({ $0.isASCII && CharacterSet.alphanumerics.contains($0) })
                ? rawLifecycle : ""
            out.append(CmuxFileSession(sessionId: sid, surfaceId: surface, workspaceId: workspace, cwd: cwd,
                                       lifecycle: lifecycle, pid: pid, pidStart: pidStart,
                                       startedAt: (s["startedAt"] as? Double) ?? 0))
        }
        return out
    }

    // MARK: reconcile

    /// A surface whose session ended is not planned again by a discovery that starts within this long: the
    /// snapshot may have been read before the SessionEnd, or while the process was still shutting down.
    static let endedGrace: TimeInterval = 10

    /// What discovery changes. With a tree: one workspace plan per workspace that has an agent surface (a
    /// terminal surface with a live session in the file, or one the hooks reported with a valid token); a
    /// surface lives under the pill of the tree's workspace (an entry filed under another pill is moved, unless
    /// that pill is protected). Entries the tree does not account for are dropped, except those of a protected
    /// pill, those without a surface id (left to the time rule), those heard after the snapshot began, those of
    /// another socket than the tree's, and all of them when the tree was cut at a cap. Without a readable
    /// session file an entry the tree still lists as a terminal stays an agent surface. A pill left with no
    /// surface is dropped. New pills stop at `maxTasks`. Without a tree (no token) nothing is dropped and the
    /// pills come from the session file alone, grouped by workspace. Without either, nothing happens.
    /// `ended` holds the surface keys of sessions that just ended, with the time.
    static func reconcile(snapshot: CmuxSnapshot, entries: [CmuxSurface], protected: Set<String>,
                          ended: [String: TimeInterval] = [:]) -> CmuxReconcilePlan {
        var plan = CmuxReconcilePlan()
        let byKey = Dictionary(entries.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
        let files = Dictionary((snapshot.sessions ?? []).map { (sanitize($0.surfaceId), $0) },
                               uniquingKeysWith: { a, b in a.startedAt <= b.startedAt ? a : b })
        func recentlyEnded(_ key: String) -> Bool {
            guard let at = ended[key] else { return false }
            return snapshot.startedAt < at + endedGrace
        }
        var candidates: [CmuxWorkspacePlan] = []
        var kept = Set<String>()
        var rehomed = Set<String>()

        if let tree = snapshot.tree {
            for ws in tree {
                guard let wk = workspaceKey(ws.id) else { continue }
                let taskId = taskPrefix + wk
                var surfaces: [CmuxSurfacePlan] = []
                for sf in ws.surfaces where sf.type == "terminal" {
                    let key = sanitize(sf.id)
                    if recentlyEnded(key) { continue }
                    var file = files[key]
                    if let f = file, f.workspaceId.caseInsensitiveCompare(ws.id) != .orderedSame { file = nil }
                    let entry = byKey[key]
                    let isAgent = file != nil || entry?.heard == true || (snapshot.sessions == nil && entry != nil)
                    guard isAgent else { continue }
                    if let entry, entry.taskId != taskId, protected.contains(entry.taskId) {
                        // Its pill is in use (a card, the open reply view): left exactly where it is.
                        kept.insert(key)
                        continue
                    }
                    guard surfaces.count < maxSurfacesPerTask else { break }
                    surfaces.append(CmuxSurfacePlan(key: key, surfaceId: sf.id, title: sf.title.isEmpty ? nil : sf.title,
                                                    index: sf.index, sessionId: file?.sessionId ?? "",
                                                    cwd: file?.cwd ?? "", startedAt: file?.startedAt,
                                                    lifecycle: file?.lifecycle))
                    kept.insert(key)
                    if let entry, entry.taskId != taskId { rehomed.insert(key) }
                }
                guard !surfaces.isEmpty else { continue }
                candidates.append(CmuxWorkspacePlan(taskId: taskId, workspaceId: ws.id,
                                                    title: ws.title.isEmpty ? nil : ws.title,
                                                    index: ws.index, surfaces: surfaces))
            }
            var removed = Set<String>()
            if !snapshot.treeTruncated {
                for e in entries where !kept.contains(e.key) {
                    // Only what this tree can speak for: the same socket, a surface id, nothing newer than the run.
                    guard !e.surfaceId.isEmpty, !snapshot.socketPath.isEmpty, e.socketPath == snapshot.socketPath,
                          e.lastSeen < snapshot.startedAt, !protected.contains(e.taskId) else { continue }
                    removed.insert(e.key)
                }
            }
            plan.removeKeys = removed.sorted()
            // A pill the plan does not keep goes when none of its entries stays under it (removed or moved).
            let planned = Set(candidates.map { $0.taskId })
            for task in Set(entries.map { $0.taskId }).subtracting(planned).sorted() {
                let stays = entries.contains { $0.taskId == task && !removed.contains($0.key) && !rehomed.contains($0.key) }
                if !stays { plan.removeTasks.append(task) }
            }
        } else if let sessions = snapshot.sessions {
            var order: [String] = []
            var groups: [String: [CmuxFileSession]] = [:]
            for f in sessions.sorted(by: { ($0.startedAt, $0.surfaceId) < ($1.startedAt, $1.surfaceId) })
            where !recentlyEnded(sanitize(f.surfaceId)) {
                let wk = f.workspaceId.lowercased()
                if groups[wk] == nil { order.append(wk) }
                groups[wk, default: []].append(f)
            }
            for (i, wk) in order.enumerated() {
                let surfaces = (groups[wk] ?? []).prefix(maxSurfacesPerTask).map {
                    CmuxSurfacePlan(key: sanitize($0.surfaceId), surfaceId: $0.surfaceId, title: nil, index: nil,
                                    sessionId: $0.sessionId, cwd: $0.cwd, startedAt: $0.startedAt,
                                    lifecycle: $0.lifecycle)
                }
                guard let first = groups[wk]?.first else { continue }
                candidates.append(CmuxWorkspacePlan(taskId: taskPrefix + wk, workspaceId: first.workspaceId,
                                                    title: nil, index: i, surfaces: Array(surfaces)))
            }
        } else {
            return plan
        }

        // New pills stop at the cap; a pill that exists already is always kept.
        let existing = Set(entries.map { $0.taskId }).subtracting(plan.removeTasks)
        var count = existing.count
        for c in candidates {
            if existing.contains(c.taskId) { plan.workspaces.append(c); continue }
            guard count < maxTasks else { continue }
            count += 1
            plan.workspaces.append(c)
        }
        return plan
    }
}

/// One per agent surface (a Claude session in a cmux terminal); a pill (workspace) holds one or more.
/// The capability is a credential: memory only, never logged or persisted.
struct CmuxSurface: Equatable {
    var taskId: String                  // pill id (workspace)
    var surfaceId: String
    var workspaceId: String
    var socketPath: String
    var capability: String
    var sessionId: String
    var lastSeen: TimeInterval
    /// Registry key (surface level). Empty only for a value built by hand: the registry always sets it.
    var key: String = ""
    var title: String? = nil            // tab title, cleaned
    var index: Int? = nil               // workspace wide index from the tree
    var startedAt: TimeInterval? = nil  // from the cmux session file
    var state: String = "idle"          // BotState raw value of this session
    /// True once a hook event of this surface carried a valid cmux context (surface, workspace, socket and
    /// token as one unit) that the registry accepted. A tokenless event, the cmux tree and the session file never
    /// set it: they cannot prove that the surface runs an agent session.
    var heard: Bool = false

    var canFocusExactly: Bool {
        !surfaceId.isEmpty && !workspaceId.isEmpty && !socketPath.isEmpty && !capability.isEmpty
    }

    /// The one rule for typing into a surface: Coucou holds a token that came with the ids of this very surface
    /// in a hook event (its own unit). A surface known only through discovery or the session file has none, and a
    /// token of another surface, even on the same socket, is never lent to it.
    var canType: Bool { canFocusExactly && heard }
}

struct CmuxRegistry {
    /// Keyed by surface key.
    private(set) var surfaces: [String: CmuxSurface] = [:]
    /// Pill id → sticky main surface key.
    private(set) var mainKeys: [String: String] = [:]
    /// True when the last `note` created its entry (a surface the registry did not know).
    private(set) var lastNoteCreated = false
    /// True when the last `note` was the first event of its surface that carried an accepted valid context:
    /// a surface that discovery registered earlier, but whose hook never spoke, counts as new.
    private(set) var lastNoteFirstHeard = false

    private func count(ofTask taskId: String) -> Int { surfaces.values.filter { $0.taskId == taskId }.count }

    /// The pill a surface belongs to. One source of truth: an event routes to the pill of its surface's entry,
    /// whatever workspace it names, so a forged or stale workspace id never opens a second pill for a surface.
    func pillId(forKey key: String) -> String? { surfaces[key]?.taskId }

    /// Upsert from a hook event. surfaceId, workspaceId, socketPath and capability are one unit: replaced
    /// together and only when the incoming capability is non empty. Without a capability they stay as they
    /// were (lastSeen and sessionId are still refreshed) and the surface is not marked heard. A live entry (it
    /// has a socket path and a capability) never gets another socket path while its stored socket file is still
    /// a socket owned by the user: the whole unit is refused and false is returned. When that file is gone
    /// (cmux restarted somewhere else without a termination notice), the new unit is accepted.
    /// `key` is the surface key; without it the entry is keyed by the task id (one surface per task). An
    /// existing entry keeps its pill (`taskId` only places a new one).
    /// A pill never holds more than `maxSurfacesPerTask` surfaces: one more is not registered.
    @discardableResult
    mutating func note(taskId: String, key: String? = nil, surfaceId: String, workspaceId: String, socketPath: String,
                       capability: String, sessionId: String, now: TimeInterval,
                       isStoredSocketTrusted: (String) -> Bool = CmuxRouting.socketFileIsTrusted(path:)) -> Bool {
        let k = key ?? taskId
        let existing = surfaces[k]
        let isNew = existing == nil
        let wasHeard = existing?.heard ?? false
        lastNoteCreated = false
        lastNoteFirstHeard = false
        if isNew && count(ofTask: taskId) >= CmuxRouting.maxSurfacesPerTask { return true }
        var s = existing ?? CmuxSurface(taskId: taskId, surfaceId: "", workspaceId: "",
                                        socketPath: "", capability: "", sessionId: "",
                                        lastSeen: now, key: k)
        var accepted = true
        var unitAccepted = false
        if !capability.isEmpty {
            let live = !s.socketPath.isEmpty && !s.capability.isEmpty
            if live && s.socketPath != socketPath && isStoredSocketTrusted(s.socketPath) {
                accepted = false
            } else {
                s.surfaceId = surfaceId
                s.workspaceId = workspaceId
                s.socketPath = socketPath
                s.capability = capability
                unitAccepted = true
            }
        }
        if !sessionId.isEmpty { s.sessionId = sessionId }
        s.lastSeen = now
        if unitAccepted { s.heard = true }
        surfaces[k] = s
        lastNoteCreated = isNew
        lastNoteFirstHeard = unitAccepted && !wasHeard
        refreshMain(taskId: s.taskId)
        return accepted
    }

    /// Upsert from discovery (the cmux tree and session file). Sets ids, title, index, start time and
    /// session id. Never touches a token backed unit (its ids, socket path and token stay as the hook gave
    /// them), never sets a token, never marks the surface as heard: a surface known this way cannot be typed
    /// into. The tree is the authority on which workspace a surface is in: an entry filed under another pill is
    /// moved to `taskId`. lastSeen is refreshed only for an entry that was never heard: discovery must not keep
    /// a heard session alive after its process is gone (the time rule decides that).
    /// False when the pill is full and the surface is new or moves in.
    @discardableResult
    mutating func noteDiscovered(taskId: String, key: String, surfaceId: String, workspaceId: String,
                                 socketPath: String, sessionId: String, title: String?, index: Int?,
                                 startedAt: TimeInterval?, now: TimeInterval) -> Bool {
        let existing = surfaces[key]
        let arrives = existing == nil || existing?.taskId != taskId
        if arrives && count(ofTask: taskId) >= CmuxRouting.maxSurfacesPerTask { return false }
        var s = existing ?? CmuxSurface(taskId: taskId, surfaceId: "", workspaceId: "",
                                        socketPath: "", capability: "", sessionId: "",
                                        lastSeen: now, key: key)
        let oldTask = s.taskId
        s.taskId = taskId
        if s.capability.isEmpty {
            s.surfaceId = surfaceId
            s.workspaceId = workspaceId
            if !socketPath.isEmpty { s.socketPath = socketPath }
        }
        if !sessionId.isEmpty { s.sessionId = sessionId }
        if let title { s.title = title }
        if let index { s.index = index }
        if let startedAt { s.startedAt = startedAt }
        if !s.heard { s.lastSeen = now }
        surfaces[key] = s
        if oldTask != taskId { refreshMain(taskId: oldTask) }
        refreshMain(taskId: taskId)
        return true
    }

    /// The main surface of a pill is kept while it lives; a main without a tree index yields to a surface
    /// that has one (the first hook event of a workspace can come from a helper).
    private mutating func refreshMain(taskId: String) {
        let mine = surfaces.values.filter { $0.taskId == taskId }
        guard !mine.isEmpty else { mainKeys[taskId] = nil; return }
        mainKeys[taskId] = CmuxRouting.mainSurfaceKey(
            current: mainKeys[taskId],
            candidates: mine.map { (key: $0.key, index: $0.index, startedAt: $0.startedAt) })
    }

    mutating func setState(key: String, _ state: String) {
        surfaces[key]?.state = state
    }

    func surface(key: String) -> CmuxSurface? { surfaces[key] }

    /// The main surface of the pill.
    func surface(for taskId: String) -> CmuxSurface? {
        guard let key = mainKeys[taskId] else { return nil }
        return surfaces[key]
    }

    /// Surfaces of a pill, the main one first, then by index, start time and key.
    func surfaces(ofTask taskId: String) -> [CmuxSurface] {
        let mine = surfaces.values.filter { $0.taskId == taskId }
        let main = mainKeys[taskId]
        return mine.sorted { a, b in
            if (a.key == main) != (b.key == main) { return a.key == main }
            return CmuxRouting.surfaceOrder(a.key, a.index, a.startedAt, b.key, b.index, b.startedAt)
        }
    }

    var taskIds: Set<String> { Set(surfaces.values.map { $0.taskId }) }

    /// Most recent lastSeen of the surfaces of the pill.
    func pillLastSeen(_ taskId: String) -> TimeInterval? {
        surfaces.values.filter { $0.taskId == taskId }.map { $0.lastSeen }.max()
    }

    /// Folded state of the pill (see `CmuxRouting.foldedState`). nil when the pill has no surface.
    func foldedState(ofTask taskId: String) -> String? {
        let mine = surfaces.values.filter { $0.taskId == taskId }
        guard !mine.isEmpty else { return nil }
        return CmuxRouting.foldedState(mine.map { $0.state })
    }

    mutating func remove(key: String) {
        guard let s = surfaces.removeValue(forKey: key) else { return }
        refreshMain(taskId: s.taskId)
    }

    /// Every surface of the pill.
    mutating func remove(taskId: String) {
        for (k, s) in surfaces where s.taskId == taskId { surfaces[k] = nil }
        mainKeys[taskId] = nil
    }

    /// cmux quit: its tokens are dead. Entries and ids stay, so the next event restores them.
    mutating func clearCredentials() {
        for k in surfaces.keys { surfaces[k]?.capability = "" }
    }

    /// Credential order: the target's own token (its main surface), else the freshest live token, else
    /// the stored password, else none. Only entries that can address a surface count.
    func credential(for taskId: String?, hasPassword: Bool) -> CmuxCredential {
        if let taskId, let own = surface(for: taskId), own.canFocusExactly { return .token(own) }
        let freshest = surfaces.values.filter { $0.canFocusExactly }
            .max { ($0.lastSeen, $0.key) < ($1.lastSeen, $1.key) }
        if let freshest { return .token(freshest) }
        return hasPassword ? .password : CmuxCredential.none
    }

    /// Credential for typing into a surface: its own token, nothing else. Never the password, never a token of
    /// another surface on the same socket, never the ids that discovery read: only a hook event of this very
    /// surface proved that it runs an agent session and gave Coucou the token that goes with its ids.
    func sendCredential(forKey key: String) -> CmuxCredential {
        guard let target = surfaces[key], target.canType else { return CmuxCredential.none }
        return .token(target)
    }

    /// Credential for typing into the main surface of a pill.
    func sendCredential(for taskId: String) -> CmuxCredential {
        guard let key = mainKeys[taskId] else { return CmuxCredential.none }
        return sendCredential(forKey: key)
    }

    /// Credential for bringing a surface to the front (select a workspace, focus a panel: nothing is typed): its
    /// own token, else the freshest on the same socket. Never the password.
    func jumpCredential(forKey key: String) -> CmuxCredential {
        guard let target = surfaces[key] else { return CmuxCredential.none }
        if target.canFocusExactly { return .token(target) }
        guard !target.socketPath.isEmpty else { return CmuxCredential.none }
        let same = surfaces.values.filter { $0.canFocusExactly && $0.socketPath == target.socketPath }
            .max { ($0.lastSeen, $0.key) < ($1.lastSeen, $1.key) }
        if let same { return .token(same) }
        return CmuxCredential.none
    }

    /// Keys of the entries not seen for `staleAfter`, whatever their state, except those of a `protected`
    /// pill or key (a queued card, the card on screen, the open reply view). A `busy` pill or key (mid turn,
    /// hooks can stay silent for a long time) is stale only after `busyStaleAfter`. `only` narrows the
    /// entries the rule may remove (with an authoritative tree, only the ones the tree cannot account for).
    func staleTaskIds(now: TimeInterval, protected: Set<String>, busy: Set<String> = [],
                      only: (CmuxSurface) -> Bool = { _ in true }) -> [String] {
        surfaces.values
            .filter {
                let isBusy = busy.contains($0.taskId) || busy.contains($0.key)
                let limit = isBusy ? CmuxRouting.busyStaleAfter : CmuxRouting.staleAfter
                return now - $0.lastSeen > limit && !protected.contains($0.taskId)
                    && !protected.contains($0.key) && only($0)
            }
            .map { $0.key }
            .sorted()
    }

    /// Pill ids to evict so that the pill count <= maxTasks. Only ids listed in `idle`, oldest lastSeen
    /// first, never `keep`.
    func evictionCandidates(idle: Set<String>, keep: String?) -> [String] {
        let pills = taskIds
        let excess = pills.count - CmuxRouting.maxTasks
        guard excess > 0 else { return [] }
        let candidates = pills
            .filter { idle.contains($0) && $0 != keep }
            .sorted { (pillLastSeen($0) ?? 0, $0) < (pillLastSeen($1) ?? 0, $1) }
        return Array(candidates.prefix(excess))
    }
}

enum CmuxCredential: Equatable {
    case token(CmuxSurface)
    case password
    case none
}

enum CmuxPromptMode: Hashable {
    case reply(taskId: String)
    case newChat
}

/// A "New chat" waiting for the SessionStart of the surface it created. Memory only.
/// `workspaceId` is the workspace UUID resolved after `new-workspace` ("" when it could not be resolved),
/// `socketPath` the socket the token used ("" in password mode, where the CLI picks its own).
struct CmuxPendingLaunch: Equatable {
    var workspaceId: String
    var socketPath: String
    var cwd: String
    var prompt: String
    var createdAt: TimeInterval

    /// The prompt may be typed without a click only when the workspace and the socket are both known.
    var autoSendable: Bool { !workspaceId.isEmpty && !socketPath.isEmpty }

    /// A token launch whose workspace was not resolved: no SessionStart can ever match it (the folder
    /// fallback is for the password mode only), so waiting for it would only end in the timeout.
    var cannotBeMatched: Bool { workspaceId.isEmpty && !socketPath.isEmpty }

    private func fresh(isNewTask: Bool, now: TimeInterval) -> Bool {
        isNewTask && now >= createdAt && now - createdAt <= CmuxRouting.launchTimeout
    }

    /// New task, same workspace UUID (case insensitive) and same socket path. Empty ids never match.
    func matches(workspaceId: String, socketPath: String, isNewTask: Bool, now: TimeInterval) -> Bool {
        guard fresh(isNewTask: isNewTask, now: now), autoSendable, !workspaceId.isEmpty else { return false }
        return self.workspaceId.caseInsensitiveCompare(workspaceId) == .orderedSame && self.socketPath == socketPath
    }

    /// Fallback for a launch started with the socket password (no socket path): a new task in the same
    /// folder. It only focuses the session and offers the prompt as a draft, it never authorizes a send.
    /// A launch that used a token never takes this path: its workspace lookup failing is not a reason to
    /// trust a folder match.
    func matchesFolder(cwd: String, isNewTask: Bool, now: TimeInterval) -> Bool {
        guard fresh(isNewTask: isNewTask, now: now), socketPath.isEmpty, !cwd.isEmpty else { return false }
        return (self.cwd as NSString).standardizingPath == (cwd as NSString).standardizingPath
    }
}

enum CmuxCardKind { case approval, question }

struct CmuxQueuedCard: Equatable {
    var id: Int
    var kind: CmuxCardKind
    var taskId: String
    var sessionId: String
    var tool: String
    var inputKey: String
    var arrivedAt: TimeInterval
    /// Surface key of the session that asked. Defaults to the task id (one surface per pill).
    var surfaceKey: String = ""
}

struct CmuxCardQueue {
    /// Older entries are not worth presenting (the hook gives up at 118 s).
    static let maxAge: TimeInterval = 110
    static let maxCards = 16
    static let maxCardsPerSurface = 2
    static let maxCardsPerPill = 6
    private(set) var cards: [CmuxQueuedCard] = []
    private var nextId = 1

    /// False when the queue is full (16 in total, 2 per surface, 6 per pill): the request is answered
    /// "ask" at once. Without a surface key the task id stands for it.
    func canAccept(taskId: String, surfaceKey: String? = nil) -> Bool {
        let key = surfaceKey ?? taskId
        return cards.count < Self.maxCards
            && cards.filter { $0.surfaceKey == key }.count < Self.maxCardsPerSurface
            && cards.filter { $0.taskId == taskId }.count < Self.maxCardsPerPill
    }

    @discardableResult
    mutating func enqueue(kind: CmuxCardKind, taskId: String, sessionId: String, tool: String,
                          inputKey: String, now: TimeInterval, atFront: Bool = false,
                          arrivedAt: TimeInterval? = nil, surfaceKey: String? = nil) -> Int {
        let id = nextId
        nextId += 1
        let card = CmuxQueuedCard(id: id, kind: kind, taskId: taskId, sessionId: sessionId,
                                  tool: tool, inputKey: inputKey, arrivedAt: arrivedAt ?? now,
                                  surfaceKey: surfaceKey ?? taskId)
        if atFront { cards.insert(card, at: 0) } else { cards.append(card) }
        return id
    }

    /// Pops the first non-expired card; `expired` lists the ids skipped (caller closes their fds).
    mutating func popNext(now: TimeInterval) -> (card: CmuxQueuedCard?, expired: [Int]) {
        var expired: [Int] = []
        while !cards.isEmpty {
            let card = cards.removeFirst()
            if now - card.arrivedAt > Self.maxAge {
                expired.append(card.id)
            } else {
                return (card, expired)
            }
        }
        return (nil, expired)
    }

    /// Ids resolved elsewhere. PostToolUse/PostToolUseFailure: same session + tool + inputKey.
    /// Stop/StopFailure/UserPromptSubmit/SessionEnd/Interrupt: every card of that session. Removes them.
    mutating func resolve(event: String, sessionId: String, tool: String, inputKey: String) -> [Int] {
        guard !sessionId.isEmpty else { return [] }
        let matches: (CmuxQueuedCard) -> Bool
        switch event {
        case "PostToolUse", "PostToolUseFailure":
            matches = { $0.sessionId == sessionId && $0.tool == tool && $0.inputKey == inputKey }
        case "Stop", "StopFailure", "UserPromptSubmit", "SessionEnd", "Interrupt":
            matches = { $0.sessionId == sessionId }
        default:
            return []
        }
        let ids = cards.filter(matches).map { $0.id }
        cards.removeAll(where: matches)
        return ids
    }

    @discardableResult
    mutating func remove(id: Int) -> CmuxQueuedCard? {
        guard let i = cards.firstIndex(where: { $0.id == id }) else { return nil }
        return cards.remove(at: i)
    }

    mutating func removeAll(taskId: String) -> [Int] {
        let ids = cards.filter { $0.taskId == taskId }.map { $0.id }
        cards.removeAll { $0.taskId == taskId }
        return ids
    }

    mutating func removeAll(surfaceKey: String) -> [Int] {
        let ids = cards.filter { $0.surfaceKey == surfaceKey }.map { $0.id }
        cards.removeAll { $0.surfaceKey == surfaceKey }
        return ids
    }

    func hasCards(for taskId: String) -> Bool { cards.contains { $0.taskId == taskId } }

    func hasCards(forSurface key: String) -> Bool { cards.contains { $0.surfaceKey == key } }
}


/// The cmux sessions whose last Stop told nobody (silent, or its alert had nowhere to go) and that have not been given
/// the waiting badge since. A Stop that told someone, a new prompt, a StopFailure and a forgotten surface take the key
/// out; a waiting badge takes it out too, so one idle period gives the badge once. A session never recorded (fresh,
/// never stopped) is not a candidate. Bounded by what the registry can hold: a full record gives no badge rather than
/// an extra one.
struct CmuxStopRecord {
    static let capacity = CmuxRouting.maxTasks * CmuxRouting.maxSurfacesPerTask
    private var keys = Set<String>()

    func toldNobody(_ key: String) -> Bool { keys.contains(key) }

    mutating func stop(_ key: String, told: Bool) {
        if told { keys.remove(key) } else if keys.contains(key) || keys.count < Self.capacity { keys.insert(key) }
    }
    mutating func prompt(_ key: String) { keys.remove(key) }
    mutating func stopFailed(_ key: String) { keys.remove(key) }
    mutating func gaveWaitingBadge(_ key: String) { keys.remove(key) }
    mutating func forget(_ key: String) { keys.remove(key) }
}


extension CmuxRouting {
    /// The terminal a Claude Code session runs in (Warp, Terminal, iTerm…), for the terminal pill. cmux is not one:
    /// its sessions go to the cmux pill, and one that pill does not take stays ignored. cmux sets TERM_PROGRAM=ghostty,
    /// so the bundle id decides when it is present.
    static func terminalHost(termProgram: String, bundleId: String) -> ClaudeHost? {
        if bundleId.lowercased() == CmuxRouting.bundleId { return nil }
        let host = ClaudeHost.terminal(termProgram: termProgram, bundleId: bundleId)
        return host?.bundleId == CmuxRouting.bundleId ? nil : host
    }
}

#endif
