import { test } from "node:test";
import assert from "node:assert/strict";
import { CompanionWorld, PET_SPACING, PET_IDLE_SECONDS, PET_TRANSITION_SECONDS, companionIdentities } from "../src/mochi/companions.ts";
import { SPOTIFY_ID } from "../src/core/spotify.ts";

const task = (id, state = "idle") => ({ id, name: id, color: "#83b5ff", state, steps: [], stepIndex: 0, source: "agent", isIntegration: true });
const session = (id, state = "idle") => ({...task(id,state),sessionId:`session-${id}`});
const snapshot = (tasks, changes = {}) => ({ enabled: true, paused: false, motion: true,
  pets: companionIdentities(tasks, null, false, "none"), ...changes });

test("an approval changes only its agent; only the Spotify pet dances", () => {
  const tasks = [task("codex", "working"), task("github"), task(SPOTIFY_ID)];
  const pets = companionIdentities(tasks, { pillId: "codex", requestId: "req", sessionId: "session", tool: "shell", command: "test" }, true, "none");
  assert.equal(pets[0].state, "approval");
  assert.equal(pets[0].attention, true);
  assert.equal(pets[0].dancing, false);
  assert.equal(pets[1].state, "idle");
  assert.equal(pets[1].dancing, false);
  assert.equal(pets[2].dancing, true);
  assert.equal(companionIdentities(tasks, null, false, "none")[2].dancing, false);
});

test("questions remain with the right pet and duplicate task identities cannot create twins", () => {
  const pets = companionIdentities([task("codex"), task("codex"), task("claude")], { pillId: "claude", questions: [] }, false, "none");
  assert.deepEqual(pets.map(p => p.id), ["codex", "claude"]);
  assert.equal(pets[1].state, "question");
  assert.equal(pets[0].attention, false);
});

test("all integrations fit on narrow displays and preserve positions across state/focus updates", () => {
  const world = new CompanionWorld();
  const tasks = Array.from({ length: 9 }, (_, i) => task(`agent-${i}`, "working"));
  world.sync(snapshot(tasks), 320, 0);
  const positions = [...world.pets.values()].map(p => [p.identity.id, p.x, p.y]);
  assert.equal(world.pets.size, 9);
  assert.ok(new Set(positions.map(p => p[2])).size > 1);
  world.sync(snapshot([...tasks].reverse().map(t => ({ ...t, state: "working" }))), 320, 1);
  assert.deepEqual([...world.pets.values()].map(p => [p.identity.id, p.x, p.y]), positions);
});

test("ten minutes of independent movement stay inside the habitat and never overlap", () => {
  for (const width of [80, 320, 1440, 3440]) {
    const world = new CompanionWorld();
    world.sync(snapshot(Array.from({ length: 9 }, (_, i) => task(`a-${i}`, "working"))), width, 0);
    for (let tick = 0; tick < 6000; tick++) {
      world.tick(0.1, tick / 10);
      const pets = [...world.pets.values()];
      for (const p of pets) {
        assert.ok(p.x >= 40 && p.x <= width - 40, `${width}: ${p.x}`);
        for (const other of pets) if (p !== other && p.y === other.y) {
          assert.ok(Math.abs(p.x - other.x) >= PET_SPACING - 0.001, `${width}: collision`);
        }
      }
    }
  }
});

test("idle pets sleep, working pets stay awake, and touching wakes only the selected pet", () => {
  const world = new CompanionWorld();
  world.sync(snapshot([session("idle-1"), session("idle-2"), task("busy", "working")]), 1000, 0);
  world.tick(0.03, 121);
  assert.equal(world.pets.get("idle-1").action, "sleep");
  assert.equal(world.pets.get("idle-2").action, "sleep");
  assert.notEqual(world.pets.get("busy").action, "sleep");
  world.touch("idle-1", 122);
  world.tick(0.03, 122);
  assert.equal(world.pets.get("idle-1").action, "rest");
  assert.equal(world.pets.get("idle-2").action, "sleep");
});

