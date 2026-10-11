// One behaviour suite, run against the Worker (inside workerd, tests/worker.relay.test.ts) and against the Node twin
// (tests/node.relay.test.ts). The same expectations hold for both, so the twin that the Rust and Kotlin clients are tested
// against really behaves like the relay that is deployed.

import { describe, expect, it, afterAll, beforeAll } from "vitest";

export const ACCESS = "test-access-key-test-access-key-0123456789";
export const OTHER_ACCESS = "another-access-key-another-access-key-9876543210";

export type Msg =
  | { kind: "binary"; data: Uint8Array }
  | { kind: "text"; data: string }
  | { kind: "close"; code: number; reason: string };

export interface Conn {
  next(timeoutMs?: number): Promise<Msg>;
  /** Resolves true if nothing arrives within `ms`. */
  quiet(ms?: number): Promise<boolean>;
  send(data: Uint8Array | string): void;
  close(code?: number, reason?: string): void;
}

export interface Options {
  key?: string | null; // null: no Authorization header
  protocols?: string; // the whole Sec-WebSocket-Protocol offer
  proof?: string; // join proof only (builds the offer)
}

export interface Harness {
  http(path: string, method?: string): Promise<{ status: number; text: string }>;
  connect(room: string, role: string, options?: Options): Promise<Conn | { refused: number }>;
  setAccessKey(key: string | undefined): Promise<void>;
  /** Rooms that exist (Node: with a live socket; Worker: objects ever created in this test file). */
  roomsCreated(): Promise<number>;
  stop(): Promise<void>;
}

export const randomRoom = () => Buffer.from(crypto.getRandomValues(new Uint8Array(16))).toString("base64url");
export const proofOf = (seed: number) => Buffer.from(new Uint8Array(32).fill(seed)).toString("base64url");
export const offer = (proof: string) => `coucou.v1, coucou.join.${proof}`;
const isConn = (c: Conn | { refused: number }): c is Conn => !("refused" in c);

export async function open(h: Harness, room: string, role: string, o: Options = {}): Promise<Conn> {
  const c = await h.connect(room, role, o);
  if (!isConn(c)) throw new Error(`refused with ${c.refused}`);
  return c;
}

