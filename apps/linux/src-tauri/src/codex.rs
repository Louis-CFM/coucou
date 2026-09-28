//! Official OpenAI Codex bridge (Python openai-codex SDK over JSONL stdio).
//! Frontend only receives safe auth state — never tokens.

use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;
use tauri::{AppHandle, Emitter, Manager, State};

static REQ_SEQ: AtomicU64 = AtomicU64::new(1);

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CodexAuthState {
    pub authenticated: bool,
    pub account_label: Option<String>,
    pub provider: String,
    pub status: String,
    pub error: Option<String>,
    pub login_id: Option<String>,
    pub auth_url: Option<String>,
    pub verification_url: Option<String>,
    pub user_code: Option<String>,
    pub mode: Option<String>,
}

impl Default for CodexAuthState {
    fn default() -> Self {
        Self {
            authenticated: false,
            account_label: None,
            provider: "openai-codex".into(),
            status: "disconnected".into(),
            error: None,
            login_id: None,
            auth_url: None,
            verification_url: None,
            user_code: None,
            mode: None,
        }
    }
}

struct BridgeProcess {
    child: Child,
    stdin: std::process::ChildStdin,
    /// Responses keyed by request id
    pending: Arc<Mutex<std::collections::HashMap<String, std::sync::mpsc::Sender<Value>>>>,
}

pub struct CodexState {
    inner: Mutex<Option<BridgeProcess>>,
    auth: Mutex<CodexAuthState>,
    python: Mutex<Option<PathBuf>>,
}

impl CodexState {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(None),
            auth: Mutex::new(CodexAuthState::default()),
            python: Mutex::new(None),
        }
    }
}

fn bridge_script_path(app: &AppHandle) -> Result<PathBuf, String> {
    // Dev: relative to crate; release: resource
    let candidates = [
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../codex-bridge/bridge.py"),
        app.path()
            .resource_dir()
            .map(|p| p.join("codex-bridge/bridge.py"))
            .unwrap_or_default(),
    ];
    for c in candidates {
        if c.exists() {
            return Ok(c);
        }
    }
    Err("Codex bridge script not found".into())
}

fn resolve_python(app: &AppHandle) -> Result<PathBuf, String> {
    // Prefer project venv that has openai-codex installed
    let venv = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../.venv-codex/bin/python");
    if venv.exists() {
        return Ok(venv);
    }
    if let Ok(p) = std::env::var("COUCOU_CODEX_PYTHON") {
        let pb = PathBuf::from(p);
        if pb.exists() {
            return Ok(pb);
        }
    }
    // Fallback: python3 (may lack openai-codex)
    which_python().ok_or_else(|| {
        format!(
            "Codex runtime unavailable (install openai-codex in apps/linux/.venv-codex). bridge={:?}",
            bridge_script_path(app).ok()
        )
    })
}

fn which_python() -> Option<PathBuf> {
    for name in ["python3", "python"] {
        if let Ok(out) = Command::new("which").arg(name).output() {
            if out.status.success() {
                let p = String::from_utf8_lossy(&out.stdout).trim().to_string();
                if !p.is_empty() {
                    return Some(PathBuf::from(p));
                }
            }
        }
    }
    None
}

