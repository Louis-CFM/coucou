use std::path::{Path, PathBuf};

use serde::Serialize;
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

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorHookPreview {
    pub diff: String,
    pub backup: Option<String>,
    pub settings_path: String,
    pub fingerprint: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CursorHookStatus {
    pub installed: bool,
    pub settings_path: String,
    pub hook_path: String,
    pub hook_ready: bool,
}

const MARKER: &str = "coucou-hook";

pub fn settings_path() -> PathBuf {
    let home = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));

    home.join(".cursor").join("hooks.json")
}

fn read_settings() -> Result<Value, String> {
    let path = settings_path();
    read_settings_at(&path)
}

fn read_settings_at(path: &Path) -> Result<Value, String> {
    match std::fs::read(path) {
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

fn entry_is_ours(entry: &Value) -> bool {
    entry
        .get("command")
        .and_then(Value::as_str)
        .map(|command| {
            command.contains(MARKER) && command.contains("--agent cursor")
        })
        .unwrap_or(false)
}

fn is_installed(existing: &Value) -> bool {
    existing
        .get("hooks")
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
            Some(Value::Array(existing)) => {
                existing.retain(|item| !entry_is_ours(item));
                existing.push(entry);
            }
            _ => {
                hooks.insert((*event).to_string(), Value::Array(vec![entry]));
            }
        }
    }

    root.insert("hooks".into(), Value::Object(hooks));

    Value::Object(root)
}

fn without_ours(existing: &Value) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();

    let Some(existing_hooks) = root
        .get("hooks")
        .and_then(Value::as_object)
        .cloned()
    else {
        return Value::Object(root);
    };

    let mut hooks = serde_json::Map::new();

    for (event, value) in existing_hooks {
        match value {
            Value::Array(entries) => {
                let kept: Vec<Value> = entries
                    .into_iter()
                    .filter(|entry| !entry_is_ours(entry))
                    .collect();

                if !kept.is_empty() {
                    hooks.insert(event, Value::Array(kept));
                }
            }
            other => {
                hooks.insert(event, other);
            }
        }
    }

    if hooks.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(hooks));
    }

    Value::Object(root)
}

fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;

    for byte in bytes {
        hash ^= *byte as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }

    format!("{hash:016x}")
}

fn current_fingerprint() -> String {
    current_fingerprint_at(&settings_path())
}

fn current_fingerprint_at(path: &Path) -> String {
    match std::fs::read(path) {
        Ok(bytes) => fingerprint(&bytes),
        Err(_) => fingerprint(b""),
    }
}

fn pretty(value: &Value) -> String {
    serde_json::to_string_pretty(value).unwrap_or_default()
}

pub fn status() -> CursorHookStatus {
    let current = read_settings().unwrap_or_else(|_| json!({}));
    let hook_path = settings::hook_exe_path();

    CursorHookStatus {
        installed: is_installed(&current),
        settings_path: settings_path().to_string_lossy().to_string(),
        hook_ready: hook_path.exists(),
        hook_path: hook_path.to_string_lossy().to_string(),
    }
}

pub fn preview(install: bool) -> Result<CursorHookPreview, String> {
    let current = read_settings()?;

    let next = if install {
        merged(&current)
    } else {
        without_ours(&current)
    };

    Ok(CursorHookPreview {
        diff: crate::hooks::unified_diff(&pretty(&current), &pretty(&next)),
        backup: settings_path()
            .exists()
            .then(|| backup_path_for(&settings_path()).to_string_lossy().to_string()),
        settings_path: settings_path().to_string_lossy().to_string(),
        fingerprint: current_fingerprint(),
    })
}

fn backup_path_for(path: &Path) -> PathBuf {
    let stamp = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);

    path.with_file_name(format!("hooks.json.bak-{stamp}"))
}

fn write_like(temp: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;

    let mut file = std::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(temp)?;

    file.write_all(bytes)
}

pub fn write(
    install: bool,
    expected_fingerprint: &str,
) -> Result<Option<String>, String> {
    let path = settings_path();
    write_at(&path, install, expected_fingerprint)
}

