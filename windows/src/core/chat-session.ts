// Serializes chat settings persistence and backend history resets so a new turn
// cannot race ahead of the provider/model change that selected it.

import { Bridge } from "./bridge";
import { State, type Settings } from "./state";

let seenConfig: string | null = null;
let seenGeneration = 0;
let transition: Promise<void> = Promise.resolve();
let transitionRevision = 0;
let lastFailure: { config: string; persist: boolean } | null = null;

function configKey(settings: Settings): string {
  return `${settings.chatProvider}\n${settings.codexModel}\n${settings.model}\n${settings.codexAuthMode}`;
}

function queueTransition(settings: Settings, persist: boolean) {
  const snapshot = { ...settings };
  const provider = snapshot.chatProvider;
  const model = provider === "codex" ? snapshot.codexModel : snapshot.model;
  const config = configKey(snapshot);
  const revision = ++transitionRevision;
  lastFailure = null;
  transition = transition.catch(() => {}).then(async () => {
    if (persist) await Bridge.saveSettings(snapshot);
    await Bridge.chatReset(provider, model);
  });
  // Observe errors without turning a failed transition into a successful one.
  // submit() awaits the original promise and presents the error before sending.
  void transition.then(
    () => { if (revision === transitionRevision) lastFailure = null; },
    (error: unknown) => {
      if (revision === transitionRevision) lastFailure = { config, persist };
      console.error("[coucou] chat configuration reset failed", error);
    },
  );
}

/** Call after boot has loaded saved settings, so defaults are not mistaken for a change. */
export function initializeChatSession() {
  seenConfig = configKey(State.settings);
  seenGeneration = State.chatGeneration;
  lastFailure = null;
}

/**
 * Reconcile a provider/model change or a frontend chat reset with the backend.
 * `persist` is true only for changes made in the island chat controls; settings
 * events from the dedicated window are already saved before they arrive here.
 */
export function reconcileChatSession(persist = false, retryFailed = false) {
  const currentConfig = configKey(State.settings);
  if (seenConfig == null) {
    seenConfig = currentConfig;
    seenGeneration = State.chatGeneration;
    return;
  }

  const configChanged = currentConfig !== seenConfig;
  const failedSameConfig = lastFailure?.config === currentConfig;
  if (configChanged) {
    seenConfig = currentConfig;
    State.clearChatForConfigChange();
  }
  if (!configChanged && State.chatGeneration === seenGeneration && !(retryFailed && failedSameConfig)) return;
  const retryPersistence = retryFailed && !configChanged && failedSameConfig && lastFailure?.persist === true;
  seenGeneration = State.chatGeneration;
  queueTransition(State.settings, persist || retryPersistence);
}

export function waitForChatSessionReady(): Promise<void> {
  return transition;
}
