import type { AppState } from "../core/state.js";
import { BOT_STATES } from "../bot/engine.js";
import {
  hooksInstalled,
  isTauri,
  previewClaudeHooks,
  secretsGet,
  secretsSet,
  uninstallClaudeHooks,
  writeClaudeHooks,
} from "../bridge/tauri.js";
import { CodexProvider } from "../services/ai/codex-provider.js";
import type { ProviderAuthInfo } from "../services/ai/types.js";
import { runDesktopRequest } from "../services/desktop-control.js";

export interface ViewActions {
  goView: (view: import("../core/types.js").IslandView) => void;
  collapse: () => void;
  permissionDecision: (decision: "allow" | "always" | "deny") => void;
  appendPrompt: (text: string, role?: "user" | "assistant") => void;
  playSound: (name: string) => void;
}

let hooksStatusEl: HTMLElement | null = null;
const codexProvider = new CodexProvider();
let codexAuth: ProviderAuthInfo | null = null;
let codexLoginId: string | null = null;

function focusTask(state: AppState): import("../core/types.js").AgentTask | undefined {
  return state.focusTask;
}

function setText(root: ParentNode, sel: string, text: string): void {
  root.querySelectorAll(sel).forEach((el) => {
    el.textContent = text;
  });
}

function syncTicker(state: AppState, island: HTMLElement): void {
  const task = focusTask(state);
  const tk = island.querySelector("#tk");
  if (!tk || !task) return;
  const lines = tk.querySelectorAll(".ln span");
  const steps = task.steps;
  const L = steps.length;
  const idx = task.stepIndex;
  const txt = (i: number) => (L ? steps[((i % L) + L) % L] : "");
  if (lines.length >= 3) {
    lines[0].textContent = txt(idx - 1);
    lines[1].textContent = txt(idx);
    lines[2].textContent = txt(idx + 1);
  }
}

function syncBotGlow(island: HTMLElement, state: AppState): void {
  const glow = island.querySelector(".botwrap .glow") as HTMLElement | null;
  if (!glow) return;
  const st = state.effectiveState;
  const cfg = BOT_STATES[st];
  glow.style.setProperty("--g", cfg.glow);
  glow.style.setProperty("--go", String(cfg.glowOpacity));
}

export function syncViews(island: HTMLElement, state: AppState): void {
  const task = focusTask(state);
  const toolLabel =
    task?.source === "n8n" ? "n8n" : task?.isIntegration ? "Claude Code" : "Claude Code";

  island.querySelectorAll('[data-f="dot"]').forEach((el) => {
    (el as HTMLElement).style.setProperty("--c", task?.color ?? "#fff");
  });
  setText(island, '[data-f="name"]', task?.name ?? "");
  setText(island, '[data-f="tool"]', toolLabel);

  syncTicker(state, island);
  syncBotGlow(island, state);

  const approval = state.pendingApproval;
  setText(
    island,
    '[data-f="command"]',
    approval?.command ?? approval?.tool ?? "",
  );

  const lastStep = task?.steps[task.stepIndex] ?? "";
  setText(island, '[data-f="question"]', lastStep || "…");
  setText(island, '[data-f="finishmsg"]', lastStep || "Session finished.");
  setText(island, '[data-f="errmsg"]', lastStep || "Check the terminal for details.");

  const fileName = state.droppedFile?.name ?? "file";
  setText(island, '[data-f="file"]', fileName);

  const upBar = island.querySelector("#upBar") as HTMLElement | null;
  const upPct = island.querySelector("#upPct");
  if (upBar) upBar.style.width = `${Math.round(state.uploadProgress * 100)}%`;
  if (upPct) upPct.textContent = `${Math.round(state.uploadProgress * 100)} %`;

  const drop = island.querySelector("#drop");
  drop?.classList.toggle("over", state.fileDragOver);

  const chatLog = island.querySelector("#chatLog");
  if (chatLog) {
    chatLog.innerHTML = state.chatHistory
      .slice(-8)
      .map(
        (m) =>
          `<div class="msg ${m.role}">${escapeHtml(m.content)}</div>`,
      )
      .join("");
  }

  const ctx = island.querySelector("#ctxChips");
  if (ctx && state.promptContext?.kind === "window") {
    ctx.innerHTML = `<span class="chip ctx"><i></i>${escapeHtml(state.promptContext.appName)}</span>`;
  } else if (ctx) {
    ctx.innerHTML = "";
  }

  const hdrCount = island.querySelector("#hdrCount");
  if (hdrCount) {
    hdrCount.textContent =
      state.tasks.length > 0 ? `${state.tasks.length} running` : "";
  }

  const sndBtn = island.querySelector("#hdrSnd");
  sndBtn?.classList.toggle("muted", !state.soundEnabled);

  island.querySelectorAll(".view").forEach((v) => {
    const viewName = (v as HTMLElement).dataset.view;
    const on =
      state.mode === "expanded" &&
      viewName === state.view;
    v.classList.toggle("on", on);
  });

  island.querySelectorAll(".tab").forEach((t) => {
    const go = (t as HTMLElement).dataset.go;
    const active =
      go === state.view ||
      (go === "overview" && (state.view === "overview" || state.view === "empty")) ||
      (go === "settings" && state.view === "settings");
    t.classList.toggle("on", active);
  });

  syncSettingsPanel(island, state);
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;");
}

