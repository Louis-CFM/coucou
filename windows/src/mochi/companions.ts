// Independent lives for the declared integrations. No DOM, OS access or actions
// on applications: this model can only move and express a pet's actual status.
import type { BotEmoteName, BotStateName } from "../core/layout";
import type { AgentTask, ApprovalInfo } from "../core/state";
import type { Outfit } from "./wardrobe";
import { SPOTIFY_ID } from "../core/spotify";
import { pillDefinition } from "../core/pills";

export const PET_SIZE = 64;
export const PET_SPACING = 76;
export const PET_IDLE_SECONDS = 60;
export const PET_TRANSITION_SECONDS = 0.35;
export const PET_EVENTS = {
  state: "companions-state", ready: "companions-ready", open: "companions-open", action: "companions-action",
} as const;

export interface PetIdentity {
  id: string;
  name: string;
  color: string;
  state: BotStateName;
  attention: boolean;
  dancing: boolean;
  /** Actual work, an open agent session or a running player; configuration alone is not activity. */
  active: boolean;
  /** Real work stays awake; an open but quiet session can rest. */
  busy: boolean;
  /** Meaningful events only, never a poll/position timestamp or transcript. */
  activity: string;
  outfit: Outfit;
}

export interface CompanionsSnapshot {
  enabled: boolean;
  paused: boolean;
  presented?: string | null;
  motion: boolean;
  language?: string;
  pets: PetIdentity[];
  band?: { height: number; lanes: [number, number][] } | null;
}

/** Selection never changes another pet's identity, expression or music state. */
export function companionIdentities(
  tasks: readonly AgentTask[], pending: ApprovalInfo | null, music: boolean, outfit: Outfit,
  running: ReadonlySet<string> = new Set(),
  activity: ReadonlyMap<string, string> = new Map(),
): PetIdentity[] {
  const seen = new Set<string>();
  return tasks.filter(t => !seen.has(t.id) && !!seen.add(t.id)).map(t => {
    const state = pending?.pillId === t.id ? (pending.questions ? "question" : "approval") : t.state;
    return {
      id: t.id, name: pillDefinition(t.id)?.name ?? t.name,
      color: /^#[0-9a-f]{6}$/i.test(t.color) ? t.color : "#94A3B8", state, outfit,
      active: running.has(t.id) || !!t.sessionId || !["idle", "sleeping"].includes(state) || !!t.pillBadge,
      busy: ["working", "thinking", "searching"].includes(state),
      activity: JSON.stringify([state, t.sessionId ?? null, t.stepSeq ?? t.stepIndex, t.pillBadge ?? null, activity.get(t.id) ?? null]),
      attention: ["approval", "question", "error", "ratelimit"].includes(state),
      dancing: t.id === SPOTIFY_ID && music && !["approval", "question", "error", "sleeping"].includes(state),
    };
  });
}

export type PetAction = "rest" | "walk" | "look" | "wave" | "celebrate" | "dance" | "attention" | "sleep";
export interface PetLife {
  identity: PetIdentity;
  x: number;
  y: number;
  direction: number;
  action: PetAction;
  until: number;
  lastActivity: number;
  socialAfter: number;
  holdUntil: number;
  emote: BotEmoteName | null;
  seed: number;
  shown: boolean;
  lane: [number, number] | null;
  parked: boolean;
  visibility: "hidden" | "appearing" | "visible" | "leaving";
  opacity: number;
  transitionAt: number;
  transitionFrom: number;
  retired: boolean;
}

function seedFor(id: string): number {
  let hash = 2166136261;
  for (const c of id) hash = Math.imul(hash ^ c.charCodeAt(0), 16777619);
  return hash >>> 0;
}
function random(p: PetLife): number {
  p.seed = (Math.imul(p.seed, 1664525) + 1013904223) >>> 0;
  return p.seed / 0x100000000;
}

