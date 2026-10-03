// Unix socket bridge to the Coucou notch app.
// Protocol: newline-terminated JSON lines. Coucou answers permission requests
// with {"permissionDecision":"allow"|"always"|"deny"|"ask"} on the same
// connection.
import net from "node:net";

export type PermissionDecision = "allow" | "always" | "deny" | "ask";

/** Resolves to an open client socket on sockPath; rejects on connect failure. */
export function connectSocket(sockPath: string): Promise<net.Socket> {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(sockPath);
    sock.once("connect", () => resolve(sock));
    sock.once("error", (err) => {
      sock.destroy();
      reject(err);
    });
  });
}

/** Writes obj as one newline-terminated JSON line. */
export function sendEvent(sock: net.Socket, obj: object): void {
  sock.write(JSON.stringify(obj) + "\n");
}

/**
 * Opens a dedicated held-open connection, sends payload, and resolves with
 * Coucou's permission decision. Resolves "ask" (never rejects) when Coucou is
 * silent past timeoutMs, sends an unrecognized value, or closes the
 * connection without a decision — so OpenCode is never stuck. Connect failure
 * rejects; the caller must no-op in that case.
 */
export async function sendPermissionRequest(
  sockPath: string,
  payload: object,
  timeoutMs = 110_000, // Coucou has a ~115 s safety window; stay under it
): Promise<PermissionDecision> {
  const sock = await connectSocket(sockPath);
  return new Promise<PermissionDecision>((resolve) => {
    let buf = "";
    let settled = false;
    const finish = (decision: PermissionDecision) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(decision);
    };
    const timer = setTimeout(() => finish("ask"), timeoutMs);
    sock.on("data", (chunk) => {
      buf += chunk.toString();
      let idx;
      while ((idx = buf.indexOf("\n")) >= 0) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (!line.trim()) continue;
        let obj: { permissionDecision?: unknown };
        try {
          obj = JSON.parse(line);
        } catch {
          continue;
        }
        const d = obj?.permissionDecision;
        if (typeof d === "string") {
          finish(d === "allow" || d === "always" || d === "deny" ? d : "ask");
          return;
        }
      }
    });
    sock.on("close", () => finish("ask"));
    sock.on("error", () => finish("ask"));
    sock.write(JSON.stringify(payload) + "\n");
  });
}