export function behaviour(name: string, make: () => Promise<Harness>) {
  describe(`${name}: the relay`, () => {
    let h: Harness;
    beforeAll(async () => {
      h = await make();
    });
    afterAll(async () => {
      await h.stop();
    });

    const P1 = proofOf(1);
    const pair = async (room = randomRoom(), proof = P1) => {
      const pc = await open(h, room, "pc", { proof });
      const phone = await open(h, room, "phone", { proof });
      expect(await pc.next()).toEqual({ kind: "text", data: '{"peer":"online"}' });
      expect(await phone.next()).toEqual({ kind: "text", data: '{"peer":"online"}' });
      return { room, pc, phone };
    };

    it("answers the health check and nothing else on /", async () => {
      expect(await h.http("/")).toEqual({ status: 200, text: "Coucou link relay" });
      expect((await h.http("/", "POST")).status).toBe(405);
      expect((await h.http("/elsewhere")).status).toBe(404);
    });

    it("refuses a bad path, room id or role with 404 and creates no room", async () => {
      const before = await h.roomsCreated();
      const good = randomRoom();
      const bad = [
        ["short", "phone"], [good + "x", "phone"], [good.slice(0, 21) + "!", "phone"], [good, "tablet"], [good, ""],
      ] as const;
      for (const [room, role] of bad) expect(await h.connect(room, role, { proof: P1 })).toEqual({ refused: 404 });
      expect(await h.roomsCreated()).toBe(before);
    });

    it("refuses a missing, wrong or malformed access key with 401, before any room exists", async () => {
      const before = await h.roomsCreated();
      const room = randomRoom();
      for (const key of [null, "", "short", OTHER_ACCESS, ACCESS + "x", ACCESS.slice(1), ACCESS.toUpperCase()]) {
        expect(await h.connect(room, "pc", { key, proof: P1 }), String(key)).toEqual({ refused: 401 });
      }
      expect(await h.roomsCreated()).toBe(before);
    });

    it("refuses a missing or malformed join proof with 400", async () => {
      const room = randomRoom();
      for (const protocols of ["", "coucou.v1", "coucou.join." + proofOf(1), "coucou.v1, coucou.join.short", "coucou.v1, coucou.join." + proofOf(1) + "A",
        "coucou.v1, coucou.join." + proofOf(1) + ", coucou.join." + proofOf(2), "other, coucou.join." + proofOf(1)]) {
        expect(await h.connect(room, "pc", { protocols }), protocols).toEqual({ refused: 400 });
      }
    });

    it("fails closed: with no access key configured every room request is refused", async () => {
      await h.setAccessKey(undefined);
      try {
        expect(await h.connect(randomRoom(), "pc", { proof: P1 })).toEqual({ refused: 401 });
        expect(await h.connect(randomRoom(), "pc", { key: "", proof: P1 })).toEqual({ refused: 401 });
        expect((await h.http("/")).status).toBe(200); // the health check needs no key
      } finally {
        await h.setAccessKey(ACCESS);
      }
    });

    it("forwards binary frames both ways, byte for byte, and tells each side the other arrived", async () => {
      const { pc, phone } = await pair();
      const all = Uint8Array.from({ length: 256 }, (_, i) => i);
      phone.send(all);
      expect(await pc.next()).toEqual({ kind: "binary", data: all });
      pc.send(new Uint8Array([9, 8, 7]));
      expect(await phone.next()).toEqual({ kind: "binary", data: new Uint8Array([9, 8, 7]) });
      pc.send(new Uint8Array(0));
      expect(await phone.next()).toEqual({ kind: "binary", data: new Uint8Array(0) });
      const biggest = new Uint8Array(66_000).fill(0xab);
      phone.send(biggest);
      const got = await pc.next(5000);
      expect(got.kind === "binary" && got.data.length).toBe(66_000);
    });

    it("closes a socket that sends a frame over 66,000 bytes (1009)", async () => {
      const { pc, phone } = await pair();
      phone.send(new Uint8Array(66_001));
      const m = await phone.next(5000);
      expect(m.kind === "close" && m.code).toBe(1009);
      // The other side only hears that the peer left.
      expect(await pc.next()).toEqual({ kind: "text", data: '{"peer":"offline"}' });
    });

    it("never buffers: a frame for an absent peer is dropped and the sender hears 'offline'", async () => {
      const room = randomRoom();
      const phone = await open(h, room, "phone", { proof: P1 });
      phone.send(new Uint8Array([1, 2, 3]));
      expect(await phone.next()).toEqual({ kind: "text", data: '{"peer":"offline"}' });
      const pc = await open(h, room, "pc", { proof: P1 });
      expect(await pc.next()).toEqual({ kind: "text", data: '{"peer":"online"}' });
      expect(await phone.next()).toEqual({ kind: "text", data: '{"peer":"online"}' });
      expect(await pc.quiet(300)).toBe(true); // the dropped frame did not come back
    });

    it("tells the remaining side when the other leaves", async () => {
      const { pc, phone } = await pair();
      pc.close(1000, "bye");
      expect(await phone.next()).toEqual({ kind: "text", data: '{"peer":"offline"}' });
    });

    it("answers a text 'ping' with 'pong' and closes on any other text (1003)", async () => {
      const { pc, phone } = await pair();
      phone.send("ping");
      expect(await phone.next()).toEqual({ kind: "text", data: "pong" });
      expect(await pc.quiet(200)).toBe(true); // a heartbeat is not forwarded
      phone.send("hello there");
      const m = await phone.next();
      expect(m.kind === "close" && m.code).toBe(1003);
    });

    it("refuses a second key for a room that is held (1008) and leaves the first pair alone", async () => {
      const { room, pc, phone } = await pair();
      const intruder = await open(h, room, "pc", { proof: proofOf(2) });
      const m = await intruder.next();
      expect(m).toEqual({ kind: "close", code: 1008, reason: "join proof" });
      pc.send(new Uint8Array([5]));
      expect(await phone.next()).toEqual({ kind: "binary", data: new Uint8Array([5]) });
    });

    it("lets a role's new socket replace the old one (1000 'replaced') without telling the other side it left", async () => {
      const { room, pc, phone } = await pair();
      const again = await open(h, room, "pc", { proof: P1 });
      expect(await pc.next()).toEqual({ kind: "close", code: 1000, reason: "replaced" });
      expect(await again.next()).toEqual({ kind: "text", data: '{"peer":"online"}' });
      expect(await phone.next()).toEqual({ kind: "text", data: '{"peer":"online"}' });
      again.send(new Uint8Array([7]));
      expect(await phone.next()).toEqual({ kind: "binary", data: new Uint8Array([7]) });
    });

    it("keeps rooms apart", async () => {
      const a = await pair();
      const b = await pair();
      a.pc.send(new Uint8Array([1]));
      expect(await a.phone.next()).toEqual({ kind: "binary", data: new Uint8Array([1]) });
      expect(await b.phone.quiet(200)).toBe(true);
      expect(await b.pc.quiet(100)).toBe(true);
    });

    it("closes a socket that floods (1008 'rate')", async () => {
      const { pc, phone } = await pair();
      for (let i = 0; i < 300; i++) phone.send(new Uint8Array([i & 255]));
      let closed: Msg | undefined;
      for (let i = 0; i < 400 && !closed; i++) {
        const m = await phone.next(3000);
        if (m.kind === "close") closed = m;
      }
      expect(closed).toEqual({ kind: "close", code: 1008, reason: "rate" });
      // The other side received at most the burst and the refill, far fewer than 300.
      let got = 0;
      while (!(await pc.quiet(150))) {
        const m = await pc.next();
        if (m.kind === "binary") got++;
      }
      expect(got).toBeGreaterThan(30);
      expect(got).toBeLessThan(150);
    });

    it("closes live sockets at their next frame when the access key is rotated, and refuses the old key", async () => {
      const { room, pc, phone } = await pair();
      await h.setAccessKey(OTHER_ACCESS);
      try {
        phone.send(new Uint8Array([1]));
        const m = await phone.next();
        expect(m).toEqual({ kind: "close", code: 1008, reason: "access key changed" });
        expect(await h.connect(room, "phone", { key: ACCESS, proof: P1 })).toEqual({ refused: 401 });
        const fresh = await open(h, room, "phone", { key: OTHER_ACCESS, proof: P1 });
        expect(fresh).toBeTruthy();
        void pc;
      } finally {
        await h.setAccessKey(ACCESS);
      }
    });
  });
}
