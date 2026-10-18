// Drives PhoneBox (and the /v1/phone router in front of it) with a mocked
// Durable Object storage — no wrangler, no network. `npm test` compiles
// src/ into .test-dist/ first.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { PhoneBox } from "../.test-dist/index.js";
import { tokenGone } from "../.test-dist/fcm.js";

const ID = "a1b2c3d4e5f6a1b2c3d4e5f6";
const SECRET = "f".repeat(64);
const OTHER = "0".repeat(64);
const env = {}; // no FCM_SA: pushes no-op

function makeCtx() {
  const store = new Map();
  const ctx = {
    storage: {
      get: async (k) => store.get(k),
      put: async (k, v) => {
        if (typeof k === "string") store.set(k, v);
        else for (const [kk, vv] of Object.entries(k)) store.set(kk, vv);
      },
      delete: async (k) => store.delete(k),
      deleteAll: async () => store.clear(),
    },
  };
  return { ctx, store };
}

function box() {
  const { ctx } = makeCtx();
  return new PhoneBox(ctx, env);
}

function call(box, action, body) {
  return box.fetch(
    new Request(`https://box/${action}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
    }),
  );
}

const ok = async (p) => {
  const r = await p;
  assert.equal(r.status, 200, await r.clone().text());
  return r.json();
};

async function paired() {
  const b = box();
  await ok(call(b, "pair", { id: ID, secret: SECRET }));
  return b;
}

// ── Router (worker.fetch → /v1/phone/* → stub) ────────────────────────────────

test("router: GET, unknown action and bad ids are rejected", async () => {
  const b = box();
  const ns = { idFromName: () => ({}), get: () => ({ fetch: (r) => b.fetch(r) }) };
  const send = (path, opts = {}) =>
    worker.fetch(new Request(`https://relay${path}`, { method: "POST", ...opts }), {
      PHONE_BOX: ns,
    });
  assert.equal((await send("/v1/phone/pair", { method: "GET" })).status, 404);
  assert.equal((await send("/v1/phone/nope", { body: "{}" })).status, 404);
  assert.equal((await send("/v1/phone/pair", { body: "not json" })).status, 400);
  assert.equal((await send("/v1/phone/pair", { body: '{"id":"nothex!"}' })).status, 400);
  assert.equal(
    (await send("/v1/phone/pair", { body: "{}", headers: { "content-length": "450000" } })).status,
    413,
  );
  assert.equal(
    (await worker.fetch(new Request("https://relay/v1/phone/pair", { method: "POST", body: "{}" }), {})).status,
    501, // no PHONE_BOX binding on this deploy
  );
});

test("router: bodies are capped by what arrives and must be JSON objects", async () => {
  const b = box();
  const ns = { idFromName: () => ({}), get: () => ({ fetch: (r) => b.fetch(r) }) };
  const post = (body, extra = {}) =>
    worker.fetch(new Request("https://relay/v1/phone/pair", { method: "POST", body, ...extra }), { PHONE_BOX: ns });

  assert.equal((await post("null")).status, 400);
  assert.equal((await post("[1,2]")).status, 400);
  assert.equal((await post('"just a string"')).status, 400);

  // No Content-Length header, as a chunked upload sends it: the size is still counted.
  const big = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode(`{"id":"${"a".repeat(450000)}"}`));
      c.close();
    },
  });
  assert.equal((await post(big, { duplex: "half" })).status, 413);
});

test("live-activity: an oversized body is refused whatever Content-Length says", async () => {
  const big = new ReadableStream({
    start(c) {
      c.enqueue(new TextEncoder().encode(`{"token":"${"a".repeat(5000)}"}`));
      c.close();
    },
  });
  const r = await worker.fetch(
    new Request("https://relay/v1/live-activity", { method: "POST", body: big, duplex: "half" }),
    {},
  );
  assert.equal(r.status, 413);
});

