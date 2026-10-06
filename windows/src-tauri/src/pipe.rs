// Named-pipe server for coucou-hook.
//
// `\\.\pipe\coucou-<sid>` — one instance per connection. Valid events are
// forwarded to the island as `hook` events; malformed/oversized frames and
// tagged permission requests from anyone but Codex are rejected. An untagged
// Claude or a `coucou_agent: "codex"` `PermissionRequest` holds the connection
// for a possible island decision. Kimi and Hermes approvals arrive as the
// display-only `ApprovalNotice` observer event and are never answered.
//
// The relay budgets 300 ms to connect and 2 s for observer events. Permission
// requests first need an island acknowledgement (800 ms), then can wait for a
// human decision (108 s server / 110 s relay). Without a decision, the relay
// prints nothing and the agent shows its own approval prompt.
//
// What we write back is one line: the bare word `allow` or `deny`, or for a
// Claude `AskUserQuestion` the picked labels by question index,
// `{"answers":[["label"],["a","b"]]}`. Turning that into the documented
// hookSpecificOutput JSON is coucou-hook's job, so the wire format Claude Code
// expects lives in exactly one place.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::mpsc;

use crate::island::WINDOW_LABEL;
use crate::log;

/// Slightly under coucou-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// How long the island gets to say "the card is up". This is the whole of B4:
/// without it, an island that is paused, hidden behind a crashed webview or
/// simply not listening would leave Claude Code staring at a prompt nobody can
/// see for nearly two minutes.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const FRAME_TIMEOUT: Duration = Duration::from_secs(2);
const MAX_PAYLOAD: usize = 1 << 20;

#[derive(Debug)]
enum FrameError {
    Io,
    Timeout,
    TooLarge,
    Invalid,
}

fn parse_hook_frame(line: &[u8]) -> Result<Value, FrameError> {
    if line.len() > MAX_PAYLOAD {
        return Err(FrameError::TooLarge);
    }
    let frame = line.strip_suffix(b"\n").unwrap_or(line);
    let payload: Value = serde_json::from_slice(frame).map_err(|_| FrameError::Invalid)?;
    let map = payload.as_object().ok_or(FrameError::Invalid)?;
    let event = map.get("hook_event_name").and_then(Value::as_str)
        .filter(|event| !event.trim().is_empty()).ok_or(FrameError::Invalid)?;
    if let Some(agent) = map.get("coucou_agent") {
        let valid = agent.as_str().is_some_and(|name| {
            !name.is_empty() && name.len() <= 24 && name != "claude"
                && name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-')
        });
        // Codex is the one tagged agent whose PermissionRequest can be answered.
        if !valid || (event == "PermissionRequest" && agent.as_str() != Some("codex")) {
            return Err(FrameError::Invalid);
        }
    }
    Ok(payload)
}

async fn read_hook_frame<R: tokio::io::AsyncRead + Unpin>(reader: &mut R) -> Result<Value, FrameError> {
    tokio::time::timeout(FRAME_TIMEOUT, async {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = reader.read(&mut chunk).await.map_err(|_| FrameError::Io)?;
            if n == 0 {
                return parse_hook_frame(&buf);
            }
            let end = chunk[..n].iter().position(|b| *b == b'\n');
            let part = &chunk[..end.map_or(n, |i| i + 1)];
            if part.len() > MAX_PAYLOAD - buf.len() {
                return Err(FrameError::TooLarge);
            }
            buf.extend_from_slice(part);
            if end.is_some() {
                return parse_hook_frame(&buf);
            }
        }
    }).await.map_err(|_| FrameError::Timeout)?
}

/// What the island can say about a permission request.
pub enum Reply {
    /// The card is on screen and a human can act on it.
    Ack,
    /// A human clicked: `allow`, `deny`, or an `{"answers":…}` line.
    Decision(String),
    /// Nobody can act on it — paused, or another request already holds the card.
    Decline,
}

/// Permission requests the island has been told about.
#[derive(Default)]
pub struct Pending(pub Mutex<HashMap<String, mpsc::Sender<Reply>>>);

static COUNTER: AtomicU64 = AtomicU64::new(1);

