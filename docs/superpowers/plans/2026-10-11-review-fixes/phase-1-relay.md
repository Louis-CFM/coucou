# Phase 1 — Relay Worker Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the self-hosted relay cheap to run idle, refuse oversized or non-object bodies, keep a paired box bound to its phone, drop FCM tokens that no longer work, and carry multi-select questions.

**Architecture:** All changes are in `relay/src/index.ts`, plus one pure helper module `relay/src/fcm.ts`. Every change stays backward compatible with today's PC (`windows/src-tauri/src/phone.rs`) and phone (`android/.../Relay.kt`): new fields are optional, and old requests keep their old answers. The one exception is the 409 on re-claim, which only affects a phone that is not the one that claimed the box.

**Tech Stack:** TypeScript, Cloudflare Workers + Durable Objects (SQLite-backed, `wrangler.toml` `new_sqlite_classes`), Node `node:test` against `.test-dist/` (compiled by `tsc -p tsconfig.test.json`).

**Spec:** `README.md` in this folder (findings C14, V4, R1–R5, cross-phase contracts 1–3).

## Global Constraints

See `README.md` → Global Constraints. For this phase in particular:
- No new npm dependencies.
- Requests the shipped PC and phone builds send today must get the same answer as before. Only the re-claim from a different phone changes, to 409.
- Run everything from `relay/`: `npm test` (compiles, then `node --test`) and `npm run typecheck`.

## Review Focus

See `README.md`. The test this phase owns: Task 1.3, "a box paired before device ids existed is taken by the first phone that sends one".

---

### Task 1.1: An empty `take` writes nothing

The PC polls `take` every 3 s (every 10 s once Phase 2 lands). Today each poll does `put("out", [])` even when the outbox is already empty. That is one billed row write per poll: about 28.8k a day per PC against a 100k/day free tier.

**Files:**
- Modify: `relay/src/index.ts` (the `case "take":` block, currently lines 507-511)
- Test: `relay/test/phone.test.mjs`

**Interfaces:**
- Consumes: nothing new.
- Produces: same `take` response `{ out: OutboxItem[] }`.

- [ ] **Step 1: Write the failing test**

Append to `relay/test/phone.test.mjs`, below the `"decide/chat enqueue; take drains once"` test:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd relay && npm test`
Expected: FAIL, `polling an empty outbox must not write` (3 !== 0).

- [ ] **Step 3: Write minimal implementation**

In `relay/src/index.ts`, replace the `case "take":` block with:

```ts
      case "take": {
        const stored = (await this.ctx.storage.get<OutboxItem[]>("out")) ?? [];
        // The PC asks every few seconds: an empty outbox costs a read, never a write.
        if (stored.length === 0) return json({ out: [] });
        const out = stored.filter((i) => now - i.at < OUTBOX_TTL_MS);
        await this.ctx.storage.put("out", []);
        return json({ out });
      }
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd relay && npm test`
Expected: PASS (all tests, including the existing `"decide/chat enqueue; take drains once"`).

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/test/phone.test.mjs
git commit -m "relay: an empty take is a read, not a write"
```

---

### Task 1.2: Bodies are capped by what arrives, and must be JSON objects

`index.ts:48` and `:223` trust `Content-Length`, which a chunked upload does not send. A JSON `null` body throws inside the `.then` success handler (`index.ts:230-239`) and becomes a 500.