fn write_at(
    path: &Path,
    install: bool,
    expected_fingerprint: &str,
) -> Result<Option<String>, String> {
    let dir = path.parent().unwrap_or(Path::new("."));

    std::fs::create_dir_all(dir)
        .map_err(|err| format!("Can't create {}: {err}", dir.display()))?;

    let current = read_settings_at(path)?;

    if current_fingerprint_at(path) != expected_fingerprint {
        return Err(format!(
            "{} changed since the preview. Nothing was written.",
            path.display()
        ));
    }

    let backup = if path.exists() {
        let backup = backup_path_for(path);

        std::fs::copy(path, &backup)
            .map_err(|err| format!("Backup failed: {err}"))?;

        Some(backup)
    } else {
        None
    };

    let next = if install {
        merged(&current)
    } else {
        without_ours(&current)
    };

    let mut text = pretty(&next);
    text.push('\n');

    let temp = path.with_extension(format!("json.coucou-{}", std::process::id()));

    if let Err(err) = write_like(&temp, text.as_bytes()) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("Write failed: {err}"));
    }

    if let Err(err) = std::fs::rename(&temp, path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("Write failed: {err}"));
    }

    Ok(backup.map(|path| path.to_string_lossy().to_string()))
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

    #[test]
    fn cursor_hooks_do_not_duplicate_coucou_entries() {
        let once = merged(&json!({}));
        let twice = merged(&once);

        let hooks = twice["hooks"]["preToolUse"].as_array().unwrap();

        assert_eq!(
            hooks.iter().filter(|entry| entry_is_ours(entry)).count(),
            1
        );
    }

    #[test]
    fn removing_cursor_hooks_preserves_other_entries() {
        let existing = json!({
            "version": 1,
            "hooks": {
                "preToolUse": [
                    {
                        "command": "other-tool.exe"
                    },
                    {
                        "command": hook_command()
                    }
                ]
            }
        });

        let config = without_ours(&existing);
        let hooks = config["hooks"]["preToolUse"].as_array().unwrap();

        assert_eq!(hooks.len(), 1);
        assert_eq!(hooks[0]["command"], "other-tool.exe");
    }

    #[test]
    fn cursor_hook_fingerprint_notices_changes() {
        assert_eq!(fingerprint(b"{}"), fingerprint(b"{}"));
        assert_ne!(fingerprint(b"{}"), fingerprint(b"{ }"));
        assert_ne!(fingerprint(b""), fingerprint(b"{}"));
    }

    #[test]
    fn cursor_hook_preview_does_not_modify_source_config() {
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

        let before = pretty(&existing);
        let after = pretty(&merged(&existing));

        assert!(before.contains("other-tool.exe"));
        assert!(after.contains("other-tool.exe"));
        assert!(after.contains("coucou-hook"));
    }

    #[test]
    fn cursor_hook_write_preserves_existing_config_and_creates_backup() {
        let dir = std::env::temp_dir().join(format!(
            "coucou-cursor-hooks-{}",
            std::process::id()
        ));

        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let path = dir.join("hooks.json");

        let original = json!({
            "version": 1,
            "hooks": {
                "preToolUse": [
                    {
                        "command": "other-tool.exe"
                    }
                ]
            }
        });

        let original_text = pretty(&original);
        std::fs::write(&path, &original_text).unwrap();

        let expected = current_fingerprint_at(&path);

        let backup = write_at(&path, true, &expected).unwrap().unwrap();

        let written = read_settings_at(&path).unwrap();
        let hooks = written["hooks"]["preToolUse"].as_array().unwrap();

        assert!(hooks.iter().any(|entry| {
            entry["command"] == "other-tool.exe"
        }));

        assert!(hooks.iter().any(entry_is_ours));

        assert!(Path::new(&backup).exists());

        let backup_bytes = std::fs::read(&backup).unwrap();
        assert_eq!(backup_bytes, original_text.as_bytes());

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn cursor_hook_write_rejects_stale_fingerprint() {
        let dir = std::env::temp_dir().join(format!(
            "coucou-cursor-hooks-stale-{}",
            std::process::id()
        ));

        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let path = dir.join("hooks.json");

        std::fs::write(&path, "{}").unwrap();
        let stale = current_fingerprint_at(&path);

        // Simulate Cursor or the user changing hooks.json after preview.
        std::fs::write(&path, "{\"version\":1}").unwrap();

        let result = write_at(&path, true, &stale);

        assert!(result.is_err());

        let contents = std::fs::read_to_string(&path).unwrap();
        assert_eq!(contents, "{\"version\":1}");

        std::fs::remove_dir_all(&dir).unwrap();
    }

    #[test]
    fn cursor_hook_status_detects_coucou_entry() {
        let config = json!({
            "version": 1,
            "hooks": {
                "preToolUse": [
                    {
                        "command": "\"C:/Coucou/coucou-hook.exe\" --agent cursor"
                    }
                ]
            }
        });

        assert!(is_installed(&config));
        assert!(!is_installed(&json!({})));
    }

    #[test]
    fn cursor_hook_write_without_existing_file_has_no_backup() {
        let dir = std::env::temp_dir().join(format!(
            "coucou-cursor-hooks-new-{}",
            std::process::id()
        ));

        let _ = std::fs::remove_dir_all(&dir);
        std::fs::create_dir_all(&dir).unwrap();

        let path = dir.join("hooks.json");
        let expected = current_fingerprint_at(&path);

        let backup = write_at(&path, true, &expected).unwrap();

        assert!(backup.is_none());
        assert!(path.exists());

        std::fs::remove_dir_all(&dir).unwrap();
    }
}