async function syncSettingsPanel(island: HTMLElement, state: AppState): Promise<void> {
  if (state.view !== "settings" && state.mode !== "expanded") return;

  const sound = island.querySelector("#setSound") as HTMLInputElement | null;
  const vol = island.querySelector("#setVolume") as HTMLInputElement | null;
  if (sound && sound !== document.activeElement) sound.checked = state.soundEnabled;
  if (vol && vol !== document.activeElement) vol.value = String(state.soundVolume);

  hooksStatusEl = island.querySelector("#hooksStatus");
  if (hooksStatusEl && !hooksStatusEl.dataset.loaded) {
    hooksStatusEl.dataset.loaded = "1";
    try {
      const installed = await hooksInstalled();
      hooksStatusEl.textContent = installed
        ? "Coucou hooks installed in ~/.claude/settings.json"
        : "Hooks not installed";
    } catch (e) {
      hooksStatusEl.textContent = String(e);
    }
  }

  const apiKey = island.querySelector("#apiKey") as HTMLInputElement | null;
  if (apiKey && !apiKey.dataset.loaded) {
    apiKey.dataset.loaded = "1";
    const key = await secretsGet("anthropic-api-key");
    if (key) apiKey.placeholder = "•••••••• (saved)";
  }

  if (!codexAuth) {
    try {
      codexAuth = await codexProvider.getAuth();
    } catch {
      /* ignore */
    }
  }
  renderCodexPanel(island, codexAuth);
}

export function applyCodexAuthUpdate(island: HTMLElement | null, info: ProviderAuthInfo): void {
  codexAuth = info;
  if (info.loginId) codexLoginId = info.loginId;
  if (island) renderCodexPanel(island, info);
}

function renderCodexPanel(island: HTMLElement, info: ProviderAuthInfo | null): void {
  const statusEl = island.querySelector("#codexStatus");
  const accountEl = island.querySelector("#codexAccount") as HTMLElement | null;
  const deviceEl = island.querySelector("#codexDevice") as HTMLElement | null;
  const errEl = island.querySelector("#codexError") as HTMLElement | null;
  const tipEl = island.querySelector("#codexTip") as HTMLElement | null;
  const disc = island.querySelector("#codexActionsDisconnected") as HTMLElement | null;
  const wait = island.querySelector("#codexActionsWaiting") as HTMLElement | null;
  const conn = island.querySelector("#codexActionsConnected") as HTMLElement | null;

  if (!info) {
    if (statusEl) statusEl.textContent = "Status: …";
    return;
  }

  const inApp = isTauri();
  if (tipEl) {
    tipEl.hidden = inApp;
  }

  const label =
    info.status === "connected"
      ? "Connected to ChatGPT"
      : info.status === "waiting"
        ? "Waiting for ChatGPT sign in…"
        : info.status === "error"
          ? "Error"
          : "Disconnected";
  if (statusEl) statusEl.textContent = `Status: ${label}`;

  if (accountEl) {
    if (info.authenticated && info.accountLabel) {
      accountEl.hidden = false;
      accountEl.textContent = info.accountLabel;
    } else {
      accountEl.hidden = true;
      accountEl.textContent = "";
    }
  }

  if (deviceEl) {
    if (info.mode === "device_code" && (info.verificationUrl || info.userCode)) {
      deviceEl.hidden = false;
      deviceEl.textContent = [
        info.verificationUrl ? `URL: ${info.verificationUrl}` : "",
        info.userCode ? `Code: ${info.userCode}` : "",
      ]
        .filter(Boolean)
        .join(" · ");
    } else {
      deviceEl.hidden = true;
    }
  }

  if (errEl) {
    // Never surface the Vite/browser tip as a red error banner.
    const showErr = !!(info.error && inApp);
    errEl.hidden = !showErr;
    errEl.textContent = showErr ? (info.error ?? "") : "";
  }

  const waiting = info.status === "waiting";
  const connected = info.status === "connected" && info.authenticated;
  if (disc) {
    disc.hidden = waiting || connected || !inApp;
  }
  if (wait) wait.hidden = !waiting;
  if (conn) conn.hidden = !connected;
}

