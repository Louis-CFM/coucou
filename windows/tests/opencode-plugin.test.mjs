import { test } from "node:test";
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

test("generated OpenCode plugin forwards new and resumed user messages without prompt text or blocking", async () => {
  const source = await readFile(new URL("../src-tauri/src/agents.rs", import.meta.url), "utf8");
  const template = source.split('const OPENCODE_PLUGIN: &str = r#"')[1]?.split('"#;')[0];
  assert.ok(template);
  const events = [];
  globalThis.__coucouSpawn = (_hook, args, options) => {
    assert.deepEqual(args, ["--agent", "opencode"]);
    assert.equal(options.windowsHide, true);
    return { on() { return this; }, unref() {}, stdin: {
      on() { return this; }, end(line) { events.push(JSON.parse(line)); },
    } };
  };
  try {
    const code = template.replace("import { spawn } from 'node:child_process';", "const spawn = globalThis.__coucouSpawn;")
      .replace("{HOOK}", JSON.stringify("C:/Coucou/coucou-hook.exe"));
    const { CoucouPlugin } = await import(`data:text/javascript,${encodeURIComponent(code)}`);
    const plugin = await CoucouPlugin({ directory: "C:/project" });
    await plugin.event({ event: { type: "session.created", properties: { info: { id: "ses_new" } } } });
    for (const [sessionID, id] of [["ses_new", "msg_1"], ["ses_resumed", "msg_2"]]) {
      await plugin.event({ event: { type: "message.updated", properties: {
        info: { role: "user", sessionID, id, content: "private prompt" },
      } } });
    }
    assert.deepEqual(events.map(({ hook_event_name }) => hook_event_name),
      ["SessionStart", "UserPromptSubmit", "UserPromptSubmit"]);
    assert.deepEqual(events.slice(1), [
      { hook_event_name: "UserPromptSubmit", session_id: "ses_new", turn_id: "msg_1", cwd: "C:/project" },
      { hook_event_name: "UserPromptSubmit", session_id: "ses_resumed", turn_id: "msg_2", cwd: "C:/project" },
    ]);
    assert.doesNotMatch(JSON.stringify(events), /private prompt/);
    await plugin.event({ event: { type: "message.updated", properties: {
      info: { role: "assistant", sessionID: "ses_new", id: "msg_3" },
    } } });
    await plugin.event({ event: { type: "session.idle", properties: { sessionID: "ses_new" } } });
    assert.equal(events.at(-1).hook_event_name, "Stop");
    assert.equal(events.length, 4);
    globalThis.__coucouSpawn = () => { throw Error("relay unavailable"); };
    await plugin.event({ event: { type: "message.updated", properties: {
      info: { role: "user", sessionID: "ses_new", id: "msg_4" },
    } } });
  } finally {
    delete globalThis.__coucouSpawn;
  }
});
