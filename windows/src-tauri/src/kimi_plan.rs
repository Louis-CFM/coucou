// Kimi Code plan usage from the local server behind Kimi Code's /usage.
//
// Coucou starts `kimi web --no-open`, discovers its loopback address and bearer
// token from the startup output, asks GET /api/v1/oauth/usage, and stops the
// server it started. The token never leaves this module and no credential file
// is read. Only quota windows reach the webview.

use std::io::{BufRead, BufReader, Read};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{self, AtomicBool};
use std::sync::mpsc;
use std::time::{Duration, Instant};

use serde_json::{json, Map, Value};

use crate::platform;

const STARTUP_TIMEOUT: Duration = Duration::from_secs(15);
const REQUEST_TIMEOUT: Duration = Duration::from_secs(10);
const MAX_LINE: usize = 64 * 1024;
const MAX_TOTAL: usize = 1024 * 1024;

static BUSY: AtomicBool = AtomicBool::new(false);

struct NotBusy;
impl Drop for NotBusy {
    fn drop(&mut self) {
        BUSY.store(false, atomic::Ordering::Release);
    }
}

pub fn read() -> Option<Value> {
    if crate::integrations::PAUSED.load(atomic::Ordering::Relaxed) {
        return None;
    }
    if BUSY.swap(true, atomic::Ordering::AcqRel) {
        return None;
    }
    let _busy = NotBusy;

    let exe = platform::cli_candidates("kimi").into_iter().next()?;
    let mut cmd = Command::new(&exe);
    cmd.args(["web", "--no-open"])
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    if let Some(dir) = exe.parent() {
        let mut dirs = vec![dir.to_path_buf()];
        if let Some(path) = std::env::var_os("PATH") {
            dirs.extend(std::env::split_paths(&path));
        }
        if let Ok(joined) = std::env::join_paths(dirs) {
            cmd.env("PATH", joined);
        }
    }
    platform::no_console(&mut cmd);
    let mut child = cmd.spawn().ok()?;
    let answer = read_from_server(&mut child);
    stop(&mut child);
    answer
}

fn read_from_server(child: &mut Child) -> Option<Value> {
    let (tx, rx) = mpsc::channel();
    stream_lines(child.stdout.take()?, tx.clone());
    stream_lines(child.stderr.take()?, tx);

    let mut base = None;
    let mut token = None;
    let deadline = Instant::now() + STARTUP_TIMEOUT;
    while base.is_none() || token.is_none() {
        let remaining = deadline.checked_duration_since(Instant::now())?;
        let line = rx.recv_timeout(remaining).ok()?;
        startup_details(&line, &mut base, &mut token);
    }

    let response = reqwest::blocking::Client::builder()
        .timeout(REQUEST_TIMEOUT)
        .build()
        .ok()?
        .get(format!("{}/api/v1/oauth/usage", base?))
        .bearer_auth(token?)
        .send()
        .ok()?;
    if !response.status().is_success() {
        return None;
    }
    quota_only(&response.json::<Value>().ok()?)
}

fn stream_lines(reader: impl Read + Send + 'static, tx: mpsc::Sender<String>) {
    std::thread::spawn(move || {
        let mut reader = BufReader::new(reader);
        let mut total = 0usize;
        let mut line = Vec::new();
        while total < MAX_TOTAL {
            line.clear();
            let n = match (&mut reader).take(MAX_LINE as u64 + 1).read_until(b'\n', &mut line) {
                Ok(0) | Err(_) => break,
                Ok(n) => n,
            };
            total += n;
            if line.len() <= MAX_LINE && tx.send(String::from_utf8_lossy(&line).into_owned()).is_err() {
                break;
            }
        }
    });
}

fn stop(child: &mut Child) {
    #[cfg(windows)]
    {
        let mut kill = Command::new("taskkill");
        kill.args(["/T", "/F", "/PID", &child.id().to_string()]);
        platform::no_console(&mut kill);
        let _ = kill.status();
    }
    let _ = child.kill();
    let _ = child.wait();
}

