// Drives PhoneBox (and the /v1/phone router in front of it) with a mocked
// Durable Object storage — no wrangler, no network. `npm test` compiles
// src/ into .test-dist/ first.
import { test } from "node:test";
import assert from "node:assert/strict";
import worker, { PhoneBox } from "../.test-dist/index.js";

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
    (await send("/v1/phone/pair", { body: "{}", headers: { "content-length": "9000" } })).status,
    413,
  );
  assert.equal(
    (await worker.fetch(new Request("https://relay/v1/phone/pair", { method: "POST", body: "{}" }), {})).status,
    501, // no PHONE_BOX binding on this deploy
  );
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
  assert.deepEqual(aw.questions, [{ q: "Pick", options: ["A", "B"] }]);
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

test("the outbox caps at 50 pending items", async () => {
  const b = await paired();
  for (let i = 0; i < 50; i++) {
    await ok(call(b, "chat", { id: ID, secret: SECRET, text: `m${i}` }));
  }
  assert.equal((await call(b, "chat", { id: ID, secret: SECRET, text: "51st" })).status, 429);
});

// ── Unpair ────────────────────────────────────────────────────────────────────

test("unpair wipes the box; the old secret dies with it", async () => {
  const b = await paired();
  await ok(call(b, "unpair", { id: ID, secret: SECRET }));
  assert.equal((await call(b, "fetch", { id: ID, secret: SECRET })).status, 403);
});
