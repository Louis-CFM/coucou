// Relay server for coucou-hook.
//
// Windows: the named pipe `\\.\pipe\coucou-<sid>`, one instance per connection.
// Linux: the Unix socket `$XDG_RUNTIME_DIR/coucou.sock`. Every hook event is
// forwarded to the island as a `hook` event. `PermissionRequest` is the only one
// that keeps its connection open: it waits for the island's decision and writes
// it back on the same connection, which is how approving from the island works.
//
// Claude Code is never blocked by us. Three things guarantee it:
//   * coucou-hook gives the connection 300 ms and exits cleanly if we are closed;
//   * we only wait for a human once the island has *confirmed* the card is on
//     screen, so a paused island or a webview that is not listening costs a few
//     hundred milliseconds, not two minutes;
//   * whatever happens we drop the connection after the decision timeout, and
//     the terminal takes over.
//
// What we write back is the bare word `allow` or `deny` — or, when the request
// was Claude Code asking a question, `{"answers":{…}}` with what was picked on
// the island. Turning either into the documented hookSpecificOutput JSON is
// coucou-hook's job, so the wire format Claude Code expects lives in exactly
// one place.

use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Mutex;
use std::time::Duration;

use serde_json::{json, Value};
use tauri::{AppHandle, Emitter, Manager};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};
#[cfg(windows)]
use tokio::net::windows::named_pipe::{NamedPipeServer, ServerOptions};
use tokio::sync::mpsc;

use crate::island::WINDOW_LABEL;
use crate::log;
use crate::session_window;

/// Slightly under coucou-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// How long the island gets to say "the card is up". This is the whole of B4:
/// without it, an island that is paused, hidden behind a crashed webview or
/// simply not listening would leave Claude Code staring at a prompt nobody can
/// see for nearly two minutes.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const MAX_PAYLOAD: usize = 1 << 20;

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
#[cfg(windows)]
pub fn pipe_name() -> String {
    let key = crate::platform::current_user_sid()
        .unwrap_or_else(|| std::env::var("USERNAME").unwrap_or_else(|_| "user".into()));
    format!(r"\\.\pipe\coucou-{key}")
}

#[cfg(windows)]
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

#[cfg(target_os = "linux")]
pub fn start(app: AppHandle) {
    use std::os::unix::fs::PermissionsExt;
    use tokio::net::UnixListener;

    tauri::async_runtime::spawn(async move {
        let Some(path) = crate::platform::relay_socket_path() else {
            log::line("no private runtime directory ($XDG_RUNTIME_DIR) — Claude Code hooks are inactive");
            return;
        };
        // A socket file left behind by a crash answers nothing and can go. One
        // that answers belongs to a Coucou that is still running: like
        // first_pipe_instance on Windows, we refuse to serve on top of it.
        if path.exists() {
            if std::os::unix::net::UnixStream::connect(&path).is_ok() {
                log::line("another Coucou already serves the relay socket");
                return;
            }
            let _ = std::fs::remove_file(&path);
        }
        let listener = match UnixListener::bind(&path) {
            Ok(l) => l,
            Err(err) => {
                log::line(format!("cannot open the relay socket: {err}"));
                return;
            }
        };
        // The runtime directory is already 0700; this is belt and braces.
        let _ = std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600));
        let uid = unsafe { libc::getuid() };
        loop {
            let stream = match listener.accept().await {
                Ok((stream, _)) => stream,
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    continue;
                }
            };
            // Only the relay run by our own user may drive the island.
            if !matches!(stream.peer_cred(), Ok(c) if c.uid() == uid) {
                log::line("refused a relay connection from another user");
                continue;
            }
            let app = app.clone();
            tauri::async_runtime::spawn(async move { handle(app, stream).await });
        }
    });
}

/// One accepted relay connection, whatever carries it.
trait Relay: AsyncRead + AsyncWrite + Unpin {
    /// Ends the conversation once everything has been written.
    fn finish(&mut self) {}
    /// The relay process on the other end, where the OS says.
    fn client_pid(&self) -> Option<u32> {
        None
    }
}

#[cfg(windows)]
impl Relay for NamedPipeServer {
    fn finish(&mut self) {
        let _ = self.disconnect();
    }
    fn client_pid(&self) -> Option<u32> {
        use std::os::windows::io::AsRawHandle;
        crate::platform::pipe_client_pid(self.as_raw_handle())
    }
}

