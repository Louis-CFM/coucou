// Cursor agent hook installation.
//
// Same rule as the Claude Code installer: read the file, take a dated backup,
// merge without touching anybody else's hooks, show the diff, and write only
// after an explicit click. The file is `%USERPROFILE%\.cursor\hooks.json`,
// whose shape is `{ version, hooks: { event: [{ command, timeout }] } }` —
// not Claude's nested `hooks` arrays.
//
// Every command is observational. `failClosed` is never set, and the relay
// always answers allow / continue, so a closed Alfred cannot block the agent.

use std::path::{Path, PathBuf};

use serde_json::{json, Map, Value};

use crate::hooks::{self, HookPreview, HookStatus};
use crate::settings;

/// Events the island shows. Short timeout: the relay answers in well under a
/// second and never waits for a click.
const EVENTS: &[&str] = &[
    "sessionStart",
    "sessionEnd",
    "beforeSubmitPrompt",
    "preToolUse",
    "postToolUseFailure",
    "subagentStart",
    "subagentStop",
    "stop",
];

const TIMEOUT: u64 = 5;

/// Marker that identifies a Alfred entry inside hooks.json.
const MARKER: &str = "alfred-hook";

fn home() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
}

pub fn hooks_path() -> PathBuf {
    home().join(".cursor").join("hooks.json")
}

fn read_hooks() -> Result<Value, String> {
    let path = hooks_path();
    match std::fs::read(&path) {
        Ok(bytes) => parse_hooks(&bytes, &path.display().to_string()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

fn parse_hooks(bytes: &[u8], path: &str) -> Result<Value, String> {
    let text = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    match serde_json::from_slice::<Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(format!("{path} isn't a JSON object — Alfred won't touch it.")),
        Err(err) => Err(format!(
            "{path} isn't valid JSON ({err}). Fix or move it, then try again — Alfred won't overwrite it."
        )),
    }
}

fn read_hooks_lossy() -> Value {
    read_hooks().unwrap_or_else(|_| json!({}))
}

/// Quoted absolute path plus `--cursor`. Forward slashes survive both cmd and a
/// path that contains spaces.
fn hook_command() -> String {
    let exe = settings::hook_exe_path().to_string_lossy().replace('\\', "/");
    format!("\"{exe}\" --cursor")
}

fn entry_is_ours(entry: &Value) -> bool {
    entry
        .get("command")
        .and_then(Value::as_str)
        .map(|command| command.contains(MARKER))
        .unwrap_or(false)
}

fn merged(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    if !root.contains_key("version") {
        root.insert("version".into(), json!(1));
    }
    let mut hooks = root
        .get("hooks")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_else(Map::new);

    let command = hook_command();
    for event in EVENTS {
        let mut list = hooks
            .get(*event)
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        list.retain(|entry| !entry_is_ours(entry));
        list.push(json!({
            "command": command,
            "timeout": TIMEOUT,
        }));
        hooks.insert((*event).to_string(), Value::Array(list));
    }

    root.insert("hooks".into(), Value::Object(hooks));
    Value::Object(root)
}

fn without_ours(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object).cloned() else {
        return Value::Object(root);
    };
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let kept: Vec<Value> = list.iter().filter(|e| !entry_is_ours(e)).cloned().collect();
                if !kept.is_empty() {
                    out.insert(event, Value::Array(kept));
                }
            }
            None => {
                out.insert(event, value);
            }
        }
    }
    if out.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(out));
    }
    Value::Object(root)
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

fn backup_path() -> PathBuf {
    let p = hooks_path();
    p.with_file_name(format!("hooks.json.bak-{}", hooks::stamp()))
}

fn current_fingerprint() -> String {
    match std::fs::read(hooks_path()) {
        Ok(bytes) => hooks::fingerprint(&bytes),
        Err(_) => hooks::fingerprint(b""),
    }
}

fn installed_in(root: &Value) -> bool {
    root.get("hooks")
        .and_then(Value::as_object)
        .map(|hooks| {
            hooks
                .values()
                .filter_map(Value::as_array)
                .flatten()
                .any(entry_is_ours)
        })
        .unwrap_or(false)
}

pub fn status() -> HookStatus {
    let hook_path = settings::hook_exe_path();
    HookStatus {
        installed: installed_in(&read_hooks_lossy()),
        settings_path: hooks_path().to_string_lossy().to_string(),
        hook_ready: hook_path.exists(),
        hook_path: hook_path.to_string_lossy().to_string(),
    }
}