/** Stable ordering prevents other pets teleporting when the selected pill changes. */
export class CompanionWorld {
  readonly pets = new Map<string, PetLife>();
  width = 1920;
  paused = false;
  motion = true;
  hovered: string | null = null;
  private layoutKey = "";
  scale = 1;
  presented: string | null = null;
  band: CompanionsSnapshot["band"] = null;
  get spacing() { return (this.band ? 56 : PET_SPACING) * this.scale; }
  bounds(p: PetLife): [number, number] { return p.lane ?? [40, this.width - 40]; }

  sync(snapshot: CompanionsSnapshot, width: number, now: number) {
    this.width = Math.max(80, width);
    this.band = snapshot.band;
    this.scale = this.band ? Math.min(0.75, Math.max(0.3, (this.band.height - 4) / PET_SIZE)) : 1;
    this.paused = snapshot.paused;
    this.presented = snapshot.presented ?? null;
    this.motion = snapshot.motion;
    const ids = new Set(snapshot.pets.map(p => p.id));
    for (const p of this.pets.values()) if (!ids.has(p.identity.id)) p.retired = true;
    for (const identity of snapshot.pets) {
      const p = this.pets.get(identity.id);
      if (p) {
        if (p.retired || p.identity.activity !== identity.activity || p.identity.active !== identity.active || p.identity.dancing !== identity.dancing) {
          p.lastActivity = now;
          // Never move a target out from under the pointer or its open card.
          if (this.hovered !== identity.id && this.presented !== identity.id) p.parked = false;
          if (identity.state === "finished") { p.emote = "happy"; p.until = now + 2; p.action = "celebrate"; }
        }
        p.identity = identity;
        p.retired = false;
      } else {
        this.pets.set(identity.id, {
          identity, x: 0, y: PET_SIZE / 2, direction: 1, action: "rest", until: now + 3,
          lastActivity: now, socialAfter: now + 12, holdUntil: now, emote: null, seed: seedFor(identity.id), shown: false, lane: null, parked: false,
          visibility: "hidden", opacity: 0, transitionAt: now, transitionFrom: 0, retired: false,
        });
      }
    }
    this.updatePresence(now);
    this.layout(now);
  }

  private layout(now: number) {
    if (this.band) { this.layoutBand(now); return; }
    for (const p of this.pets.values()) { p.shown = p.visibility !== "hidden"; p.lane = null; }
    // Only present pets need space. Narrow displays still use additional rows.
    const columns = Math.max(1, Math.floor((this.width - 16) / PET_SPACING));
    const all = [...this.pets.values()].filter(p => p.shown);
    const layoutKey = JSON.stringify([this.width, all.map(p => p.identity.id)]);
    const relayout = layoutKey !== this.layoutKey;
    this.layoutKey = layoutKey;
    for (let i = 0; i < all.length; i++) {
      const p = all[i];
      const row = Math.floor(i / columns);
      const count = Math.min(columns, all.length - row * columns);
      const initial = count === 1 ? this.width / 2 : 40 + (i % columns) * (this.width - 80) / (count - 1);
      const newY = PET_SIZE / 2 + row * PET_SPACING;
      if (relayout || newY !== p.y || !this.inBounds(p.x)) p.x = initial;
      p.y = newY;
      p.x = this.clamp(p.x);
    }
  }

  private shouldPark(p: PetLife, now: number) {
    // Pointer interaction must never relocate the target under that pointer.
    // A dormant pet wakes in its parking slot, and only real activity moves it.
    if (p.visibility === "hidden" || p.retired || !p.identity.active || p.identity.busy || p.identity.attention) return false;
    if (p.parked) return true;
    return this.hovered !== p.identity.id && this.presented !== p.identity.id
      && now >= p.holdUntil && now - p.lastActivity >= PET_IDLE_SECONDS;
  }

