#!/usr/bin/env node
/**
 * Dev-only Claude Code hook Unix socket server (mirrors apps/linux Rust HookServer).
 * Used by scripts/dev-linux.sh when running the Vite UI without Tauri.
 *
 * - Unix socket: $XDG_DATA_HOME/coucou/nb.sock
 * - SSE bridge:  http://127.0.0.1:1421/events  (frontend listens in browser mode)
 * - POST /permission  { sessionId, decision }
 */
import { createServer } from "node:net";
import { mkdirSync, unlinkSync, writeFileSync, chmodSync, existsSync } from "node:fs";
import { join } from "node:path";
import { homedir } from "node:os";
import { createServer as createHttpServer } from "node:http";

const dataHome = process.env.XDG_DATA_HOME || join(homedir(), ".local/share");
const dataDir = join(dataHome, "coucou");
const socketPath = process.env.COUCOU_SOCK || join(dataDir, "nb.sock");
const hookPath = join(dataDir, "nb-hook");
const HTTP_PORT = Number(process.env.COUCOU_HOOK_HTTP || 1421);

mkdirSync(dataDir, { recursive: true });
mkdirSync(join(dataDir, "inbox"), { recursive: true });

const NB_HOOK = `#!/usr/bin/env python3
import sys, json, os, socket
def main():
    try:
        raw = sys.stdin.buffer.read()
        if not raw: return
        payload = json.loads(raw)
    except Exception:
        return
    env = os.environ
    payload.setdefault('term_program', env.get('TERM_PROGRAM', '') or env.get('term_program', ''))
    payload.setdefault('bundle_id', env.get('__CFBundleIdentifier', ''))
    if not payload.get('term_program'):
        if env.get('CURSOR_TRACE_ID') or 'cursor' in (env.get('TERM_PROGRAM','')+env.get('VSCODE_PID','')).lower():
            payload['term_program'] = 'cursor'
        elif env.get('VSCODE_PID') or env.get('VSCODE_INJECTION'):
            payload['term_program'] = 'vscode'
    if 'cwd' not in payload or not payload['cwd']:
        payload['cwd'] = os.getcwd()
    event = payload.get('hook_event_name', '')
    socket_path = os.environ.get('COUCOU_SOCK') or os.path.expanduser('~/.local/share/coucou/nb.sock')
    if event == 'PermissionRequest':
        try:
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(118)
            s.connect(socket_path)
            s.sendall((json.dumps(payload) + '\\n').encode())
            chunks = []
            while True:
                chunk = s.recv(4096)
                if not chunk: break
                chunks.append(chunk)
                if b'\\n' in chunk: break
            s.close()
            response = b''.join(chunks).decode().strip()
            if response and 'permissionDecision' in response:
                sys.stdout.write(response + '\\n'); sys.stdout.flush(); sys.exit(0)
        except Exception:
            pass
        sys.stdout.write('{"permissionDecision":"deny"}\\n'); sys.stdout.flush(); sys.exit(0)
    try:
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(0.3)
        s.connect(socket_path)
        s.sendall((json.dumps(payload) + '\\n').encode())
        s.close()
    except Exception:
        pass
main()
sys.exit(0)
`;

writeFileSync(hookPath, NB_HOOK, { mode: 0o755 });
chmodSync(hookPath, 0o755);

if (existsSync(socketPath)) {
  try {
    unlinkSync(socketPath);
  } catch {
    /* ignore */
  }
}

/** @type {import('node:http').ServerResponse[]} */
const sseClients = [];
const pending = new Map();

function broadcast(obj) {
  const data = `data: ${JSON.stringify(obj)}\n\n`;
  for (const res of sseClients) {
    try {
      res.write(data);
    } catch {
      /* ignore */
    }
  }
  console.log(`[hook] ${obj.hook_event_name || "event"}`);
}

function sendLine(sock, text) {
  sock.write(text + "\n");
}

const unix = createServer((sock) => {
  let buf = Buffer.alloc(0);
  sock.on("data", (chunk) => {
    buf = Buffer.concat([buf, chunk]);
    const idx = buf.indexOf(0x0a);
    if (idx < 0) return;
    const line = buf.subarray(0, idx).toString("utf8");
    let payload;
    try {
      payload = JSON.parse(line);
    } catch {
      sendLine(sock, '{"ok":true}');
      sock.end();
      return;
    }
    const event = payload.hook_event_name || "";
    if (event === "PermissionRequest") {
      const sid = payload.session_id || "unknown";
      if (pending.has(sid)) {
        const old = pending.get(sid);
        clearTimeout(old.timer);
        sendLine(old.socket, '{"permissionDecision":"deny"}');
        old.socket.end();
      }
      const timer = setTimeout(() => {
        const p = pending.get(sid);
        if (!p) return;
        sendLine(p.socket, '{"permissionDecision":"deny"}');
        p.socket.end();
        pending.delete(sid);
      }, 115_000);
      pending.set(sid, { socket: sock, timer });
      broadcast(payload);
      return;
    }
    broadcast(payload);
    sendLine(sock, '{"ok":true}');
    sock.end();
  });
  sock.on("error", () => {});
});

unix.listen(socketPath, () => {
  try {
    chmodSync(socketPath, 0o600);
  } catch {
    /* ignore */
  }
  console.log(`[coucou-dev] Unix socket ${socketPath}`);
  console.log(`[coucou-dev] nb-hook installed at ${hookPath}`);
});

function cors(res) {
  res.setHeader("Access-Control-Allow-Origin", "*");
  res.setHeader("Access-Control-Allow-Methods", "GET,POST,OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type");
}

const httpServer = createHttpServer((req, res) => {
  cors(res);
  if (req.method === "OPTIONS") {
    res.writeHead(204);
    res.end();
    return;
  }
  if (req.url === "/events") {
    res.writeHead(200, {
      "Content-Type": "text/event-stream",
      "Cache-Control": "no-cache",
      Connection: "keep-alive",
    });
    res.write(":\n\n");
    sseClients.push(res);
    req.on("close", () => {
      const i = sseClients.indexOf(res);
      if (i >= 0) sseClients.splice(i, 1);
    });
    return;
  }
  if (req.url === "/permission" && req.method === "POST") {
    let body = "";
    req.on("data", (c) => {
      body += c;
    });
    req.on("end", () => {
      try {
        const msg = JSON.parse(body);
        const sid = msg.sessionId || "unknown";
        const p = pending.get(sid);
        if (p) {
          clearTimeout(p.timer);
          pending.delete(sid);
          const text =
            msg.decision === "always"
              ? '{"permissionDecision":"allow","alwaysAllow":true}'
              : JSON.stringify({
                  permissionDecision: msg.decision === "deny" ? "deny" : "allow",
                });
          sendLine(p.socket, text);
          p.socket.end();
        }
        res.writeHead(200, { "Content-Type": "application/json" });
        res.end('{"ok":true}');
      } catch (e) {
        res.writeHead(400);
        res.end(String(e));
      }
    });
    return;
  }
  res.writeHead(200, { "Content-Type": "text/plain" });
  res.end("coucou hook bridge\n");
});

httpServer.listen(HTTP_PORT, "127.0.0.1", () => {
  console.log(`[coucou-dev] SSE bridge http://127.0.0.1:${HTTP_PORT}/events`);
});

process.on("SIGINT", () => {
  try {
    unlinkSync(socketPath);
  } catch {
    /* ignore */
  }
  process.exit(0);
});