**Files:**
- Modify: `relay/src/index.ts` (the `fetch` handler's live-activity branch at lines 45-59, and `phoneRoute` at lines 218-240)
- Test: `relay/test/phone.test.mjs`

**Interfaces:**
- Consumes: nothing new.
- Produces: `async function readObject(request: Request, max: number): Promise<Record<string, unknown> | Response>` (module-private; Tasks 1.3 and 1.6 rely on `phoneRoute` being `async` and using it).

- [ ] **Step 1: Write the failing tests**

Append to `relay/test/phone.test.mjs` in the Router section:

```js
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
      c.enqueue(new TextEncoder().encode(`{"id":"${"a".repeat(300000)}"}`));
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npm test`
Expected: FAIL. `null` gives 500 (or an unhandled rejection) instead of 400, and the streamed bodies give 400/404 instead of 413.

- [ ] **Step 3: Write minimal implementation**

In `relay/src/index.ts`:

1. Add, next to `function text(...)`:

```ts
/**
 * The request body as a JSON object, refused past `max` bytes counted as they
 * arrive — a chunked upload carries no Content-Length to trust — and refused
 * when it is anything but an object (`null`, a list, a string).
 */
async function readObject(request: Request, max: number): Promise<Record<string, unknown> | Response> {
  if (Number(request.headers.get("content-length") ?? "0") > max) return text(413, "too large");
  const chunks: Uint8Array[] = [];
  let size = 0;
  if (request.body) {
    const reader = request.body.getReader();
    for (;;) {
      const { done, value } = await reader.read();
      if (done) break;
      size += value.byteLength;
      if (size > max) {
        await reader.cancel();
        return text(413, "too large");
      }
      chunks.push(value);
    }
  }
  const bytes = new Uint8Array(size);
  let at = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, at);
    at += chunk.byteLength;
  }
  let parsed: unknown;
  try {
    parsed = JSON.parse(new TextDecoder().decode(bytes));
  } catch {
    return text(400, "bad json");
  }
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) return text(400, "body");
  return parsed as Record<string, unknown>;
}

/** State pushes carry the chat transcript tail — up to ~200 KB with every cleanState bound maxed out. */
const PHONE_BODY_MAX = 262144;
const LIVE_ACTIVITY_BODY_MAX = 4096;
const PHONE_ACTIONS = ["pair", "claim", "claimed", "state", "fetch", "decide", "chat", "select", "take", "unpair"];
```

2. In `fetch`, replace the block from `if (Number(request.headers.get("content-length") ?? "0") > 4096) {` through `const problem = validate(body);` with:

```ts
    const parsed = await readObject(request, LIVE_ACTIVITY_BODY_MAX);
    if (parsed instanceof Response) return parsed;
    const body = parsed as unknown as RelayRequest;
    const problem = validate(body);
```

3. Replace the whole `function phoneRoute(...)` with:

```ts
async function phoneRoute(request: Request, url: URL, env: Env): Promise<Response> {
  if (!env.PHONE_BOX) return text(501, "android support not deployed on this relay");
  if (request.method !== "POST") return text(404, "not found");
  const action = url.pathname.slice("/v1/phone/".length);
  if (!PHONE_ACTIONS.includes(action)) return text(404, "not found");
  const body = await readObject(request, PHONE_BODY_MAX);
  if (body instanceof Response) return body;
  const id = body.id;
  if (typeof id !== "string" || !ID_RE.test(id)) return text(400, "id");
  const stub = env.PHONE_BOX.get(env.PHONE_BOX.idFromName(id));
  return stub.fetch(new Request(`https://box/${action}`, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify(body),
  }));
}
```

- [ ] **Step 4: Run tests and typecheck**

Run: `cd relay && npm test && npm run typecheck`
Expected: PASS. The existing router test still sees 404 for GET, 404 for an unknown action, 400 for `not json` and for `{"id":"nothex!"}`, 413 for `content-length: 300000`, and 501 with no binding.

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/test/phone.test.mjs
git commit -m "relay: cap bodies by what arrives; refuse null, lists and strings"
```

---

### Task 1.3: A paired box only takes a new token from the phone that claimed it

Today `claim` (`index.ts:429-435`) overwrites the token and device for anyone holding the secret. A leaked QR code or pasted code therefore hijacks the box silently. Phase 4 Task 4.1 makes the phone send a random `device` id (32 hex).

**Files:**
- Modify: `relay/src/index.ts` (constants near `ID_RE`; the `case "claim":` block)
- Test: `relay/test/phone.test.mjs`