/// Dropping the stream closes it; the relay reads up to our newline first.
#[cfg(target_os = "linux")]
impl Relay for tokio::net::UnixStream {
    /// SO_PEERCRED: the process that connected, as the kernel saw it.
    fn client_pid(&self) -> Option<u32> {
        let pid = self.peer_cred().ok()?.pid()?;
        u32::try_from(pid).ok().filter(|pid| *pid > 1)
    }
}

async fn handle(app: AppHandle, mut pipe: impl Relay) {
    let mut buf = Vec::new();
    let mut chunk = [0u8; 4096];
    loop {
        match pipe.read(&mut chunk).await {
            Ok(0) => break,
            Ok(n) => {
                buf.extend_from_slice(&chunk[..n]);
                if buf.contains(&b'\n') || buf.len() > MAX_PAYLOAD {
                    break;
                }
            }
            Err(_) => return,
        }
    }
    let line = match buf.iter().position(|b| *b == b'\n') {
        Some(i) => &buf[..i],
        None => &buf[..],
    };
    // Hand-rolled clients may prefix a UTF-8 BOM; coucou-hook never does.
    let line = line.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(line);
    let Ok(mut payload) = serde_json::from_slice::<Value>(line) else { return };
    if !payload.is_object() {
        return;
    }

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    let session = payload.get("session_id").and_then(Value::as_str).map(str::to_string);
    let relay_pid = pipe.client_pid();
    // Counts for the weekly recap — never the command, path or prompt itself.
    crate::recap::observe(&app, &payload);

    if event != "PermissionRequest" {
        // The status line relay calls in with every Claude Code update: not log-worthy.
        if event != "StatusLine" {
            log::line(format!("hook {event}"));
        }
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
        remember_session_window(relay_pid, session, &event);
        pipe.finish();
        return;
    }

    let id = format!("{}-{}", std::process::id(), COUNTER.fetch_add(1, Ordering::Relaxed));
    let (tx, mut rx) = mpsc::channel::<Reply>(4);
    {
        let pending = app.state::<Pending>();
        pending.0.lock().unwrap().insert(id.clone(), tx);
    }
    crate::recap::note_request(&app, &id, &payload);
    payload["request_id"] = json!(id);
    log::line(format!("hook PermissionRequest id={id}"));
    let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
    remember_session_window(relay_pid, session, &event);

    let outcome = wait_for_decision(&id, &mut rx, peer_closed(&mut pipe)).await;
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    match outcome {
        // What we write is a bare word or the answers line; coucou-hook turns it into the agent's JSON.
        Outcome::Decision(d) => {
            let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
            let _ = pipe.flush().await;
        }
        // The island said so itself. No decision: say nothing at all, and the
        // agent asks in its terminal exactly as if Coucou were closed.
        Outcome::Declined => {}
        // The card may still be up for a request nobody waits on any more.
        Outcome::TimedOut | Outcome::Gone => {
            crate::recap::forget_request(&app, &id);
            let _ = app.emit_to(WINDOW_LABEL, "approval-released", json!({ "requestId": id }));
        }
    }
    pipe.finish();
}

/// Finds, once per session, the window it runs in (session_window.rs). The
/// process snapshot runs on the blocking pool after the island has the event:
/// taken before, it held the event back while a later one from a faster relay
/// went ahead. Only while the session is unknown; the relay must still be
/// running for its parents to be found: it stays connected until we hang up
/// (`finish`), so it is. One that exited anyway (killed, or an older relay)
/// leaves no ancestors, and then a later event tries again.
fn remember_session_window(relay: Option<u32>, session: Option<String>, event: &str) {
    let Some(session) = session else { return };
    if event == "SessionEnd" {
        session_window::forget(&session);
        return;
    }
    if session_window::known(&session) {
        return;
    }
    let Some(relay) = relay else { return };
    tauri::async_runtime::spawn_blocking(move || {
        let ancestors = crate::platform::process_ancestors(relay);
        // No ancestors: the relay was already gone, so try again next time.
        // Some, but none with a window (a classic console): settled.
        if !ancestors.is_empty() {
            session_window::remember(&session, crate::platform::window_owners(&ancestors));
        }
    });
}

/// How a held permission request ended.
#[derive(Debug, PartialEq)]
enum Outcome {
    /// A human clicked: what goes back to the relay.
    Decision(String),
    /// The island said nobody can act on it (paused, full queue, "answer in terminal").
    Declined,
    /// No ack, or no click before the deadline.
    TimedOut,
    /// The relay hung up: the agent stopped waiting (answered in the terminal, gave up).
    Gone,
}

