// opencode-coucou — OpenCode V2 plugin bridging session events to the Coucou
// notch app. Plain plugin object (no @opencode/plugin import) so it loads
// anywhere node can, matching the bundled ponytail plugin pattern.
import os from "node:os";
import path from "node:path";
import { connectSocket } from "./src/socket.ts";

// GitHub build of Coucou (NotchBuddy.swift, non-sandboxed branch).
const SOCKET_PATH = path.join(
  os.homedir(),
  "Library/Application Support/NotchBuddy/nb.sock",
);

export default {
  id: "coucou",
  async setup(_ctx: unknown) {
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
    // Persistent event connection; Task 2 routes ctx events through
    // sendEvent(sock, mapEvent(evt)) here.
    sock.on("error", (err) =>
      console.error(`[coucou] socket error: ${err.message}`),
    );
    sock.on("close", () => {
      sock = null;
    });
    return () => {
      sock?.destroy();
    };
  },
};
