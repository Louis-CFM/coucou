// Approve Antigravity commands from the island (Settings → Agents → Antigravity, off by
// default). Port of the Mac's HookServer.agyApprovalGate (PR #934).
//
// Antigravity has no permission-request event: it runs its PreToolUse hook before its own
// permission check and waits for the hook's `decision`. The relay (hook/src/main.rs) sends
// that event tagged `coucou_kind: "agy_pre_tool"` and reads one line back:
//   * `ask` at once — this module found no reason for a card, and Antigravity decides;
//   * or `pending` once the card is up, then `allow`, `deny` or `ask` (pipe.rs).
// Only a click on Allow ever lets a command run. No click, Reply in terminal, Coucou closed
// or slow: "ask", and Antigravity shows its own prompt as if Coucou were not there.

use std::path::Path;
use std::time::Duration;

use serde::Serialize;
use serde_json::Value;
use tauri::{Emitter, State, WebviewWindow};

use crate::agy_rules::{AgyRules, Verdict};
use crate::{log, platform, settings, Shared};

/// The PreToolUse hook needs this long (seconds) for a card to wait for a click: the hooks
/// Coucou wrote before had 10 s and must be installed again (agents.rs writes 120).
pub const HOOK_TIMEOUT: u64 = 120;

/// What the relay tags the PreToolUse events it waits on with.
pub const KIND: &str = "agy_pre_tool";

/// A command to put on the card, and how long it may wait there.
#[derive(Debug, PartialEq)]
pub struct Gate {
    pub command: String,
    pub wait: Duration,
}

/// The card to show when Antigravity is about to run a shell command none of its rules
/// covers; None when Antigravity decides on its own. `enabled` is the setting, `home`
/// holds Antigravity's `.gemini` folder.
pub fn gate(payload: &Value, enabled: bool, home: &Path) -> Option<Gate> {
    if !enabled || payload.get("coucou_agent").and_then(Value::as_str) != Some("antigravity") {
        return None;
    }
    let tool = payload.get("tool_name").and_then(Value::as_str).unwrap_or_default();
    if tool != "run_command" && !tool.ends_with(":run_command") {
        return None;
    }
    // The relay shortens long strings: a command that was cut is not one to approve
    // without seeing it whole, nor one the rules could read.
    if payload.get("coucou_command_cut").and_then(Value::as_bool) == Some(true) {
        return None;
    }
    let command = payload
        .get("tool_input")
        .and_then(|i| i.get("command"))
        .and_then(Value::as_str)
        .unwrap_or_default()
        .trim()
        .to_string();
    if command.is_empty() {
        return None;
    }
    // Coucou gives up 10 s before Antigravity stops waiting for the hook.
    let timeout = pre_tool_timeout(home).filter(|t| *t >= HOOK_TIMEOUT)?;
    let cwd = payload.get("cwd").and_then(Value::as_str).unwrap_or_default();
    if AgyRules::load(home, cwd).verdict(&command) != Verdict::Unknown {
        return None;
    }
    Some(Gate { command, wait: Duration::from_secs((timeout - 10).min(110)) })
}

/// Timeout (seconds) of Coucou's PreToolUse hook in ~/.gemini/config/hooks.json, None if
/// it is not there.
pub fn pre_tool_timeout(home: &Path) -> Option<u64> {
    let bytes = std::fs::read(home.join(".gemini").join("config").join("hooks.json")).ok()?;
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(&bytes);
    let root: Value = serde_json::from_slice(bytes).ok()?;
    let groups = root.get("coucou")?.get("PreToolUse")?.as_array()?;
    groups
        .iter()
        .filter_map(|g| g.get("hooks").and_then(Value::as_array))
        .flatten()
        .find(|h| h.get("command").and_then(Value::as_str).is_some_and(|c| c.contains("coucou-hook")))
        // Antigravity's default when no timeout is written is 30 s.
        .map(|h| h.get("timeout").and_then(Value::as_f64).map_or(30, |t| t.max(0.0) as u64))
}

// ── Settings → Agents → Antigravity ───────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgyApprovalsStatus {
    pub enabled: bool,
    /// Coucou's PreToolUse hook gives Antigravity time to wait for a click: hooks
    /// written by an older Coucou (10 s) must be installed again.
    pub hooks_ready: bool,
}

fn status(enabled: bool) -> AgyApprovalsStatus {
    let ready = pre_tool_timeout(&platform::home_dir()).is_some_and(|t| t >= HOOK_TIMEOUT);
    AgyApprovalsStatus { enabled, hooks_ready: ready }
}