/// `\\.\pipe\coucou-<sid>` — must match coucou-hook's `pipe_path()` exactly.
pub fn pipe_name() -> String {
    let key = crate::platform::current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let name = pipe_name();
        // first_pipe_instance also means we refuse to join a pipe somebody else
        // already owns under our name, rather than serving on top of it.
        let mut server = match ServerOptions::new().first_pipe_instance(true).create(&name) {
            Ok(s) => s,
            Err(err) => {
                log::line(format!("cannot open the relay pipe: {err}"));
                return;
            }
        };
        loop {
            if server.connect().await.is_err() {
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
            // Hand the connected instance to a task and listen on a fresh one.
            let next = match ServerOptions::new().create(&name) {
                Ok(s) => s,
                Err(err) => {
                    log::line(format!("cannot reopen the relay pipe: {err}"));
                    return;
                }
            };
            let connected = std::mem::replace(&mut server, next);
            let app = app.clone();
            tauri::async_runtime::spawn(async move { handle(app, connected).await });
        }
    });
}

async fn handle(app: AppHandle, mut pipe: NamedPipeServer) {
    let Ok(mut payload) = read_hook_frame(&mut pipe).await else { return };
    let event = payload["hook_event_name"].as_str().unwrap().to_string();

    if event != "PermissionRequest" {
        if let Some(agent) = payload.get("coucou_agent").and_then(Value::as_str) {
            crate::agent_hooks::mark_live(agent);
        }
        log::line("hook event received");
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        let _ = pipe.disconnect();
        return;
    }

    if let Some(agent) = payload.get("coucou_agent").and_then(Value::as_str) {
        crate::agent_hooks::mark_live(agent);
    }
    let id = format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    {
        let pending = app.state::<Pending>();
        pending.0.lock().unwrap().insert(id.clone(), tx);
    }
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);

    let decision = wait_for_decision(&id, &mut rx).await;
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    // No decision: say nothing at all. coucou-hook then writes nothing to stdout
    // and the agent (Claude Code or Codex) asks itself, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    let _ = pipe.disconnect();
}

/// The log names the kind of reply, never the picked labels.
fn decision_label(d: &str) -> &str {
    if d.starts_with('{') { "answers" } else { d }
}

/// Two waits: a short one for "the card is up", then the long one for a human.
async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>) -> Option<String> {
    match tokio::time::timeout(ACK_TIMEOUT, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", decision_label(&d)));
            return Some(d);
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return None;
        }
        Ok(None) => return None,
        Err(_) => {
            log::line(format!("hook id={id} island never acknowledged — terminal takes over"));
            return None;
        }
    }

    match tokio::time::timeout(DECISION_TIMEOUT, rx.recv()).await {
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", decision_label(&d)));
            Some(d)
        }
        Ok(Some(Reply::Decline)) => {
            log::line(format!("hook id={id} released without a decision"));
            None
        }
        _ => {
            log::line(format!("hook id={id} timed out — terminal takes over"));
            None
        }
    }
}

fn send(app: &AppHandle, request_id: &str, reply: Reply, keep: bool) {
    let sender = {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        if keep { map.get(request_id).cloned() } else { map.remove(request_id) }
    };
    match sender {
        Some(tx) => {
            let _ = tx.try_send(reply);
        }
        None => log::line(format!("reply for id={request_id} — no pending request")),
    }
}

/// The island has the card on screen; the long wait may begin.
pub fn acknowledge(app: &AppHandle, request_id: &str) {
    send(app, request_id, Reply::Ack, true);
}

/// Nobody can act on this one — paused, or another card already holds the view.
pub fn decline(app: &AppHandle, request_id: &str) {
    log::line(format!("decline id={request_id}"));
    send(app, request_id, Reply::Decline, false);
}

/// Called by the island's Allow / Deny buttons. Only ever a bare word: turning
/// it into the agent's hook JSON is coucou-hook's job.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let word = match decision {
        "allow" | "always" => "allow",
        _ => "deny",
    };
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false);
}

/// Longest answer line; coucou-hook rejects anything over the same bound.
const MAX_ANSWER: usize = 64 * 1024;