test("router: new boxes are rate-limited per address when a limiter is bound", async () => {
  const b = box();
  const ns = { idFromName: () => ({}), get: () => ({ fetch: (r) => b.fetch(r) }) };
  const keys = [];
  const PAIR_LIMITER = { limit: async ({ key }) => (keys.push(key), { success: false }) };
  const send = (action) =>
    worker.fetch(
      new Request(`https://relay/v1/phone/${action}`, {
        method: "POST",
        body: JSON.stringify({ id: ID, secret: SECRET }),
        headers: { "cf-connecting-ip": "203.0.113.7" },
      }),
      { PHONE_BOX: ns, PAIR_LIMITER },
    );
  assert.equal((await send("pair")).status, 429);
  assert.deepEqual(keys, ["203.0.113.7"]);
  // Authenticated actions never consult it (this box is not paired: 403).
  assert.equal((await send("fetch")).status, 403);
  assert.deepEqual(keys, ["203.0.113.7"]);
});

// ── Pairing and auth ──────────────────────────────────────────────────────────

test("pair creates the box; every action needs the secret", async () => {
  const b = box();
  assert.equal((await call(b, "fetch", { id: ID, secret: SECRET })).status, 403);
  assert.equal((await call(b, "pair", { id: ID, secret: "short" })).status, 400);
  await ok(call(b, "pair", { id: ID, secret: SECRET }));
  assert.equal((await call(b, "fetch", { id: ID, secret: OTHER })).status, 403);
  assert.equal((await call(b, "fetch", { id: ID, secret: SECRET })).status, 200);
  // A second pair with a different secret must not take over the box.
  assert.equal((await call(b, "pair", { id: ID, secret: OTHER })).status, 409);
  // Same secret re-pairing is idempotent.
  await ok(call(b, "pair", { id: ID, secret: SECRET }));
});

// ── Claim / fetch / state ─────────────────────────────────────────────────────

test("claim → claimed → fetch round-trips device and state", async () => {
  const b = await paired();
  assert.deepEqual(await ok(call(b, "claimed", { id: ID, secret: SECRET })), {
    paired: false,
    device: null,
  });
  await ok(call(b, "claim", { id: ID, secret: SECRET, token: "tok", name: "Pixel" }));
  assert.deepEqual(await ok(call(b, "claimed", { id: ID, secret: SECRET })), {
    paired: true,
    device: "Pixel",
  });
  assert.equal((await call(b, "claim", { id: ID, secret: SECRET })).status, 400); // no token
});

const PHONE = "1".repeat(32);
const THIEF = "2".repeat(32);

test("a paired box only takes a new token from the phone that claimed it", async () => {
  const b = await paired();
  await ok(call(b, "claim", { id: ID, secret: SECRET, token: "t1", name: "Pixel", device: PHONE }));
  // The same phone refreshing its FCM token is fine.
  await ok(call(b, "claim", { id: ID, secret: SECRET, token: "t2", name: "Pixel", device: PHONE }));
  // Anyone else holding the code cannot take the box over…
  assert.equal(
    (await call(b, "claim", { id: ID, secret: SECRET, token: "t3", name: "Evil", device: THIEF })).status,
    409,
  );
  // …with or without a device id.
  assert.equal((await call(b, "claim", { id: ID, secret: SECRET, token: "t3", name: "Evil" })).status, 409);
  assert.deepEqual(await ok(call(b, "claimed", { id: ID, secret: SECRET })), { paired: true, device: "Pixel" });
  // A malformed device id is refused outright.
  assert.equal(
    (await call(b, "claim", { id: ID, secret: SECRET, token: "t4", device: "not-hex" })).status,
    400,
  );
});

test("a box paired before device ids existed is taken by the first phone that sends one", async () => {
  const b = await paired();
  await ok(call(b, "claim", { id: ID, secret: SECRET, token: "t1", name: "Old build" })); // no device
  // The old build refreshing its token still works until it learns device ids.
  await ok(call(b, "claim", { id: ID, secret: SECRET, token: "t1b", name: "Old build" }));
  await ok(call(b, "claim", { id: ID, secret: SECRET, token: "t2", name: "Pixel", device: PHONE }));
  assert.equal(
    (await call(b, "claim", { id: ID, secret: SECRET, token: "t3", device: THIEF })).status,
    409,
  );
});