fn ensure_bridge(app: &AppHandle, state: &CodexState) -> Result<(), String> {
    let mut guard = state.inner.lock().map_err(|e| e.to_string())?;
    if guard.is_some() {
        return Ok(());
    }
    let python = resolve_python(app)?;
    *state.python.lock().map_err(|e| e.to_string())? = Some(python.clone());
    let script = bridge_script_path(app)?;

    let mut child = Command::new(&python)
        .arg(&script)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .map_err(|e| format!("Codex runtime unavailable: {e}"))?;

    let stdin = child.stdin.take().ok_or("no stdin")?;
    let stdout = child.stdout.take().ok_or("no stdout")?;
    let stderr = child.stderr.take();

    let pending: Arc<Mutex<std::collections::HashMap<String, std::sync::mpsc::Sender<Value>>>> =
        Arc::new(Mutex::new(std::collections::HashMap::new()));
    let pending_r = Arc::clone(&pending);
    let app_r = app.clone();

    thread::spawn(move || {
        let reader = BufReader::new(stdout);
        for line in reader.lines().flatten() {
            if let Ok(v) = serde_json::from_str::<Value>(&line) {
                if let Some(id) = v.get("id").and_then(|x| x.as_str()) {
                    if let Ok(mut map) = pending_r.lock() {
                        if let Some(tx) = map.remove(id) {
                            let _ = tx.send(v.clone());
                        }
                    }
                }
                // Forward agent_state / progress events (never tokens)
                if v.get("event").and_then(|e| e.as_str()) == Some("agent_state") {
                    let _ = app_r.emit("codex-agent-state", v);
                }
            }
        }
    });

    if let Some(err) = stderr {
        thread::spawn(move || {
            let reader = BufReader::new(err);
            for line in reader.lines().flatten() {
                // Bridge already redacts; just mirror to stderr for `tauri dev`
                eprintln!("{line}");
            }
        });
    }

    *guard = Some(BridgeProcess {
        child,
        stdin,
        pending,
    });
    Ok(())
}

fn request(state: &CodexState, mut body: Value, timeout_ms: u64) -> Result<Value, String> {
    let id = REQ_SEQ.fetch_add(1, Ordering::SeqCst).to_string();
    body.as_object_mut()
        .ok_or("body must be object")?
        .insert("id".into(), json!(id));

    let (tx, rx) = std::sync::mpsc::channel();
    {
        let mut guard = state.inner.lock().map_err(|e| e.to_string())?;
        let proc = guard.as_mut().ok_or("Codex bridge not started")?;
        proc.pending
            .lock()
            .map_err(|e| e.to_string())?
            .insert(id.clone(), tx);
        let line = serde_json::to_string(&body).map_err(|e| e.to_string())? + "\n";
        proc.stdin
            .write_all(line.as_bytes())
            .map_err(|e| e.to_string())?;
        proc.stdin.flush().map_err(|e| e.to_string())?;
    }

    rx.recv_timeout(Duration::from_millis(timeout_ms))
        .map_err(|_| "Authentication timed out".to_string())
}