/// Two waits: a short one for "the card is up", then the long one for a human —
/// either cut short by the relay going away.
async fn wait_for_decision(
    id: &str,
    rx: &mut mpsc::Receiver<Reply>,
    gone: impl std::future::Future<Output = ()>,
) -> Outcome {
    tokio::pin!(gone);
    let first = tokio::select! {
        r = tokio::time::timeout(ACK_TIMEOUT, rx.recv()) => r,
        () = &mut gone => {
            log::line(format!("hook id={id} relay gone before the card was up"));
            return Outcome::Gone;
        }
    };
    match first {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", loggable(&d)));
            return Outcome::Decision(d);
        }
        Ok(Some(Reply::Decline)) | Ok(None) => {
            log::line(format!("hook id={id} not shown — terminal takes over"));
            return Outcome::Declined;
        }
        Err(_) => {
            log::line(format!("hook id={id} island never acknowledged — terminal takes over"));
            return Outcome::TimedOut;
        }
    }
    tokio::select! {
        r = tokio::time::timeout(DECISION_TIMEOUT, rx.recv()) => match r {
            Ok(Some(Reply::Decision(d))) => {
                log::line(format!("hook id={id} answered {}", loggable(&d)));
                Outcome::Decision(d)
            }
            Ok(Some(Reply::Decline)) => {
                log::line(format!("hook id={id} released without a decision"));
                Outcome::Declined
            }
            _ => {
                log::line(format!("hook id={id} timed out — terminal takes over"));
                Outcome::TimedOut
            }
        },
        () = &mut gone => {
            log::line(format!("hook id={id} relay gone — answered in the terminal"));
            Outcome::Gone
        }
    }
}

/// Resolves when the relay closed its end. It never sends anything after its
/// event, so any read that returns is either nothing (closed) or noise.
async fn peer_closed(pipe: &mut impl Relay) {
    let mut buf = [0u8; 64];
    loop {
        match pipe.read(&mut buf).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}

/// The log says a question was answered, never with what.
fn loggable(decision: &str) -> &str {
    if decision.starts_with('{') { "a question" } else { decision }
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
    let word = match decision {
        "allow" | "always" => "allow",
        _ => "deny",
    };
    log::line(format!("decision id={request_id} {word}"));
    send(app, request_id, Reply::Decision(word.to_string()), false);
}

/// Called when an option is picked for a question Claude Code asked. `answers`
/// maps each question's text to the chosen label, which is the shape
/// AskUserQuestion takes them in. `other` lists the questions answered in words
/// under "Other…", which the relay then accepts as free text.
pub fn answer_question(
    app: &AppHandle,
    request_id: &str,
    answers: &HashMap<String, serde_json::Value>,
    other: &[String],
) {
    log::line(format!("decision id={request_id} answered a question"));
    // One line: the relay reads up to the first newline (serde_json escapes any
    // newline typed in a free-text answer).
    let line = json!({ "answers": answers, "other": other }).to_string();
    send(app, request_id, Reply::Decision(line), false);
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn a_relay_that_goes_away_releases_its_card() {
        block_on(async {
            let (_tx, mut rx) = mpsc::channel::<Reply>(4);
            let gone = tokio::time::sleep(Duration::from_millis(20));
            assert_eq!(wait_for_decision("t1", &mut rx, gone).await, Outcome::Gone);
        });
    }

    #[test]
    fn an_acknowledged_card_waits_for_the_click() {
        block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            tx.send(Reply::Ack).await.unwrap();
            tx.send(Reply::Decision("allow".into())).await.unwrap();
            let outcome = wait_for_decision("t2", &mut rx, std::future::pending::<()>()).await;
            assert_eq!(outcome, Outcome::Decision("allow".into()));
        });
    }

    #[test]
    fn answered_in_the_terminal_after_the_card_was_up() {
        block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            tx.send(Reply::Ack).await.unwrap();
            let gone = tokio::time::sleep(Duration::from_millis(20));
            assert_eq!(wait_for_decision("t3", &mut rx, gone).await, Outcome::Gone);
        });
    }

    #[test]
    fn a_decline_is_no_decision() {
        block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            tx.send(Reply::Decline).await.unwrap();
            assert_eq!(wait_for_decision("t4", &mut rx, std::future::pending::<()>()).await, Outcome::Declined);
        });
    }
}
