// The Deezer commands (src-tauri/src/deezer.rs). Kept out of Bridge so the
// module needs no change in core/bridge.ts.

import { invoke } from "@tauri-apps/api/core";
import { IS_TAURI } from "./bridge";
import type { DeezerState } from "./deezer";

export type DeezerAction = "playPause" | "next" | "previous" | "seek" | "volume";

async function call<T>(cmd: string, args?: Record<string, unknown>): Promise<T | null> {
  if (!IS_TAURI) return null;
  try {
    return await invoke<T>(cmd, args);
  } catch (err) {
    console.error(`[coucou] ${cmd} failed`, err);
    return null;
  }
}

export const DeezerBridge = {
  refresh: () => call<DeezerState>("deezer_refresh"),
  /** True when Deezer took it. `value`: seconds for seek, 0…100 for volume. */
  control: (action: DeezerAction, value?: number) =>
    call<boolean>("deezer_control", { action, value: value ?? null }),
  open: () => call<boolean>("deezer_open"),
  installed: () => call<boolean>("deezer_installed"),
};
