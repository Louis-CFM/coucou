import { test } from "node:test";
import assert from "node:assert/strict";
import { CompanionWorld, PET_SPACING, companionIdentities } from "../src/mochi/companions.ts";
import { SPOTIFY_ID } from "../src/core/spotify.ts";

const task = (id, state = "idle") => ({ id, name: id, color: "#83b5ff", state, steps: [], stepIndex: 0, source: "agent", isIntegration: true });
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
  const tasks = Array.from({ length: 9 }, (_, i) => task(`agent-${i}`));
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
  world.sync(snapshot([task("idle-1"), task("idle-2"), task("busy", "working")]), 1000, 0);
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
  world.sync(snapshot([task("a", "working"), task("c", "working"), task("d", "working")]), 320, 1);
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


test("unused bar pets park together at the left and need no animation frames", () => {
  const world = new CompanionWorld();
  const s = snapshot([task("a"),task("b"),task("c")], {band:{height:42,lanes:[[600,1600],[1800,3100]]}});
  world.sync(s,3440,0); world.tick(.03,0);
  assert.equal(world.needsFrames,false);
  const pets=[...world.pets.values()];
  assert.ok(pets.every(p=>p.parked && p.action==="sleep" && p.x<710));
  world.touch("b",1); world.tick(.03,1);
  assert.equal(world.pets.get("b").parked,true);
  assert.equal(world.pets.get("b").action,"rest");
  assert.equal(world.pets.get("a").parked,true);
  world.tick(.03,10);
  assert.equal(world.needsFrames,false);
  world.sync(snapshot([task("a"),task("b","working"),task("c")],{band:s.band}),3440,11);
  world.tick(.03,11);
  assert.equal(world.pets.get("b").parked,false);
  assert.equal(world.pets.get("a").parked,true);
});

test("a configured integration does not count as use, a session or running player does", () => {
  const pets=companionIdentities([task("github"),{...task("codex"),sessionId:"local-session"},task(SPOTIFY_ID)],null,false,"none",new Set([SPOTIFY_ID]));
  assert.deepEqual(pets.map(p=>p.active),[false,true,true]);
});


test("hovering and opening a sleeping pet never moves its click target", () => {
  const world=new CompanionWorld();
  const s=snapshot([task("a"),task("b"),task("c")],{band:{height:42,lanes:[[600,1600],[1800,3100]]}});
  world.sync(s,3440,0);world.tick(.1,0);
  const p=world.pets.get("b"),x=p.x;
  for(let i=0;i<40;i++) {
    world.hovered=i%2 ? "b" : null;
    world.tick(.1,i/10);
    assert.equal(p.x,x);
  }
  world.touch("b",5);
  world.sync({...s,presented:"b"},3440,5);
  world.tick(.1,5);
  assert.equal(p.x,x);
  assert.equal(p.action,"rest");
});


test("Spotify wanders while playing, then dances and holds still under the pointer", () => {
 const world=new CompanionWorld();
 const pets=companionIdentities([task(SPOTIFY_ID)],null,true,"none",new Set([SPOTIFY_ID]));
 world.sync({enabled:true,paused:false,motion:true,pets,band:{height:42,lanes:[[600,1600]]}},3440,0);
 const p=world.pets.get(SPOTIFY_ID),positions=[],actions=new Set();
 for(let i=0;i<1800;i++){world.tick(.1,i/10);positions.push(p.x);actions.add(p.action);}
 assert.ok(Math.max(...positions)-Math.min(...positions)>150);
 assert.ok(actions.has("walk") && actions.has("dance"));
 world.hovered=SPOTIFY_ID;const x=p.x;
 for(let i=0;i<100;i++)world.tick(.1,180+i/10);
 assert.equal(p.x,x);
 assert.equal(p.action,"rest");
});