/// The island's picks for a Claude `AskUserQuestion`, one label list per
/// question in order, as the single line coucou-hook validates. Only the shape
/// is checked here; whether each label is a real option is the relay's call,
/// against its own untruncated copy of the questions.
fn answers_line(answers: &[Vec<String>]) -> Option<String> {
    if answers.is_empty() || answers.iter().any(Vec::is_empty) {
        return None;
    }
    let line = json!({ "answers": answers }).to_string();
    (line.len() <= MAX_ANSWER && !line.contains('\n')).then_some(line)
}

/// Called by the question card's Submit. Malformed input sends nothing, and the
/// request is released so Claude Code asks in its own interface.
pub fn answer_questions(app: &AppHandle, request_id: &str, answers: &[Vec<String>]) {
    match answers_line(answers) {
        Some(line) => {
            log::line(format!("decision id={request_id} answers={}", answers.len()));
            send(app, request_id, Reply::Decision(line), false);
        }
        None => {
            log::line(format!("decision id={request_id} answers rejected"));
            send(app, request_id, Reply::Decline, false);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_oversized_unterminated_frame() {
        assert!(parse_hook_frame(&vec![b'x'; MAX_PAYLOAD + 1]).is_err());
    }

    #[test]
    fn rejects_oversized_object_even_with_newline() {
        let mut line = format!(r#"{{"hook_event_name":"Stop","data":"{}"}}"#, "x".repeat(MAX_PAYLOAD)).into_bytes();
        line.push(b'\n');
        assert!(parse_hook_frame(&line).is_err());
    }

    #[test]
    fn rejects_exact_payload_limit_when_newline_exceeds_limit() {
        let prefix = br#"{"hook_event_name":"Stop","data":""#;
        let suffix = b"\"}";
        let mut line = prefix.to_vec();
        line.extend(vec![b'x'; MAX_PAYLOAD - prefix.len() - suffix.len()]);
        line.extend_from_slice(suffix);
        line.push(b'\n');
        assert!(matches!(parse_hook_frame(&line), Err(FrameError::TooLarge)));
    }

    #[test]
    fn rejects_non_object_and_empty_event() {
        assert!(parse_hook_frame(br#"[{"hook_event_name":"Stop"}]"#).is_err());
        assert!(parse_hook_frame(br#"{"hook_event_name":""}"#).is_err());
        assert!(parse_hook_frame(br#"{"hook_event_name":"   "}"#).is_err());
    }

    #[test]
    fn rejects_invalid_or_reserved_agent_without_falling_back_to_claude() {
        for agent in ["", "claude", "Claude", "other_agent", "a.b", "abcdefghijklmnopqrstuvwxy"] {
            let frame = serde_json::json!({"hook_event_name": "Stop", "coucou_agent": agent}).to_string();
            assert!(parse_hook_frame(frame.as_bytes()).is_err(), "accepted {agent:?}");
        }
        assert!(parse_hook_frame(br#"{"hook_event_name":"Stop","coucou_agent":null}"#).is_err());
    }

    #[test]
    fn only_claude_and_codex_permission_requests_are_accepted() {
        assert!(parse_hook_frame(br#"{"hook_event_name":"PermissionRequest","coucou_agent":"kimi-code"}"#).is_err());
        assert!(parse_hook_frame(br#"{"hook_event_name":"PermissionRequest","coucou_agent":"hermes"}"#).is_err());
        assert!(parse_hook_frame(br#"{"hook_event_name":"PermissionRequest"}"#).is_ok());
        assert!(parse_hook_frame(br#"{"hook_event_name":"PermissionRequest","coucou_agent":"codex"}"#).is_ok());
        // Display-only notices are ordinary observer events.
        assert!(parse_hook_frame(br#"{"hook_event_name":"ApprovalNotice","coucou_agent":"kimi-code"}"#).is_ok());
    }

    #[test]
    fn accepts_legacy_claude_and_valid_tag() {
        assert_eq!(parse_hook_frame(br#"{"hook_event_name":"PermissionRequest"}"#).unwrap()["hook_event_name"], "PermissionRequest");
        assert_eq!(parse_hook_frame(br#"{"hook_event_name":"Stop","coucou_agent":"kimi-code"}"#).unwrap()["coucou_agent"], "kimi-code");
        let agent = "a".repeat(24);
        let frame = serde_json::json!({"hook_event_name": "Stop", "coucou_agent": agent}).to_string();
        assert!(parse_hook_frame(frame.as_bytes()).is_ok());
    }

    #[test]
    fn read_does_not_accept_oversized_line_before_newline() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (mut writer, mut reader) = tokio::io::duplex(MAX_PAYLOAD + 256);
            let mut frame = format!(r#"{{"hook_event_name":"Stop","data":"{}"}}"#, "x".repeat(MAX_PAYLOAD)).into_bytes();
            frame.push(b'\n');
            writer.write_all(&frame).await.unwrap();
            assert!(matches!(read_hook_frame(&mut reader).await, Err(FrameError::TooLarge)));
        });
    }

    #[test]
    fn read_rejects_frame_when_newline_exceeds_limit() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (mut writer, mut reader) = tokio::io::duplex(MAX_PAYLOAD + 2);
            let prefix = br#"{"hook_event_name":"Stop","data":""#;
            let suffix = b"\"}";
            let mut frame = prefix.to_vec();
            frame.extend(vec![b'x'; MAX_PAYLOAD - prefix.len() - suffix.len()]);
            frame.extend_from_slice(suffix);
            frame.push(b'\n');
            writer.write_all(&frame).await.unwrap();
            assert!(matches!(read_hook_frame(&mut reader).await, Err(FrameError::TooLarge)));
        });
    }

    #[test]
    fn read_accepts_exact_payload_limit_without_newline() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (mut writer, mut reader) = tokio::io::duplex(MAX_PAYLOAD + 2);
            let prefix = br#"{"hook_event_name":"Stop","data":""#;
            let suffix = b"\"}";
            let mut frame = prefix.to_vec();
            frame.extend(vec![b'x'; MAX_PAYLOAD - prefix.len() - suffix.len()]);
            frame.extend_from_slice(suffix);
            writer.write_all(&frame).await.unwrap();
            drop(writer);
            assert_eq!(read_hook_frame(&mut reader).await.unwrap()["hook_event_name"], "Stop");
        });
    }

    #[test]
    fn read_accepts_exact_payload_limit_with_newline() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (mut writer, mut reader) = tokio::io::duplex(MAX_PAYLOAD + 2);
            let prefix = br#"{"hook_event_name":"Stop","data":""#;
            let suffix = b"\"}";
            let mut frame = prefix.to_vec();
            frame.extend(vec![b'x'; MAX_PAYLOAD - prefix.len() - suffix.len() - 1]);
            frame.extend_from_slice(suffix);
            frame.push(b'\n');
            writer.write_all(&frame).await.unwrap();
            assert_eq!(read_hook_frame(&mut reader).await.unwrap()["hook_event_name"], "Stop");
        });
    }

    #[test]
    fn read_times_out_on_incomplete_frame() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (mut writer, mut reader) = tokio::io::duplex(64);
            writer.write_all(br#"{"hook_event_name":"Stop""#).await.unwrap();
            assert!(matches!(read_hook_frame(&mut reader).await, Err(FrameError::Timeout)));
        });
    }

    #[test]
    fn answers_line_is_one_bounded_line_indexed_by_question() {
        let line = answers_line(&[vec!["Anime cel video".into()], vec!["a".into(), "b".into()]]).unwrap();
        assert_eq!(line, r#"{"answers":[["Anime cel video"],["a","b"]]}"#);
        let multiline = answers_line(&[vec!["two\nlines".into()]]).unwrap();
        assert!(!multiline.contains('\n'));
        assert!(answers_line(&[]).is_none());
        assert!(answers_line(&[vec!["a".into()], vec![]]).is_none());
        assert!(answers_line(&[vec!["x".repeat(MAX_ANSWER)]]).is_none());
        assert_eq!(decision_label(&line), "answers");
        assert_eq!(decision_label("deny"), "deny");
    }

    #[test]
    fn read_accepts_newline_delimited_frame() {
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let (mut writer, mut reader) = tokio::io::duplex(64);
            writer.write_all(b"{\"hook_event_name\":\"Stop\"}\n").await.unwrap();
            assert_eq!(read_hook_frame(&mut reader).await.unwrap()["hook_event_name"], "Stop");
        });
    }
}
