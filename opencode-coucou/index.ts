// opencode-coucou — OpenCode V2 plugin bridging session events to the Coucou
// notch app. Plain plugin object (no @opencode/plugin import) so it loads
// anywhere node can, matching the bundled ponytail plugin pattern.
import os from "node:os";
import path from "node:path";
import { connectSocket, sendEvent, sendPermissionRequest } from "./src/socket.ts";
import { mapEvent, type CanonicalEvent } from "./src/mapping.ts";
import { buildPermissionPayload, decisionToReply } from "./src/permission.ts";

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
  permission?: {
    reply?: (req: {
      sessionID: string;
      requestID: string;
      reply: string;
    }) => Promise<unknown>;
  };
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

      // Fire-and-forget permission relay (Task 3): forward to Coucou on a
      // held connection, then ctx.permission.reply. Not awaited in the loop —
      // a decision can take up to ~110 s and must not stall event forwarding.
      // Every failure is logged and dropped, never thrown at the runtime.
      let warnedNoReply = false;
      const relayPermission = (properties: unknown) => {
        void (async () => {
          try {
            const payload = buildPermissionPayload(properties, cwd);
            if (!payload) return;
            const requestID =
              typeof properties === "object" && properties !== null
                ? (properties as { id?: unknown }).id
                : undefined;
            if (typeof requestID !== "string") return;
            const decision = await sendPermissionRequest(SOCKET_PATH, payload);
            const reply = decisionToReply(decision);
            if (!reply) return; // "ask" → let OpenCode re-ask in its terminal
            const replyFn = ctx.permission?.reply;
            if (typeof replyFn !== "function") {
              // Feature-detect: no reply surface → decisions are dropped.
              if (!warnedNoReply) {
                warnedNoReply = true;
                console.error(
                  "[coucou] ctx.permission.reply unavailable; permission decisions dropped",
                );
              }
              return;
            }
            // Live v2.0.18 signature (confirmed from the bundled SDK):
            // reply({ requestID, reply }); sessionID is extra and used by the
            // runtime wrapper for cache invalidation.
            await replyFn({ sessionID: payload.session_id, requestID, reply });
          } catch (err) {
            console.error(
              `[coucou] permission relay failed: ${err instanceof Error ? err.message : err}`,
            );
          }
        })();
      };

      void (async () => {
        try {
          for await (const event of subscribe({ signal: controller.signal })) {
            // Permission requests take the relay path; lifecycle events go
            // through mapEvent (which stays permission-free by contract).
            const e =
              typeof event === "object" && event !== null
                ? (event as {
                    type?: unknown;
                    properties?: unknown;
                    data?: unknown;
                  })
                : {};
            if (e.type === "permission.asked") {
              relayPermission(e.properties ?? e.data);
              continue;
            }
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
