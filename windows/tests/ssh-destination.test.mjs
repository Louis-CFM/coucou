// What the user types for a remote host → the one destination ssh takes after `--`.

import assert from "node:assert/strict";
import { test } from "node:test";
import { sshDestination, sshLabel } from "../src/core/ssh.ts";

test("a host with a port becomes ssh's own URL form", () => {
  assert.equal(sshDestination("devbox"), "devbox");
  assert.equal(sshDestination(" alice@203.0.113.7 "), "alice@203.0.113.7");
  assert.equal(sshDestination("alice@203.0.113.7 -p 2222"), "ssh://alice@203.0.113.7:2222");
  assert.equal(sshDestination("-p 2222 alice@203.0.113.7"), "ssh://alice@203.0.113.7:2222");
  assert.equal(sshDestination("alice@203.0.113.7 -p2222"), "ssh://alice@203.0.113.7:2222");
  assert.equal(sshDestination("alice@203.0.113.7:2222"), "ssh://alice@203.0.113.7:2222");
  assert.equal(sshDestination("ssh://alice@devbox:2222"), "ssh://alice@devbox:2222");
  assert.equal(sshDestination("[fe80::1]:2222"), "ssh://[fe80::1]:2222");
  assert.equal(sshDestination("fe80::1"), "fe80::1");
});

test("nothing typed reaches ssh as an option", () => {
  for (const bad of ["", "devbox -p 0", "devbox -p 70000", "-oProxyCommand=x", "devbox -i key", "devbox; rm"]) {
    assert.equal(sshDestination(bad), null, bad);
  }
});

test("the label drops the scheme and the port", () => {
  assert.equal(sshLabel("ssh://alice@203.0.113.7:2222"), "alice@203.0.113.7");
  assert.equal(sshLabel("ssh://[2001:db8::7]:2222"), "[2001:db8::7]");
  assert.equal(sshLabel("devbox"), "devbox");
});
