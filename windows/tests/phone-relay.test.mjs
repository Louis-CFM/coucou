// Settings → Android phone → Away from home Wi-Fi: the status line and the way the access key is handled.

import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { installFakeDom } from "./fakedom.mjs";
import { relayStateText } from "../src/settings/phone.ts";

installFakeDom();

const STATES = ["off", "connecting", "waiting", "linked", "accessRefused", "unreachable", "roomTaken", "tooMany"];

test("every relay state has its own plain sentence", () => {
  const lines = STATES.map((s) => relayStateText(s));
  for (const line of lines) assert.ok(line.length > 2);
  assert.equal(new Set(lines).size, STATES.length, "no two states say the same thing");
});

test("the access key is typed into a password field, sent once and wiped from the page", () => {
  const src = readFileSync(new URL("../src/settings/phone.ts", import.meta.url), "utf8");
  const block = src.slice(src.indexOf("function relayBlock"), src.indexOf("function detailsBlock"));
  assert.match(block, /type: "password"/);
  assert.match(block, /access\.value = ""/, "the field is emptied after saving");
  assert.ok(!/localStorage|sessionStorage|console\./.test(block), "the key goes nowhere but Rust");
  assert.ok(!block.includes("status.access"), "the window never gets the key back");
});

test("the bridge never asks Rust for the access key", () => {
  const bridge = readFileSync(new URL("../src/core/bridge.ts", import.meta.url), "utf8");
  assert.match(bridge, /phoneRelaySetAccess/);
  assert.ok(!/phone_relay_get_access|relayAccess:/.test(bridge));
  const status = bridge.slice(bridge.indexOf("export interface PhoneRelayStatus"), bridge.indexOf("export interface PhoneLinkStatus") > 0 ? undefined : undefined);
  assert.match(status.slice(0, 400), /hasAccess: boolean/);
  assert.ok(!/access: string/.test(status.slice(0, 400)));
});
