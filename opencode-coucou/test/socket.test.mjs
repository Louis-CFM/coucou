// test/socket.test.mjs — plain node test, no framework. Run: node test/socket.test.mjs
// (node >= 23.6 strips TS types by default; node 26 here needs no flag.)
import assert from "node:assert/strict";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import fs from "node:fs";
import { connectSocket, sendEvent, sendPermissionRequest } from "../src/socket.ts";

const sockPath = path.join(os.tmpdir(), `coucou-test-${process.pid}.sock`);
fs.rmSync(sockPath, { force: true });

const received = [];

// Stub Coucou server: records every line. Replies {"permissionDecision": ...}
// when the payload carries a "request" field; swallows "silent" payloads;
// closes without a decision for "hang".
const server = net.createServer((client) => {
  let buf = "";
  client.on("data", (chunk) => {
    buf += chunk.toString();
    let idx;
    while ((idx = buf.indexOf("\n")) >= 0) {
      const line = buf.slice(0, idx);
      buf = buf.slice(idx + 1);
      if (!line.trim()) continue;
      received.push(line);
      let obj = {};
      try { obj = JSON.parse(line); } catch {}
      if (obj.request) {
        client.write(JSON.stringify({ permissionDecision: obj.request }) + "\n");
      } else if (obj.hang) {
        client.end();
      }
    }
  });
});
await new Promise((r) => server.listen(sockPath, r));

// 1. connectSocket resolves with an open client socket
const s = await connectSocket(sockPath);
assert.ok(s, "connectSocket should resolve to a socket");

// 2. connectSocket rejects on connect failure (never throws synchronously)
await assert.rejects(() => connectSocket("/nonexistent/coucou.sock"));

// 3. sendEvent writes a single newline-terminated JSON line
sendEvent(s, { coucou_agent: "opencode", hello: "world" });
await new Promise((r) => setTimeout(r, 50));
assert.deepEqual(received, [JSON.stringify({ coucou_agent: "opencode", hello: "world" })]);
s.destroy();

// 4. sendPermissionRequest resolves with Coucou's decision
assert.equal(await sendPermissionRequest(sockPath, { request: "allow" }), "allow");
assert.equal(await sendPermissionRequest(sockPath, { request: "always" }), "always");
assert.equal(await sendPermissionRequest(sockPath, { request: "deny" }), "deny");

// 5. Unknown decision values degrade to "ask" (OpenCode prompts the user)
assert.equal(await sendPermissionRequest(sockPath, { request: "weird" }), "ask");

// 6. No reply before the timeout → resolves "ask", never hangs OpenCode
assert.equal(await sendPermissionRequest(sockPath, { silent: true }, 200), "ask");

// 7. Coucou closes the connection without a decision → resolves "ask"
assert.equal(await sendPermissionRequest(sockPath, { hang: true }), "ask");

// 8. Unreachable socket path rejects (caller is responsible for no-op handling)
await assert.rejects(() => sendPermissionRequest("/nonexistent/coucou.sock", { request: "allow" }));

server.close();
fs.rmSync(sockPath, { force: true });
console.log("socket.test.mjs PASS");
