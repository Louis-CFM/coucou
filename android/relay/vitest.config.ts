import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

// The Worker and its Room run in the Workers runtime (workerd, through Miniflare). The access key is a test value.
export default defineConfig({
  plugins: [
    cloudflareTest({
      wrangler: { configPath: "./wrangler.toml" },
      miniflare: {
        bindings: { ACCESS_KEY: "test-access-key-test-access-key-0123456789" },
        // The tests open far more than 30 connections a minute from one "address"; the 429 path has its own test.
        ratelimits: { CONNECT_LIMIT: { namespace_id: "1001", simple: { limit: 100000, period: 60 } } },
      },
    }),
  ],
  test: { include: ["tests/worker.*.test.ts"] },
});
