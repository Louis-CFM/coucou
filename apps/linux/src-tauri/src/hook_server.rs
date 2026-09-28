use crate::paths;
use crate::resources::NB_HOOK_SCRIPT;
use serde_json::{json, Value};
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::net::{UnixListener, UnixStream};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter};

const PERMISSION_TIMEOUT_SECS: u64 = 115;

pub struct HookServerState {
    pending_hooks: Mutex<Option<Vec<u8>>>,
    pending_permissions: Mutex<HashMap<String, Arc<Mutex<UnixStream>>>>,
}

impl HookServerState {
    pub fn new() -> Self {
        Self {
            pending_hooks: Mutex::new(None),
            pending_permissions: Mutex::new(HashMap::new()),
        }
    }
}

pub fn install_hook_script() {
    let _ = paths::ensure();
    let script_path = paths::hook_script_path();
    if std::fs::write(&script_path, NB_HOOK_SCRIPT).is_ok() {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&script_path, std::fs::Permissions::from_mode(0o755));
    }
}

fn log_line(message: &str) {
    let _ = paths::ensure();
    let path = paths::log_path();
    let now = chrono::Local::now().format("%Y-%m-%d %H:%M:%S");
    let line = format!("{now} {message}\n");
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
    {
        let _ = f.write_all(line.as_bytes());
    }
}

fn send_line(stream: &mut UnixStream, text: &str) {
    let line = format!("{text}\n");
    let _ = stream.write_all(line.as_bytes());
    let _ = stream.flush();
}

fn read_json_line(stream: &mut UnixStream) -> Option<Value> {
    let mut raw = Vec::new();
    let mut buf = [0u8; 4096];
    loop {
        match stream.read(&mut buf) {
            Ok(0) => break,
            Ok(n) => {
                for &b in &buf[..n] {
                    if b == b'\n' {
                        return serde_json::from_slice(&raw).ok();
                    }
                    raw.push(b);
                }
            }
            Err(_) => break,
        }
    }
    if raw.is_empty() {
        None
    } else {
        serde_json::from_slice(&raw).ok()
    }
}

fn permission_key(payload: &Value) -> String {
    payload
        .get("session_id")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .or_else(|| payload.get("id").and_then(|v| v.as_str()))
        .unwrap_or("unknown")
        .to_string()
}