test("pause and reduced motion prevent wandering, including music", () => {
  const world = new CompanionWorld();
  const s = snapshot([task("codex", "working"), task(SPOTIFY_ID)]);
  s.pets[1].dancing = true;
  s.pets[1].active = true;
  world.sync({ ...s, paused: true }, 800, 0);
  const positions = [...world.pets.values()].map(p => p.x);
  for (let i = 0; i < 200; i++) world.tick(0.1, i / 10);
  assert.ok([...world.pets.values()].every(p => p.action === "sleep"));
  assert.deepEqual([...world.pets.values()].map(p => p.x), positions);
  world.sync({ ...s, motion: false }, 800, 20);
  for (let i = 0; i < 200; i++) world.tick(0.1, 20 + i / 10);
  assert.deepEqual([...world.pets.values()].map(p => p.x), positions);
  assert.ok([...world.pets.values()].every(p => p.action !== "dance" && p.action !== "walk"));
});

test("an alert or hovering holds a pet still so its target cannot run away", () => {
  const world = new CompanionWorld();
  world.sync(snapshot([task("approval", "approval"), task("hover", "working")]), 800, 0);
  world.hovered = "hover";
  const positions = [...world.pets.values()].map(p => p.x);
  for (let i = 0; i < 1000; i++) world.tick(0.1, i / 10);
  assert.deepEqual([...world.pets.values()].map(p => p.x), positions);
  assert.equal(world.pets.get("approval").action, "attention");
});

test("encounter greetings cannot override an approval, sleeping pet or music", () => {
  const world = new CompanionWorld();
  world.sync(snapshot([task("a", "working"), task("b", "working")]), 800, 0);
  const a = world.pets.get("a"), b = world.pets.get("b");
  a.x = 200; b.x = 276; a.action = "walk"; a.direction = 1; a.until = 100; b.until = 100;
  a.socialAfter = b.socialAfter = 0;
  world.tick(0.1, 25);
  assert.equal(a.action, "wave");
  assert.equal(b.action, "wave");
  a.action = "walk"; a.direction = 1; a.until = 200;
  b.identity.attention = true; a.socialAfter = b.socialAfter = 0;
  world.tick(0.1, 100);
  assert.notEqual(a.action, "wave");
  assert.equal(b.action, "attention");
});

test("closed integrations disappear, new ones fit, and resuming never teleports", () => {
  const world = new CompanionWorld();
  world.sync(snapshot([task("a", "working"), task("b", "working")]), 800, 0);
  world.tick(.1,.5);
  world.sync(snapshot([task("a", "working"), task("c", "working"), task("d", "working")]), 320, 1);
  assert.equal(world.pets.get("b").visibility,"leaving");
  world.tick(.1,1.4);
  assert.equal(world.pets.has("b"), false);
  assert.equal(world.pets.size, 3);
  const p = world.pets.get("a");
  p.x = 80; p.action = "walk"; p.direction = 1; p.until = 1e6;
  world.tick(600, 400);
  assert.ok(p.x - 80 <= 2.2 + 1e-6);
  assert.equal(world.hit(p.x, p.y)?.identity.id, "a");
  assert.equal(world.hit(0, 0), null, "the transparent background is never a pet");
});

test("bar companions stay within live free lanes and never enter application content", () => {
  const world = new CompanionWorld();
  const s = snapshot(Array.from({length:6},(_,i)=>task(`bar-${i}`, "working")), {band:{height:42,lanes:[[628,1617],[1823,3106]]}});
  world.sync(s, 3440, 0);
  for (let i=0;i<6000;i++) {
    world.tick(.1,i/10);
    for (const p of world.pets.values()) {
      assert.ok(p.shown);
      assert.equal(p.y,21);
      assert.ok(p.x>=p.lane[0] && p.x<=p.lane[1]);
      for(const q of world.pets.values()) if(p!==q) assert.ok(Math.abs(p.x-q.x)>=world.spacing-.001);
    }
  }
  // The clock/media region grows: the next event must keep every hit target safe.
  world.sync({...s,band:{height:42,lanes:[[628,1000],[2300,3106]]}},3440,601);
  for(const p of world.pets.values()) assert.ok(p.x>=p.lane[0] && p.x<=p.lane[1]);
  world.sync({...s,band:{height:42,lanes:[]}},3440,602);
  assert.ok([...world.pets.values()].every(p=>!p.shown));
  assert.equal(world.hit(1000,21),null);
});

