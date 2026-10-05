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
}