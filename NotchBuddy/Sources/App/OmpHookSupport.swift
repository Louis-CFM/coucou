import Foundation

// Oh My Pi (omp) hook support — self-contained so tests can compile it alone
// (see scripts/test-omp-hook.sh). HookServer installs `OmpHook.source` into
// omp's user-level hook discovery directory; omp loads it as a TS hook factory
// and the file forwards omp events to Coucou over the agent socket.

enum OmpHook {
    /// The `coucou_agent` name omp events are tagged with (pill id: `agent_oh-my-pi`).
    static let agentName = "oh-my-pi"

    /// Comment every Coucou-written hook file carries; `owns(content:)` keys on it.
    static let marker = "Managed by Coucou"

    /// Where the hook file lives inside a given home directory.
    static func hookPath(home: String) -> String {
        (home as NSString).appendingPathComponent(".omp/agent/hooks/pre/coucou.ts")
    }

    /// True when the file content was written by Coucou (safe to overwrite or delete).
    static func owns(content: String?) -> Bool {
        guard let content, !content.isEmpty else { return false }
        return content.contains(marker)
    }

    /// The TypeScript hook omp discovers and runs. Talks to the socket directly
    /// (docs/AGENTS.md "Payload format"), never blocks or breaks the session.
    static let source: String = #"""
// Managed by Coucou — this file is overwritten by the Oh My Pi hooks installer.
// It forwards omp events to the Coucou island. Uninstall from Coucou's Settings
// (or delete this file) to stop the integration.
import * as net from "node:net";
import * as os from "node:os";
import * as path from "node:path";

const AGENT = "oh-my-pi";
const CONNECT_TIMEOUT_MS = 400;

interface MinimalPi {
    on(event: string, handler: (event: any, ctx: any) => void): unknown;
}

function socketCandidates(): string[] {
    const home = os.homedir();
    if (process.platform === "win32") {
        const sid = (os.userInfo() as { sid?: string }).sid;
        return sid ? ["\\\\.\\pipe\\coucou-" + sid] : [];
    }
    if (process.platform === "darwin") {
        return [
            path.join(home, "Library", "Application Support", "NotchBuddy", "nb.sock"),
            path.join(home, "Library", "Containers", "fr.louisraille.Coucou", "Data", "nb.sock"),
        ];
    }
    const paths: string[] = [];
    if (process.env.XDG_RUNTIME_DIR) {
        paths.push(path.join(process.env.XDG_RUNTIME_DIR, "coucou.sock"));
    }
    if (typeof process.getuid === "function") {
        paths.push(path.join("/run", "user", String(process.getuid()), "coucou.sock"));
    }
    return paths;
}

let resolvedPath: string | null = null;
const queue: string[] = [];
let sending = false;

function base(ctx: any): Record<string, unknown> {
    let sessionId = "unknown";
    let cwd = "";
    try {
        sessionId = ctx.sessionManager.getSessionId() || "unknown";
        cwd = ctx.sessionManager.getCwd() || "";
    } catch {
        // Never break the session because Coucou's payload is incomplete.
    }
    return { coucou_agent: AGENT, session_id: sessionId, cwd: cwd };
}

function emit(event: string, extra: Record<string, unknown>, ctx: any): void {
    try {
        const payload = Object.assign({ hook_event_name: event }, base(ctx), extra);
        queue.push(JSON.stringify(payload) + "\n");
        if (queue.length > 16) { queue.shift(); }
        pump();
    } catch {
        // Never break the session.
    }
}

function pump(): void {
    if (sending) { return; }
    const line = queue.shift();
    if (!line) { return; }
    sending = true;
    const onDone = () => {
        sending = false;
        if (queue.length > 0) { pump(); }
    };
    const candidates = resolvedPath
        ? [resolvedPath].concat(socketCandidates().filter((p) => p !== resolvedPath))
        : socketCandidates();
    try {
        tryNext(candidates, 0, line, onDone);
    } catch {
        onDone();
    }
}

function tryNext(candidates: string[], index: number, line: string, onDone: () => void): void {
    if (index >= candidates.length) {
        onDone();
        return;
    }
    const target = candidates[index];
    let settled = false;
    const socket = net.connect(target);
    const timer = setTimeout(() => {
        if (!settled) {
            settled = true;
            socket.destroy();
            if (resolvedPath === target) { resolvedPath = null; }
            tryNext(candidates, index + 1, line, onDone);
        }
    }, CONNECT_TIMEOUT_MS);
    socket.on("connect", () => {
        if (settled) { socket.destroy(); return; }
        settled = true;
        clearTimeout(timer);
        resolvedPath = target;
        socket.on("error", () => { socket.destroy(); });
        socket.end(line, () => { socket.destroy(); });
        socket.on("close", () => { onDone(); });
    });
    socket.on("error", () => {
        if (settled) { socket.destroy(); return; }
        settled = true;
        clearTimeout(timer);
        socket.destroy();
        if (resolvedPath === target) { resolvedPath = null; }
        tryNext(candidates, index + 1, line, onDone);
    });
}

export default function coucouRelay(pi: MinimalPi): void {
    pi.on("session_start", (_event, ctx) => {
        emit("SessionStart", {}, ctx);
    });
    pi.on("before_agent_start", (event, ctx) => {
        emit("UserPromptSubmit", { prompt: String((event && event.prompt) || "") }, ctx);
    });
    pi.on("tool_call", (event, ctx) => {
        const toolName = String((event && event.toolName) || "tool");
        emit("PreToolUse", { tool_name: toolName, tool_input: (event && event.input) || {} }, ctx);
    });
    pi.on("tool_result", (event, ctx) => {
        const toolName = String((event && event.toolName) || "tool");
        const name = event && event.isError ? "PostToolUseFailure" : "PostToolUse";
        emit(name, { tool_name: toolName, tool_input: (event && event.input) || {} }, ctx);
    });
    pi.on("agent_end", (event, ctx) => {
        if (!(event && event.willContinue)) {
            emit("Stop", {}, ctx);
        }
    });
    pi.on("session_shutdown", (_event, ctx) => {
        emit("SessionEnd", {}, ctx);
    });
}
"""#
}
