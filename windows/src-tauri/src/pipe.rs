// Named-pipe server for coucou-hook.
//
// `\\.\pipe\coucou-<sid>` — one instance per connection. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same pipe, which is how approving from the island works.
//
// The provider is never blocked by us. Three things guarantee it:
//   * coucou-hook gives the connection 300 ms and exits cleanly if we are closed;
//   * we only wait for a human once the island has *confirmed* the card is on
//     screen, so a paused island or a webview that is not listening costs a few
//     hundred milliseconds, not two minutes;
//   * whatever happens we drop the connection after the decision timeout, and
//     the terminal takes over.
//
// What we write back is the bare choice. Turning it into provider-specific hook
// JSON is coucou-hook's job, so wire formats live in exactly one place.

use std::collections::HashMap;
use std::future::Future;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::{Duration, Instant};

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
/// The relay sends at most 256 KiB. Keep its first read bounded even if a client
/// connects and stops halfway through a message.
const INITIAL_READ_TIMEOUT: Duration = Duration::from_secs(2);
const DECISION_WRITE_TIMEOUT: Duration = Duration::from_secs(1);
const MAX_PAYLOAD: usize = 256 << 10;

#[derive(Clone, Debug, Default, PartialEq, Eq)]
struct RequestIdentity {
    provider: Option<String>,
    session_id: Option<String>,
    turn_id: Option<String>,
}

impl RequestIdentity {
    fn from_payload(payload: &Value) -> Self {
        fn string_field(payload: &Value, key: &str) -> Option<String> {
            payload.get(key).and_then(Value::as_str).map(str::to_owned)
        }

        Self {
            provider: string_field(payload, "provider"),
            session_id: string_field(payload, "session_id"),
            turn_id: string_field(payload, "turn_id"),
        }
    }

    fn closed_event(&self, request_id: &str, resolution: &str) -> Value {
        let mut event = json!({
            "hook_event_name": "PermissionRequestClosed",
            "request_id": request_id,
            "resolution": resolution,
        });
        let object = event.as_object_mut().expect("event is an object");
        if let Some(provider) = &self.provider {
            object.insert("provider".into(), json!(provider));
        }
        if let Some(session_id) = &self.session_id {
            object.insert("session_id".into(), json!(session_id));
        }
        if let Some(turn_id) = &self.turn_id {
            object.insert("turn_id".into(), json!(turn_id));
        }
        event
    }
}

#[derive(Clone)]
struct PendingRequest {
    sender: mpsc::Sender<Reply>,
    identity: RequestIdentity,
}

/// What the island can say about a permission request.
#[derive(Debug, PartialEq, Eq)]
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
pub struct Pending(Mutex<HashMap<String, PendingRequest>>);

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
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    let read_result = tokio::time::timeout(INITIAL_READ_TIMEOUT, async {
        loop {
            match pipe.read(&mut chunk).await {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    if buf.contains(&b'\n') || buf.len() > MAX_PAYLOAD {
                        break;
                    }
                }
                Err(_) => return false,
            }
        }
        true
    })
    .await;
    if !matches!(read_result, Ok(true)) || buf.len() > MAX_PAYLOAD {
        return;
    }
    let Some(mut payload) = parse_frame(&buf) else {
        return;
    };

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

    let id = format!(
        "{}-{}",
        std::process::id(),
        COUNTER.fetch_add(1, Ordering::Relaxed)
    );
    let identity = RequestIdentity::from_payload(&payload);
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    let pending_request = PendingRequest {
        sender: tx,
        identity,
    };
    {
        let pending = app.state::<Pending>();
        pending
            .0
            .lock()
            .unwrap()
            .insert(id.clone(), pending_request.clone());
    }
    let identity = pending_request.identity.clone();
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);

    let outcome = wait_for_decision(&id, &mut rx, &mut pipe).await;
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    // No decision: say nothing at all. coucou-hook then writes nothing to stdout
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    let resolution = match outcome {
        WaitOutcome::Decision(d) => {
            let resolution = applied_decision(identity.provider.as_deref(), &d);
            let write_result = tokio::time::timeout(DECISION_WRITE_TIMEOUT, async {
                pipe.write_all(format!("{d}\n").as_bytes()).await?;
                pipe.flush().await
            })
            .await;
            if matches!(write_result, Ok(Ok(()))) {
                resolution
            } else {
                "disconnected"
            }
        }
        WaitOutcome::Closed(reason) => reason,
    };
    let _ = app.emit_to(WINDOW_LABEL, "hook", identity.closed_event(&id, resolution));
    let _ = pipe.disconnect();
}

