// opencode-coucou — OpenCode V2 plugin bridging session events to the Coucou
// notch app. Plain plugin object (no @opencode/plugin import) so it loads
// anywhere node can, matching the bundled ponytail plugin pattern.
import os from "node:os";
import path from "node:path";
import { connectSocket, sendEvent } from "./src/socket.ts";
import { mapEvent, type CanonicalEvent } from "./src/mapping.ts";

// GitHub build of Coucou (NotchBuddy.swift, non-sandboxed branch).
const SOCKET_PATH = path.join(
  os.homedir(),
  "Library/Application Support/NotchBuddy/nb.sock",
);

// Minimal structural view of the V2 plugin ctx we actually use — no
// @opencode/plugin import. Fields are read defensively: a ctx that lacks
// them (or a ctx that isn't an object at all) simply disables forwarding.
type Ctx = {
  event?: {
    subscribe?: (opts: { signal?: AbortSignal }) => AsyncIterable<unknown>;
  };
  location?: { directory?: unknown };
};

export default {
  id: "coucou",
  async setup(_ctx: unknown) {
    const ctx = typeof _ctx === "object" && _ctx !== null ? (_ctx as Ctx) : {};
    let sock: import("node:net").Socket | null = null;
    try {
      sock = await connectSocket(SOCKET_PATH);
    } catch (err) {
      // Never throw — a dead socket must not block OpenCode startup.
      console.error(
        `[coucou] cannot reach ${SOCKET_PATH}: ${err instanceof Error ? err.message : err}; plugin inactive`,
      );
      return () => {};
    }
    sock.on("error", (err) =>
      console.error(`[coucou] socket error: ${err.message}`),
    );
    sock.on("close", () => {
      sock = null;
    });

    // Persistent event connection: subscribe once, forward every mapped event.
    // A mapping miss or a write failure is logged and dropped — never thrown
    // back at the OpenCode runtime.
    const controller = new AbortController();
    const subscribe = ctx.event?.subscribe;
    if (typeof subscribe === "function") {
      const cwd =
        typeof ctx.location?.directory === "string"
          ? ctx.location.directory
          : undefined;
      void (async () => {
        try {
          for await (const event of subscribe({ signal: controller.signal })) {
            let mapped: CanonicalEvent | null = null;
            try {
              mapped = mapEvent(event);
            } catch (err) {
              console.error(
                `[coucou] dropped event: ${err instanceof Error ? err.message : err}`,
              );
              continue;
            }
            const s = sock;
            if (!mapped || !s) continue;
            try {
              sendEvent(s, { ...mapped, coucou_agent: "opencode", cwd });
            } catch (err) {
              console.error(
                `[coucou] forward failed: ${err instanceof Error ? err.message : err}`,
              );
            }
          }
        } catch (err) {
          if ((err as Error)?.name !== "AbortError")
            console.error(
              `[coucou] event stream ended: ${err instanceof Error ? err.message : err}`,
            );
        }
      })();
    }
    return () => {
      controller.abort();
      sock?.destroy();
    };
  },
};
