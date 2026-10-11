import { env, exports } from "cloudflare:workers";
import { evictDurableObject, listDurableObjectIds, runInDurableObject } from "cloudflare:test";
import { describe, expect, it } from "vitest";
import worker from "../src/index.ts";
import { ACCESS, behaviour, offer, open, proofOf, randomRoom, type Conn, type Harness, type Msg, type Options } from "./behaviour.ts";

type Anything = Record<string, unknown>;
const mutableEnv = env as unknown as Anything;

function wrap(ws: WebSocket): Conn {
  ws.binaryType = "arraybuffer"; // workerd's default is a Blob
  const queue: Msg[] = [];
  let wake: (() => void) | undefined;
  const push = (m: Msg) => {
    queue.push(m);
    wake?.();
  };
  ws.addEventListener("message", (e) => {
    const d = e.data as string | ArrayBuffer;
    push(typeof d === "string" ? { kind: "text", data: d } : { kind: "binary", data: new Uint8Array(d) });
  });
  ws.addEventListener("close", (e) => push({ kind: "close", code: e.code, reason: e.reason }));
  const next = async (timeoutMs = 1500): Promise<Msg> => {
    const until = Date.now() + timeoutMs;
    while (queue.length === 0) {
      if (Date.now() > until) throw new Error("timed out waiting for a message");
      await new Promise<void>((r) => {
        wake = r;
        setTimeout(r, 25);
      });
    }
    return queue.shift()!;
  };
  return {
    next,
    quiet: async (ms = 200) => {
      const until = Date.now() + ms;
      while (Date.now() < until) {
        if (queue.length > 0) return false;
        await new Promise((r) => setTimeout(r, 15));
      }
      return queue.length === 0;
    },
    send: (d) => ws.send(d),
    close: (code, reason) => ws.close(code ?? 1000, reason ?? ""),
  };
}

async function upgrade(room: string, role: string, o: Options = {}): Promise<Response> {
  const headers: Record<string, string> = { Upgrade: "websocket" };
  if (o.key !== null) headers.Authorization = `Bearer ${o.key ?? ACCESS}`;
  const protocols = o.protocols ?? offer(o.proof ?? proofOf(1));
  if (protocols) headers["Sec-WebSocket-Protocol"] = protocols;
  return exports.default.fetch(`https://relay.test/v1/room/${room}?role=${role}`, { headers });
}

const harness = async (): Promise<Harness> => ({
  async http(path, method = "GET") {
    const r = await exports.default.fetch(`https://relay.test${path}`, { method });
    return { status: r.status, text: await r.text() };
  },
  async connect(room, role, o = {}) {
    const res = await upgrade(room, role, o);
    if (res.status !== 101) return { refused: res.status };
    const ws = res.webSocket!;
    ws.accept();
    return wrap(ws);
  },
  async setAccessKey(key) {
    mutableEnv.ACCESS_KEY = key; // the Worker and every Room read the configured key from env
  },
  roomsCreated: async () => (await listDurableObjectIds(env.ROOM)).length,
  stop: async () => {},
});

behaviour("Worker (workerd)", harness);

