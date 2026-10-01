// Named-pipe server for coucou-hook.
//
// `\\.\pipe\coucou-<sid>` — one instance per connection. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same pipe, which is how approving from the island works.
//
// Claude Code is never blocked by us. Three things guarantee it:
//   * coucou-hook gives the connection 300 ms and exits cleanly if we are closed;
//   * we only wait for a human once the island has *confirmed* the card is on
//     screen, so a paused island or a webview that is not listening costs a few
//     hundred milliseconds, not two minutes;
//   * whatever happens we drop the connection after the decision timeout, and
//     the terminal takes over.
//
// What we write back is the bare word `allow` or `deny`. Turning that into the
// documented hookSpecificOutput JSON is coucou-hook's job, so the wire format
// Claude Code expects lives in exactly one place.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
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
const MAX_PAYLOAD: usize = 1 << 20;
const READ_TIMEOUT: Duration = Duration::from_secs(2);

/// What the island can say about a permission request.
pub enum Reply {
    /// The card is on screen and a human can act on it.
    Ack,
    /// A human clicked: `allow` or `deny`.
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
    let key = crate::win_user::current_user_sid()
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
    let Some(mut payload) = read_payload(&mut pipe, READ_TIMEOUT).await else { return };

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    if event != "PermissionRequest" {
        log::line(format!("hook {event}"));
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        let _ = pipe.disconnect();
        return;
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
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    let _ = pipe.disconnect();
}

/// Read one bounded frame. A client that never sends EOF/newline gets no
/// permanent server task, and exceeding the size limit rejects the whole frame.
async fn read_payload<R: AsyncRead + Unpin>(reader: &mut R, timeout: Duration) -> Option<Value> {
    tokio::time::timeout(timeout, async {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            let n = reader.read(&mut chunk).await.ok()?;
            if n == 0 { break; }
            if buf.len() + n > MAX_PAYLOAD { return None; }
            buf.extend_from_slice(&chunk[..n]);
            if buf.contains(&b'\n') { break; }
        }
        let line = &buf[..buf.iter().position(|b| *b == b'\n').unwrap_or(buf.len())];
        let payload: Value = serde_json::from_slice(line).ok()?;
        payload.is_object().then_some(payload)
    }).await.ok().flatten()
}

/// Two waits: a short one for "the card is up", then the long one for a human.
async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>) -> Option<String> {
    let decision = receive_decision(rx, ACK_TIMEOUT, DECISION_TIMEOUT).await;
    log::line(format!("hook id={id} {}", if decision.is_some() { "answered explicitly" } else { "released without a decision" }));
    decision
}

async fn receive_decision(rx: &mut mpsc::Receiver<Reply>, ack: Duration, decision: Duration) -> Option<String> {
    match tokio::time::timeout(ack, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            return answer_word(&d).map(str::to_owned);
        }
        Ok(Some(Reply::Decline)) => {
            return None;
        }
        Ok(None) => return None,
        Err(_) => {
            return None;
        }
    }

    match tokio::time::timeout(decision, rx.recv()).await {
        Ok(Some(Reply::Decision(d))) => {
            answer_word(&d).map(str::to_owned)
        }
        Ok(Some(Reply::Decline)) => {
            None
        }
        _ => {
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
/// it into Claude Code's JSON is coucou-hook's job.
pub fn answer(app: &AppHandle, request_id: &str, decision: &str) {
    let Some(word) = answer_word(decision) else { return };
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false);
}

fn answer_word(decision: &str) -> Option<&'static str> {
    match decision {
        "allow" | "always" => Some("allow"),
        "deny" => Some("deny"),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn runtime() -> tokio::runtime::Runtime {
        tokio::runtime::Builder::new_current_thread().enable_time().build().unwrap()
    }

    #[test]
    fn malformed_decisions_do_not_become_implicit_denials() {
        assert_eq!(answer_word("allow"), Some("allow"));
        assert_eq!(answer_word("deny"), Some("deny"));
        assert_eq!(answer_word("always"), Some("allow"));
        for word in ["", "ask", "unknown", "ALLOW", " allow"] { assert_eq!(answer_word(word), None); }
    }

    #[test]
    fn pipe_frames_reject_malformed_and_oversized_input() {
        runtime().block_on(async {
            for input in [b"invalid".to_vec(), b"[]".to_vec(), b"null".to_vec(), vec![b' '; MAX_PAYLOAD + 1]] {
                assert!(read_payload(&mut input.as_slice(), READ_TIMEOUT).await.is_none());
            }
            let payload = read_payload(&mut br#"{"hook_event_name":"Stop"}"#.as_slice(), READ_TIMEOUT).await.unwrap();
            assert_eq!(payload["hook_event_name"], "Stop");
        });
    }

    #[test]
    fn stalled_pipe_reader_times_out_without_a_payload() {
        struct Stalled;
        impl AsyncRead for Stalled {
            fn poll_read(self: std::pin::Pin<&mut Self>, _: &mut std::task::Context<'_>, _: &mut tokio::io::ReadBuf<'_>) -> std::task::Poll<std::io::Result<()>> {
                std::task::Poll::Pending
            }
        }
        runtime().block_on(async {
            assert!(read_payload(&mut Stalled, Duration::from_millis(10)).await.is_none());
        });
    }

    #[test]
    fn only_explicit_decisions_survive_ack_decline_and_timeout() {
        runtime().block_on(async {
            let timeout = Duration::from_millis(10);
            for replies in [vec![Reply::Decision("allow".into())], vec![Reply::Ack, Reply::Decision("deny".into())],
                            vec![Reply::Ack, Reply::Decline], vec![Reply::Decision("invalid".into())], vec![]] {
                let expected = match replies.last() { Some(Reply::Decision(d)) => answer_word(d).map(str::to_owned), _ => None };
                let (tx, mut rx) = mpsc::channel(4);
                for reply in replies { tx.send(reply).await.unwrap(); }
                assert_eq!(receive_decision(&mut rx, timeout, timeout).await, expected);
            }
            let (tx, mut rx) = mpsc::channel(4);
            tx.send(Reply::Ack).await.unwrap();
            assert_eq!(receive_decision(&mut rx, timeout, timeout).await, None);
        });
    }
}
