// Test runs: the double-check of unclear results and the fix loop — dotpals'
// bridge/checker.js and bridge/laya.js, and its "Make agents fix failing tests"
// (MIT, see windows/THIRD_PARTY_NOTICES.md; the question and thresholds come from
// claude-referee, MIT).
//
// Double-check (Settings → Agents → Test results, off by default). A test run
// whose output can't say whether it passed is asked about once:
//   local  Laya (Convai Innovations) on this computer, `laya-serve` on 127.0.0.1.
//          Nothing leaves the computer. "Set up Laya" installs it in a private
//          Python environment in Coucou's folder, and Coucou starts and stops it.
//   cloud  TypeSafe's Jev, with the user's API key (Windows Credential Manager),
//          after removing anything that looks like a key, password, email, IP
//          address or the user's own folder.
// It gets 5 seconds and fails open: no answer changes nothing.
//
// Fix loop (off by default): Claude Code ending its turn while the session's last
// test run failed is sent back to fix them, at most twice per request, as dotpals
// does. The relay waits for that answer only while the loop is on (a marker file
// it can see, `fix-loop.on` in Coucou's folder).

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};

const BUDGET: Duration = Duration::from_secs(5);
pub const JEV_KEY: &str = "typesafe-api-key";
const JEV_URL: &str = "https://api.typesafe.ai";
const JEV_MODEL: &str = "jev-1.13.0";
pub const LAYA_URL: &str = "http://127.0.0.1:8000";
/// Times one request may be sent back (dotpals: at most twice per request).
const MAX_SEND_BACKS: u32 = 2;

/// claude-referee's done.met question, asked about the tests passing.
fn questions() -> Value {
    json!({ "done.met": {
        "type": "noul",
        "instructions": {
            "question": "Does `evidence` show that the tests pass?",
            "note": "`evidence` holds facts parsed from the test command's output (runner, passed, failed, errors, skipped, failing test names) or null when no summary was found, its exit status, the end of the output and the lines that look like failures. A claim of success in prose is not evidence. Zero tests, only skipped tests, a missing summary or a missing exit code do not show that tests pass.",
        },
        "criteria": {
            "true": "The test output directly shows that the tests pass.",
            "false": "The output does not show it, or shows that they fail.",
        },
    } })
}

// ── Settings ──────────────────────────────────────────────────────────────────

struct Config {
    mode: String,
    laya_url: String,
    fix_loop: bool,
}

fn config(app: &AppHandle) -> Config {
    app.try_state::<crate::Shared>()
        .map(|s| {
            let s = s.settings.lock().unwrap();
            Config { mode: s.test_checker.clone(), laya_url: s.laya_url.clone(), fix_loop: s.fix_failing_tests }
        })
        .unwrap_or(Config { mode: "off".into(), laya_url: String::new(), fix_loop: false })
}

fn laya_url(c: &Config) -> String {
    let u = c.laya_url.trim().trim_end_matches('/');
    // Only an address on this computer: Laya is the private option.
    if u.starts_with("http://127.0.0.1:") || u.starts_with("http://localhost:") { u.to_string() } else { LAYA_URL.to_string() }
}

// ── Redaction (before anything goes to the cloud) ─────────────────────────────

fn looks_secret(word: &str) -> bool {
    let w = word.trim_matches(|c: char| !c.is_ascii_alphanumeric());
    // Keys are long runs of mixed-case letters and digits; test names rarely are.
    w.len() >= 24
        && w.chars().all(|c| c.is_ascii_alphanumeric() || "-_.+=".contains(c))
        && w.chars().any(|c| c.is_ascii_uppercase())
        && w.chars().any(|c| c.is_ascii_lowercase())
        && w.chars().any(|c| c.is_ascii_digit())
}

fn looks_email(word: &str) -> bool {
    let w = word.trim_matches(|c: char| !(c.is_ascii_alphanumeric() || c == '@' || c == '.'));
    match w.split_once('@') {
        Some((user, domain)) => !user.is_empty() && domain.contains('.') && !domain.ends_with('.'),
        None => false,
    }
}

fn looks_ip(word: &str) -> bool {
    let w = word.trim_matches(|c: char| !(c.is_ascii_digit() || c == '.'));
    w.split('.').count() == 4 && w.parse::<std::net::Ipv4Addr>().is_ok()
}

const SECRET_NAMES: [&str; 8] = ["password", "passwd", "secret", "token", "api_key", "apikey", "authorization", "bearer"];