  private updatePresence(now: number): boolean {
    let changed = false;
    for (const p of this.pets.values()) {
      const wanted = !p.retired && (p.identity.active || p.identity.attention || this.presented === p.identity.id
        || this.hovered === p.identity.id || now < p.holdUntil);
      const target = wanted ? 1 : 0;
      if ((wanted && ["hidden", "leaving"].includes(p.visibility))
          || (!wanted && ["visible", "appearing"].includes(p.visibility))) {
        p.visibility = wanted ? "appearing" : "leaving";
        p.transitionAt = now;
        p.transitionFrom = p.opacity;
        changed = true;
      }
      if (!this.motion || this.paused) {
        p.opacity = target;
        p.visibility = wanted ? "visible" : "hidden";
      } else if (p.visibility === "appearing" || p.visibility === "leaving") {
        const t = Math.max(0, Math.min(1, (now - p.transitionAt) / PET_TRANSITION_SECONDS));
        const eased = t * t * (3 - 2 * t);
        p.opacity = p.transitionFrom + (target - p.transitionFrom) * eased;
        if (t === 1) { p.visibility = wanted ? "visible" : "hidden"; changed = true; }
      }
      if (p.visibility === "hidden") {
        p.shown = false; p.parked = false; p.lane = null;
        if (p.retired) this.pets.delete(p.identity.id);
      }
    }
    return changed;
  }

  private layoutBand(now: number) {
    if (!this.band) return;
    const pets = [...this.pets.values()];
    const all = pets.filter(p => p.visibility !== "hidden");
    const lanes = this.band.lanes.filter(([a,b]) => Number.isFinite(a) && Number.isFinite(b) && b-a >= this.spacing)
      .map(([a,b]) => [a,b] as [number,number]).sort((a,b)=>a[0]-b[0]);
    for (const p of pets) { p.parked = this.shouldPark(p, now); p.shown = false; p.y = this.band.height/2; }
    // Open but quiet integrations rest at the beginning of the free space.
    // The compositor owns the opaque bar controls: never cross them to park.
    for (const p of all.filter(p=>p.parked)) {
      const lane = lanes.find(([a,b])=>b-a >= this.spacing);
      if (!lane) continue;
      p.x = lane[0]+this.spacing/2; p.lane = [p.x,p.x];
      p.shown = true; p.action = "sleep"; lane[0] += this.spacing;
    }
    const groups: PetLife[][] = lanes.map(()=>[]);
    for (const [i,p] of all.filter(p=>!p.parked).entries()) {
      const fits = (k:number) => (groups[k].length+1)*this.spacing <= lanes[k][1]-lanes[k][0];
      let lane = lanes.findIndex(([a,b], k)=>fits(k) && p.x>=a+this.spacing/2 && p.x<=b-this.spacing/2);
      if (lane < 0) for (let j=0;j<lanes.length;j++) { const k=(i+j)%lanes.length; if(fits(k)){lane=k;break;} }
      if(lane>=0) { groups[lane].push(p); p.shown=true; }
    }
    for (let i=0;i<lanes.length;i++) {
      const [a,b]=lanes[i], group=groups[i].sort((p,q)=>p.x-q.x);
      for(let j=0;j<group.length;j++) {
        const p=group[j], initial=!p.lane;
        p.lane=[a+this.spacing/2,b-this.spacing/2];
        if(initial) p.x=(a+b)/2+(j-(group.length-1)/2)*this.spacing;
        p.x=Math.max(p.lane[0],Math.min(p.lane[1],p.x));
        if(j) p.x=Math.max(p.x,group[j-1].x+this.spacing);
      }
      // Project backwards from the right edge, not by shifting the whole group:
      // a large gap before its last member must not push the first outside a lane.
      for(let j=group.length-1;j>=0;j--) group[j].x=Math.min(group[j].x,
        j===group.length-1 ? b-this.spacing/2 : group[j+1].x-this.spacing);
    }
  }

  /** Sleeping pets are static. Only activity/input/layout events restart frames. */
  get needsFrames() { return [...this.pets.values()].some(p=>p.shown && (p.action!=="sleep" || p.visibility!=="visible")); }