fn deny_all_pending(state: &HookServerState) {
    let drained: Vec<Arc<Mutex<UnixStream>>> = {
        let mut map = state.pending_permissions.lock().unwrap();
        map.drain().map(|(_, v)| v).collect()
    };
    for stream in drained {
        if let Ok(mut s) = stream.lock() {
            send_line(&mut s, r#"{"permissionDecision":"deny"}"#);
        }
    }
}

fn handle_client(
    mut stream: UnixStream,
    app: AppHandle,
    state: Arc<HookServerState>,
) {
    let payload = match read_json_line(&mut stream) {
        Some(v) => v,
        None => {
            send_line(&mut stream, r#"{"ok":true}"#);
            return;
        }
    };

    let event_name = payload
        .get("hook_event_name")
        .and_then(|v| v.as_str())
        .unwrap_or("");

    let _ = app.emit("hook-event", payload.clone());

    if event_name == "PermissionRequest" {
        let key = permission_key(&payload);
        log_line(&format!("PermissionRequest session={key}"));

        deny_all_pending(&state);

        let shared = Arc::new(Mutex::new(stream));
        {
            let mut map = state.pending_permissions.lock().unwrap();
            map.insert(key.clone(), Arc::clone(&shared));
        }

        let app_timeout = app.clone();
        let state_timeout = Arc::clone(&state);
        thread::spawn(move || {
            thread::sleep(Duration::from_secs(PERMISSION_TIMEOUT_SECS));
            let removed = {
                let mut map = state_timeout.pending_permissions.lock().unwrap();
                map.remove(&key)
            };
            if let Some(stream) = removed {
                if let Ok(mut s) = stream.lock() {
                    send_line(&mut s, r#"{"permissionDecision":"deny"}"#);
                }
                let _ = app_timeout.emit("hook-permission-timeout", json!({ "session_id": key }));
            }
        });
    } else {
        send_line(&mut stream, r#"{"ok":true}"#);
    }
}

fn server_thread(app: AppHandle, state: Arc<HookServerState>) {
    let path = paths::socket_path();
    let _ = paths::ensure();
    let _ = std::fs::remove_file(&path);

    let listener = match UnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            log_line(&format!("socket bind failed: {e}"));
            return;
        }
    };

    log_line(&format!("listening on {}", path.display()));

    for stream in listener.incoming() {
        match stream {
            Ok(client) => {
                let app = app.clone();
                let state = Arc::clone(&state);
                thread::spawn(move || handle_client(client, app, state));
            }
            Err(e) => {
                log_line(&format!("accept error: {e}"));
            }
        }
    }
}

pub fn start(app: AppHandle, state: Arc<HookServerState>) {
    install_hook_script();
    thread::spawn(move || server_thread(app, state));
}

fn claude_settings_path() -> std::path::PathBuf {
    dirs::home_dir()
        .unwrap_or_else(|| std::path::PathBuf::from("."))
        .join(".claude/settings.json")
}

fn is_coucou_hook_command(cmd: &str) -> bool {
    cmd.contains("coucou") || cmd.contains("NotchBuddy")
}

fn hook_command_string(hook_path: &std::path::Path) -> String {
    let escaped = hook_path.to_string_lossy().replace('"', "\\\"");
    format!("\"{escaped}\"")
}

fn build_hooks_data() -> Result<Vec<u8>, String> {
    let settings_path = claude_settings_path();
    let mut settings: Value = if settings_path.exists() {
        let data = std::fs::read(&settings_path).map_err(|e| e.to_string())?;
        serde_json::from_slice(&data).unwrap_or(json!({}))
    } else {
        json!({})
    };
    if !settings.is_object() {
        settings = json!({});
    }

    let hook_path = paths::hook_script_path();
    let quoted = hook_command_string(&hook_path);

    let events = [
        "SessionStart",
        "SessionEnd",
        "UserPromptSubmit",
        "PreToolUse",
        "PostToolUse",
        "PostToolUseFailure",
        "PermissionRequest",
        "Notification",
        "Stop",
        "StopFailure",
        "SubagentStart",
        "SubagentStop",
    ];

    let hooks_obj = settings
        .as_object_mut()
        .ok_or_else(|| "settings root must be object".to_string())?;

    let hooks = hooks_obj
        .entry("hooks")
        .or_insert_with(|| json!({}))
        .as_object_mut()
        .ok_or_else(|| "hooks must be object".to_string())?;

    for event in events {
        let existing = hooks.entry(event).or_insert_with(|| json!([]));
        let matchers = existing
            .as_array_mut()
            .ok_or_else(|| format!("hooks.{event} must be array"))?;

        matchers.retain(|matcher| {
            !matcher_matches_coucou(matcher)
        });

        let already = matchers.iter().any(|matcher| {
            nested_commands(matcher)
                .iter()
                .any(|c| is_coucou_hook_command(c))
        });

        if !already {
            matchers.push(json!({
                "hooks": [{
                    "type": "command",
                    "command": quoted.clone(),
                    "timeout": 10
                }]
            }));
        }
    }

    serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())
}

fn nested_commands(matcher: &Value) -> Vec<String> {
    matcher
        .get("hooks")
        .and_then(|h| h.as_array())
        .map(|arr| {
            arr.iter()
                .filter_map(|h| h.get("command").and_then(|c| c.as_str()).map(str::to_string))
                .collect()
        })
        .unwrap_or_default()
}

fn matcher_matches_coucou(matcher: &Value) -> bool {
    nested_commands(matcher)
        .iter()
        .any(|c| is_coucou_hook_command(c))
}

#[tauri::command]
pub fn preview_claude_hooks(state: tauri::State<'_, HookServerState>) -> Result<String, String> {
    let data = build_hooks_data()?;
    *state.pending_hooks.lock().unwrap() = Some(data.clone());
    String::from_utf8(data).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn write_claude_hooks(state: tauri::State<'_, HookServerState>) -> Result<(), String> {
    let data = state
        .pending_hooks
        .lock()
        .unwrap()
        .take()
        .ok_or_else(|| "call preview_claude_hooks first".to_string())?;

    let settings_path = claude_settings_path();
    if settings_path.exists() {
        let stamp = chrono::Local::now().format("%Y%m%d-%H%M");
        let backup = settings_path
            .parent()
            .unwrap_or(settings_path.as_path())
            .join(format!("settings.json.bak-{stamp}"));
        let _ = std::fs::copy(&settings_path, backup);
    }

    if let Some(parent) = settings_path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    std::fs::write(&settings_path, &data).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn uninstall_claude_hooks() -> Result<(), String> {
    let settings_path = claude_settings_path();
    let data = std::fs::read(&settings_path).map_err(|e| e.to_string())?;
    let mut settings: Value = serde_json::from_slice(&data).map_err(|e| e.to_string())?;

    let hooks = settings
        .get_mut("hooks")
        .and_then(|h| h.as_object_mut())
        .ok_or_else(|| "no hooks in settings".to_string())?;

    let keys: Vec<String> = hooks.keys().cloned().collect();
    for key in keys {
        if let Some(matchers) = hooks.get_mut(&key).and_then(|m| m.as_array_mut()) {
            matchers.retain(|matcher| !matcher_matches_coucou(matcher));
            if matchers.is_empty() {
                hooks.remove(&key);
            }
        }
    }

    let out = serde_json::to_vec_pretty(&settings).map_err(|e| e.to_string())?;
    std::fs::write(&settings_path, out).map_err(|e| e.to_string())?;
    Ok(())
}

#[tauri::command]
pub fn hooks_installed() -> bool {
    let settings_path = claude_settings_path();
    let Ok(data) = std::fs::read(&settings_path) else {
        return false;
    };
    let Ok(settings) = serde_json::from_slice::<Value>(&data) else {
        return false;
    };
    let Some(hooks) = settings.get("hooks").and_then(|h| h.as_object()) else {
        return false;
    };
    hooks.values().any(|matchers| {
        matchers
            .as_array()
            .map(|arr| arr.iter().any(|m| matcher_matches_coucou(m)))
            .unwrap_or(false)
    })
}

#[tauri::command]
pub fn permission_decision(
    state: tauri::State<'_, HookServerState>,
    session_id: String,
    decision: String,
) -> Result<(), String> {
    let stream = {
        let mut map = state.pending_permissions.lock().unwrap();
        map.remove(&session_id)
    };

    let Some(stream) = stream else {
        return Err(format!("no pending permission for session {session_id}"));
    };

    let json_line = match decision.as_str() {
        "allow" => r#"{"permissionDecision":"allow"}"#,
        "always" => r#"{"permissionDecision":"allow","alwaysAllow":true}"#,
        _ => r#"{"permissionDecision":"deny"}"#,
    };

    if let Ok(mut s) = stream.lock() {
        send_line(&mut s, json_line);
    }
    Ok(())
}
