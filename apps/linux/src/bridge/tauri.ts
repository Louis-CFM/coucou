export function isTauri(): boolean {
  if (typeof window === "undefined") return false;
  const w = window as Window & { __TAURI_INTERNALS__?: unknown };
  return w.__TAURI_INTERNALS__ !== undefined;
}

async function invoke<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const { invoke: tauriInvoke } = await import("@tauri-apps/api/core");
  return tauriInvoke<T>(cmd, args);
}

export type PermissionDecision = "allow" | "always" | "deny";

export interface DisplayInfo {
  width: number;
  height: number;
  scale: number;
  x: number;
  y: number;
}

export interface ActiveWindowInfo {
  app: string;
  title: string;
  url?: string;
  available: boolean;
  backend: string;
  reason?: string;
}

export interface SecretsStatus {
  secureStorageAvailable: boolean;
  secureStorageBackend: string;
}

export type SessionType = "wayland" | "x11" | "unknown";

const DEV_HOOK_HTTP =
  (typeof import.meta !== "undefined" &&
    (import.meta as ImportMeta & { env?: { VITE_COUCOU_HOOK_HTTP?: string } }).env
      ?.VITE_COUCOU_HOOK_HTTP) ||
  "http://127.0.0.1:1421";

export async function listenHookEvent(
  handler: (payload: unknown) => void,
): Promise<() => void> {
  if (isTauri()) {
    const { listen } = await import("@tauri-apps/api/event");
    const unlisten = await listen("hook-event", (ev) => {
      handler(ev.payload);
    });
    return unlisten;
  }
  // Browser / Vite dev: SSE bridge from scripts/linux-hook-dev-server.mjs
  const es = new EventSource(`${DEV_HOOK_HTTP}/events`);
  es.onmessage = (ev) => {
    try {
      handler(JSON.parse(ev.data));
    } catch {
      /* ignore */
    }
  };
  es.onerror = () => {
    /* server may not be up yet — EventSource retries */
  };
  return () => es.close();
}

export async function permissionDecision(
  sessionId: string,
  decision: PermissionDecision,
): Promise<void> {
  if (isTauri()) {
    await invoke("permission_decision", { sessionId, decision });
    return;
  }
  try {
    await fetch(`${DEV_HOOK_HTTP}/permission`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ sessionId, decision }),
    });
  } catch (e) {
    console.debug("[coucou] permissionDecision (dev bridge unreachable)", e);
  }
}

export async function secretsGet(key: string): Promise<string | null> {
  if (!isTauri()) return null;
  const v = await invoke<string | null>("secrets_get", { key });
  return v;
}

export async function secretsSet(key: string, value: string): Promise<void> {
  if (!isTauri()) return;
  await invoke("secrets_set", { key, value });
}

export async function secretsStatus(): Promise<SecretsStatus> {
  if (!isTauri()) {
    return {
      secureStorageAvailable: false,
      secureStorageBackend: "browser-dev",
    };
  }
  return invoke<SecretsStatus>("secrets_status");
}

export async function previewClaudeHooks(): Promise<string> {
  if (!isTauri()) return "{}";
  return invoke<string>("preview_claude_hooks");
}

export async function writeClaudeHooks(): Promise<void> {
  if (!isTauri()) return;
  await invoke("write_claude_hooks");
}

export async function uninstallClaudeHooks(): Promise<void> {
  if (!isTauri()) return;
  await invoke("uninstall_claude_hooks");
}

export async function hooksInstalled(): Promise<boolean> {
  if (!isTauri()) return false;
  return invoke<boolean>("hooks_installed");
}

export async function positionIsland(panelW: number, panelH: number): Promise<void> {
  if (!isTauri()) return;
  await invoke("position_island", { panelW, panelH });
}

export async function setClickThrough(enabled: boolean): Promise<void> {
  if (!isTauri()) return;
  await invoke("set_click_through", { enabled });
}

export async function getDisplayInfo(): Promise<DisplayInfo | null> {
  if (!isTauri()) return null;
  try {
    return await invoke<DisplayInfo>("get_display_info");
  } catch {
    return null;
  }
}