fn open_default_browser(url: &str) -> Result<(), String> {
    // Never log the URL (may contain sensitive query params)
    let status = Command::new("xdg-open")
        .arg(url)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map_err(|e| format!("Could not open browser: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        // Fallbacks
        for cmd in ["gio", "kde-open5", "gnome-open"] {
            let mut c = Command::new(cmd);
            if cmd == "gio" {
                c.args(["open", url]);
            } else {
                c.arg(url);
            }
            if c.stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .status()
                .map(|s| s.success())
                .unwrap_or(false)
            {
                return Ok(());
            }
        }
        Err("Could not open browser".into())
    }
}

fn apply_status_response(state: &CodexState, resp: &Value) -> CodexAuthState {
    let mut auth = CodexAuthState::default();
    auth.authenticated = resp
        .get("authenticated")
        .and_then(|v| v.as_bool())
        .unwrap_or(false);
    auth.account_label = resp
        .get("accountLabel")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    auth.provider = "openai-codex".into();
    auth.status = if auth.authenticated {
        "connected".into()
    } else {
        "disconnected".into()
    };
    if let Some(err) = resp.get("error").and_then(|v| v.as_str()) {
        if !resp.get("ok").and_then(|v| v.as_bool()).unwrap_or(true) {
            auth.error = Some(err.to_string());
            auth.status = "error".into();
        }
    }
    if let Ok(mut g) = state.auth.lock() {
        *g = auth.clone();
    }
    auth
}

pub fn refresh_auth_on_startup(app: AppHandle) {
    thread::spawn(move || {
        let state = app.state::<CodexState>();
        if ensure_bridge(&app, &state).is_err() {
            return;
        }
        if let Ok(resp) = request(&state, json!({"cmd": "status"}), 15_000) {
            let auth = apply_status_response(&state, &resp);
            let _ = app.emit("codex-auth", &auth);
        }
    });
}

#[tauri::command]
pub fn codex_status(app: AppHandle, state: State<'_, CodexState>) -> Result<CodexAuthState, String> {
    ensure_bridge(&app, &state)?;
    let resp = request(&state, json!({"cmd": "status"}), 15_000)?;
    let auth = apply_status_response(&state, &resp);
    let _ = app.emit("codex-auth", &auth);
    Ok(auth)
}

#[tauri::command]
pub fn codex_login_chatgpt(
    app: AppHandle,
    state: State<'_, CodexState>,
) -> Result<CodexAuthState, String> {
    ensure_bridge(&app, &state)?;
    let resp = request(&state, json!({"cmd": "login_chatgpt"}), 30_000)?;
    if !resp.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        let err = resp
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("Codex runtime unavailable")
            .to_string();
        let mut auth = CodexAuthState::default();
        auth.status = "error".into();
        auth.error = Some(err.clone());
        *state.auth.lock().map_err(|e| e.to_string())? = auth.clone();
        return Err(err);
    }
    let auth_url = resp
        .get("authUrl")
        .and_then(|v| v.as_str())
        .ok_or("Could not obtain authentication URL")?
        .to_string();
    let login_id = resp
        .get("loginId")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    if let Err(e) = open_default_browser(&auth_url) {
        let mut auth = CodexAuthState::default();
        auth.status = "error".into();
        auth.error = Some(e.clone());
        auth.login_id = Some(login_id.clone());
        auth.auth_url = Some(auth_url.clone());
        *state.auth.lock().map_err(|e| e.to_string())? = auth.clone();
        let _ = app.emit("codex-auth", &auth);
        // Still allow manual open via returned URL in UI — but do not leave tokens in UI beyond auth URL from official flow
        return Ok(auth);
    }

    let mut auth = CodexAuthState::default();
    auth.status = "waiting".into();
    auth.login_id = Some(login_id.clone());
    auth.mode = Some("browser".into());
    // Intentionally omit auth_url from persisted UI state after successful open (user already in browser)
    *state.auth.lock().map_err(|e| e.to_string())? = auth.clone();
    let _ = app.emit("codex-auth", &auth);

    // Async wait in background — never block UI thread beyond this command return
    let app2 = app.clone();
    let login_id2 = login_id;
    thread::spawn(move || {
        let st = app2.state::<CodexState>();
        match request(
            &st,
            json!({"cmd": "login_wait", "loginId": login_id2}),
            300_000,
        ) {
            Ok(resp) => {
                let mut auth = CodexAuthState::default();
                if resp.get("ok").and_then(|v| v.as_bool()).unwrap_or(false)
                    && resp
                        .get("authenticated")
                        .and_then(|v| v.as_bool())
                        .unwrap_or(false)
                {
                    auth.authenticated = true;
                    auth.status = "connected".into();
                    auth.account_label = resp
                        .get("accountLabel")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                } else {
                    auth.status = "disconnected".into();
                    auth.error = resp
                        .get("error")
                        .and_then(|v| v.as_str())
                        .map(|s| s.to_string());
                }
                if let Ok(mut g) = st.auth.lock() {
                    *g = auth.clone();
                }
                let _ = app2.emit("codex-auth", &auth);
            }
            Err(e) => {
                let mut auth = CodexAuthState::default();
                auth.status = "error".into();
                auth.error = Some(e);
                if let Ok(mut g) = st.auth.lock() {
                    *g = auth.clone();
                }
                let _ = app2.emit("codex-auth", &auth);
            }
        }
    });

    Ok(auth)
}