describe("Worker only", () => {
  it("never contacts a room for a request it refuses (a stand-in room namespace records every call)", async () => {
    const calls: string[] = [];
    const fake = {
      idFromName: (n: string) => (calls.push(`id:${n}`), n),
      get: (id: string) => (calls.push(`get:${id}`), { fetch: async () => new Response(null, { status: 200 }) }),
    };
    const base = { ROOM: fake, ACCESS_KEY: ACCESS } as never;
    const room = randomRoom();
    const ws = { Upgrade: "websocket", "Sec-WebSocket-Protocol": offer(proofOf(1)) };
    const refused = [
      new Request("https://r.test/v1/room/bad?role=pc", { headers: { ...ws, Authorization: `Bearer ${ACCESS}` } }),
      new Request(`https://r.test/v1/room/${room}?role=x`, { headers: { ...ws, Authorization: `Bearer ${ACCESS}` } }),
      new Request(`https://r.test/v1/room/${room}?role=pc`, { headers: ws }),
      new Request(`https://r.test/v1/room/${room}?role=pc`, { headers: { ...ws, Authorization: "Bearer nope-nope-nope-nope-nope" } }),
      new Request(`https://r.test/v1/room/${room}?role=pc`, { headers: { Upgrade: "websocket", Authorization: `Bearer ${ACCESS}` } }),
      new Request(`https://r.test/v1/room/${room}?role=pc`, { headers: { "Sec-WebSocket-Protocol": offer(proofOf(1)), Authorization: `Bearer ${ACCESS}` } }),
      new Request(`https://r.test/v1/room/${room}?role=pc`, { method: "POST", headers: { ...ws, Authorization: `Bearer ${ACCESS}` } }),
    ];
    const statuses = [];
    for (const r of refused) statuses.push((await worker.fetch(r, base)).status);
    expect(statuses).toEqual([404, 404, 401, 401, 400, 426, 404]);
    expect(calls).toEqual([]);
    // And the same request, well-formed, reaches exactly one room, the one named by the id.
    const ok = await worker.fetch(new Request(`https://r.test/v1/room/${room}?role=pc`, { headers: { ...ws, Authorization: `Bearer ${ACCESS}` } }), base);
    expect(ok.status).toBe(200);
    expect(calls).toEqual([`id:${room}`, `get:${room}`]);
  });

  it("asks the rate limiter first: a limited address gets 429 before the key is even compared", async () => {
    const keys: string[] = [];
    const limited = { limit: async ({ key }: { key: string }) => (keys.push(key), { success: false }) };
    const base = { ROOM: {}, ACCESS_KEY: ACCESS, CONNECT_LIMIT: limited } as never;
    const room = randomRoom();
    const r = await worker.fetch(new Request(`https://r.test/v1/room/${room}?role=pc`, { headers: { "CF-Connecting-IP": "203.0.113.9", Authorization: "Bearer wrong-wrong-wrong-wrong" } }), base);
    expect(r.status).toBe(429);
    expect(keys).toEqual(["203.0.113.9"]);
    // A path that is not a room request costs the limiter nothing.
    keys.length = 0;
    expect((await worker.fetch(new Request("https://r.test/nope"), base)).status).toBe(404);
    expect(keys).toEqual([]);
  });

  it("stores nothing: the room's storage stays empty through a whole conversation", async () => {
    const room = randomRoom();
    const pc = await open(await harness(), room, "pc");
    const phone = await open(await harness(), room, "phone");
    await pc.next();
    await phone.next();
    for (let i = 0; i < 20; i++) {
      pc.send(new Uint8Array([i]));
      await phone.next();
    }
    const stub = env.ROOM.get(env.ROOM.idFromName(room));
    const keys = await runInDurableObject(stub, async (_instance, state) => [...(await state.storage.list()).keys()]);
    expect(keys).toEqual([]);
  });

  it("survives hibernation: the roles, the join proof and the access generation live in the sockets", async () => {
    const h = await harness();
    const room = randomRoom();
    const pc = await open(h, room, "pc");
    const phone = await open(h, room, "phone");
    await pc.next();
    await phone.next();
    await evictDurableObject(env.ROOM.get(env.ROOM.idFromName(room)), { webSockets: "hibernate" });
    phone.send(new Uint8Array([42]));
    expect(await pc.next(5000)).toEqual({ kind: "binary", data: new Uint8Array([42]) });
    // The join proof is still enforced after the room woke up again.
    const intruder = await open(h, room, "pc", { proof: proofOf(2) });
    expect(await intruder.next()).toEqual({ kind: "close", code: 1008, reason: "join proof" });
  });

  it("a room with no socket left remembers nothing: the next pair may use another join proof", async () => {
    const h = await harness();
    const room = randomRoom();
    const a = await open(h, room, "pc", { proof: proofOf(1) });
    a.close(1000, "bye");
    await new Promise((r) => setTimeout(r, 100));
    const b = await open(h, room, "pc", { proof: proofOf(2) });
    b.send(new Uint8Array([1])); // accepted: a different proof is fine for an empty room
    expect(await b.next()).toEqual({ kind: "text", data: '{"peer":"offline"}' });
  });
});