/// Where a "name=value" or "name: value" secret starts in a line, if one does.
fn secret_at(lower: &str) -> Option<usize> {
    SECRET_NAMES
        .iter()
        .flat_map(|name| lower.match_indices(name).map(move |(i, _)| (i, name.len())))
        .filter(|(i, len)| {
            let rest = lower[i + len..].trim_start();
            rest.starts_with('=') || rest.starts_with(':') || (lower[*i..].starts_with("bearer") && rest.chars().next().is_some_and(|c| c.is_ascii_alphanumeric()))
        })
        .map(|(i, _)| i)
        .min()
}

/// One line with keys, passwords, emails, IP addresses and the home folder taken out.
pub fn redact_line(line: &str, home: &str) -> String {
    let mut out = if home.len() > 3 { line.replace(home, "~") } else { line.to_string() };
    if let Some(i) = secret_at(&out.to_ascii_lowercase()) {
        // "password=hunter2", "Authorization: Bearer x": everything after the name goes.
        out = format!("{}[redacted]", &out[..i]);
    }
    out.split(' ')
        .map(|w| if looks_email(w) || looks_ip(w) || looks_secret(w) { "[redacted]" } else { w })
        .collect::<Vec<_>>()
        .join(" ")
}

pub fn redact(value: &Value, home: &str) -> Value {
    match value {
        Value::String(s) => Value::String(s.split('\n').map(|l| redact_line(l, home)).collect::<Vec<_>>().join("\n")),
        Value::Array(a) => Value::Array(a.iter().map(|v| redact(v, home)).collect()),
        Value::Object(m) => Value::Object(m.iter().map(|(k, v)| (k.clone(), redact(v, home))).collect()),
        other => other.clone(),
    }
}

// ── Asking ────────────────────────────────────────────────────────────────────

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Answer {
    /// "laya" or "jev".
    pub by: String,
    /// P(the tests pass), 0…1.
    pub p: Option<f64>,
    pub model: Option<String>,
    pub error: Option<String>,
    pub ms: u64,
}

fn client() -> reqwest::Client {
    reqwest::Client::builder().timeout(BUDGET).no_proxy().build().unwrap_or_default()
}

fn jev_client() -> reqwest::Client {
    reqwest::Client::builder().timeout(BUDGET).build().unwrap_or_default()
}

/// A short, safe reason: never the raw error, which could echo the request.
fn reason(by: &str, status: Option<u16>, timed_out: bool) -> String {
    use crate::i18n::t;
    if timed_out {
        return t("no answer within 5 s");
    }
    match (by, status) {
        ("jev", Some(401 | 403)) => t("TypeSafe didn't accept the API key"),
        (_, Some(429)) => t("too many requests right now"),
        ("jev", Some(_)) => t("TypeSafe answered with an error"),
        (_, Some(_)) => t("Laya answered with an error"),
        ("jev", None) => t("couldn't reach TypeSafe"),
        _ => t("couldn't reach Laya: is it running?"),
    }
}

async fn ask(by: &str, url: &str, key: Option<&str>, body: &Value) -> Result<(f64, Option<String>), String> {
    let req = if by == "jev" {
        jev_client().post(format!("{JEV_URL}/v1/systemone")).bearer_auth(key.unwrap_or_default())
    } else {
        client().post(format!("{url}/v1/systemone"))
    };
    let res = req.json(body).send().await.map_err(|e| reason(by, None, e.is_timeout()))?;
    let status = res.status().as_u16();
    if !res.status().is_success() {
        return Err(reason(by, Some(status), false));
    }
    let data: Value = res.json().await.map_err(|_| crate::i18n::t("gave no probability"))?;
    let p = data.pointer("/answers/done.met/noul").and_then(Value::as_f64).filter(|p| (0.0..=1.0).contains(p));
    let model = data.get("model").and_then(Value::as_str).map(|m| m.chars().take(60).collect());
    p.map(|p| (p, model)).ok_or_else(|| crate::i18n::t("gave no probability"))
}