test("a displayed pet stays beside its card while other companions can move", () => {
  const world = new CompanionWorld();
  world.sync(snapshot([task("a","working"),task("b","working")],{presented:"a",band:{height:42,lanes:[[100,500]]}}),800,0);
  const x=world.pets.get("a").x;
  for(let i=0;i<600;i++)world.tick(.1,i/10);
  assert.equal(world.pets.get("a").x,x);
});


test("open quiet sessions rest together at the left after a minute without recurring frames", () => {
  const world = new CompanionWorld();
  const s = snapshot([session("a"),session("b"),session("c")], {band:{height:42,lanes:[[600,1600],[1800,3100]]}});
  world.sync(s,3440,0); world.tick(.03,PET_IDLE_SECONDS+1);
  assert.equal(world.needsFrames,false);
  const pets=[...world.pets.values()];
  assert.ok(pets.every(p=>p.parked && p.action==="sleep" && p.x<710));
  world.touch("b",62); world.tick(.03,62);
  assert.equal(world.pets.get("b").parked,true);
  assert.equal(world.pets.get("b").action,"rest");
  assert.equal(world.pets.get("a").parked,true);
  world.tick(.03,123);
  assert.equal(world.needsFrames,false);
  world.sync(snapshot([session("a"),session("b","working"),session("c")],{band:s.band}),3440,124);
  world.tick(.03,124);
  assert.equal(world.pets.get("b").parked,false);
  assert.equal(world.pets.get("a").parked,true);
});

test("a configured integration does not count as use, a session or running player does", () => {
  const pets=companionIdentities([task("github"),{...task("codex"),sessionId:"local-session"},task(SPOTIFY_ID)],null,false,"none",new Set([SPOTIFY_ID]));
  assert.deepEqual(pets.map(p=>p.active),[false,true,true]);
});


test("hovering and opening a sleeping pet never moves its click target", () => {
  const world=new CompanionWorld();
  const s=snapshot([session("a"),session("b"),session("c")],{band:{height:42,lanes:[[600,1600],[1800,3100]]}});
  world.sync(s,3440,0);world.tick(.1,61);
  const p=world.pets.get("b"),x=p.x;
  for(let i=0;i<40;i++) {
    world.hovered=i%2 ? "b" : null;
    world.tick(.1,62+i/10);
    assert.equal(p.x,x);
  }
  world.touch("b",67);
  world.sync({...s,presented:"b"},3440,67);
  world.tick(.1,67);
  assert.equal(p.x,x);
  assert.equal(p.action,"rest");
});


test("Spotify wanders while playing, then dances and holds still under the pointer", () => {
 const world=new CompanionWorld();
 const pets=companionIdentities([task(SPOTIFY_ID)],null,true,"none",new Set([SPOTIFY_ID]));
 world.sync({enabled:true,paused:false,motion:true,pets,band:{height:42,lanes:[[600,1600]]}},3440,0);
 const p=world.pets.get(SPOTIFY_ID),positions=[],actions=new Set();
 for(let i=0;i<1800;i++){
   if(i && i%400===0) world.sync({enabled:true,paused:false,motion:true,pets:companionIdentities([task(SPOTIFY_ID)],null,true,"none",new Set([SPOTIFY_ID]),new Map([[SPOTIFY_ID,`track-${i}`]])),band:{height:42,lanes:[[600,1600]]}},3440,i/10);
   world.tick(.1,i/10);positions.push(p.x);actions.add(p.action);
 }
 assert.ok(Math.max(...positions)-Math.min(...positions)>150);
 assert.ok(actions.has("walk") && actions.has("dance"));
 world.hovered=SPOTIFY_ID;const x=p.x;
 for(let i=0;i<100;i++)world.tick(.1,180+i/10);
 assert.equal(p.x,x);
 assert.equal(p.action,"rest");
});

