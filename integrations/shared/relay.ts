import { spawn } from "node:child_process";
import { homedir } from "node:os";
import { posix, win32 } from "node:path";

export type Agent = "pi" | "oh-my-pi";
export type HookEvent =
  | { hook_event_name: "SessionStart" | "SessionEnd" | "UserPromptSubmit" | "Stop" | "StopFailure" | "Interrupt" }
  | { hook_event_name: "PreToolUse" | "PostToolUse" | "PostToolUseFailure"; tool_name: string };
export type Session = { session_id: string; cwd: string };

/** Use Coucou's installed relay, including its socket discovery and peer checks. */
export function relayCommand(
  platform = process.platform,
  env = process.env,
  home = homedir(),
): { command: string; args: string[] } | undefined {
  const paths = platform === "win32" ? win32 : posix;
  let path = env.COUCOU_HOOK_PATH;
  if (!path) {
    switch (platform) {
      case "darwin": path = paths.join(home, "Library/Application Support/NotchBuddy/nb-hook"); break;
      case "linux": path = paths.join(env.XDG_DATA_HOME || paths.join(home, ".local/share"), "coucou/bin/coucou-hook"); break;
      case "win32":
        if (!env.LOCALAPPDATA) return;
        path = paths.join(env.LOCALAPPDATA, "Coucou/bin/coucou-hook.exe");
        break;
      default: return;
    }
  }
  if (!paths.isAbsolute(path)) return;
  return platform === "darwin" ? { command: "/bin/sh", args: [path] } : { command: path, args: [] };
}

const MAX_PENDING = 32;
const DELIVERY_MS = 500;

/** One bounded FIFO per extension instance; event handlers never wait on I/O. */
export function createRelay(agent: Agent) {
  const command = relayCommand();
  let pending: { session: Session; event: HookEvent }[] = [];
  let cancel: (() => void) | undefined;
  let stopped = false;

  function next(): void {
    const item = pending.shift();
    if (!command || !item || stopped) return;
    try {
      const child = spawn(command.command, [...command.args, "--agent", agent], {
        stdio: ["pipe", "ignore", "ignore"],
        detached: process.platform !== "win32",
        windowsHide: true,
      });
      const kill = () => {
        // nb-hook is a shell wrapper around Python: end its whole process group.
        try {
          if (process.platform !== "win32" && child.pid) process.kill(-child.pid, "SIGKILL");
          else child.kill("SIGKILL");
        } catch { /* Already exited. */ }
      };
      const timer = setTimeout(kill, DELIVERY_MS);
      timer.unref();
      cancel = () => { clearTimeout(timer); kill(); };
      child.on("error", () => {});
      child.stdin.on("error", () => {});
      child.once("close", () => {
        clearTimeout(timer);
        cancel = undefined;
        next();
      });
      child.stdin.end(JSON.stringify({ ...item.session, ...item.event, coucou_agent: agent }) + "\n");
    } catch {
      cancel = undefined;
      pending.length = 0;
    }
  }

  return {
    send(session: Session, event: HookEvent): void {
      if (!command || stopped) return;
      if (pending.length >= MAX_PENDING / 2
          && ["Stop", "StopFailure", "Interrupt", "SessionEnd"].includes(event.hook_event_name)) {
        // Under load, a final state supersedes queued tool updates from that
        // session. Keep lifecycle records so SessionEnd still reaches Coucou.
        pending = pending.filter(item => item.session.session_id !== session.session_id
          || ["SessionStart", "SessionEnd", "Stop", "StopFailure", "Interrupt"].includes(item.event.hook_event_name));
      }
      // Drop oldest undelivered metadata on overload, retaining the newest state.
      if (pending.length === MAX_PENDING) pending.shift();
      pending.push({ session, event });
      if (!cancel) next();
    },
    async close(): Promise<void> {
      // A quit is the only handler allowed to wait, for at most one second.
      const deadline = Date.now() + 1000;
      while ((cancel || pending.length) && Date.now() < deadline) {
        await new Promise<void>(resolve => setTimeout(resolve, 10));
      }
      stopped = true;
      pending.length = 0;
      cancel?.();
    },
  };
}