/// Asks the double-check about one unclear test run. None while it is off.
#[tauri::command]
pub async fn tests_check(app: AppHandle, evidence: Value) -> Option<Answer> {
    let c = config(&app);
    let by = match c.mode.as_str() {
        "local" => "laya",
        "cloud" => "jev",
        _ => return None,
    };
    let started = Instant::now();
    let key = if by == "jev" { crate::secrets::get(JEV_KEY) } else { None };
    if by == "jev" && key.is_none() {
        return Some(Answer { by: by.into(), p: None, model: None, error: Some(crate::i18n::t("no API key: add one in Settings")), ms: 0 });
    }
    let home = std::env::var("USERPROFILE").unwrap_or_default();
    // Laya runs here: the evidence as it is. Jev is in the cloud: redacted first.
    let evidence = if by == "jev" { redact(&evidence, &home) } else { evidence };
    let body = if by == "jev" {
        json!({ "state": { "evidence": evidence }, "questions": questions(), "model": JEV_MODEL })
    } else {
        json!({ "state": { "evidence": evidence }, "questions": questions() })
    };
    let answer = ask(by, &laya_url(&c), key.as_deref(), &body).await;
    let ms = started.elapsed().as_millis() as u64;
    Some(match answer {
        Ok((p, model)) => Answer { by: by.into(), p: Some((p * 1000.0).round() / 1000.0), model, error: None, ms },
        Err(error) => Answer { by: by.into(), p: None, model: None, error: Some(error), ms },
    })
}

/// "Test connection": a tiny request (Laya's /health, Jev's model list).
#[tauri::command]
pub async fn tests_check_ping(app: AppHandle, mode: String) -> Answer {
    let c = config(&app);
    let by = if mode == "cloud" { "jev" } else { "laya" };
    let started = Instant::now();
    let result: Result<(), String> = async {
        let res = if by == "jev" {
            let key = crate::secrets::get(JEV_KEY).ok_or_else(|| crate::i18n::t("no API key: add one in Settings"))?;
            jev_client().get(format!("{JEV_URL}/v1/models")).bearer_auth(key).send().await
        } else {
            client().get(format!("{}/health", laya_url(&c))).send().await
        }
        .map_err(|e| reason(by, None, e.is_timeout()))?;
        if res.status().is_success() { Ok(()) } else { Err(reason(by, Some(res.status().as_u16()), false)) }
    }
    .await;
    let ms = started.elapsed().as_millis() as u64;
    Answer { by: by.into(), p: None, model: None, error: result.err(), ms }
}

// ── Laya on this computer ─────────────────────────────────────────────────────

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct LayaStatus {
    /// idle, python, venv, install, starting, ready, error
    pub phase: String,
    pub message: String,
    /// The last line pip or the server printed.
    pub line: String,
    pub installed: bool,
    pub running: bool,
}

struct Laya {
    status: LayaStatus,
    server: Option<Child>,
    busy: bool,
}

static LAYA: Mutex<Option<Laya>> = Mutex::new(None);

fn laya_dir() -> PathBuf {
    crate::platform::local_dir().join("laya")
}

fn venv_bin(name: &str) -> PathBuf {
    laya_dir().join(".venv").join("Scripts").join(format!("{name}.exe"))
}

fn installed() -> bool {
    venv_bin("laya-serve").is_file()
}

fn with_laya<T>(f: impl FnOnce(&mut Laya) -> T) -> T {
    let mut slot = LAYA.lock().unwrap();
    let laya = slot.get_or_insert_with(|| Laya {
        status: LayaStatus { phase: "idle".into(), message: String::new(), line: String::new(), installed: installed(), running: false },
        server: None,
        busy: false,
    });
    f(laya)
}

fn publish(app: &AppHandle) {
    let status = with_laya(|l| {
        if let Some(child) = l.server.as_mut() {
            if !matches!(child.try_wait(), Ok(None)) {
                l.server = None;
            }
        }
        l.status.installed = installed();
        l.status.running = l.server.is_some();
        l.status.clone()
    });
    let _ = app.emit("laya", status);
}

fn set(app: &AppHandle, phase: &str, message: String) {
    with_laya(|l| {
        l.status.phase = phase.into();
        l.status.message = message;
        l.status.line.clear();
    });
    publish(app);
}

#[cfg(windows)]
fn hidden(cmd: &mut Command) -> &mut Command {
    use std::os::windows::process::CommandExt;
    cmd.creation_flags(0x0800_0000) // CREATE_NO_WINDOW
}

#[cfg(not(windows))]
fn hidden(cmd: &mut Command) -> &mut Command {
    cmd
}

