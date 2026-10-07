// Antigravity hook installation.
//
// Manages %USERPROFILE%\.gemini\config\hooks.json following the Coucou rules:
// take a dated backup, merge without touching any other custom hooks, show the diff,
// and write only after an explicit click. Uninstall removes Coucou's entries only.

use std::path::PathBuf;
use serde_json::{json, Map, Value};
use crate::hooks::{self, HookPreview, HookStatus};
use crate::{platform, settings};

const MARKER: &str = "coucou-hook";

pub fn hooks_path() -> PathBuf {
    platform::home_dir().join(".gemini").join("config").join("hooks.json")
}

fn read_hooks_json() -> Result<Value, String> {
    let path = hooks_path();
    match std::fs::read(&path) {
        Ok(bytes) => parse_hooks_json(&bytes, &path.display().to_string()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

fn parse_hooks_json(bytes: &[u8], path: &str) -> Result<Value, String> {
    let text = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    match serde_json::from_slice::<Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(format!("{path} isn't a JSON object — Coucou won't touch it.")),
        Err(err) => Err(format!(
            "{path} isn't valid JSON ({err}). Fix or move it, then try again — Coucou won't overwrite it."
        )),
    }
}

fn read_hooks_lossy() -> Value {
    read_hooks_json().unwrap_or_else(|_| json!({}))
}

#[cfg(windows)]
fn hook_command(event: &str) -> String {
    let exe = settings::hook_exe_path().to_string_lossy().to_string();
    format!("{exe} --agent antigravity {event}")
}

#[cfg(unix)]
fn hook_command(event: &str) -> String {
    let exe = settings::hook_exe_path().to_string_lossy();
    format!("\"{exe}\" --agent antigravity {event}")
}

fn build_coucou_block() -> Value {
    let mut coucou = Map::new();

    // PreToolUse and PostToolUse are tool hooks — require matcher group
    for event in ["PreToolUse", "PostToolUse"] {
        coucou.insert(
            event.to_string(),
            json!([
                {
                    "matcher": "*",
                    "hooks": [
                        {
                            "type": "command",
                            "command": hook_command(event),
                            "timeout": 10
                        }
                    ]
                }
            ]),
        );
    }

    // PreInvocation, PostInvocation and Stop are lifecycle hooks — flat list
    for event in ["PreInvocation", "PostInvocation", "Stop"] {
        coucou.insert(
            event.to_string(),
            json!([
                {
                    "type": "command",
                    "command": hook_command(event),
                    "timeout": 10
                }
            ]),
        );
    }

    Value::Object(coucou)
}

fn merged(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    root.insert("coucou".into(), build_coucou_block());
    Value::Object(root)
}

fn without_ours(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    root.remove("coucou");
    Value::Object(root)
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

fn stamp() -> String {
    let t = platform::local_time();
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.year, t.month, t.day, t.hour, t.minute, t.second
    )
}

fn backup_path() -> PathBuf {
    let p = hooks_path();
    p.with_file_name(format!("hooks.json.bak-{}", stamp()))
}

fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

fn current_fingerprint() -> String {
    match std::fs::read(hooks_path()) {
        Ok(bytes) => fingerprint(&bytes),
        Err(_) => fingerprint(b""),
    }
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn status() -> HookStatus {
    let current = read_hooks_lossy();
    let installed = current
        .get("coucou")
        .and_then(Value::as_object)
        .map(|coucou| serde_json::to_string(coucou).map(|s| s.contains(MARKER)).unwrap_or(false))
        .unwrap_or(false);

    HookStatus {
        installed,
        settings_path: hooks_path().to_string_lossy().to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
        hook_ready: settings::hook_exe_path().exists(),
    }
}

pub fn preview(install: bool) -> Result<HookPreview, String> {
    let current = read_hooks_json()?;
    let path = hooks_path();
    let exists = path.exists();
    if !install && !exists {
        return Err("No Antigravity hooks to remove.".into());
    }

    let before_str = if exists { pretty(&current) } else { String::new() };
    let after_val = if install { merged(&current) } else { without_ours(&current) };
    let after_str = pretty(&after_val);

    let diff = hooks::unified_diff(&before_str, &after_str);
    let backup = if exists {
        backup_path().to_string_lossy().to_string()
    } else {
        "(none — file will be created)".into()
    };

    Ok(HookPreview {
        diff,
        backup,
        settings_path: path.to_string_lossy().to_string(),
        fingerprint: current_fingerprint(),
    })
}

pub fn write(install: bool, expected_fingerprint: &str) -> Result<String, String> {
    let path = hooks_path();
    let current_bytes = std::fs::read(&path).unwrap_or_default();
    if fingerprint(&current_bytes) != expected_fingerprint {
        return Err(
            "hooks.json changed since the preview was shown. Review the new changes and try again."
                .into(),
        );
    }

    let current = read_hooks_json()?;
    let next_val = if install { merged(&current) } else { without_ours(&current) };
    let mut next_bytes = serde_json::to_vec_pretty(&next_val).map_err(|e| e.to_string())?;
    next_bytes.push(b'\n');

    let backup = if path.exists() {
        let b = backup_path();
        std::fs::write(&b, &current_bytes)
            .map_err(|e| format!("Could not write backup {}: {e}", b.display()))?;
        b.to_string_lossy().to_string()
    } else {
        "(file created, no previous content)".into()
    };

    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("Could not create directory {}: {e}", parent.display()))?;
    }

    let temp = path.with_extension(format!("new-{}", std::process::id()));
    std::fs::write(&temp, &next_bytes)
        .map_err(|e| format!("Could not write {}: {e}", temp.display()))?;
    std::fs::rename(&temp, &path)
        .map_err(|e| format!("Could not replace {}: {e}", path.display()))?;

    Ok(backup)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merging_and_removing_antigravity_hooks() {
        let existing = json!({
            "existing-hook": {
                "PreToolUse": [{ "command": "my-script.bat" }]
            }
        });

        let after = merged(&existing);
        assert!(after.get("existing-hook").is_some());
        let coucou = after.get("coucou").unwrap();
        assert!(coucou.get("PreToolUse").is_some());
        assert!(coucou.get("PostToolUse").is_some());
        assert!(coucou.get("PreInvocation").is_some());
        assert!(coucou.get("PostInvocation").is_some());
        assert!(coucou.get("Stop").is_some());

        let cleaned = without_ours(&after);
        assert_eq!(cleaned, existing);
    }
}
