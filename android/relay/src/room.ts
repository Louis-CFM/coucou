// One room = one Durable Object, named by the room id. At most one live socket per role (pc, phone); frames from one go to
// the other as they are. It never parses, buffers or stores a frame. Hibernation API: an idle room costs nothing.
//
// Everything it remembers lives in the sockets' attachments (hibernation state, not storage): the role, the join verifier
// and the access-key generation the socket was admitted under. When the last socket is gone, nothing is left.

import { DurableObject } from "cloudflare:workers";
import type { Env } from "./index";
import {
  Bucket, MAX_FRAME, PEER_OFFLINE, PEER_ONLINE, RATE_BURST, RATE_PER_SECOND, SUBPROTOCOL,
  accessGeneration, joinVerifier, otherRole, parseJoinProof, parseRoomRequest,
  type Role,
} from "./protocol";

interface Attachment {
  role: Role;
  verifier: string;
  gen: string;
  replaced?: boolean;
}

const OPEN = 1;

export class Room extends DurableObject<Env> {
  /** Token buckets live in memory only: a room that hibernated has no flood in progress. */
  private readonly buckets = new Map<WebSocket, Bucket>();

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    // The platform answers this itself, without waking the room: the clients' heartbeat.
    ctx.setWebSocketAutoResponse(new WebSocketRequestResponsePair("ping", "pong"));
  }

  async fetch(request: Request): Promise<Response> {
    const target = parseRoomRequest(new URL(request.url));
    const proof = parseJoinProof(request.headers.get("Sec-WebSocket-Protocol"));
    if (!target || !proof || request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return new Response(null, { status: 400 });

    const verifier = await joinVerifier(proof);
    const gen = await accessGeneration(this.env.ACCESS_KEY);
    const live = this.live();
    const wrongProof = live.length > 0 && attachmentOf(live[0]).verifier !== verifier;

    const pair = new WebSocketPair();
    const [client, server] = [pair[0], pair[1]];
    if (wrongProof) {
      // The room is held by someone else's key. Accept, then say why, so the client can show "room is taken".
      server.accept();
      server.close(1008, "join proof");
      return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": SUBPROTOCOL } });
    }

    // A new socket for a role replaces the old one of that role.
    for (const old of live) {
      const att = attachmentOf(old);
      if (att.role === target.role) {
        old.serializeAttachment({ ...att, replaced: true });
        old.close(1000, "replaced");
      }
    }

    this.ctx.acceptWebSocket(server, [target.role]);
    server.serializeAttachment({ role: target.role, verifier, gen } satisfies Attachment);
    if (this.peerOf(target.role, server)) {
      server.send(PEER_ONLINE);
      this.peerOf(target.role, server)?.send(PEER_ONLINE);
    }
    return new Response(null, { status: 101, webSocket: client, headers: { "Sec-WebSocket-Protocol": SUBPROTOCOL } });
  }

  async webSocketMessage(ws: WebSocket, message: string | ArrayBuffer): Promise<void> {
    const att = attachmentOf(ws);
    // The key the socket was admitted under must still be the configured one (rotation closes live sockets here).
    if (!att.gen || att.gen !== (await accessGeneration(this.env.ACCESS_KEY))) {
      ws.close(1008, "access key changed");
      return;
    }
    // "ping" never gets here (the platform answers it). Nothing else may be text.
    if (typeof message === "string") {
      ws.close(1003, "binary only");
      return;
    }
    if (message.byteLength > MAX_FRAME) {
      ws.close(1009, "too big");
      return;
    }
    let bucket = this.buckets.get(ws);
    if (!bucket) this.buckets.set(ws, (bucket = new Bucket(RATE_PER_SECOND, RATE_BURST)));
    if (!bucket.take()) {
      ws.close(1008, "rate");
      return;
    }
    const peer = this.peerOf(att.role, ws);
    if (!peer) {
      ws.send(PEER_OFFLINE); // nothing is buffered: the frame is dropped
      return;
    }
    peer.send(message);
  }

  async webSocketClose(ws: WebSocket, code: number, _reason: string, _wasClean: boolean): Promise<void> {
    this.gone(ws);
    try {
      ws.close(code >= 1000 && code <= 1011 && code !== 1005 && code !== 1006 ? code : 1000, "");
    } catch {
      /* already closed */
    }
  }

  async webSocketError(ws: WebSocket): Promise<void> {
    this.gone(ws);
  }

  // ── helpers ────────────────────────────────────────────────────────────────────

  private live(): WebSocket[] {
    return this.ctx.getWebSockets().filter((w) => w.readyState === OPEN && !attachmentOf(w).replaced);
  }

  private peerOf(role: Role, except: WebSocket): WebSocket | undefined {
    return this.ctx.getWebSockets(otherRole(role)).find((w) => w !== except && w.readyState === OPEN && !attachmentOf(w).replaced);
  }

  /** A socket left: forget its bucket, and tell the other side unless the same role is still here (a replacement). */
  private gone(ws: WebSocket): void {
    this.buckets.delete(ws);
    const att = attachmentOf(ws);
    if (att.replaced) return;
    const sameRoleStillHere = this.ctx.getWebSockets(att.role).some((w) => w !== ws && w.readyState === OPEN && !attachmentOf(w).replaced);
    if (sameRoleStillHere) return;
    this.peerOf(att.role, ws)?.send(PEER_OFFLINE);
  }
}

function attachmentOf(ws: WebSocket): Attachment {
  return (ws.deserializeAttachment() ?? { role: "pc", verifier: "", gen: "" }) as Attachment;
}
