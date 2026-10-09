import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const binary = resolve("target/debug/coucou.exe");
const relay = resolve(process.env.LOCALAPPDATA, "Coucou/bin/coucou-hook.exe");
const log = resolve(process.env.LOCALAPPDATA, "Coucou/coucou.log");

function coucouProcesses() {
  const output = execFileSync("powershell.exe", ["-NoProfile", "-Command",
    "Get-Process -Name coucou -ErrorAction SilentlyContinue | Select-Object Id,Path | ConvertTo-Json -Compress",
  ], { encoding: "utf8" }).trim();
  return output ? [JSON.parse(output)].flat().filter((p) => p.Path?.toLowerCase() === binary.toLowerCase()) : [];
}

async function until(check, timeout = 45000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    if (check()) return;
    await new Promise((done) => setTimeout(done, 500));
  }
  throw new Error("Timed out waiting for Coucou process state");
}

async function invoke(name, args = {}) {
  return await browser.tauri.execute(name, args);
}

function fields(status) {
  return Object.fromEntries(status.split(" ").map((part) => part.split("=")));
}

describe("Auto-Quit in the Windows app", () => {
  it("persists five minutes, respects active sessions and Settings, exits, then auto-launches once", async () => {
    await until(() => coucouProcesses().length === 1);
    await invoke("open_settings_window");
    let found = false;
    for (const handle of await browser.getWindowHandles()) {
      await browser.switchToWindow(handle);
      if ((await browser.getUrl()).includes("settings.html")) { found = true; break; }
    }
    assert.equal(found, true, "Settings window was not opened");

    const delay = await browser.$("#auto-quit-delay");
    await delay.waitForExist();
    assert.equal(await delay.isEnabled(), false);
    await browser.$("#auto-quit-enabled").click();
    await delay.selectByAttribute("value", "5");
    await browser.$("#auto-launch-enabled").click();
    await until(() => {
      try {
        const stored = JSON.parse(readFileSync(resolve(process.env.APPDATA, "Coucou/settings.json"), "utf8"));
        return stored.autoQuitWhenAgentsFinish === true && stored.autoQuitDelayMinutes === 5
          && stored.autoLaunchWithAgents === true;
      } catch { return false; }
    }, 5000);
    assert.equal(fields(await invoke("test_status")).minutes, "5");
    await browser.refresh();
    await browser.$("#auto-quit-delay").waitForExist();
    assert.equal(await browser.$("#auto-quit-delay").getValue(), "5");

    await invoke("test_event", { agent: "codex", session: 2, event: "SessionEnd" });
    assert.equal(fields(await invoke("test_status")).sessions, "0");
    assert.equal(fields(await invoke("test_status")).deadline_seconds, "none");

    await invoke("test_event", { agent: "codex", session: 1, event: "SessionStart" });
    await invoke("test_advance", { seconds: 601 });
    assert.equal(fields(await invoke("test_status")).open_codex, "1");
    assert.equal(fields(await invoke("test_status")).deadline_seconds, "none");
    assert.equal(coucouProcesses().length, 1);

    await invoke("test_event", { agent: "hermes", session: 3, event: "SessionStart" });
    await invoke("test_event", { agent: "codex", session: 1, event: "SessionEnd" });
    assert.equal(fields(await invoke("test_status")).open_hermes, "1");
    assert.equal(fields(await invoke("test_status")).deadline_seconds, "none");
    await invoke("test_event", { agent: "hermes", session: 3, event: "SessionEnd" });
    await invoke("test_advance", { seconds: 120 });
    await invoke("test_event", { agent: "codex", session: 4, event: "SessionStart" });
    assert.equal(fields(await invoke("test_status")).deadline_seconds, "none");
    await invoke("test_advance", { seconds: 301 });
    assert.equal(coucouProcesses().length, 1);
    await invoke("test_event", { agent: "codex", session: 4, event: "SessionEnd" });
    await invoke("test_advance", { seconds: 301 });
    assert.equal(coucouProcesses().length, 1);
    await until(() => readFileSync(log, "utf8").includes("reason=settings_open"), 5000);
    await invoke("test_hide_settings");
    await until(() => coucouProcesses().length === 0, 45000);

    const launch = spawnSync(relay, ["--agent", "codex"], {
      input: JSON.stringify({ hook_event_name: "UserPromptSubmit", session_id: "wdio-relaunch",
        turn_id: "wdio-turn", prompt: "" }), encoding: "utf8", timeout: 5000,
    });
    assert.equal(launch.status, 0, launch.stderr);
    await until(() => coucouProcesses().length === 1);
    assert.equal(coucouProcesses().length, 1);
  });
});