test("state is clipped to bounds before it is stored", async () => {
  const b = await paired();
  const sessions = Array.from({ length: 20 }, (_, i) => ({
    pillId: `p${i}`,
    agent: "a".repeat(100),
    color: i === 0 ? "not-a-color" : "#a1B2c3",
    state: "working",
    statusText: "x".repeat(500),
    stepIndex: -5,
    stepCount: 9999,
  }));
  await ok(call(b, "state", {
    id: ID,
    secret: SECRET,
    state: {
      sessions,
      awaiting: {
        requestId: "r1",
        pillId: "p0",
        agent: "Claude",
        kind: "question",
        title: "y".repeat(400),
        detail: "z".repeat(1000),
        options: ["o".repeat(200)],
        questions: [{ q: "Pick", options: ["A", "B"] }],
      },
      chatTail: [{ role: "user", text: "hi" }, { role: "nope", text: "w".repeat(3000) }],
    },
    alert: "approval", // pushes FCM; no-ops without FCM_SA
  }));
  const { state, card } = await ok(call(b, "fetch", { id: ID, secret: SECRET }));
  assert.equal(state.sessions.length, 12);
  assert.equal(state.sessions[0].color, "#8C8C8C");
  assert.equal(state.sessions[0].agent.length, 40);
  assert.equal(state.sessions[0].statusText.length, 120);
  assert.equal(state.sessions[0].stepIndex, 0);
  assert.equal(state.sessions[0].stepCount, 999);
  const aw = state.awaiting;
  assert.equal(aw.title.length, 160);
  assert.equal(aw.detail.length, 600);
  assert.deepEqual(aw.questions, [{ q: "Pick", options: ["A", "B"], multi: false }]);
  assert.equal(state.chatTail[1].role, "user"); // unknown roles fall back
  assert.equal(state.chatTail[1].text.length, 2000);
  assert.equal(card, null);
});

// ── Decisions and chat outbox ─────────────────────────────────────────────────

test("decide/chat enqueue; take drains once", async () => {
  const b = await paired();
  assert.equal((await call(b, "decide", { id: ID, secret: SECRET, requestId: "r1", decision: "maybe" })).status, 400);
  await ok(call(b, "decide", { id: ID, secret: SECRET, requestId: "r1", decision: "allow" }));
  await ok(call(b, "decide", {
    id: ID, secret: SECRET, requestId: "r2", decision: "answer",
    answers: { "Which file?": "src/main.ts" },
  }));
  await ok(call(b, "chat", { id: ID, secret: SECRET, text: "hello pc" }));
  const { out } = await ok(call(b, "take", { id: ID, secret: SECRET }));
  assert.deepEqual(
    out.map((i) => [i.type, i.requestId, i.decision]),
    [
      ["decision", "r1", "allow"],
      ["decision", "r2", "answer"],
      ["chat", undefined, undefined],
    ],
  );
  assert.deepEqual(out[1].answers, { "Which file?": "src/main.ts" });
  assert.equal(out[2].text, "hello pc");
  assert.deepEqual((await ok(call(b, "take", { id: ID, secret: SECRET }))).out, []); // drained
});

test("an empty take writes nothing; a drain writes once", async () => {
  const { ctx } = makeCtx();
  let puts = 0;
  const put = ctx.storage.put;
  ctx.storage.put = async (k, v) => {
    puts++;
    return put(k, v);
  };
  const b = new PhoneBox(ctx, env);
  await ok(call(b, "pair", { id: ID, secret: SECRET }));

  puts = 0;
  for (let i = 0; i < 3; i++) {
    assert.deepEqual((await ok(call(b, "take", { id: ID, secret: SECRET }))).out, []);
  }
  assert.equal(puts, 0, "polling an empty outbox must not write");

  await ok(call(b, "chat", { id: ID, secret: SECRET, text: "hi" }));
  puts = 0;
  assert.equal((await ok(call(b, "take", { id: ID, secret: SECRET }))).out.length, 1);
  assert.equal(puts, 1, "the drain itself is one write");
});

test("fcm: an unregistered or missing token is gone; other failures are not", () => {
  assert.equal(tokenGone(404, '{"error":{"status":"NOT_FOUND"}}'), true);
  assert.equal(tokenGone(400, '{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}'), true);
  assert.equal(tokenGone(400, '{"error":{"status":"INVALID_ARGUMENT","message":"bad payload"}}'), false);
  assert.equal(tokenGone(500, ""), false);
  assert.equal(tokenGone(429, "quota"), false);
});

