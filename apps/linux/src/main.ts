import "./styles.css";
import { appState } from "./core/state.js";
import { applyHookEvent, type HookEvent } from "./services/hooks-client.js";
import { audio } from "./services/audio.js";
import { startIsland, type IslandController } from "./ui/island.js";
import {
  listenCodexAgentState,
  listenCodexAuth,
  listenDesktopHotkey,
  listenHookEvent,
  positionIsland,
  type CodexAuthStateDto,
} from "./bridge/tauri.js";
import { applyCodexAuthUpdate } from "./ui/views.js";
import { companionStateFromAgent } from "./services/ai/event-adapter.js";
import type { NormalizedAgentState, ProviderAuthInfo } from "./services/ai/types.js";
import { runDesktopRequest } from "./services/desktop-control.js";

declare global {
  interface Window {
    __coucou?: {
      appState?: typeof appState;
      fsm?: IslandController["fsm"];
      expandTo?: IslandController["expandTo"];
      collapse?: IslandController["collapse"];
      simulateHook?: (event: HookEvent) => void;
      permissionDecision?: (
        decision: "allow" | "always" | "deny",
      ) => Promise<void>;
      desktop?: (cmd: string) => ReturnType<typeof runDesktopRequest>;
    };
  }
}

let controller: IslandController | null = null;

function applyEffects(effects: ReturnType<typeof applyHookEvent>): void {
  if (effects.playSound) {
    void audio.play(effects.playSound);
  }
  if (effects.reveal) {
    controller?.reveal();
  }
  if (effects.expandTo && controller) {
    controller.expandTo(effects.expandTo);
  }
}

function onHookEvent(payload: unknown): void {
  const event = payload as HookEvent;
  const effects = applyHookEvent(appState, event);
  applyEffects(effects);
}

function dtoToProviderAuth(dto: CodexAuthStateDto): ProviderAuthInfo {
  return {
    provider: "openai-codex",
    authenticated: !!dto.authenticated,
    accountLabel: dto.accountLabel ?? null,
    status: (["disconnected", "connecting", "waiting", "connected", "error"].includes(
      dto.status,
    )
      ? dto.status
      : "disconnected") as ProviderAuthInfo["status"],
    error: dto.error ?? null,
    loginId: dto.loginId ?? null,
    verificationUrl: dto.verificationUrl ?? null,
    userCode: dto.userCode ?? null,
    mode: dto.mode === "device_code" || dto.mode === "browser" ? dto.mode : null,
  };
}

async function bootstrap(): Promise<void> {
  const stage = document.querySelector("#stage");
  if (!stage) {
    console.error("Missing #stage");
    return;
  }

  await audio.preload("/sounds");
  audio.setVolume(appState.soundVolume);
  audio.setEnabled(appState.soundEnabled);

  appState.loadIntegrationTasks();
  controller = startIsland(stage as HTMLElement);

  await positionIsland(720, 320);

  const unlistenHook = await listenHookEvent(onHookEvent);
  const unlistenCodex = await listenCodexAuth((dto) => {
    const island = document.querySelector("#island") as HTMLElement | null;
    applyCodexAuthUpdate(island, dtoToProviderAuth(dto));
  });
  const unlistenAgent = await listenCodexAgentState((payload) => {
    const p = payload as { agentState?: string };
    if (!p.agentState) return;
    const bot = companionStateFromAgent(p.agentState as NormalizedAgentState);
    appState.stateOverride = bot;
  });

  const openDesktopControl = () => {
    controller?.expandTo("prompt");
    appState.appendChat(
      "assistant",
      "Desktop control — tell me what to do (open YouTube, next song, analyze screen…).",
    );
    window.setTimeout(() => {
      const input = document.querySelector("#promptIn") as HTMLInputElement | null;
      input?.focus();
    }, 200);
  };

  const unlistenHotkey = await listenDesktopHotkey(() => {
    openDesktopControl();
  });

  // Fallback when global shortcut plugin cannot register (browser / permission).
  window.addEventListener("keydown", (ev) => {
    if (ev.shiftKey && (ev.key === "M" || ev.key === "m") && !ev.ctrlKey && !ev.metaKey && !ev.altKey) {
      const t = ev.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA" || t.isContentEditable)) {
        return;
      }
      ev.preventDefault();
      openDesktopControl();
    }
  });

  controller.fsm.launch();

  window.__coucou = {
    ...window.__coucou,
    appState,
    fsm: controller.fsm,
    expandTo: controller.expandTo,
    collapse: controller.collapse,
    simulateHook: (event) => onHookEvent(event),
    desktop: (cmd: string) => runDesktopRequest(cmd),
  };

  window.addEventListener("beforeunload", () => {
    void unlistenHook();
    void unlistenCodex();
    void unlistenAgent();
    void unlistenHotkey();
  });
}

void bootstrap();