/// Runs a command, the last line of its output reported as it goes. True when it succeeded.
fn run(app: &AppHandle, program: &PathBuf, args: &[&str]) -> (bool, String) {
    use std::io::{BufRead, BufReader};
    let mut cmd = Command::new(program);
    cmd.args(args)
        .current_dir(laya_dir())
        .env("PIP_DISABLE_PIP_VERSION_CHECK", "1")
        .env("PYTHONIOENCODING", "utf-8")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let Ok(mut child) = hidden(&mut cmd).spawn() else { return (false, String::new()) };
    let mut last = String::new();
    if let Some(out) = child.stderr.take() {
        // pip writes progress to stderr: read it in the background, keep the tail.
        let app = app.clone();
        std::thread::spawn(move || {
            for line in BufReader::new(out).lines().map_while(Result::ok) {
                let line = line.trim().chars().take(160).collect::<String>();
                if !line.is_empty() {
                    with_laya(|l| l.status.line = line);
                    publish(&app);
                }
            }
        });
    }
    if let Some(out) = child.stdout.take() {
        for line in BufReader::new(out).lines().map_while(Result::ok) {
            let line = line.trim().chars().take(160).collect::<String>();
            if !line.is_empty() {
                last = line.clone();
                with_laya(|l| l.status.line = line);
                publish(app);
            }
        }
    }
    let ok = child.wait().map(|s| s.success()).unwrap_or(false);
    (ok, last)
}

/// Python 3.10–3.13 (PyTorch, which Laya needs, lags the newest Python): the
/// Windows launcher's versions first, newest first.
fn find_python() -> Option<(PathBuf, Vec<String>)> {
    for v in ["3.12", "3.11", "3.13", "3.10"] {
        let mut cmd = Command::new("py");
        cmd.args([&format!("-{v}"), "--version"]).stdout(Stdio::piped()).stderr(Stdio::piped());
        if hidden(&mut cmd).output().is_ok_and(|o| o.status.success()) {
            return Some((PathBuf::from("py"), vec![format!("-{v}")]));
        }
    }
    let mut cmd = Command::new("python");
    cmd.args(["-c", "import sys; print(sys.version_info[:2])"]).stdout(Stdio::piped()).stderr(Stdio::piped());
    let out = hidden(&mut cmd).output().ok()?;
    let v = String::from_utf8_lossy(&out.stdout);
    ["(3, 10)", "(3, 11)", "(3, 12)", "(3, 13)"].iter().any(|ok| v.trim() == *ok).then(|| (PathBuf::from("python"), Vec::new()))
}

/// "Set up Laya": a private Python environment, `pip install "laya[serve]"`, then start it.
#[tauri::command]
pub fn laya_setup(app: AppHandle) {
    if with_laya(|l| std::mem::replace(&mut l.busy, true)) {
        return;
    }
    std::thread::spawn(move || {
        use crate::i18n::t;
        let done = |app: &AppHandle| {
            with_laya(|l| l.busy = false);
            publish(app);
        };
        let _ = std::fs::create_dir_all(laya_dir());
        set(&app, "python", t("Looking for Python 3.10 to 3.13…"));
        let Some((python, args)) = find_python() else {
            set(&app, "error", t("No Python 3.10 to 3.13 was found. Install Python 3.12 from python.org, then set up Laya again."));
            done(&app);
            return;
        };
        set(&app, "venv", t("Making a private Python environment for Laya…"));
        let venv = laya_dir().join(".venv");
        let _ = std::fs::remove_dir_all(&venv);
        let mut a: Vec<&str> = args.iter().map(String::as_str).collect();
        let venv_s = venv.to_string_lossy().to_string();
        a.extend(["-m", "venv", venv_s.as_str()]);
        if !run(&app, &python, &a).0 || !venv_bin("python").is_file() {
            set(&app, "error", t("Python couldn't make the environment."));
            done(&app);
            return;
        }
        set(&app, "install", t("Installing Laya and PyTorch (a few GB, once)…"));
        let py = venv_bin("python");
        let _ = run(&app, &py, &["-m", "pip", "install", "--upgrade", "--quiet", "pip"]);
        let (ok, _) = run(&app, &py, &["-m", "pip", "install", "--progress-bar", "off", "laya[serve]"]);
        if !ok || !installed() {
            set(&app, "error", t("Installing Laya failed. Check your connection and try again."));
            done(&app);
            return;
        }
        done(&app);
        start_server(&app);
    });
}

