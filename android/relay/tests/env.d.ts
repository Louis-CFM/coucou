// Types for `import { env, exports } from "cloudflare:workers"` in the tests.
declare namespace Cloudflare {
  interface Env {
    ROOM: DurableObjectNamespace<import("../src/room").Room>;
    ACCESS_KEY?: string;
  }
  interface GlobalProps {
    mainModule: typeof import("../src/index");
  }
}