test("the outbox caps at 50 pending items", async () => {
  const b = await paired();
  for (let i = 0; i < 50; i++) {
    await ok(call(b, "chat", { id: ID, secret: SECRET, text: `m${i}` }));
  }
  assert.equal((await call(b, "chat", { id: ID, secret: SECRET, text: "51st" })).status, 429);
});

test("a multi-select question keeps its flag and its answer stays a list", async () => {
  const b = await paired();
  await ok(call(b, "state", {
    id: ID,
    secret: SECRET,
    state: {
      sessions: [],
      awaiting: {
        requestId: "q1", pillId: "p", agent: "Claude", kind: "question", title: "AskUserQuestion",
        detail: "", options: [], questions: [{ q: "Extras?", options: ["Tests", "Docs"], multi: true }],
      },
    },
  }));
  const { state } = await ok(call(b, "fetch", { id: ID, secret: SECRET }));
  assert.equal(state.awaiting.questions[0].multi, true);

  await ok(call(b, "decide", {
    id: ID, secret: SECRET, requestId: "q1", decision: "answer",
    answers: { "Extras?": ["Tests", "Docs", "x".repeat(300), ...Array(10).fill("y")], Single: "A" },
  }));
  const { out } = await ok(call(b, "take", { id: ID, secret: SECRET }));
  const extras = out[0].answers["Extras?"];
  assert.ok(Array.isArray(extras));
  assert.equal(extras.length, 6);
  assert.deepEqual(extras.slice(0, 2), ["Tests", "Docs"]);
  assert.equal(extras[2].length, 200);
  assert.equal(out[0].answers.Single, "A");
});

// ── Unpair ────────────────────────────────────────────────────────────────────

test("unpair wipes the box; the old secret dies with it", async () => {
  const b = await paired();
  await ok(call(b, "unpair", { id: ID, secret: SECRET }));
  assert.equal((await call(b, "fetch", { id: ID, secret: SECRET })).status, 403);
});

// ── End-to-end blobs (the box stores, never reads) ────────────────────────────

test("an encrypted state is stored untouched and fetched back as it arrived", async () => {
  const b = await paired();
  const blob = { enc: 1, n: "AQIDBAUGBwgJCgsM", ct: "s9NCsOUHmz_m5rSKEVucA1ZlOHm45daYIKuASYQjPZie6MWq" };
  await ok(call(b, "state", { id: ID, secret: SECRET, state: blob, alert: "approval" }));
  const { state } = await ok(call(b, "fetch", { id: ID, secret: SECRET }));
  assert.deepEqual(state, blob); // verbatim — not clipped, not cleaned
});

test("sealed decide/chat/select land in the outbox as enc items", async () => {
  const b = await paired();
  const n = "AQIDBAUGBwgJCgsM";
  const ct = "aGFuZHMtb2ZmLXRoZS1jb250ZW50cw"; // not plaintext the box could clip
  await ok(call(b, "decide", { id: ID, secret: SECRET, n, ct }));
  await ok(call(b, "chat", { id: ID, secret: SECRET, n, ct: ct + "2" }));
  await ok(call(b, "select", { id: ID, secret: SECRET, n, ct: ct + "3" }));
  const { out } = await ok(call(b, "take", { id: ID, secret: SECRET }));
  assert.deepEqual(
    out.map((i) => [i.type, i.n, i.ct]),
    [
      ["enc", n, ct],
      ["enc", n, ct + "2"],
      ["enc", n, ct + "3"],
    ],
  );
});

test("a malformed enc call falls through to the plain-field checks", async () => {
  const b = await paired();
  // n present but no ct → not a blob; the legacy decision validation answers.
  assert.equal(
    (await call(b, "decide", { id: ID, secret: SECRET, n: "AQIDBAUGBwgJCgsM" })).status,
    400,
  );
  // Bad nonce length → same.
  assert.equal(
    (await call(b, "chat", { id: ID, secret: SECRET, n: "AA", ct: "AA" })).status,
    400,
  );
});