fn start_server(app: &AppHandle) {
    use crate::i18n::t;
    if !installed() || with_laya(|l| l.server.is_some()) {
        publish(app);
        return;
    }
    let port = laya_url(&config(app)).rsplit(':').next().and_then(|p| p.parse::<u16>().ok()).unwrap_or(8000);
    let hf = laya_dir().join("hf");
    let log = std::fs::File::create(laya_dir().join("laya.log")).ok();
    let mut cmd = Command::new(venv_bin("laya-serve"));
    cmd.current_dir(laya_dir())
        // Only this computer, never every network (Laya's own default is 0.0.0.0).
        .env("LAYA_HOST", "127.0.0.1")
        .env("LAYA_PORT", port.to_string())
        .env("LAYA_MODELS", "english")
        .env("HF_HOME", &hf)
        .env("HF_HUB_DISABLE_TELEMETRY", "1")
        .env("PYTHONUNBUFFERED", "1")
        .env("PYTHONIOENCODING", "utf-8")
        .env_remove("LAYA_API_KEY")
        .stdin(Stdio::null());
    match &log {
        Some(f) => {
            cmd.stdout(f.try_clone().map(Stdio::from).unwrap_or(Stdio::null()));
            cmd.stderr(f.try_clone().map(Stdio::from).unwrap_or(Stdio::null()));
        }
        None => {
            cmd.stdout(Stdio::null()).stderr(Stdio::null());
        }
    }
    match hidden(&mut cmd).spawn() {
        Ok(child) => {
            with_laya(|l| l.server = Some(child));
            let first = !hf.join("hub").exists();
            set(app, "starting", if first { t("Starting Laya. The first time it downloads its model (about 850 MB)…") } else { t("Starting Laya…") });
            let app = app.clone();
            std::thread::spawn(move || {
                // Up to 20 minutes for the first model download, then ready.
                for _ in 0..600 {
                    std::thread::sleep(Duration::from_secs(2));
                    if !with_laya(|l| l.server.is_some()) {
                        return;
                    }
                    let url = format!("http://127.0.0.1:{port}/health");
                    let ok = tauri::async_runtime::block_on(async move {
                        let c = reqwest::Client::builder().timeout(Duration::from_secs(3)).no_proxy().build().ok()?;
                        c.get(url).send().await.ok().map(|r| r.status().is_success())
                    })
                    .unwrap_or(false);
                    if ok {
                        set(&app, "ready", t("Laya is ready on this computer."));
                        return;
                    }
                }
                set(&app, "error", t("Laya didn't start. See laya.log in Coucou's folder."));
            });
        }
        Err(_) => set(app, "error", t("Laya couldn't be started.")),
    }
}

fn stop_server() {
    if let Some(mut child) = with_laya(|l| l.server.take()) {
        // laya-serve.exe starts python.exe: the whole tree goes.
        let mut kill = Command::new("taskkill");
        kill.args(["/PID", &child.id().to_string(), "/T", "/F"]).stdout(Stdio::null()).stderr(Stdio::null());
        let _ = hidden(&mut kill).status();
        let _ = child.kill();
        let _ = child.wait();
    }
}

#[tauri::command]
pub fn laya_status(app: AppHandle) -> LayaStatus {
    publish(&app);
    with_laya(|l| l.status.clone())
}

#[tauri::command]
pub fn laya_start(app: AppHandle) {
    start_server(&app);
}

#[tauri::command]
pub fn laya_stop(app: AppHandle) {
    stop_server();
    set(&app, "idle", String::new());
}

/// "Remove Laya": stops it and deletes its environment and model (its whole folder).
#[tauri::command]
pub fn laya_remove(app: AppHandle) {
    stop_server();
    let _ = std::fs::remove_dir_all(laya_dir());
    set(&app, "idle", String::new());
}

// ── Settings applied ──────────────────────────────────────────────────────────

fn marker() -> PathBuf {
    crate::platform::local_dir().join("fix-loop.on")
}

/// At launch and after every save: Laya runs while the check is Local (once it is
/// installed), the relay's marker follows the fix loop.
pub fn settings_saved(app: &AppHandle) {
    let c = config(app);
    if c.fix_loop {
        let _ = std::fs::write(marker(), b"1");
    } else {
        let _ = std::fs::remove_file(marker());
    }
    if c.mode == "local" && installed() {
        let app = app.clone();
        std::thread::spawn(move || start_server(&app));
    } else {
        stop_server();
    }
}

pub fn shutdown() {
    stop_server();
}

// ── Fix loop ──────────────────────────────────────────────────────────────────

#[derive(Default)]
struct SessionTests {
    /// The last test run failed: its summary ("2 failed: test_sum").
    failing: Option<String>,
    /// Times this request was sent back.
    sent_back: u32,
}