#[tauri::command]
pub fn agy_approvals_status(shared: State<Shared>) -> AgyApprovalsStatus {
    status(shared.settings.lock().unwrap().agy_approvals_enabled)
}

/// "Approve commands from the notch". Off by default; only the switch in the Coucou window
/// turns it on, and save_settings keeps what it says.
#[tauri::command]
pub fn agy_approvals_set_enabled(
    app: tauri::AppHandle,
    window: WebviewWindow,
    shared: State<Shared>,
    enabled: bool,
) -> Result<AgyApprovalsStatus, String> {
    if window.label() != crate::HUB_LABEL {
        return Err("only the Coucou window may change this".into());
    }
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.agy_approvals_enabled = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    log::line(format!("Antigravity approvals from the island {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(status(enabled))
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn home(name: &str, hooks: Option<&str>) -> std::path::PathBuf {
        let home = std::env::temp_dir().join(format!(
            "coucou-agy-gate-{name}-{}-{}",
            std::process::id(),
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos()
        ));
        let config = home.join(".gemini").join("config");
        std::fs::create_dir_all(&config).unwrap();
        if let Some(hooks) = hooks {
            std::fs::write(config.join("hooks.json"), hooks).unwrap();
        }
        std::fs::create_dir_all(home.join(".gemini").join("antigravity-cli")).unwrap();
        std::fs::write(
            home.join(".gemini/antigravity-cli/settings.json"),
            r#"{"permissions":{"allow":["command(ls)"],"deny":["command(rm -rf)"]}}"#,
        )
        .unwrap();
        home
    }

    fn hooks(timeout: Option<u64>) -> String {
        let t = timeout.map(|t| format!(r#","timeout":{t}"#)).unwrap_or_default();
        format!(r#"{{"coucou":{{"PreToolUse":[{{"matcher":"*","hooks":[{{"type":"command","command":"/x/coucou-hook --agent antigravity PreToolUse"{t}}}]}}]}}}}"#)
    }

    fn run(command: &str) -> Value {
        json!({ "coucou_agent": "antigravity", "coucou_kind": KIND, "tool_name": "run_command",
                "tool_input": { "command": command }, "cwd": "/work" })
    }

    #[test]
    fn only_a_command_no_rule_covers_waits_on_the_card() {
        let h = home("cover", Some(&hooks(Some(120))));
        let gate = gate(&run("npm install"), true, &h).expect("card");
        assert_eq!(gate, Gate { command: "npm install".into(), wait: Duration::from_secs(110) });
        // Antigravity's own rules decide these.
        assert_eq!(super::gate(&run("ls -la"), true, &h), None);
        assert_eq!(super::gate(&run("rm -rf build"), true, &h), None);
        // Namespaced tool names are the same tool.
        let mut ns = run("npm install");
        ns["tool_name"] = json!("default_api:run_command");
        assert!(super::gate(&ns, true, &h).is_some());
        let _ = std::fs::remove_dir_all(&h);
    }

    #[test]
    fn nothing_waits_when_it_is_off_or_not_a_command() {
        let h = home("off", Some(&hooks(Some(120))));
        assert_eq!(gate(&run("npm install"), false, &h), None);
        for (key, value) in [
            ("coucou_agent", json!("gemini")),
            ("tool_name", json!("write_to_file")),
            ("tool_input", json!({ "command": "   " })),
            ("tool_input", json!({})),
            ("coucou_command_cut", json!(true)),
        ] {
            let mut p = run("npm install");
            p[key] = value;
            assert_eq!(gate(&p, true, &h), None, "{key}");
        }
        let _ = std::fs::remove_dir_all(&h);
    }

    #[test]
    fn hooks_from_an_older_coucou_never_wait() {
        for (name, hooks_json) in [("old", Some(hooks(Some(10)))), ("default", Some(hooks(None))), ("none", None)] {
            let h = home(name, hooks_json.as_deref());
            assert_eq!(gate(&run("npm install"), true, &h), None, "{name}");
            let _ = std::fs::remove_dir_all(&h);
        }
        let h = home("short", Some(&hooks(None)));
        assert_eq!(pre_tool_timeout(&h), Some(30));
        let _ = std::fs::remove_dir_all(&h);
        // A longer hook still gives up 10 s before it, and never after 110 s.
        let h = home("long", Some(&hooks(Some(600))));
        assert_eq!(gate(&run("npm install"), true, &h).unwrap().wait, Duration::from_secs(110));
        let _ = std::fs::remove_dir_all(&h);
    }
}