test("configured but unused pets start absent and have no hit targets or frame timer",()=>{
 const world=new CompanionWorld();
 world.sync(snapshot([task("unused")],{band:{height:42,lanes:[[600,1600]]}}),3440,0);
 const p=world.pets.get("unused");
 assert.equal(p.visibility,"hidden");assert.equal(p.shown,false);assert.equal(p.parked,false);
 assert.equal(world.hit(p.x,p.y),null);assert.equal(world.needsFrames,false);
});

test("closing a session animates out, removes input immediately and retains manual recall",()=>{
 const world=new CompanionWorld(),band={height:42,lanes:[[600,1600]]};
 world.sync(snapshot([session("a")],{band}),3440,0);world.tick(.1,1);
 const p=world.pets.get("a");assert.equal(p.opacity,1);
 world.sync(snapshot([task("a")],{band}),3440,2);
 assert.equal(p.visibility,"leaving");assert.equal(world.hit(p.x,p.y),null);
 world.tick(.1,2+PET_TRANSITION_SECONDS/2);
 assert.ok(p.opacity>0 && p.opacity<1);assert.equal(world.needsFrames,true);
 world.tick(.1,3);assert.equal(p.shown,false);assert.equal(world.needsFrames,false);
 world.touch("a",4);world.tick(.1,5);
 assert.equal(p.visibility,"visible");assert.equal(world.hit(p.x,p.y),p);
 world.tick(.1,13);world.tick(.1,14);
 assert.equal(p.shown,false,"manual recall cannot create a fictitious running app");
});

test("an open card keeps a recalled pet present, while identical refreshes do not postpone rest",()=>{
 const world=new CompanionWorld(),base=snapshot([session("a"),task("b")]);
 world.sync(base,1000,0);
 for(let now=10;now<=70;now+=10) {world.sync(base,1000,now);world.tick(.1,now);}
 assert.equal(world.pets.get("a").action,"sleep");
 world.touch("b",71);world.sync({...base,presented:"b"},1000,71);world.tick(.1,150);
 assert.equal(world.pets.get("b").shown,true);assert.notEqual(world.pets.get("b").action,"sleep");
 world.sync(base,1000,151);world.tick(.1,152);assert.equal(world.pets.get("b").shown,false);
});

test("new track and tool events wake only their own resting pet; progress polls do not",()=>{
 const world=new CompanionWorld(),band={height:42,lanes:[[600,1600]]};
 const make=(track,seq=0)=>snapshot([], {band,pets:companionIdentities([session("agent"),task(SPOTIFY_ID)],null,true,"none",new Set([SPOTIFY_ID]),new Map([[SPOTIFY_ID,track]])).map(p=>p.id==="agent"?{...p,activity:`step-${seq}`}:p)});
 world.sync(make("track-one"),3440,0);world.tick(.1,61);
 assert.ok([...world.pets.values()].every(p=>p.action==="sleep"));
 world.sync(make("track-one"),3440,62);world.tick(.1,62);
 assert.equal(world.needsFrames,false);
 world.sync(make("track-two"),3440,63);world.tick(.1,63);
 assert.notEqual(world.pets.get(SPOTIFY_ID).action,"sleep");
 assert.equal(world.pets.get("agent").action,"sleep");
 world.sync(make("track-two",1),3440,64);world.tick(.1,64);
 assert.notEqual(world.pets.get("agent").action,"sleep");
});

test("a new event reverses disappearance without an opacity jump, and reduced motion skips it",()=>{
 const world=new CompanionWorld();
 world.sync(snapshot([session("a")]),1000,0);world.tick(.1,1);
 world.sync(snapshot([task("a")]),1000,2);world.tick(.1,2.1);
 const p=world.pets.get("a"),opacity=p.opacity;
 world.sync(snapshot([session("a","approval")]),1000,2.1);
 assert.equal(p.opacity,opacity);assert.equal(p.visibility,"appearing");
 world.tick(.1,3);assert.equal(p.action,"attention");assert.equal(p.opacity,1);
 world.sync(snapshot([task("a")],{motion:false}),1000,4);
 assert.equal(p.visibility,"hidden");assert.equal(world.needsFrames,false);
});