fn parse_frame(bytes: &[u8]) -> Option<Value> {
    if bytes.len() > MAX_PAYLOAD {
        return None;
    }
    let newline = bytes.iter().position(|byte| *byte == b'\n')?;
    // One connection carries one hook invocation. Reject a second frame or any
    // trailing bytes so the disconnect watcher never loses data consumed with
    // the initial frame and mistakes the remaining wait for an open client.
    if newline + 1 != bytes.len() {
        return None;
    }
    let payload = serde_json::from_slice::<Value>(&bytes[..newline]).ok()?;
    payload.is_object().then_some(payload)
}

#[derive(Debug, PartialEq, Eq)]
enum WaitOutcome {
    Decision(String),
    Closed(&'static str),
}

#[derive(Debug, PartialEq, Eq)]
enum RelaySignal {
    Reply(Reply),
    ReplyClosed,
    Disconnected,
    TimedOut,
}

/// Wait for a decision while also watching for the hook process to go away.
/// Reading EOF is important: an exited provider must not leave a stale card on
/// screen for the full decision budget.
async fn receive_signal<R>(
    rx: &mut mpsc::Receiver<Reply>,
    reader: R,
    timeout: Duration,
) -> RelaySignal
where
    R: Future<Output = std::io::Result<usize>>,
{
    let received = tokio::time::timeout(timeout, async {
        tokio::select! {
            biased;
            reply = rx.recv() => match reply {
                Some(reply) => RelaySignal::Reply(reply),
                None => RelaySignal::ReplyClosed,
            },
            result = reader => {
                match result {
                    // There should be no bytes after the initial request. Treat
                    // unexpected data as a broken connection and fail open.
                    Ok(_) | Err(_) => RelaySignal::Disconnected,
                }
            }
        }
    })
    .await;
    received.unwrap_or(RelaySignal::TimedOut)
}

async fn wait_for_decision(
    id: &str,
    rx: &mut mpsc::Receiver<Reply>,
    pipe: &mut NamedPipeServer,
) -> WaitOutcome {
    let mut probe = [0u8; 1];
    match receive_signal(rx, pipe.read(&mut probe), ACK_TIMEOUT).await {
        RelaySignal::Reply(Reply::Ack) => {}
        // A click that beats the ack is still a click.
        RelaySignal::Reply(Reply::Decision(d)) => {
            log::line(format!("hook id={id} answered {d}"));
            return WaitOutcome::Decision(d);
        }
        RelaySignal::Reply(Reply::Decline) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return WaitOutcome::Closed("declined");
        }
        RelaySignal::ReplyClosed => return WaitOutcome::Closed("disconnected"),
        RelaySignal::Disconnected => {
            log::line(format!("hook id={id} disconnected — terminal takes over"));
            return WaitOutcome::Closed("disconnected");
        }
        RelaySignal::TimedOut => {
            log::line(format!(
                "hook id={id} island never acknowledged — terminal takes over"
            ));
            return WaitOutcome::Closed("ack_timeout");
        }
    }

    let deadline = Instant::now() + DECISION_TIMEOUT;
    loop {
        let remaining = deadline.saturating_duration_since(Instant::now());
        let mut probe = [0u8; 1];
        match receive_signal(rx, pipe.read(&mut probe), remaining).await {
            RelaySignal::Reply(Reply::Decision(d)) => {
                log::line(format!("hook id={id} answered {d}"));
                return WaitOutcome::Decision(d);
            }
            RelaySignal::Reply(Reply::Decline) => {
                log::line(format!("hook id={id} released without a decision"));
                return WaitOutcome::Closed("declined");
            }
            RelaySignal::Reply(Reply::Ack) => {
                // Duplicate ack is harmless and cannot extend the decision budget.
            }
            RelaySignal::ReplyClosed => return WaitOutcome::Closed("disconnected"),
            RelaySignal::Disconnected => {
                log::line(format!("hook id={id} disconnected — terminal takes over"));
                return WaitOutcome::Closed("disconnected");
            }
            RelaySignal::TimedOut => {
                log::line(format!("hook id={id} timed out — terminal takes over"));
                return WaitOutcome::Closed("decision_timeout");
            }
        }
    }
}