**Interfaces:**
- Consumes: claim body `{ id, secret, token, name, device? }`.
- Produces: storage key `devId` (string). Responses: `200 {ok:true}`, `400 "token"`, `400 "device"`, `409 "claimed by another phone"`.

- [ ] **Step 1: Write the failing tests**

Append to `relay/test/phone.test.mjs` in the "Claim / fetch / state" section:

```js
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npm test`
Expected: FAIL. The THIEF claims return 200 instead of 409, and `not-hex` returns 200 instead of 400.

- [ ] **Step 3: Write minimal implementation**

In `relay/src/index.ts`, add below `const SECRET_RE = ...`:

```ts
/** The phone's own id, made once per pairing (Android Prefs): who may refresh the box's token. */
const DEVICE_RE = /^[0-9a-f]{32}$/;
```

Replace the `case "claim":` block with:

```ts
      case "claim": {
        const token = clipped(body.token, TOKEN_MAX);
        const name = clipped(body.name, 40);
        if (!token) return text(400, "token");
        const device = body.device === undefined ? "" : String(body.device);
        if (device && !DEVICE_RE.test(device)) return text(400, "device");
        const paired = (await this.ctx.storage.get<boolean>("paired")) === true;
        const owner = (await this.ctx.storage.get<string>("devId")) ?? "";
        // Once a phone has the box, only that phone may refresh its token: the
        // code on the PC's screen is not a key to someone else's phone. A box
        // paired by a build that sent no device id has no owner yet: its phone
        // keeps refreshing as before, and the first claim that carries a device
        // id becomes the owner.
        if (paired && owner && device !== owner) return text(409, "claimed by another phone");
        await this.ctx.storage.put({
          token,
          dev: name || "Android",
          paired: true,
          ...(device ? { devId: device } : {}),
        });
        return json({ ok: true });
      }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd relay && npm test`
Expected: PASS, including the existing `"claim → claimed → fetch round-trips device and state"` (its first claim has no device on a box that is not yet paired, and its token-less claim still returns 400).

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/test/phone.test.mjs
git commit -m "relay: a paired box only takes a new token from its own phone"
```

---

### Task 1.4: A token FCM no longer delivers to is forgotten

`pushFcm` (`index.ts:584-600`) ignores FCM's answer, so a dead token is pushed to forever and alerts silently stop. Once the token is forgotten, the phone's next foreground claim (Phase 4 Task 4.1) stores a fresh one.

**Files:**
- Create: `relay/src/fcm.ts`
- Modify: `relay/src/index.ts` (`pushFcm`, and its caller in `case "state":`)
- Test: `relay/test/phone.test.mjs` (also gives `makeCtx` a `delete`)

**Interfaces:**
- Produces: `export function tokenGone(status: number, body: string): boolean` in `relay/src/fcm.ts`. `pushFcm` now returns `Promise<boolean>` (true = token gone).

- [ ] **Step 1: Write the failing test**

In `relay/test/phone.test.mjs`, add `delete: async (k) => store.delete(k),` inside `makeCtx`'s `storage` object (next to `deleteAll`). Then add the import at the top and the test:

```js
import { tokenGone } from "../.test-dist/fcm.js";

test("fcm: an unregistered or missing token is gone; other failures are not", () => {
  assert.equal(tokenGone(404, '{"error":{"status":"NOT_FOUND"}}'), true);
  assert.equal(
    tokenGone(400, '{"error":{"details":[{"errorCode":"UNREGISTERED"}]}}'),
    true,
  );
  assert.equal(tokenGone(400, '{"error":{"status":"INVALID_ARGUMENT","message":"bad payload"}}'), false);
  assert.equal(tokenGone(500, ""), false);
  assert.equal(tokenGone(429, "quota"), false);
});
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd relay && npm test`
Expected: FAIL. `Cannot find module '../.test-dist/fcm.js'`.

- [ ] **Step 3: Write minimal implementation**

Create `relay/src/fcm.ts`:

```ts
// What FCM's HTTP v1 answers mean for the box. Pure, so it is tested without a
// service account: https://firebase.google.com/docs/cloud-messaging/manage-tokens

