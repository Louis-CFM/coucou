import { describe, it, expect } from "vitest";
import { validate, buildPayload } from "./index";

// Minimal valid request used as base for every test.
const baseReq = {
  token: "a".repeat(64),
  env: "production" as const,
  event: "update" as const,
  state: {
    pillId: "integration_claude",
    agent: "VS Code",
    color: "#F5F6F8",
    state: "working",
    statusText: "Working…",
    tone: "working",
    stepIndex: 0,
    stepCount: 0,
    others: 0,
  },
  urgent: true,
};

describe("validate", () => {
  it("accepts a valid request without sound", () => {
    expect(validate(baseReq)).toBeNull();
  });

  it("accepts sound: 'approval.wav'", () => {
    expect(validate({ ...baseReq, sound: "approval.wav" })).toBeNull();
  });

  it("accepts sound: 'default'", () => {
    expect(validate({ ...baseReq, sound: "default" })).toBeNull();
  });

  it("rejects sound with spaces", () => {
    expect(validate({ ...baseReq, sound: "my sound.wav" })).toBe("sound");
  });

  it("rejects sound longer than 64 chars", () => {
    expect(validate({ ...baseReq, sound: "a".repeat(65) })).toBe("sound");
  });

  it("rejects sound with path traversal", () => {
    expect(validate({ ...baseReq, sound: "../secret" })).toBe("sound");
  });
});

describe("buildPayload – sound", () => {
  it("includes aps.sound when urgent and sound is set", () => {
    const payload = buildPayload({ ...baseReq, sound: "approval.wav" });
    expect((payload.aps as Record<string, unknown>)["sound"]).toBe("approval.wav");
  });

  it("omits aps.sound when urgent but no sound field", () => {
    const payload = buildPayload(baseReq);
    expect((payload.aps as Record<string, unknown>)["sound"]).toBeUndefined();
  });

  it("omits aps.sound for non-urgent updates even if sound is set", () => {
    const payload = buildPayload({ ...baseReq, urgent: false, sound: "approval.wav" });
    expect((payload.aps as Record<string, unknown>)["sound"]).toBeUndefined();
  });

  it("omits aps.sound for start events", () => {
    const payload = buildPayload({ ...baseReq, event: "start", sound: "approval.wav" });
    expect((payload.aps as Record<string, unknown>)["sound"]).toBeUndefined();
  });
});
