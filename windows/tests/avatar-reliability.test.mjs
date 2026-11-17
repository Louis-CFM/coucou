import test from "node:test";
import assert from "node:assert/strict";
import { AvatarLifecycleManager } from "../src/mochi/avatar-lifecycle";
import { Spring, Tracked } from "../src/core/anim";
import { BotEngine } from "../src/mochi/engine";

test("AvatarLifecycleManager transitions correctly across lifecycle states", () => {
  const manager = new AvatarLifecycleManager({ maxConsecutiveErrors: 3, failureCooloffMs: 100 });

  // Initial state
  assert.equal(manager.state, "UNINITIALIZED");
  assert.equal(manager.canRender(), true);

  // Initialize
  manager.initialize();
  assert.equal(manager.state, "READY");

  // Frame execution
  manager.onFrameStart();
  assert.equal(manager.state, "RENDERING");

  manager.onFrameSuccess();
  assert.equal(manager.state, "READY");
  assert.equal(manager.consecutiveErrors, 0);

  // Frame error
  const canRecover1 = manager.onFrameError(new Error("Test error 1"));
  assert.equal(manager.state, "INTERRUPTED");
  assert.equal(canRecover1, true);
  assert.equal(manager.consecutiveErrors, 1);

  // Recovery
  let recovered = false;
  const success = manager.recover(() => {
    recovered = true;
  });
  assert.equal(success, true);
  assert.equal(recovered, true);
  assert.equal(manager.state, "READY");
  assert.equal(manager.consecutiveErrors, 0);
  assert.equal(manager.totalRecoveries, 1);
});

test("AvatarLifecycleManager enforces circuit breaker when errors exceed threshold", () => {
  const manager = new AvatarLifecycleManager({ maxConsecutiveErrors: 3, failureCooloffMs: 50 });
  manager.initialize();

  manager.onFrameError(new Error("Err 1"));
  manager.onFrameError(new Error("Err 2"));
  const canRecover = manager.onFrameError(new Error("Err 3"));

  assert.equal(canRecover, false);
  assert.equal(manager.state, "FAILED");
  assert.equal(manager.canRender(), false);

  // Recovery should be denied during cool-off
  const attemptedRecovery = manager.recover(() => {});
  assert.equal(attemptedRecovery, false);

  // Snapshot reflects failure
  const snapshot = manager.getSnapshot();
  assert.equal(snapshot.state, "FAILED");
  assert.equal(snapshot.isHealthy, false);
});

test("AvatarLifecycleManager handles GPU context loss and restoration", () => {
  const manager = new AvatarLifecycleManager();
  manager.initialize();

  assert.equal(manager.isContextLost, false);
  assert.equal(manager.canRender(), true);

  // GPU context lost (e.g. sleep/wake or D3D reset)
  manager.onContextLost();
  assert.equal(manager.isContextLost, true);
  assert.equal(manager.state, "INTERRUPTED");
  assert.equal(manager.canRender(), false);

  // GPU context restored
  manager.onContextRestored();
  assert.equal(manager.isContextLost, false);
  assert.equal(manager.state, "READY");
  assert.equal(manager.canRender(), true);
});

test("AvatarLifecycleManager handles window visibility and suspension", () => {
  const manager = new AvatarLifecycleManager();
  manager.initialize();

  // Window minimized or occluded
  manager.onVisibilityChange(false);
  assert.equal(manager.isWindowVisible, false);
  assert.equal(manager.state, "PAUSED");

  // Window restored or focused
  manager.onVisibilityChange(true);
  assert.equal(manager.isWindowVisible, true);
  assert.equal(manager.state, "READY");
});

test("Spring is resilient against NaN, non-finite targets, and negative dt", () => {
  const spring = new Spring(20);
  assert.equal(spring.value, 20);

  // Non-finite step
  spring.step(NaN);
  assert.equal(Number.isFinite(spring.value), true);
  assert.equal(spring.value, 20);

  spring.step(-0.016);
  assert.equal(Number.isFinite(spring.value), true);
  assert.equal(spring.value, 20);

  // Target set to NaN
  spring.target = NaN;
  spring.step(0.016);
  assert.equal(Number.isFinite(spring.value), true);

  // Setting NaN value
  spring.set(NaN);
  assert.equal(spring.value, 0);
  assert.equal(spring.target, 0);

  // Stepping to valid target converges
  spring.target = 50;
  for (let i = 0; i < 60; i++) {
    spring.step(0.016);
  }
  assert.ok(Math.abs(spring.value - 50) < 0.5);
});

test("Tracked is resilient against non-finite inputs and step calls", () => {
  const tracked = new Tracked(10);
  assert.equal(tracked.value, 10);

  tracked.jump(NaN);
  assert.equal(tracked.value, 0);

  tracked.springTo(NaN);
  assert.equal(tracked.animating, true);
  tracked.step(NaN);
  assert.equal(Number.isFinite(tracked.value), true);

  tracked.curveTowards(100, NaN);
  tracked.step(0.016);
  assert.equal(Number.isFinite(tracked.value), true);
});

test("BotEngine update is resilient against NaN dt and non-finite properties", () => {
  const engine = new BotEngine();

  // Test updating with NaN dt
  assert.doesNotThrow(() => {
    engine.update(NaN);
  });
  assert.equal(Number.isFinite(engine.yaw), true);
  assert.equal(Number.isFinite(engine.pitch), true);
  assert.equal(Number.isFinite(engine.sx), true);
  assert.equal(Number.isFinite(engine.sy), true);

  // Test updating with negative dt
  assert.doesNotThrow(() => {
    engine.update(-1);
  });
  assert.equal(Number.isFinite(engine.yaw), true);

  // Injected NaN values auto-heal on next update
  engine.yaw = NaN;
  engine.pitch = NaN;
  engine.sx = NaN;
  engine.sy = NaN;
  engine.update(0.016);

  assert.equal(Number.isFinite(engine.yaw), true);
  assert.equal(Number.isFinite(engine.pitch), true);
  assert.equal(Number.isFinite(engine.sx), true);
  assert.equal(engine.sx, 1);
  assert.equal(Number.isFinite(engine.sy), true);
  assert.equal(engine.sy, 1);
});

test("BotEngine draw handles non-positive or non-finite dimensions safely", () => {
  const engine = new BotEngine();
  const mockCtx = {
    save: () => {},
    restore: () => {},
    translate: () => {},
    rotate: () => {},
    scale: () => {},
    beginPath: () => {},
    closePath: () => {},
    fill: () => {},
    stroke: () => {},
    clearRect: () => {},
    arc: () => {},
    arcTo: () => {},
    moveTo: () => {},
    lineTo: () => {},
    bezierCurveTo: () => {},
    setTransform: () => {},
  };

  // Calling draw with NaN, 0, or negative dimensions must return safely without throwing
  assert.doesNotThrow(() => {
    engine.draw(mockCtx, NaN, NaN);
  });
  assert.doesNotThrow(() => {
    engine.draw(mockCtx, 0, 0);
  });
  assert.doesNotThrow(() => {
    engine.draw(mockCtx, -10, -10);
  });
});
