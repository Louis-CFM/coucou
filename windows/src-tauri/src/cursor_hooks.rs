use std::path::PathBuf;

use serde_json::{json, Value};

use crate::settings;

const HOOK_EVENTS: &[&str] = &[
    "sessionStart",
    "sessionEnd",
    "beforeSubmitPrompt",
    "preToolUse",
    "postToolUse",
    "postToolUseFailure",
    "stop",
];

pub fn settings_path() -> PathBuf {
    let home = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));

    home.join(".cursor").join("hooks.json")
}

fn read_settings() -> Result<Value, String> {
    let path = settings_path();

    match std::fs::read(&path) {
        Ok(bytes) => parse_settings(&bytes, &path.display().to_string()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

fn parse_settings(bytes: &[u8], path: &str) -> Result<Value, String> {
    // PowerShell may write UTF-8 JSON with a BOM. serde_json does not accept it.
    let text = bytes
        .strip_prefix(&[0xEF, 0xBB, 0xBF])
        .unwrap_or(bytes);

    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }

    match serde_json::from_slice::<Value>(text) {
        Ok(value) if value.is_object() => Ok(value),
        Ok(_) => Err(format!(
            "{path} isn't a JSON object — Coucou won't touch it."
        )),
        Err(err) => Err(format!(
            "{path} isn't valid JSON ({err}). Coucou won't overwrite it."
        )),
    }
}

#[cfg(windows)]
fn hook_command() -> String {
    let exe = settings::hook_exe_path()
        .to_string_lossy()
        .replace('\\', "/");

    format!("\"{exe}\" --agent cursor")
}

fn merged(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();

    root.insert("version".into(), json!(1));

    let mut hooks = root
        .get("hooks")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();

    for event in HOOK_EVENTS {
        let entry = json!({
            "command": hook_command()
        });

        match hooks.get_mut(*event) {
            Some(Value::Array(existing)) => existing.push(entry),
            _ => {
                hooks.insert((*event).to_string(), Value::Array(vec![entry]));
            }
        }
    }

    root.insert("hooks".into(), Value::Object(hooks));

    Value::Object(root)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cursor_hooks_use_native_format() {
        let config = merged(&json!({}));

        assert_eq!(config["version"], 1);

        assert_eq!(
            config["hooks"]["preToolUse"][0]["command"],
            hook_command()
        );

        assert!(config["hooks"]["beforeSubmitPrompt"].is_array());
        assert!(config["hooks"]["stop"].is_array());
    }

    #[test]
    fn cursor_hooks_preserve_existing_entries() {
        let existing = json!({
            "version": 1,
            "hooks": {
                "preToolUse": [
                    {
                        "command": "other-tool.exe"
                    }
                ]
            }
        });

        let config = merged(&existing);
        let hooks = config["hooks"]["preToolUse"].as_array().unwrap();

        assert_eq!(hooks.len(), 2);
        assert_eq!(hooks[0]["command"], "other-tool.exe");
        assert_eq!(hooks[1]["command"], hook_command());
    }

    #[test]
    fn cursor_hooks_accept_utf8_bom() {
        let bytes = b"\xEF\xBB\xBF{\"version\":1,\"hooks\":{}}";

        let config = parse_settings(bytes, "hooks.json").unwrap();

        assert_eq!(config["version"], 1);
        assert!(config["hooks"].is_object());
    }

    #[test]
    fn cursor_hooks_reject_invalid_json() {
        let result = parse_settings(b"{not-json", "hooks.json");

        assert!(result.is_err());
    }
}