export async function getActiveWindow(): Promise<ActiveWindowInfo> {
  if (!isTauri()) {
    return {
      app: "",
      title: "",
      available: false,
      backend: "browser-dev",
      reason: "not in Tauri",
    };
  }
  return invoke<ActiveWindowInfo>("get_active_window");
}

export async function getSessionType(): Promise<SessionType> {
  if (!isTauri()) return "unknown";
  const info = await invoke<{ session: SessionType }>("get_session_info");
  return info.session;
}

export interface CodexAuthStateDto {
  authenticated: boolean;
  accountLabel?: string | null;
  provider: string;
  status: string;
  error?: string | null;
  loginId?: string | null;
  authUrl?: string | null;
  verificationUrl?: string | null;
  userCode?: string | null;
  mode?: string | null;
}

export async function codexStatus(): Promise<CodexAuthStateDto> {
  if (!isTauri()) {
    return {
      authenticated: false,
      provider: "openai-codex",
      status: "disconnected",
    };
  }
  return invoke<CodexAuthStateDto>("codex_status");
}

export async function codexGetAuthState(): Promise<CodexAuthStateDto> {
  if (!isTauri()) {
    return {
      authenticated: false,
      provider: "openai-codex",
      status: "disconnected",
    };
  }
  return invoke<CodexAuthStateDto>("codex_get_auth_state");
}

export async function codexLoginChatGPT(): Promise<CodexAuthStateDto> {
  return invoke<CodexAuthStateDto>("codex_login_chatgpt");
}

export async function codexLoginDeviceCode(): Promise<CodexAuthStateDto> {
  return invoke<CodexAuthStateDto>("codex_login_device_code");
}

export async function codexCancelLogin(loginId: string): Promise<CodexAuthStateDto> {
  return invoke<CodexAuthStateDto>("codex_login_cancel", { loginId });
}

export async function codexLogout(): Promise<CodexAuthStateDto> {
  return invoke<CodexAuthStateDto>("codex_logout");
}

export async function listenCodexAuth(
  handler: (payload: CodexAuthStateDto) => void,
): Promise<() => void> {
  if (!isTauri()) return () => {};
  const { listen } = await import("@tauri-apps/api/event");
  const unlisten = await listen<CodexAuthStateDto>("codex-auth", (ev) => {
    handler(ev.payload);
  });
  return unlisten;
}

export async function listenCodexAgentState(
  handler: (payload: unknown) => void,
): Promise<() => void> {
  if (!isTauri()) return () => {};
  const { listen } = await import("@tauri-apps/api/event");
  const unlisten = await listen("codex-agent-state", (ev) => {
    handler(ev.payload);
  });
  return unlisten;
}

export interface DesktopActionResult {
  ok: boolean;
  message: string;
  data?: string | null;
}

export async function desktopOpen(target: string): Promise<DesktopActionResult> {
  if (!isTauri()) return { ok: false, message: "desktop app required" };
  return invoke<DesktopActionResult>("desktop_open", { target });
}

export async function desktopTypeText(text: string): Promise<DesktopActionResult> {
  if (!isTauri()) return { ok: false, message: "desktop app required" };
  return invoke<DesktopActionResult>("desktop_type_text", { text });
}

export async function desktopKey(keys: string): Promise<DesktopActionResult> {
  if (!isTauri()) return { ok: false, message: "desktop app required" };
  return invoke<DesktopActionResult>("desktop_key", { keys });
}

export async function desktopMedia(action: string): Promise<DesktopActionResult> {
  if (!isTauri()) return { ok: false, message: "desktop app required" };
  return invoke<DesktopActionResult>("desktop_media", { action });
}

export async function desktopScreenshot(): Promise<DesktopActionResult> {
  if (!isTauri()) return { ok: false, message: "desktop app required" };
  return invoke<DesktopActionResult>("desktop_screenshot");
}

export async function desktopSessionHint(): Promise<DesktopActionResult> {
  if (!isTauri()) return { ok: false, message: "browser", data: "" };
  return invoke<DesktopActionResult>("desktop_session_hint");
}

export async function listenDesktopHotkey(
  handler: () => void,
): Promise<() => void> {
  if (!isTauri()) return () => {};
  const { listen } = await import("@tauri-apps/api/event");
  const unlisten = await listen("desktop-hotkey", () => handler());
  return unlisten;
}
