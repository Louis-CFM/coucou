import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const binary = resolve(here, "../target/debug/coucou.exe");

export const config = {
  runner: "local",
  specs: [join(here, "auto-quit.spec.mjs")],
  maxInstances: 1,
  capabilities: [{ browserName: "tauri", "tauri:options": { application: binary } }],
  services: [["@wdio/tauri-service", {
    appBinaryPath: binary,
    driverProvider: "official",
    autoInstallTauriDriver: true,
    autoDownloadEdgeDriver: true,
  }]],
  framework: "mocha",
  reporters: ["spec"],
  logLevel: "warn",
  waitforTimeout: 15000,
  connectionRetryTimeout: 90000,
  mochaOpts: { ui: "bdd", timeout: 90000 },
};
