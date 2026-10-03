// @bun
// index.ts
import os from "os";
import path from "path";

// src/socket.ts
import net from "net";
function connectSocket(sockPath) {
  return new Promise((resolve, reject) => {
    const sock = net.createConnection(sockPath);
    sock.once("connect", () => resolve(sock));
    sock.once("error", (err) => {
      sock.destroy();
      reject(err);
    });
  });
}
function sendEvent(sock, obj) {
  sock.write(JSON.stringify(obj) + `
`);
}
async function sendPermissionRequest(sockPath, payload, timeoutMs = 110000) {
  const sock = await connectSocket(sockPath);
  return new Promise((resolve) => {
    let buf = "";
    let settled = false;
    const finish = (decision) => {
      if (settled)
        return;
      settled = true;
      clearTimeout(timer);
      sock.destroy();
      resolve(decision);
    };
    const timer = setTimeout(() => finish("ask"), timeoutMs);
    sock.on("data", (chunk) => {
      buf += chunk.toString();
      let idx;
      while ((idx = buf.indexOf(`
`)) >= 0) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        if (!line.trim())
          continue;
        let obj;
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
    sock.write(JSON.stringify(payload) + `
`);
  });
}

// src/mapping.ts
var HOOK_NAMES = {
  "session.created": "SessionStart",
  "session.next.prompted": "UserPromptSubmit",
  "session.next.tool.called": "PreToolUse",
  "session.next.tool.success": "PostToolUse",
  "session.next.tool.failed": "PostToolUseFailure",
  "session.idle": "Stop",
  "session.deleted": "SessionEnd",
  "session.error": "StopFailure"
};
function mapEvent(evt) {
  if (typeof evt !== "object" || evt === null)
    return null;
  const e = evt;
  const type = typeof e.type === "string" ? e.type : null;
  const hookName = type ? HOOK_NAMES[type] : undefined;
  if (!hookName)
    return null;
  const p = typeof e.properties === "object" && e.properties || typeof e.data === "object" && e.data || null;
  const session_id = p && typeof p.sessionID === "string" ? p.sessionID : null;
  if (!session_id)
    return null;
  const out = {
    hook_event_name: hookName,
    session_id,
    coucou_agent: "opencode"
  };
  if (hookName === "UserPromptSubmit") {
    const text = p.prompt?.text;
    if (typeof text === "string")
      out.prompt = text;
  } else if (hookName === "PreToolUse") {
    if (typeof p.tool === "string")
      out.tool_name = p.tool;
    if (p.input && typeof p.input === "object")
      out.tool_input = p.input;
  } else if (hookName === "StopFailure") {
    const err = p.error;
    const message = typeof err === "string" ? err : err && typeof err === "object" ? err.error?.message : undefined;
    if (typeof message === "string")
      out.message = message;
  }
  return out;
}

// src/permission.ts
function buildPermissionPayload(properties, cwd) {
  if (typeof properties !== "object" || properties === null)
    return null;
  const p = properties;
  if (typeof p.sessionID !== "string" || typeof p.permission !== "string")
    return null;
  let tool_input = {};
  if (p.metadata && typeof p.metadata === "object") {
    tool_input = p.metadata;
  } else if (Array.isArray(p.patterns)) {
    tool_input = { patterns: p.patterns };
  }
  const out = {
    hook_event_name: "PermissionRequest",
    coucou_agent: "opencode",
    session_id: p.sessionID,
    tool_name: p.permission,
    tool_input
  };
  if (typeof cwd === "string")
    out.cwd = cwd;
  return out;
}
function decisionToReply(decision) {
  if (decision === "allow")
    return "once";
  if (decision === "always")
    return "always";
  if (decision === "deny")
    return "reject";
  return null;
}

// index.ts
var SOCKET_PATH = path.join(os.homedir(), "Library/Application Support/NotchBuddy/nb.sock");
var started = false;
var opencode_coucou_default = {
  id: "coucou",
  async setup(_ctx) {
    if (started)
      return () => {};
    const ctx = typeof _ctx === "object" && _ctx !== null ? _ctx : {};
    let sock = null;
    try {
      sock = await connectSocket(SOCKET_PATH);
    } catch (err) {
      console.error(`[coucou] cannot reach ${SOCKET_PATH}: ${err instanceof Error ? err.message : err}; plugin inactive`);
      return () => {};
    }
    started = true;
    sock.on("error", (err) => console.error(`[coucou] socket error: ${err.message}`));
    sock.on("close", () => {
      sock = null;
    });
    const controller = new AbortController;
    const subscribe = ctx.event?.subscribe;
    if (typeof subscribe === "function") {
      const cwd = typeof ctx.location?.directory === "string" ? ctx.location.directory : undefined;
      let warnedNoReply = false;
      const relayPermission = (properties) => {
        (async () => {
          try {
            const payload = buildPermissionPayload(properties, cwd);
            if (!payload)
              return;
            const requestID = typeof properties === "object" && properties !== null ? properties.id : undefined;
            if (typeof requestID !== "string")
              return;
            const decision = await sendPermissionRequest(SOCKET_PATH, payload);
            const reply = decisionToReply(decision);
            if (!reply)
              return;
            const replyFn = ctx.permission?.reply;
            if (typeof replyFn !== "function") {
              if (!warnedNoReply) {
                warnedNoReply = true;
                console.error("[coucou] ctx.permission.reply unavailable; permission decisions dropped");
              }
              return;
            }
            await replyFn({ sessionID: payload.session_id, requestID, reply });
          } catch (err) {
            console.error(`[coucou] permission relay failed: ${err instanceof Error ? err.message : err}`);
          }
        })();
      };
      (async () => {
        try {
          for await (const event of subscribe({ signal: controller.signal })) {
            const e = typeof event === "object" && event !== null ? event : {};
            if (e.type === "permission.asked") {
              relayPermission(e.properties ?? e.data);
              continue;
            }
            let mapped = null;
            try {
              mapped = mapEvent(event);
            } catch (err) {
              console.error(`[coucou] dropped event: ${err instanceof Error ? err.message : err}`);
              continue;
            }
            const s = sock;
            if (!mapped || !s)
              continue;
            try {
              sendEvent(s, { ...mapped, coucou_agent: "opencode", cwd });
            } catch (err) {
              console.error(`[coucou] forward failed: ${err instanceof Error ? err.message : err}`);
            }
          }
        } catch (err) {
          if (err?.name !== "AbortError")
            console.error(`[coucou] event stream ended: ${err instanceof Error ? err.message : err}`);
        }
      })();
    }
    return () => {
      controller.abort();
      sock?.destroy();
    };
  }
};
export {
  opencode_coucou_default as default
};