export function bindViewControls(
  island: HTMLElement,
  state: AppState,
  actions: ViewActions,
): void {
  island.addEventListener("click", (e) => {
    const target = e.target as HTMLElement;
    const go = target.closest("[data-go]") as HTMLElement | null;
    if (go?.dataset.go) {
      e.stopPropagation();
      actions.goView(go.dataset.go as import("../core/types.js").IslandView);
      return;
    }

    const act = target.closest("[data-act]") as HTMLElement | null;
    if (!act?.dataset.act) return;
    e.stopPropagation();
    void handleAction(act.dataset.act, state, actions, island);
  });

  const sndBtn = island.querySelector("#hdrSnd");
  sndBtn?.addEventListener("click", (e) => {
    e.stopPropagation();
    state.setSoundEnabled(!state.soundEnabled);
    actions.playSound("blip");
  });

  const setSound = island.querySelector("#setSound") as HTMLInputElement | null;
  setSound?.addEventListener("change", () => {
    state.setSoundEnabled(setSound.checked);
  });

  const setVolume = island.querySelector("#setVolume") as HTMLInputElement | null;
  setVolume?.addEventListener("input", () => {
    state.setSoundVolume(Number(setVolume.value));
  });

  const promptIn = island.querySelector("#promptIn") as HTMLInputElement | null;
  promptIn?.addEventListener("keydown", (ev) => {
    if (ev.key === "Enter") {
      ev.preventDefault();
      submitPrompt(promptIn, actions);
    }
  });
}

function submitPrompt(input: HTMLInputElement, actions: ViewActions): void {
  const v = input.value.trim();
  if (!v) return;
  input.value = "";
  actions.appendPrompt(v);
  actions.playSound("send");

  // Desktop control: open apps, media, type, analyze screen (Shift+M flow).
  void runDesktopRequest(v, (text) => actions.appendPrompt(text, "assistant")).then((res) => {
    if (res.analysis) return;
    const fails = res.results.filter((r) => !r.ok);
    if (fails.length) {
      actions.appendPrompt(fails.map((f) => f.message).join(" · "), "assistant");
    } else if (res.plan.summary && res.results.length) {
      actions.appendPrompt(`✓ ${res.plan.summary}`, "assistant");
    }
  });
}

async function handleAction(
  act: string,
  state: AppState,
  actions: ViewActions,
  island: HTMLElement,
): Promise<void> {
  switch (act) {
    case "ask":
    case "file-ask":
      actions.goView("prompt");
      break;
    case "allow":
      actions.permissionDecision("allow");
      break;
    case "always":
      actions.permissionDecision("always");
      break;
    case "deny":
      actions.permissionDecision("deny");
      break;
    case "ok":
    case "close":
      state.isPinned = false;
      actions.collapse();
      break;
    case "send-prompt": {
      const input = island.querySelector("#promptIn") as HTMLInputElement | null;
      if (input) submitPrompt(input, actions);
      break;
    }
    case "hooks-preview": {
      hooksStatusEl = island.querySelector("#hooksStatus");
      try {
        const preview = await previewClaudeHooks();
        if (hooksStatusEl) {
          hooksStatusEl.textContent = `Preview ready (${preview.length} bytes). Click Install to write.`;
        }
      } catch (err) {
        if (hooksStatusEl) hooksStatusEl.textContent = String(err);
      }
      break;
    }
    case "hooks-install": {
      hooksStatusEl = island.querySelector("#hooksStatus");
      try {
        await previewClaudeHooks();
        await writeClaudeHooks();
        if (hooksStatusEl) {
          hooksStatusEl.textContent = "Hooks installed.";
        }
      } catch (err) {
        if (hooksStatusEl) hooksStatusEl.textContent = String(err);
      }
      break;
    }
    case "hooks-uninstall": {
      hooksStatusEl = island.querySelector("#hooksStatus");
      try {
        await uninstallClaudeHooks();
        if (hooksStatusEl) hooksStatusEl.textContent = "Hooks uninstalled.";
      } catch (err) {
        if (hooksStatusEl) hooksStatusEl.textContent = String(err);
      }
      break;
    }
    case "save-api": {
      const apiKey = island.querySelector("#apiKey") as HTMLInputElement | null;
      if (apiKey?.value.trim()) {
        await secretsSet("anthropic-api-key", apiKey.value.trim());
        apiKey.value = "";
        apiKey.placeholder = "•••••••• (saved)";
        actions.playSound("blip");
      }
      break;
    }
    case "codex-login": {
      try {
        const info = await codexProvider.signInWithChatGPT!();
        codexLoginId = info.loginId ?? null;
        applyCodexAuthUpdate(island, info);
        actions.playSound("blip");
      } catch (err) {
        applyCodexAuthUpdate(island, {
          provider: "openai-codex",
          authenticated: false,
          status: "error",
          error: err instanceof Error ? err.message : String(err),
        });
      }
      break;
    }
    case "codex-device": {
      try {
        const info = await codexProvider.signInWithDeviceCode!();
        codexLoginId = info.loginId ?? null;
        applyCodexAuthUpdate(island, info);
      } catch (err) {
        applyCodexAuthUpdate(island, {
          provider: "openai-codex",
          authenticated: false,
          status: "error",
          error: err instanceof Error ? err.message : String(err),
        });
      }
      break;
    }
    case "codex-cancel": {
      if (codexLoginId) {
        const info = await codexProvider.cancelLogin!(codexLoginId);
        applyCodexAuthUpdate(island, info);
      }
      break;
    }
    case "codex-logout": {
      const info = await codexProvider.disconnect!();
      applyCodexAuthUpdate(island, info);
      actions.playSound("close");
      break;
    }
    default:
      break;
  }
}
