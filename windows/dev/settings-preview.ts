// The Settings window in a plain browser, on sample data: Tauri's invoke is
// faked so every section draws. `npm run dev`, then open
// /dev/settings-preview.html at 760x640 (the window's size). Not shipped.

const settings = {
  mochiName: "Mochi",
  activeIntegrations: ["integration_github", "integration_music", "integration_vercel"],
  models: [
    { id: "m-1", label: "Flux", kind: "openai", model: "flux", endpoint: "https://gen.pollinations.ai/v1", vision: null, output: "image", voice: "", detail: "" },
    { id: "m-2", label: "Whisper", kind: "openai", model: "whisper-large-v3-turbo", endpoint: "https://api.groq.com/openai/v1", vision: null, output: "stt", voice: "", detail: "" },
  ],
};

const answers: Record<string, unknown> = {
  boot: { settings, version: "0.3.0", screen: { x: 0, y: 0, width: 1920, height: 1080, scale: 1 }, hookPath: "", cursorPoll: true },
  hooks_status: { installed: true, planRelayInstalled: false, settingsPath: String.raw`C:\Users\you\.claude\settings.json`, hookPath: String.raw`C:\Program Files\Coucou\coucou-hook.exe`, hookReady: true },
  agent_hooks_list: [
    { id: "gemini", name: "Gemini CLI", installed: true, path: String.raw`C:\Users\you\.gemini\settings.json`, hookReady: true, approvals: true, note: "" },
    { id: "codex", name: "Codex", installed: false, path: String.raw`C:\Users\you\.codex\config.toml`, hookReady: true, approvals: false, note: "" },
    { id: "cursor", name: "Cursor", installed: false, path: String.raw`C:\Users\you\.cursor\hooks.json`, hookReady: true, approvals: true, note: "" },
  ],
  agent_hooks_status: { agent_gemini: true },
  shortcuts_status: { actions: [], blocked: null, command: "coucou.exe --shortcut" },
  list_monitors: [{ key: "at:0,0|DELL U2720Q", label: "DELL U2720Q" }],
  custom_sounds: [],
  recap_prefs: { enabled: true },
  endpoint_key: "groq-key",
  spotify_installed: true,
};

const present = new Set(["anthropic-api-key", "github-token", "groq-key"]);

let next = 1;
(window as any).__TAURI_INTERNALS__ = {
  metadata: { currentWindow: { label: "settings" }, currentWebview: { windowLabel: "settings", label: "settings" } },
  transformCallback: () => next++,
  unregisterCallback: () => {},
  convertFileSrc: (p: string) => p,
  invoke: async (cmd: string, args: Record<string, unknown> = {}) => {
    if (cmd === "secret_present") return present.has(String(args.key));
    if (cmd.startsWith("plugin:event")) return next++;
    return answers[cmd] ?? null;
  },
};
(window as any).__TAURI_EVENT_PLUGIN_INTERNALS__ = { unregisterListener: () => {} };

await import("../src/settings/main");