fn startup_details(line: &str, base: &mut Option<String>, token: &mut Option<String>) {
    let lower = line.to_ascii_lowercase();
    for marker in ["http://127.0.0.1:", "http://localhost:"] {
        if let Some(start) = lower.find(marker) {
            let port: String = line[start + marker.len()..].chars().take_while(char::is_ascii_digit).collect();
            if !port.is_empty() {
                *base = Some(format!("http://127.0.0.1:{port}"));
            }
        }
    }
    for marker in ["#token=", "?token=", "token=", "bearer ", "token:"] {
        if let Some(start) = lower.find(marker) {
            let value: String = line[start + marker.len()..]
                .chars()
                .take_while(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '_' | '~' | '-'))
                .collect();
            if !value.is_empty() {
                *token = Some(value);
            }
        }
    }
}

fn quota_only(value: &Value) -> Option<Value> {
    let data = value.get("data")?;
    if data.get("kind").and_then(Value::as_str) != Some("ok") {
        return None;
    }
    let usages = data.get("quota")?.get("usages")?.as_object()?;
    let mut kept = Map::new();
    for key in ["limit5h", "limit7d", "monthTotal", "monthCode"] {
        let Some(window) = usages.get(key).and_then(Value::as_object) else { continue };
        let Some(ratio) = window.get("usedRatio").and_then(Value::as_f64).filter(|v| v.is_finite()) else { continue };
        let mut clean = json!({ "usedRatio": ratio.clamp(0.0, 1.0) });
        if let Some(reset) = window.get("resetAt").and_then(Value::as_str) {
            clean["resetAt"] = json!(reset);
        }
        kept.insert(key.to_string(), clean);
    }
    (!kept.is_empty()).then(|| json!({ "usages": kept }))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn startup_output_gives_an_address_and_a_token_without_logging_it() {
        let mut base = None;
        let mut token = None;
        startup_details("Local: http://127.0.0.1:58628/#token=abc.DEF-123_~", &mut base, &mut token);
        assert_eq!(base.as_deref(), Some("http://127.0.0.1:58628"));
        assert_eq!(token.as_deref(), Some("abc.DEF-123_~"));
    }

    #[test]
    fn separate_bearer_and_localhost_lines_work_too() {
        let mut base = None;
        let mut token = None;
        startup_details("Listening on http://localhost:60000", &mut base, &mut token);
        startup_details("Authorization: Bearer secret-token", &mut base, &mut token);
        assert_eq!(base.as_deref(), Some("http://127.0.0.1:60000"));
        assert_eq!(token.as_deref(), Some("secret-token"));
    }

    #[test]
    fn only_quota_windows_reach_the_webview() {
        let value = json!({
            "code": 0,
            "data": {
                "kind": "ok",
                "quota": {
                    "usages": {
                        "limit5h": { "usedRatio": 0.1464, "resetAt": "2026-11-01T14:50:45Z" },
                        "monthTotal": { "usedRatio": 0.0234, "resetAt": "2026-12-02T00:00:00Z" },
                        "unknown": { "usedRatio": 0.5 }
                    },
                    "extraUsage": { "balanceCents": 100 }
                },
                "user": { "email": "me@example.com" }
            },
            "request_id": "private"
        });
        let kept = quota_only(&value).unwrap();
        assert_eq!(kept["usages"]["limit5h"]["usedRatio"], 0.1464);
        assert_eq!(kept["usages"]["monthTotal"]["usedRatio"], 0.0234);
        assert!(kept["usages"].get("unknown").is_none());
        assert!(kept.get("request_id").is_none());
        assert!(kept.get("user").is_none());
        assert!(kept.get("extraUsage").is_none());
    }

    #[test]
    fn errors_and_broken_windows_are_not_usage() {
        assert!(quota_only(&json!({ "data": { "kind": "error" } })).is_none());
        assert!(quota_only(&json!({ "data": { "kind": "ok", "quota": { "usages": {} } } })).is_none());
        assert!(quota_only(&json!({ "data": { "kind": "ok", "quota": { "usages": {
            "limit5h": { "usedRatio": "half" }
        } } } })).is_none());
    }
}