fn applied_decision(provider: Option<&str>, decision: &str) -> &'static str {
    match decision {
        "allow" => "allow",
        "deny" => "deny",
        "always" if provider == Some("claude") => "allow",
        "always" => "fallback",
        _ => "fallback",
    }
}

fn send(app: &AppHandle, request_id: &str, reply: Reply, keep: bool) {
    let sender = {
        let pending = app.state::<Pending>();
        let mut map = pending.0.lock().unwrap();
        if keep {
            map.get(request_id).map(|pending| pending.sender.clone())
        } else {
            map.remove(request_id).map(|pending| pending.sender)
        }
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
    let word = decision_word(decision);
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false);
}

/// Preserve the island's Always action until the provider-specific relay can
/// interpret it. Claude treats it as a one-request allow; Codex currently does
/// not support persistent permission updates and must fall back to its prompt.
fn decision_word(decision: &str) -> &'static str {
    match decision {
        "allow" => "allow",
        "always" => "always",
        _ => "deny",
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::future;

    #[test]
    fn permission_choice_is_preserved_for_provider_specific_validation() {
        assert_eq!(decision_word("allow"), "allow");
        assert_eq!(decision_word("always"), "always");
        assert_eq!(decision_word("deny"), "deny");
        assert_eq!(decision_word("unexpected"), "deny");
    }

    #[test]
    fn closed_event_preserves_the_request_identity_and_reason() {
        let identity = RequestIdentity {
            provider: Some("codex".into()),
            session_id: Some("session-exact".into()),
            turn_id: Some("turn-exact".into()),
        };
        assert_eq!(
            identity.closed_event("request-7", "disconnected"),
            json!({
                "hook_event_name": "PermissionRequestClosed",
                "request_id": "request-7",
                "provider": "codex",
                "session_id": "session-exact",
                "turn_id": "turn-exact",
                "resolution": "disconnected"
            })
        );
    }

    #[test]
    fn pipe_frame_must_be_one_bounded_newline_terminated_json_object() {
        assert_eq!(
            parse_frame(b"{\"hook_event_name\":\"Stop\"}\n"),
            Some(json!({"hook_event_name": "Stop"}))
        );
        assert!(parse_frame(b"{\"hook_event_name\":\"Stop\"}").is_none());
        assert!(parse_frame(b"{\"hook_event_name\":\"Stop\"}\n{}\n").is_none());
        assert!(parse_frame(b"[]\n").is_none());
    }

    #[tokio::test(flavor = "current_thread")]
    async fn relay_wait_distinguishes_pipe_eof_from_deadline() {
        let (_tx, mut rx) = mpsc::channel::<Reply>(1);
        assert_eq!(
            receive_signal(&mut rx, future::ready(Ok(0)), Duration::from_secs(1)).await,
            RelaySignal::Disconnected
        );

        let (_tx, mut rx) = mpsc::channel::<Reply>(1);
        assert_eq!(
            receive_signal(
                &mut rx,
                future::pending::<std::io::Result<usize>>(),
                Duration::from_millis(1)
            )
            .await,
            RelaySignal::TimedOut
        );
    }

    #[tokio::test(flavor = "current_thread")]
    async fn relay_wait_prefers_a_ready_human_decision() {
        let (tx, mut rx) = mpsc::channel::<Reply>(1);
        tx.send(Reply::Decision("allow".into())).await.unwrap();
        assert_eq!(
            receive_signal(
                &mut rx,
                future::pending::<std::io::Result<usize>>(),
                Duration::from_secs(1)
            )
            .await,
            RelaySignal::Reply(Reply::Decision("allow".into()))
        );
        assert_eq!(applied_decision(Some("claude"), "always"), "allow");
        assert_eq!(applied_decision(Some("codex"), "always"), "fallback");
        assert_eq!(applied_decision(Some("codex"), "deny"), "deny");
    }
}
