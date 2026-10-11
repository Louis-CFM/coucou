import { defineConfig } from "vitest/config";

// The Node twin (tools/dev-relay.ts) and the pure rules, in plain Node.
export default defineConfig({ test: { include: ["tests/node.*.test.ts"], environment: "node" } });