  get height(): number {
    return Math.max(88, ...[...this.pets.values()].map(p => p.y + PET_SIZE / 2 + 20));
  }
  private clamp(x: number) { return Math.max(PET_SIZE / 2 + 8, Math.min(this.width - PET_SIZE / 2 - 8, x)); }
  private inBounds(x: number) { return x >= PET_SIZE / 2 + 8 && x <= this.width - PET_SIZE / 2 - 8; }

  touch(id: string, now: number) {
    const p = this.pets.get(id);
    if (!p) return;
    p.lastActivity = now;
    p.holdUntil = now + 8;
    p.emote = "love";
    this.updatePresence(now);
    this.layout(now);
  }

  tick(dt: number, now: number) {
    // A resumed frame never tries to catch up minutes of missed movement.
    dt = Math.max(0, Math.min(0.1, dt));
    const relayout = this.updatePresence(now);
    if (relayout || (this.band && [...this.pets.values()].some(p=>p.parked!==this.shouldPark(p,now)))) this.layout(now);
    for (const p of this.pets.values()) {
      if (!p.shown) continue;
      if (this.hovered === p.identity.id) p.lastActivity = now;
      if (this.paused) { p.action = "sleep"; continue; }
      if (p.identity.attention) { p.action = "attention"; continue; }
      if (p.visibility === "leaving") { p.action = "rest"; continue; }
      const resting = !p.identity.busy && now - p.lastActivity >= PET_IDLE_SECONDS
        && this.hovered !== p.identity.id && this.presented !== p.identity.id && now >= p.holdUntil;
      if (p.parked) {
        p.action = resting ? "sleep" : "rest";
        continue;
      }
      if (resting) {
        p.action = "sleep"; continue;
      }
      if (!this.motion || this.hovered === p.identity.id || this.presented === p.identity.id || now < p.holdUntil) { p.action = "rest"; continue; }
      if (["sleep", "attention"].includes(p.action)) { p.action = "rest"; p.until = now + 2; }
      if (now >= p.until) {
        const r = random(p);
        p.action = r < 0.72 ? "walk" : p.identity.dancing ? "dance" : r < 0.88 ? "look" : "rest";
        p.direction = random(p) < 0.5 ? -1 : 1;
        p.until = now + (p.action === "walk" ? (this.band ? 10 + random(p) * 25 : 2 + random(p) * 3) : 2 + random(p) * 5);
      }
      if (p.action !== "walk") continue;
      const [left, right] = this.bounds(p);
      const next = Math.max(left, Math.min(right, p.x + p.direction * 22 * dt));
      const neighbour = [...this.pets.values()].find(other => other !== p && other.shown && other.y === p.y
        && Math.abs(next - other.x) < this.spacing && Math.abs(next - other.x) < Math.abs(p.x - other.x));
      if (neighbour || next === p.x) {
        p.direction *= -1;
        p.action = "rest";
        p.until = now + 4;
        // A nearby companion can exchange a greeting. An alert always wins;
        // this never opens, approves or controls either application.
        if (neighbour && now >= p.socialAfter && now >= neighbour.socialAfter
            && !neighbour.identity.attention && neighbour.action !== "sleep" && !neighbour.parked && this.hovered !== neighbour.identity.id && this.presented !== neighbour.identity.id) {
          p.action = neighbour.action = "wave";
          p.until = neighbour.until = now + 1.8;
          p.direction = neighbour.x > p.x ? 1 : -1;
          neighbour.direction = -p.direction;
          p.emote = neighbour.emote = random(p) < 0.5 ? "wink" : "happy";
          p.holdUntil = neighbour.holdUntil = now;
          p.socialAfter = neighbour.socialAfter = now + 25;
        }
      } else p.x = next;
    }
  }

  hit(x: number, y: number): PetLife | null {
    return [...this.pets.values()].find(p => p.shown && p.visibility !== "leaving" && p.opacity > 0.05 && (Math.hypot(x - p.x, y - p.y) <= 23 * this.scale
      || (!this.band && Math.abs(x - p.x) <= 30 && y >= p.y + 16 && y <= p.y + 42))) ?? null;
  }
}
