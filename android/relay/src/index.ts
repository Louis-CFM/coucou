// Coucou link relay: a stateless Cloudflare Worker (docs/RELAY_LINK.md).
//
// It forwards opaque, end-to-end encrypted frames between the two peers of a room, a computer and a phone. It never sees a
// content key, stores nothing (no KV, no R2, no database, no storage API call), logs nothing (observability off) and has
// no accounts. The one secret it holds is the deploy-time ACCESS_KEY, which only lets a request create or join a room.
//
// This file answers the HTTP side and refuses everything that is not a well-formed, authorised room request BEFORE a room
// (a Durable Object) is created or contacted.

import { accessKeyOk, parseJoinProof, parseRoomRequest } from "./protocol";
export { Room } from "./room";

export interface Env {
  ROOM: DurableObjectNamespace;
  /** Set with `wrangler secret put ACCESS_KEY`. Never in git. Unset: every room request is refused (fail closed). */
  ACCESS_KEY?: string;
  /** Optional Workers Rate Limiting binding: new connections per source address. */
  CONNECT_LIMIT?: { limit(options: { key: string }): Promise<{ success: boolean }> };
}

const empty = (status: number) => new Response(null, { status });

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    if (url.pathname === "/") {
      return request.method === "GET" ? new Response("Coucou link relay", { status: 200, headers: { "content-type": "text/plain" } }) : empty(405);
    }
    const target = request.method === "GET" ? parseRoomRequest(url) : null;
    if (!target) return empty(404); // bad path, bad room id, bad role, wrong method: nothing is created
    if (env.CONNECT_LIMIT) {
      const ip = request.headers.get("CF-Connecting-IP") ?? "unknown";
      if (!(await env.CONNECT_LIMIT.limit({ key: ip })).success) return empty(429);
    }
    if (!(await accessKeyOk(env.ACCESS_KEY, request.headers.get("Authorization")))) return empty(401);
    if (!parseJoinProof(request.headers.get("Sec-WebSocket-Protocol"))) return empty(400);
    if (request.headers.get("Upgrade")?.toLowerCase() !== "websocket") return empty(426);
    return env.ROOM.get(env.ROOM.idFromName(target.room)).fetch(request);
  },
};
