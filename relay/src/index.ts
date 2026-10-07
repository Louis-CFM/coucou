// Coucou relay — a stateless Cloudflare Worker.
//
// The Mac app can't send Live Activity pushes itself: that needs the APNs key,
// which must never ship inside an app. The Mac posts Mochi's state here, the
// relay signs a token with the key (a Worker secret) and forwards the push to
// Apple. Nothing is stored and nothing is logged: no database, observability
// off. The state holds no project name, command or path (see
// MochiActivityState.swift), and the relay builds the push itself, so it can't
// be used to send arbitrary notifications.

export interface Env {
  APNS_KEY: string;      // contents of the AuthKey_XXXX.p8 file (secret)
  APNS_KEY_ID: string;   // the key's ID (secret)
  APNS_TEAM_ID: string;
  APNS_TOPIC: string;
}

type Event = "start" | "update" | "end";

interface RelayRequest {
  token: string;
  env: "development" | "production";
  event: Event;
  state: Record<string, unknown>;
  urgent?: boolean;
  dismissAfter?: number;   // "end" only: seconds the final state stays on the Lock Screen
}

const STATE_STRINGS = ["pillId", "agent", "color", "state", "statusText", "tone"] as const;
const STATE_NUMBERS = ["stepIndex", "stepCount", "others"] as const;

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (request.method === "GET" && url.pathname === "/") {
      return text(200, "Coucou relay");
    }
    if (request.method !== "POST" || url.pathname !== "/v1/live-activity") {
      return text(404, "not found");
    }
    if (Number(request.headers.get("content-length") ?? "0") > 4096) {
      return text(413, "too large");
    }

    let body: RelayRequest;
    try {
      body = await request.json();
    } catch {
      return text(400, "bad json");
    }
    const problem = validate(body);
    if (problem) return text(400, problem);

    const payload = buildPayload(body);
    const host = body.env === "production" ? "api.push.apple.com" : "api.sandbox.push.apple.com";
    const jwt = await providerToken(env);
    const apns = await fetch(`https://${host}/3/device/${body.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${jwt}`,
        "apns-topic": env.APNS_TOPIC,
        "apns-push-type": "liveactivity",
        // 10 is limited by an iOS budget: only for start, end and waiting-for-you.
        "apns-priority": body.urgent || body.event !== "update" ? "10" : "5",
        "content-type": "application/json",
      },
      body: JSON.stringify(payload),
    });
    if (apns.status === 200) return text(200, "ok");
    // 400 BadDeviceToken / 410 Unregistered: the Mac drops the token.
    const reason = await apns.text();
    return new Response(reason || "{}", {
      status: apns.status === 410 ? 410 : 502,
      headers: { "content-type": "application/json", "x-apns-status": String(apns.status) },
    });
  },
};

function validate(body: RelayRequest): string | null {
  if (typeof body !== "object" || body === null) return "body";
  if (typeof body.token !== "string" || !/^[0-9a-f]{32,400}$/i.test(body.token)) return "token";
  if (body.env !== "development" && body.env !== "production") return "env";
  if (!["start", "update", "end"].includes(body.event)) return "event";
  if (typeof body.state !== "object" || body.state === null) return "state";
  for (const key of STATE_STRINGS) {
    const value = body.state[key];
    if (typeof value !== "string" || value.length > 60) return `state.${key}`;
  }
  for (const key of STATE_NUMBERS) {
    const value = body.state[key];
    if (typeof value !== "number" || !Number.isInteger(value) || value < 0 || value > 999) return `state.${key}`;
  }
  const since = body.state["since"];
  if (since !== undefined && since !== null &&
      (typeof since !== "number" || !Number.isInteger(since) || since < 1_600_000_000 || since > 4_000_000_000)) return "state.since";
  const approval = body.state["approval"];
  if (approval !== undefined && approval !== null &&
      (typeof approval !== "string" || !/^[0-9a-f]{64}$/.test(approval))) return "state.approval";
  if (body.dismissAfter !== undefined &&
      (typeof body.dismissAfter !== "number" || !Number.isInteger(body.dismissAfter) ||
       body.dismissAfter < 0 || body.dismissAfter > 4 * 3600)) return "dismissAfter";
  return null;
}

function buildPayload(body: RelayRequest) {
  const now = Math.floor(Date.now() / 1000);
  // Only the known fields, so nothing else rides along.
  const state: Record<string, unknown> = {};
  for (const key of [...STATE_STRINGS, ...STATE_NUMBERS]) state[key] = body.state[key];
  // When Mochi left for the iPhone: the activity counts the time from it.
  if (typeof body.state["since"] === "number") state["since"] = body.state["since"];
  // The pending command's fingerprint (a hash), for Allow / Deny on the Lock Screen.
  if (typeof body.state["approval"] === "string") state["approval"] = body.state["approval"];

  const aps: Record<string, unknown> = {
    timestamp: now,
    event: body.event,
    "content-state": state,
    // If the Mac goes quiet (asleep, offline), the iPhone greys the activity out.
    "stale-date": now + 15 * 60,
  };
  if (body.event === "start") {
    aps["attributes-type"] = "MochiActivityAttributes";
    aps["attributes"] = {};
    // iOS requires an alert to start a Live Activity from a push.
    aps["alert"] = { title: "Coucou", body: `${state.agent} · ${state.statusText}` };
  }
  if (body.event === "update" && body.urgent) {
    // Waiting for your OK or a question: the Dynamic Island opens and the
    // Lock Screen lights up, with Allow / Deny right there. No sound: the
    // approval notification already makes one.
    aps["alert"] = { title: String(state.agent), body: String(state.statusText) };
  }
  if (body.event === "end") {
    aps["dismissal-date"] = now + (body.dismissAfter ?? 0);
  }
  return { aps };
}

// MARK: APNs provider token (ES256 JWT), reused for 50 minutes as Apple asks.

let cached: { jwt: string; issuedAt: number; keyId: string } | null = null;

async function providerToken(env: Env): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  if (cached && cached.keyId === env.APNS_KEY_ID && now - cached.issuedAt < 50 * 60) return cached.jwt;

  const header = base64url(JSON.stringify({ alg: "ES256", kid: env.APNS_KEY_ID }));
  const claims = base64url(JSON.stringify({ iss: env.APNS_TEAM_ID, iat: now }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(env.APNS_KEY),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "ECDSA", hash: "SHA-256" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const jwt = `${header}.${claims}.${base64url(new Uint8Array(signature))}`;
  cached = { jwt, issuedAt: now, keyId: env.APNS_KEY_ID };
  return jwt;
}

function pemToDer(pem: string): ArrayBuffer {
  const b64 = pem.replace(/-----[^-]+-----/g, "").replace(/\s+/g, "");
  const bytes = Uint8Array.from(atob(b64), (c) => c.charCodeAt(0));
  return bytes.buffer;
}

function base64url(input: string | Uint8Array): string {
  const bytes = typeof input === "string" ? new TextEncoder().encode(input) : input;
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function text(status: number, message: string): Response {
  return new Response(message, { status, headers: { "content-type": "text/plain" } });
}