pub fn preview(install: bool) -> Result<HookPreview, String> {
    let current = read_hooks()?;
    let next = if install { merged(&current) } else { without_ours(&current) };
    Ok(HookPreview {
        diff: hooks::unified_diff(&pretty(&current), &pretty(&next)),
        backup: backup_path().to_string_lossy().to_string(),
        settings_path: hooks_path().to_string_lossy().to_string(),
        fingerprint: current_fingerprint(),
    })
}

/// Writes the merged (or cleaned) hooks.json after a dated backup.
/// Refuses when the file changed since the preview the user looked at.
pub fn write(install: bool, fingerprint: &str) -> Result<String, String> {
    let path = hooks_path();
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    let current = read_hooks()?;
    if current_fingerprint() != fingerprint {
        return Err(format!(
            "{} changed since the preview. Nothing was written — review the new diff.",
            path.display()
        ));
    }

    let backup = backup_path();
    if path.exists() {
        std::fs::copy(&path, &backup).map_err(|e| format!("backup failed: {e}"))?;
    }

    let next = if install { merged(&current) } else { without_ours(&current) };
    let mut text = pretty(&next);
    text.push('\n');

    let temp = path.with_extension(format!("json.alfred-{}", std::process::id()));
    std::fs::write(&temp, text.as_bytes()).map_err(|e| format!("write failed: {e}"))?;
    if let Err(err) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("write failed: {err}"));
    }
    Ok(backup.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    const WHERE: &str = "hooks.json";

    #[test]
    fn a_utf8_bom_is_stripped() {
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(br#"{"version":1,"hooks":{}}"#);
        let parsed = parse_hooks(&bytes, WHERE).expect("a BOM must not defeat the parser");
        assert_eq!(parsed["version"], 1);
    }

    #[test]
    fn unreadable_content_is_refused() {
        for bad in [&b"{ not json"[..], &b"[1,2,3]"[..], &b"\"a string\""[..]] {
            assert!(parse_hooks(bad, WHERE).is_err());
        }
    }

    #[test]
    fn merging_keeps_foreign_hooks_and_other_keys() {
        let existing = json!({
            "version": 1,
            "somethingElse": true,
            "hooks": {
                "preToolUse": [{ "command": "other.exe", "timeout": 10 }],
                "beforeShellExecution": [{ "command": "keep-me.exe" }]
            }
        });
        let after = merged(&existing);
        assert_eq!(after["version"], 1);
        assert_eq!(after["somethingElse"], true);

        let pre = after["hooks"]["preToolUse"].as_array().unwrap();
        assert!(pre.iter().any(|e| e["command"] == "other.exe"));
        assert!(pre.iter().any(entry_is_ours));
        assert!(after["hooks"]["beforeShellExecution"].is_array());
        assert!(after["hooks"]["sessionStart"].is_array());
        // Observational only: no failClosed, and the command is the cursor mode.
        let ours = pre.iter().find(|e| entry_is_ours(e)).unwrap();
        assert!(ours.get("failClosed").is_none());
        assert_eq!(ours["timeout"], TIMEOUT);
        assert!(ours["command"].as_str().unwrap().contains("--cursor"));

        let cleaned = without_ours(&after);
        assert_eq!(cleaned, existing);
    }

    #[test]
    fn writing_backs_up_and_refuses_a_changed_file() {
        let _guard = crate::hooks::lock_test_home();
        let tmp = std::env::temp_dir().join(format!("alfred-cursor-hooks-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join(".cursor")).unwrap();
        std::env::set_var("USERPROFILE", &tmp);

        let path = hooks_path();
        assert!(path.starts_with(&tmp), "the test must not touch the real home");

        let original = r#"{"version":1,"hooks":{"preToolUse":[{"command":"other.exe"}]}}"#;
        std::fs::write(&path, original).unwrap();

        let plan = preview(true).expect("preview");
        assert!(plan.diff.contains("alfred-hook"));
        let backup = write(true, &plan.fingerprint).expect("install");
        assert_eq!(std::fs::read(&backup).unwrap(), original.as_bytes());

        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        let pre = after["hooks"]["preToolUse"].as_array().unwrap();
        assert!(pre.iter().any(|e| e["command"] == "other.exe"));
        assert!(status().installed);

        let stale = preview(false).unwrap();
        std::fs::write(&path, br#"{"version":1,"edited":true}"#).unwrap();
        let err = write(false, &stale.fingerprint).unwrap_err();
        assert!(err.contains("changed since the preview"), "got: {err}");

        std::fs::write(&path, b"{ broken").unwrap();
        assert!(preview(true).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"{ broken");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
