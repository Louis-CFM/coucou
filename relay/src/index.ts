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
  // Android companion (self-hosted): the Firebase service account JSON,
  // contents only — project_id, client_email and private_key are read from it.
  FCM_SA?: string;
  PHONE_BOX?: DurableObjectNamespace;
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
    if (url.pathname.startsWith("/v1/phone/")) {
      return phoneRoute(request, url, env);
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

// MARK: Android companion (self-hosted).
//
// The Windows/Linux app and the Android app meet here the same way the Mac and
// the iPhone meet through APNs: the PC owns a "box" on this worker, created with
// a random id and a random secret at pairing time. The phone learns both from a
// QR/code the PC shows, claims the box with its FCM token, and from then on:
//   PC   POST /v1/phone/state   latest island state; "alert" pushes through FCM
//   PC   POST /v1/phone/take    drains phone - PC messages (decisions, chat)
//   PC   POST /v1/phone/claimed has a phone claimed the box yet
//   PC   POST /v1/phone/pair    creates the box
//   PC   POST /v1/phone/unpair  wipes the box (also the phone's reset)
//   phone POST /v1/phone/claim  stores the FCM token + device name
//   phone POST /v1/phone/fetch  reads state + the waiting card
//   phone POST /v1/phone/decide answers a permission / question
//   phone POST /v1/phone/chat   sends a chat line
// Every call carries the secret; the box stores only its SHA-256. FCM data
// payloads carry no content (kind + pc id only): the phone fetches details
// from the box over HTTPS, so nothing sensitive ever rides Google's push.

const ID_RE = /^[0-9a-f]{24,48}$/;
const SECRET_RE = /^[0-9a-f]{64}$/;
const TOKEN_MAX = 512;
const ALERTS = ["approval", "question", "finished"] as const;
const OUTBOX_MAX = 50;
const OUTBOX_TTL_MS = 10 * 60 * 1000;
const STATE_TTL_MS = 24 * 3600 * 1000;

function phoneRoute(request: Request, url: URL, env: Env): Promise<Response> | Response {
  if (!env.PHONE_BOX) return text(501, "android support not deployed on this relay");
  if (request.method !== "POST") return text(404, "not found");
  if (Number(request.headers.get("content-length") ?? "0") > 8192) {
    return text(413, "too large");
  }
  const action = url.pathname.slice("/v1/phone/".length);
  if (!["pair", "claim", "claimed", "state", "fetch", "decide", "chat", "take", "unpair"].includes(action)) {
    return text(404, "not found");
  }
  return request.json().then((body) => {
    const id = (body as { id?: unknown }).id;
    if (typeof id !== "string" || !ID_RE.test(id)) return text(400, "id");
    const stub = env.PHONE_BOX!.get(env.PHONE_BOX!.idFromName(id));
    return stub.fetch(new Request(`https://box/${action}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }));
  }, () => text(400, "bad json"));
}

interface PhoneStateSession {
  pillId: string;
  agent: string;
  color: string;
  state: string;
  statusText: string;
  stepIndex: number;
  stepCount: number;
}

interface PhoneCard {
  requestId: string;
  pillId: string;
  agent: string;
  kind: "approval" | "question";
  title: string;
  detail: string;
  options: string[];
  /** Question cards: each question's text and its labels, so answers map back. */
  questions: { q: string; options: string[] }[];
}

/** The waiting card, clipped to bounds — used for both `state.awaiting` and `card`. */
function cleanCard(raw: unknown): PhoneCard {
  const r = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const questions = (Array.isArray(r.questions) ? r.questions : []).slice(0, 4).map((q) => {
    const qr = (typeof q === "object" && q !== null ? q : {}) as Record<string, unknown>;
    return {
      q: clipped(qr.q, 160),
      options: (Array.isArray(qr.options) ? qr.options : []).slice(0, 6).map((o) => clipped(o, 80)),
    };
  });
  return {
    requestId: clipped(r.requestId, 64),
    pillId: clipped(r.pillId, 48),
    agent: clipped(r.agent, 40),
    kind: r.kind === "question" ? "question" : "approval",
    title: clipped(r.title, 160),
    detail: clipped(r.detail, 600),
    options: (Array.isArray(r.options) ? r.options : []).slice(0, 8).map((o) => clipped(o, 80)),
    questions,
  };
}

interface OutboxItem {
  type: "decision" | "chat";
  at: number;
  requestId?: string;
  decision?: string;
  /** Question answers as question-text → chosen label, the shape AskUserQuestion takes. */
  answers?: Record<string, string>;
  text?: string;
}

function clipped(v: unknown, max: number): string {
  return typeof v === "string" ? v.slice(0, max) : "";
}

function cleanState(raw: unknown): {
  sessions: PhoneStateSession[];
  awaiting?: unknown;
  chatReply?: unknown;
  chatTail?: { role: string; text: string }[];
} | null {
  if (typeof raw !== "object" || raw === null) return null;
  const src = raw as Record<string, unknown>;
  const sessionsIn = Array.isArray(src.sessions) ? src.sessions : [];
  const sessions: PhoneStateSession[] = sessionsIn.slice(0, 12).map((s) => {
    const r = (typeof s === "object" && s !== null ? s : {}) as Record<string, unknown>;
    return {
      pillId: clipped(r.pillId, 48),
      agent: clipped(r.agent, 40),
      color: /^#[0-9a-f]{6}$/i.test(String(r.color)) ? String(r.color) : "#8C8C8C",
      state: clipped(r.state, 16),
      statusText: clipped(r.statusText, 120),
      stepIndex: Math.min(Math.max(Number(r.stepIndex) || 0, 0), 999),
      stepCount: Math.min(Math.max(Number(r.stepCount) || 0, 0), 999),
    };
  });
  const out: ReturnType<typeof cleanState> & object = { sessions };
  const aw = src.awaiting;
  if (typeof aw === "object" && aw !== null) {
    out.awaiting = cleanCard(aw);
  }
  if (typeof src.chatReply === "string") out.chatReply = src.chatReply.slice(0, 4000);
  const tail = Array.isArray(src.chatTail) ? src.chatTail : [];
  out.chatTail = tail.slice(0, 10).map((m) => {
    const r = (typeof m === "object" && m !== null ? m : {}) as Record<string, unknown>;
    return { role: r.role === "assistant" ? "assistant" : "user", text: clipped(r.text, 2000) };
  });
  return out;
}

async function sha256hex(textIn: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(textIn));
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0")).join("");
}

/** One PC - phone mailbox. Free-tier DO: a few keys, wiped on unpair. */
export class PhoneBox {
  private ctx: DurableObjectState;
  private env: Env;

  constructor(ctx: DurableObjectState, env: Env) {
    this.ctx = ctx;
    this.env = env;
  }

  private async authed(body: Record<string, unknown>): Promise<boolean> {
    const want = await this.ctx.storage.get<string>("sec");
    if (!want) return false;
    const secret = body.secret;
    if (typeof secret !== "string" || !SECRET_RE.test(secret)) return false;
    const got = await sha256hex(secret);
    // Fixed-width hex compare; no early exit.
    let diff = 0;
    for (let i = 0; i < 64; i++) diff |= got.charCodeAt(i) ^ want.charCodeAt(i);
    return diff === 0;
  }

  async fetch(request: Request): Promise<Response> {
    const action = new URL(request.url).pathname.slice(1);
    let body: Record<string, unknown>;
    try {
      body = await request.json();
    } catch {
      return text(400, "bad json");
    }
    const now = Date.now();

    if (action === "pair") {
      const secret = body.secret;
      if (typeof secret !== "string" || !SECRET_RE.test(secret)) return text(400, "secret");
      const hash = await sha256hex(secret);
      const have = await this.ctx.storage.get<string>("sec");
      if (have && have !== hash) return text(409, "box id taken");
      if (!have) {
        await this.ctx.storage.put("sec", hash);
        await this.ctx.storage.put("out", []);
      }
      return json({ ok: true });
    }

    if (!(await this.authed(body))) return text(403, "forbidden");

    switch (action) {
      case "claim": {
        const token = clipped(body.token, TOKEN_MAX);
        const name = clipped(body.name, 40);
        if (!token) return text(400, "token");
        await this.ctx.storage.put({ token, dev: name || "Android", paired: true });
        return json({ ok: true });
      }
      case "claimed": {
        return json({
          paired: (await this.ctx.storage.get<boolean>("paired")) === true,
          device: (await this.ctx.storage.get<string>("dev")) ?? null,
        });
      }
      case "state": {
        const state = cleanState(body.state);
        if (!state) return text(400, "state");
        const card = body.card;
        const batch: Record<string, unknown> = { state, stateAt: now, card: null };
        if (typeof card === "object" && card !== null) {
          batch.card = cleanCard(card);
        }
        await this.ctx.storage.put(batch);
        const alert = String(body.alert ?? "");
        if ((ALERTS as readonly string[]).includes(alert)) {
          const token = await this.ctx.storage.get<string>("token");
          if (token) await pushFcm(this.env, token, alert);
        }
        return json({ ok: true });
      }
      case "fetch": {
        const stateAt = (await this.ctx.storage.get<number>("stateAt")) ?? 0;
        if (now - stateAt > STATE_TTL_MS) {
          return json({ paired: true, device: null, state: null, card: null });
        }
        return json({
          paired: (await this.ctx.storage.get<boolean>("paired")) === true,
          device: (await this.ctx.storage.get<string>("dev")) ?? null,
          state: (await this.ctx.storage.get("state")) ?? null,
          card: (await this.ctx.storage.get("card")) ?? null,
        });
      }
      case "decide": {
        const requestId = clipped(body.requestId, 64);
        const decision = clipped(body.decision, 16);
        if (!requestId || !["allow", "deny", "answer"].includes(decision)) return text(400, "decision");
        const item: OutboxItem = { type: "decision", at: now, requestId, decision };
        if (decision === "answer") {
          const raw = typeof body.answers === "object" && body.answers !== null
            ? body.answers as Record<string, unknown> : {};
          const answers: Record<string, string> = {};
          for (const [k, v] of Object.entries(raw).slice(0, 8)) {
            answers[clipped(k, 160)] = clipped(v, 200);
          }
          item.answers = answers;
        }
        if (await this.enqueue(item, now)) return json({ ok: true });
        return text(429, "outbox full");
      }
      case "chat": {
        const textIn = clipped(body.text, 4000);
        if (!textIn) return text(400, "text");
        if (await this.enqueue({ type: "chat", at: now, text: textIn }, now)) return json({ ok: true });
        return text(429, "outbox full");
      }
      case "take": {
        const out = ((await this.ctx.storage.get<OutboxItem[]>("out")) ?? []).filter((i) => now - i.at < OUTBOX_TTL_MS);
        await this.ctx.storage.put("out", []);
        return json({ out });
      }
      case "unpair": {
        await this.ctx.storage.deleteAll();
        return json({ ok: true });
      }
      default:
        return text(404, "not found");
    }
  }

  private async enqueue(item: OutboxItem, now: number): Promise<boolean> {
    const out = ((await this.ctx.storage.get<OutboxItem[]>("out")) ?? []).filter((i) => now - i.at < OUTBOX_TTL_MS);
    if (out.length >= OUTBOX_MAX) return false;
    out.push(item);
    await this.ctx.storage.put("out", out);
    return true;
  }
}

// MARK: FCM OAuth (RS256 JWT from the service account) + send.

let fcmCached: { token: string; at: number; email: string } | null = null;
let fcmSa: { project_id: string; client_email: string; private_key: string } | null = null;

function serviceAccount(env: Env) {
  if (fcmSa) return fcmSa;
  if (!env.FCM_SA) return null;
  try {
    fcmSa = JSON.parse(env.FCM_SA);
  } catch {
    return null;
  }
  return fcmSa;
}

async function fcmToken(env: Env): Promise<string | null> {
  const sa = serviceAccount(env);
  if (!sa) return null;
  const now = Math.floor(Date.now() / 1000);
  if (fcmCached && fcmCached.email === sa.client_email && now - fcmCached.at < 50 * 60) return fcmCached.token;

  const header = base64url(JSON.stringify({ alg: "RS256", typ: "JWT" }));
  const claims = base64url(JSON.stringify({
    iss: sa.client_email,
    scope: "https://www.googleapis.com/auth/firebase.messaging",
    aud: "https://oauth2.googleapis.com/token",
    iat: now,
    exp: now + 3600,
  }));
  const key = await crypto.subtle.importKey(
    "pkcs8",
    pemToDer(sa.private_key),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
  const signature = await crypto.subtle.sign(
    { name: "RSASSA-PKCS1-v1_5" },
    key,
    new TextEncoder().encode(`${header}.${claims}`),
  );
  const grant = await fetch("https://oauth2.googleapis.com/token", {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body: `grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=${header}.${claims}.${base64url(new Uint8Array(signature))}`,
  });
  if (grant.status !== 200) return null;
  const token = ((await grant.json()) as { access_token?: string }).access_token;
  if (!token) return null;
  fcmCached = { token, at: now, email: sa.client_email };
  return token;
}

async function pushFcm(env: Env, token: string, kind: string): Promise<void> {
  const sa = serviceAccount(env);
  const bearer = await fcmToken(env);
  if (!sa || !bearer) return;
  await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
    method: "POST",
    headers: { authorization: `Bearer ${bearer}`, "content-type": "application/json" },
    body: JSON.stringify({
      message: {
        token,
        // Kind + timestamp only: the phone fetches the content from the box.
        data: { k: kind, t: String(Math.floor(Date.now() / 1000)) },
        android: { priority: "HIGH", ttl: "600s" },
      },
    }),
  });
}

function json(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}
