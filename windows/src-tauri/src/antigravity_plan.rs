// Antigravity plan usage — fetched from the running Antigravity 2.0 desktop app.
//
// Coucou asks the local language server started by the Antigravity desktop app:
// `https://127.0.0.1:<port>/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary`
// with the session's CSRF token. No external network requests are made, no passwords
// or credentials leave the machine, and nothing extra is installed.
// Runs only when the pill is shown or clicked, at most once per minute.

use std::path::PathBuf;
use std::sync::atomic::{self, AtomicBool};
use std::time::Duration;

use serde_json::Value;

const TIMEOUT: Duration = Duration::from_secs(5);

static BUSY: AtomicBool = AtomicBool::new(false);

struct NotBusy;
impl Drop for NotBusy {
    fn drop(&mut self) {
        BUSY.store(false, atomic::Ordering::Release);
    }
}

/// Discovers the running port from main.log.
fn find_port() -> Option<u16> {
    #[cfg(windows)]
    let log_path = {
        let appdata = std::env::var_os("APPDATA")?;
        PathBuf::from(appdata).join("antigravity").join("logs").join("main.log")
    };
    #[cfg(not(windows))]
    let log_path = {
        let home = std::env::var_os("HOME")?;
        PathBuf::from(home).join(".config").join("antigravity").join("logs").join("main.log")
    };

    let bytes = std::fs::read(&log_path).ok()?;
    // Read the last 64 KB of the log where the latest start/restart line is.
    let start = bytes.len().saturating_sub(64 * 1024);
    let text = String::from_utf8_lossy(&bytes[start..]);

    // Matches `https://127.0.0.1:(\d+)`
    let mut last_port = None;
    for line in text.lines() {
        if let Some(pos) = line.find("https://127.0.0.1:") {
            let rest = &line[pos + "https://127.0.0.1:".len()..];
            let digits: String = rest.chars().take_while(|c| c.is_ascii_digit()).collect();
            if let Ok(p) = digits.parse::<u16>() {
                last_port = Some(p);
            }
        }
    }
    last_port
}

/// Discovers the CSRF token from the running `language_server` process command line.
fn find_csrf_token() -> Option<String> {
    #[cfg(windows)]
    {
        use std::process::Command;
        let mut cmd = Command::new("powershell.exe");
        cmd.args([
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            "(Get-CimInstance Win32_Process -Filter 'Name = ''language_server.exe''').CommandLine",
        ]);
        crate::platform::no_console(&mut cmd);
        let output = cmd.output().ok()?;
        if !output.status.success() {
            return None;
        }
        let stdout = String::from_utf8_lossy(&output.stdout);
        extract_csrf_token(&stdout)
    }
    #[cfg(not(windows))]
    {
        // Linux: read /proc/<pid>/cmdline for language_server
        let entries = std::fs::read_dir("/proc").ok()?;
        for entry in entries.flatten() {
            let path = entry.path().join("cmdline");
            if let Ok(bytes) = std::fs::read(&path) {
                let cmdline = String::from_utf8_lossy(&bytes).replace('\0', " ");
                if cmdline.contains("language_server") {
                    if let Some(token) = extract_csrf_token(&cmdline) {
                        return Some(token);
                    }
                }
            }
        }
        None
    }
}

fn extract_csrf_token(cmdline: &str) -> Option<String> {
    let marker = "--csrf_token";
    let pos = cmdline.find(marker)?;
    let rest = cmdline[pos + marker.len()..].trim_start();
    let token: String = rest.chars().take_while(|c| c.is_ascii_alphanumeric() || *c == '-').collect();
    if token.is_empty() {
        None
    } else {
        Some(token)
    }
}

pub async fn read() -> Option<Value> {
    if crate::integrations::PAUSED.load(atomic::Ordering::Relaxed) {
        return None;
    }
    if BUSY.swap(true, atomic::Ordering::AcqRel) {
        return None;
    }
    let _busy = NotBusy;

    let port = find_port()?;
    let csrf = find_csrf_token()?;

    let client = reqwest::Client::builder()
        .danger_accept_invalid_certs(true)
        .timeout(TIMEOUT)
        .build()
        .ok()?;

    let url = format!(
        "https://127.0.0.1:{port}/exa.language_server_pb.LanguageServerService/RetrieveUserQuotaSummary"
    );

    let res = client
        .post(&url)
        .header("Content-Type", "application/json")
        .header("x-codeium-csrf-token", &csrf)
        .body("{}")
        .send()
        .await
        .ok()?;

    if !res.status().is_success() {
        return None;
    }

    res.json::<Value>().await.ok()
}