#[tauri::command]
pub fn codex_login_device_code(
    app: AppHandle,
    state: State<'_, CodexState>,
) -> Result<CodexAuthState, String> {
    ensure_bridge(&app, &state)?;
    let resp = request(&state, json!({"cmd": "login_device_code"}), 30_000)?;
    if !resp.get("ok").and_then(|v| v.as_bool()).unwrap_or(false) {
        return Err(resp
            .get("error")
            .and_then(|v| v.as_str())
            .unwrap_or("Device-code login unavailable")
            .to_string());
    }
    let login_id = resp
        .get("loginId")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();
    let verification_url = resp
        .get("verificationUrl")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());
    let user_code = resp
        .get("userCode")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    if let Some(ref url) = verification_url {
        let _ = open_default_browser(url);
    }

    let mut auth = CodexAuthState::default();
    auth.status = "waiting".into();
    auth.mode = Some("device_code".into());
    auth.login_id = Some(login_id.clone());
    auth.verification_url = verification_url;
    auth.user_code = user_code;
    *state.auth.lock().map_err(|e| e.to_string())? = auth.clone();
    let _ = app.emit("codex-auth", &auth);

    let app2 = app.clone();
    thread::spawn(move || {
        let st = app2.state::<CodexState>();
        if let Ok(resp) = request(
            &st,
            json!({"cmd": "login_wait", "loginId": login_id}),
            300_000,
        ) {
            let mut auth = CodexAuthState::default();
            auth.authenticated = resp
                .get("authenticated")
                .and_then(|v| v.as_bool())
                .unwrap_or(false);
            auth.status = if auth.authenticated {
                "connected".into()
            } else {
                "disconnected".into()
            };
            auth.account_label = resp
                .get("accountLabel")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            auth.error = resp
                .get("error")
                .and_then(|v| v.as_str())
                .map(|s| s.to_string());
            if let Ok(mut g) = st.auth.lock() {
                *g = auth.clone();
            }
            let _ = app2.emit("codex-auth", &auth);
        }
    });

    Ok(auth)
}

#[tauri::command]
pub fn codex_login_cancel(
    app: AppHandle,
    state: State<'_, CodexState>,
    login_id: String,
) -> Result<CodexAuthState, String> {
    let _ = ensure_bridge(&app, &state);
    let _ = request(
        &state,
        json!({"cmd": "login_cancel", "loginId": login_id}),
        10_000,
    );
    let mut auth = CodexAuthState::default();
    auth.status = "disconnected".into();
    auth.error = Some("Authentication cancelled".into());
    *state.auth.lock().map_err(|e| e.to_string())? = auth.clone();
    let _ = app.emit("codex-auth", &auth);
    Ok(auth)
}

#[tauri::command]
pub fn codex_logout(app: AppHandle, state: State<'_, CodexState>) -> Result<CodexAuthState, String> {
    ensure_bridge(&app, &state)?;
    let _ = request(&state, json!({"cmd": "logout"}), 15_000)?;
    let mut auth = CodexAuthState::default();
    auth.status = "disconnected".into();
    *state.auth.lock().map_err(|e| e.to_string())? = auth.clone();
    let _ = app.emit("codex-auth", &auth);
    Ok(auth)
}

#[tauri::command]
pub fn codex_get_auth_state(state: State<'_, CodexState>) -> CodexAuthState {
    state
        .auth
        .lock()
        .map(|g| g.clone())
        .unwrap_or_default()
}

#[tauri::command]
pub fn codex_run_prompt(
    app: AppHandle,
    state: State<'_, CodexState>,
    prompt: String,
    cwd: Option<String>,
) -> Result<Value, String> {
    ensure_bridge(&app, &state)?;
    // Long timeout for agent turns
    request(
        &state,
        json!({"cmd": "thread_run", "prompt": prompt, "cwd": cwd}),
        600_000,
    )
}
