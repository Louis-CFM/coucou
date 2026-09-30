//! Codex CLI hook installation.
//!
//! Codex reads `~/.codex/hooks.json` and requires the user to trust command
//! hooks in `/hooks`. We only merge our entries, show a diff, and write after
//! an explicit confirmation. The relay itself is the same small executable
//! used by Claude Code; Codex sends the event name in the JSON payload.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Map, Value};
use windows::Win32::System::SystemInformation::GetLocalTime;

use crate::{hooks, settings};

const MARKER: &str = "coucou-hook";
const EVENTS: &[&str] = &[
    "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse",
    "PermissionRequest", "PostToolUse", "PreCompact", "PostCompact", "Interrupt",
    "SubagentStart", "SubagentStop", "Stop",
];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexStatus {
    pub installed: bool,
    pub settings_path: String,
    pub hook_path: String,
    pub hook_ready: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexPreview {
    pub diff: String,
    pub backup: String,
    pub settings_path: String,
    pub fingerprint: String,
}

fn home() -> PathBuf {
    std::env::var_os("CODEX_HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| {
            std::env::var_os("USERPROFILE")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("."))
                .join(".codex")
        })
}

pub fn settings_path() -> PathBuf {
    home().join("hooks.json")
}

fn read() -> Result<Value, String> {
    let path = settings_path();
    match std::fs::read(&path) {
        Ok(bytes) => parse(&bytes, &path.display().to_string()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(json!({})),
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

fn parse(bytes: &[u8], path: &str) -> Result<Value, String> {
    let text = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    match serde_json::from_slice::<Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(format!("{path} isn't a JSON object — Coucou won't touch it.")),
        Err(err) => Err(format!("{path} isn't valid JSON ({err}). Fix it before installing hooks.")),
    }
}

fn command() -> String {
    format!("\"{}\"", settings::hook_exe_path().to_string_lossy().replace('\\', "/"))
}

fn ours(entry: &Value) -> bool {
    entry.get("hooks").and_then(Value::as_array).map(|list| {
        list.iter().any(|hook| hook.get("command").and_then(Value::as_str)
            .map(|command| command.contains(MARKER)).unwrap_or(false)
            || hook.get("commandWindows").and_then(Value::as_str)
                .map(|command| command.contains(MARKER)).unwrap_or(false))
    }).unwrap_or(false)
}

fn merged(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let mut all = root.get("hooks").and_then(Value::as_object).cloned().unwrap_or_default();
    for event in EVENTS {
        let mut entries = all.get(*event).and_then(Value::as_array).cloned().unwrap_or_default();
        entries.retain(|entry| !ours(entry));
        entries.push(json!({
            "hooks": [{
                "type": "command",
                "command": command(),
                "commandWindows": command(),
                "timeout": if *event == "PermissionRequest" { 120 } else { 10 },
            }]
        }));
        all.insert((*event).to_string(), Value::Array(entries));
    }
    root.insert("hooks".into(), Value::Object(all));
    Value::Object(root)
}

fn without_ours(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let Some(all) = root.get("hooks").and_then(Value::as_object) else { return Value::Object(root) };
    let mut kept = Map::new();
    for (event, value) in all {
        if let Some(entries) = value.as_array() {
            let entries: Vec<_> = entries.iter().filter(|entry| !ours(entry)).cloned().collect();
            if !entries.is_empty() { kept.insert(event.clone(), Value::Array(entries)); }
        } else {
            kept.insert(event.clone(), value.clone());
        }
    }
    if kept.is_empty() { root.remove("hooks"); } else { root.insert("hooks".into(), Value::Object(kept)); }
    Value::Object(root)
}

fn pretty(value: &Value) -> String { serde_json::to_string_pretty(value).unwrap_or_default() }

fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

fn current_fingerprint() -> String {
    fingerprint(&std::fs::read(settings_path()).unwrap_or_default())
}

fn backup_path() -> PathBuf {
    let t = unsafe { GetLocalTime() };
    settings_path().with_file_name(format!(
        "hooks.json.bak-{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    ))
}

pub fn status() -> CodexStatus {
    let current = read().unwrap_or_else(|_| json!({}));
    let installed = current.get("hooks").and_then(Value::as_object).map(|all| {
        all.values().filter_map(Value::as_array).flatten().any(ours)
    }).unwrap_or(false);
    CodexStatus {
        installed,
        settings_path: settings_path().to_string_lossy().to_string(),
        hook_path: settings::hook_exe_path().to_string_lossy().to_string(),
        hook_ready: settings::hook_exe_path().exists(),
    }
}

pub fn preview(install: bool) -> Result<CodexPreview, String> {
    let current = read()?;
    let next = if install { merged(&current) } else { without_ours(&current) };
    Ok(CodexPreview {
        diff: hooks::unified_diff(&pretty(&current), &pretty(&next)),
        backup: backup_path().to_string_lossy().to_string(),
        settings_path: settings_path().to_string_lossy().to_string(),
        fingerprint: current_fingerprint(),
    })
}

pub fn write(install: bool, expected: &str) -> Result<String, String> {
    let path = settings_path();
    let dir = path.parent().unwrap_or(Path::new("."));
    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;
    let current = read()?;
    if current_fingerprint() != expected {
        return Err(format!("{} changed since the preview. Nothing was written.", path.display()));
    }
    let backup = backup_path();
    if path.exists() { std::fs::copy(&path, &backup).map_err(|e| format!("backup failed: {e}"))?; }
    let mut text = pretty(if install { &merged(&current) } else { &without_ours(&current) });
    text.push('\n');
    let temp = path.with_extension(format!("json.coucou-{}", std::process::id()));
    std::fs::write(&temp, text).map_err(|e| format!("write failed: {e}"))?;
    if let Err(err) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("write failed: {err}"));
    }
    Ok(backup.to_string_lossy().to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn merge_preserves_foreign_hooks_and_removal_restores_them() {
        let existing = json!({"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "other.exe"}]}]}});
        let after = merged(&existing);
        assert_eq!(without_ours(&after), existing);
        assert!(after["hooks"]["PermissionRequest"].is_array());
    }

    #[test]
    fn parser_rejects_non_objects() {
        assert!(parse(br#"[]"#, "hooks.json").is_err());
        assert_eq!(parse(b"\xef\xbb\xbf{}", "hooks.json").unwrap(), json!({}));
    }
}