/**
 * True when FCM says the token will never deliver again — the app was removed
 * or the token rotated. A 5xx, a quota answer or a malformed message is not
 * the token's fault and keeps it.
 */
export function tokenGone(status: number, body: string): boolean {
  return status === 404 || body.includes('"UNREGISTERED"');
}
```

In `relay/src/index.ts`, add the import at the top: `import { tokenGone } from "./fcm.js";`. The `.js` extension is required: the tests run the compiled `.test-dist/index.js` under plain Node ESM, which does not add extensions, while TypeScript (`moduleResolution: Bundler`) and wrangler's esbuild both map `./fcm.js` to `fcm.ts`. Then replace `pushFcm` with:

```ts
/** Sends the wake-up. True when FCM says the token is gone for good. */
async function pushFcm(env: Env, token: string, kind: string): Promise<boolean> {
  const sa = serviceAccount(env);
  const bearer = await fcmToken(env);
  if (!sa || !bearer) return false;
  const res = await fetch(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
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
  if (res.ok) return false;
  return tokenGone(res.status, await res.text());
}
```

In `case "state":`, replace `if (token) await pushFcm(this.env, token, alert);` with:

```ts
          // A token FCM says is gone is dropped; the phone claims a fresh one when it next opens.
          if (token && (await pushFcm(this.env, token, alert))) await this.ctx.storage.delete("token");
```

- [ ] **Step 4: Run tests and typecheck**

Run: `cd relay && npm test && npm run typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add relay/src/fcm.ts relay/src/index.ts relay/test/phone.test.mjs
git commit -m "relay: forget an FCM token that no longer delivers"
```

---

### Task 1.5: Multi-select questions travel to the phone and their answers come back as lists

`cleanCard` (`index.ts:267-273`) drops `multiSelect`, and `decide` (`:476-483`) clips every answer to a string. The PC's hook (`windows/hook/src/reply.rs:150-158`) requires a list for a multi-select question, so phone answers to those were rejected.

**Files:**
- Modify: `relay/src/index.ts` (`PhoneCard`, `cleanCard`, `OutboxItem.answers`, `case "decide":`)
- Test: `relay/test/phone.test.mjs`

**Interfaces:**
- Produces: cross-phase contract 1, `questions: { q: string; options: string[]; multi: boolean }[]`, and contract 2, `answers: Record<string, string | string[]>`.

- [ ] **Step 1: Write the failing tests**

In `relay/test/phone.test.mjs`, change the line in `"state is clipped to bounds before it is stored"` from
`assert.deepEqual(aw.questions, [{ q: "Pick", options: ["A", "B"] }]);` to:

```js
  assert.deepEqual(aw.questions, [{ q: "Pick", options: ["A", "B"], multi: false }]);
```

Append:

```js
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd relay && npm test`
Expected: FAIL. `multi` is missing, and `extras` is a string.

- [ ] **Step 3: Write minimal implementation**

In `relay/src/index.ts`:

1. In `interface PhoneCard`, change the `questions` line to:

```ts
  /** Question cards: each question's text, its labels and whether several may be picked. */
  questions: { q: string; options: string[]; multi: boolean }[];
```

2. In `cleanCard`, change the per-question `return { … }` to:

```ts
    return {
      q: clipped(qr.q, 160),
      options: (Array.isArray(qr.options) ? qr.options : []).slice(0, 6).map((o) => clipped(o, 80)),
      multi: qr.multi === true,
    };
```

3. In `interface OutboxItem`, change `answers` to:

```ts
  /** Question text → the label picked, or the labels picked for a multi-select question. */
  answers?: Record<string, string | string[]>;
```

4. In `case "decide":`, replace the `answers` loop with:

```ts
          const answers: Record<string, string | string[]> = {};
          for (const [k, v] of Object.entries(raw).slice(0, 8)) {
            const key = clipped(k, 160);
            answers[key] = Array.isArray(v)
              ? v.slice(0, 6).map((x) => clipped(x, 200)).filter((x) => x !== "")
              : clipped(v, 200);
          }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd relay && npm test && npm run typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/test/phone.test.mjs
git commit -m "relay: carry multi-select questions and list answers"
```

---

### Task 1.6: Rate-limit box creation when a limiter is bound; drop fields nobody sends

`pair` is the only unauthenticated action, and anyone who finds the worker URL can create unlimited boxes on the owner's quota (`index.ts:413-424`). `chatReply` (`:333`) is never sent by any client, and the `"finished"` alert (`:213`) is never produced (`phone.rs:257` maps only approval/question).

**Files:**
- Modify: `relay/src/index.ts` (`Env`, `phoneRoute`, `ALERTS`, `cleanState`)
- Modify: `relay/wrangler.toml`
- Modify: `relay/README.md` (one paragraph)
- Test: `relay/test/phone.test.mjs`

**Interfaces:**
- Consumes: optional binding `PAIR_LIMITER: { limit(o: { key: string }): Promise<{ success: boolean }> }`.
- Produces: `429 "slow down"` from `pair` when the limiter refuses.

- [ ] **Step 1: Write the failing test**

Append to the Router section of `relay/test/phone.test.mjs`:

```js
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd relay && npm test`
Expected: FAIL. `pair` returns 200, not 429.

- [ ] **Step 3: Write minimal implementation**

In `relay/src/index.ts`:

1. In `interface Env`, add:

```ts
  // Optional (wrangler.toml [[ratelimits]]): how many new boxes one address may create.
  PAIR_LIMITER?: { limit(options: { key: string }): Promise<{ success: boolean }> };
```

2. In `phoneRoute`, after the `id` check and before `const stub = …`, add:

```ts
  // `pair` is the one call without a secret: without a limit, anyone who finds
  // this worker could spend its owner's Durable Object quota on empty boxes.
  if (action === "pair" && env.PAIR_LIMITER) {
    const { success } = await env.PAIR_LIMITER.limit({ key: request.headers.get("cf-connecting-ip") ?? "unknown" });
    if (!success) return text(429, "slow down");
  }
```

3. Change `const ALERTS = ["approval", "question", "finished"] as const;` to `const ALERTS = ["approval", "question"] as const;`.

4. In `cleanState`'s return type, delete the `chatReply?: unknown;` line, and delete the line `if (typeof src.chatReply === "string") out.chatReply = src.chatReply.slice(0, 4000);`.

5. In `interface OutboxItem`, change the `agent` doc comment to `/** Which CLI owns the session — "devin" | "claude" | "codex" | "opencode". */`.

In `relay/wrangler.toml`, append:

```toml
# Optional: limit how fast new phone boxes can be created (the one call that
# needs no secret). Uncomment to enable; the code works with or without it.
# [[ratelimits]]
# name = "PAIR_LIMITER"
# namespace_id = "1001"
#   [ratelimits.simple]
#   limit = 5
#   period = 60
```

In `relay/README.md`, in the Android/phone section, add this paragraph:

```markdown
**Optional — rate-limit pairing.** `POST /v1/phone/pair` is the only call that
needs no secret. Uncomment the `[[ratelimits]]` block in `wrangler.toml` to let
one address create at most 5 boxes a minute.
```

- [ ] **Step 4: Run tests and typecheck**

Run: `cd relay && npm test && npm run typecheck`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add relay/src/index.ts relay/wrangler.toml relay/README.md relay/test/phone.test.mjs
git commit -m "relay: optional pair rate limit; drop chatReply and the unsent finished alert"
```

---

## Phase 1 done when

- [ ] `cd relay && npm test` passes (7 original + 8 new tests).
- [ ] `cd relay && npm run typecheck` passes.
- [ ] `wrangler deploy --dry-run` (from `relay/`) bundles without errors.