static SESSIONS: Mutex<Option<HashMap<String, SessionTests>>> = Mutex::new(None);

fn with_session<T>(id: &str, f: impl FnOnce(&mut SessionTests) -> T) -> T {
    let mut slot = SESSIONS.lock().unwrap();
    let map = slot.get_or_insert_with(HashMap::new);
    if map.len() > 200 {
        map.clear();
    }
    f(map.entry(id.to_string()).or_default())
}

/// The island read a test run: `failed` with what failed, or passed (clears it).
#[tauri::command]
pub fn tests_note(session_id: String, failed: bool, summary: String) {
    if session_id.is_empty() {
        return;
    }
    with_session(&session_id, |s| s.failing = failed.then(|| summary.chars().take(200).collect()));
}

/// Every hook event goes by here (pipe.rs). A new prompt is a new request: its
/// send-backs start again.
pub fn observe(payload: &Value, event: &str) {
    if event == "UserPromptSubmit" {
        if let Some(id) = payload.get("session_id").and_then(Value::as_str) {
            with_session(id, |s| s.sent_back = 0);
        }
    }
}

/// The fix loop is on (Settings).
pub fn fix_loop_on(app: &AppHandle) -> bool {
    config(app).fix_loop
}

/// Claude Code is ending its turn: the line the relay prints, to send it back
/// when its tests fail, or None. Only Claude Code, only with the loop on.
pub fn stop_reply(app: &AppHandle, payload: &Value) -> Option<String> {
    if !config(app).fix_loop || payload.get("coucou_agent").and_then(Value::as_str).is_some_and(|a| !a.is_empty()) {
        return None;
    }
    let id = payload.get("session_id").and_then(Value::as_str)?;
    stop_decision(id)
}

pub fn stop_decision(session_id: &str) -> Option<String> {
    with_session(session_id, |s| {
        let failing = s.failing.clone()?;
        if s.sent_back >= MAX_SEND_BACKS {
            return None;
        }
        s.sent_back += 1;
        let reason = format!(
            "Coucou: the last test run failed ({failing}). Fix the code so the tests pass, run them again, then finish. Don't change the tests just to make them pass."
        );
        Some(json!({ "decision": "block", "reason": reason }).to_string())
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn secrets_emails_ips_and_home_are_taken_out() {
        let home = r"C:\Users\umar0";
        assert_eq!(redact_line(r"at C:\Users\umar0\app\x.py:3", home), r"at ~\app\x.py:3");
        assert_eq!(redact_line("mail me@example.com now", home), "mail [redacted] now");
        assert_eq!(redact_line("server 192.168.1.20 down", home), "server [redacted] down");
        assert_eq!(redact_line("PASSWORD=hunter2 rest", home), "[redacted]");
        assert_eq!(redact_line("key sk1234567890abcdefXYZ9Qw used", home), "key [redacted] used");
        assert_eq!(redact_line("test_tokenizer FAILED", home), "test_tokenizer FAILED");
        assert_eq!(redact_line("3 passed, 1 failed", home), "3 passed, 1 failed");
        assert_eq!(redact_line("tests/test_math.py::test_sum FAILED", home), "tests/test_math.py::test_sum FAILED");
    }

    #[test]
    fn a_failing_session_is_sent_back_twice_per_request_then_let_go() {
        let id = "s-fix-loop";
        tests_note(id.into(), true, "1 failed: test_sum".into());
        let first: Value = serde_json::from_str(&stop_decision(id).unwrap()).unwrap();
        assert_eq!(first["decision"], "block");
        assert!(first["reason"].as_str().unwrap().contains("1 failed: test_sum"));
        assert!(stop_decision(id).is_some());
        assert!(stop_decision(id).is_none(), "at most twice");
        // A new request starts again; tests passing let it finish.
        observe(&json!({ "session_id": id }), "UserPromptSubmit");
        assert!(stop_decision(id).is_some());
        tests_note(id.into(), false, String::new());
        assert!(stop_decision(id).is_none());
    }

    #[test]
    fn laya_is_only_ever_asked_on_this_computer() {
        let c = |u: &str| Config { mode: "local".into(), laya_url: u.into(), fix_loop: false };
        assert_eq!(laya_url(&c("http://127.0.0.1:9000/")), "http://127.0.0.1:9000");
        assert_eq!(laya_url(&c("https://evil.example.com")), LAYA_URL);
        assert_eq!(laya_url(&c("")), LAYA_URL);
    }
}
