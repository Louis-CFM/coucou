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
#[cfg(windows)]
use crate::platform::PipeSecurity;
use crate::session_window;

/// Slightly under coucou-hook's own 110 s wait, so we always answer first.
const DECISION_TIMEOUT: Duration = Duration::from_secs(108);
/// How long the island gets to say "the card is up". This is the whole of B4:
/// without it, an island that is paused, hidden behind a crashed webview or
/// simply not listening would leave Claude Code staring at a prompt nobody can
/// see for nearly two minutes.
const ACK_TIMEOUT: Duration = Duration::from_millis(800);
const MAX_PAYLOAD: usize = 1 << 20;
/// Cap on reading a client's request. coucou-hook writes it in one go as soon
/// as it connects, and its whole run fits in 2 s when nobody waits for an
/// answer: a silent connection, or one that trickles bytes in, must not hold a
/// pipe instance. Only the read is bounded here; waiting for a decision has its
/// own timeouts (ACK_TIMEOUT, DECISION_TIMEOUT).
const REQUEST_READ_TIMEOUT: Duration = Duration::from_secs(5);
/// Pause after an accept error before listening again, so a lasting failure
/// does not spin.
const ACCEPT_RETRY: Duration = Duration::from_millis(200);
/// Pause between two attempts to take the pipe name (see first_instance).
#[cfg(windows)]
const FIRST_INSTANCE_RETRY: Duration = Duration::from_secs(2);

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
        // Never fall back to the default security descriptor. Without a SID,
        // coucou-hook refuses to talk to a server it cannot check anyway.
        let Some(security) =
            crate::platform::current_user_sid().and_then(|sid| PipeSecurity::for_user(&sid))
        else {
            log::line("relay pipe not opened: cannot restrict it to the current user");
            return;
        };
        let mut server = first_instance(&name, &security).await;
        // An error is logged once per streak: repeated every 200 ms, it would
        // fill the log.
        let mut failing = false;
        loop {
            let accepted = server.connect().await;
            // The next instance is created before this one is handed off, so the
            // pipe name is never free, not even for a moment.
            let next = match create_instance(&name, &security, false) {
                Ok(next) => next,
                Err(err) => {
                    if !std::mem::replace(&mut failing, true) {
                        log::line(format!("relay pipe: cannot create a new instance ({err}), retrying"));
                    }
                    tokio::time::sleep(ACCEPT_RETRY).await;
                    continue;
                }
            };
            // Hand the connected instance to a task and listen on a fresh one.
            let instance = std::mem::replace(&mut server, next);
            match accepted {
                Ok(()) => {
                    failing = false;
                    let app = app.clone();
                    tauri::async_runtime::spawn(async move { handle(app, instance).await });
                }
                // Rare: mio already returns Ok for a client that left before the
                // accept (ERROR_NO_DATA). Any other error discards the instance,
                // and listening resumes on the fresh one.
                Err(err) => {
                    if !std::mem::replace(&mut failing, true) {
                        log::line(format!("relay pipe: a connection failed ({err}), listening again"));
                    }
                    drop(instance);
                    tokio::time::sleep(ACCEPT_RETRY).await;
                }
            }
        }
    });
}

/// The first instance, with FILE_FLAG_FIRST_PIPE_INSTANCE: we refuse to join a
/// pipe somebody else already owns under our name, rather than serving on top
/// of it. The name may also still be held by a Coucou that is shutting down
/// (restart, update): we retry instead of giving up the relay for the whole
/// session.
#[cfg(windows)]
async fn first_instance(name: &str, security: &PipeSecurity) -> NamedPipeServer {
    let mut waited = false;
    loop {
        match create_instance(name, security, true) {
            Ok(server) => {
                if waited {
                    log::line("relay pipe opened");
                }
                return server;
            }
            Err(err) => {
                if !std::mem::replace(&mut waited, true) {
                    // Not necessarily a name already taken: any CreateNamedPipeW error ends up here.
                    log::line(format!("relay pipe: first instance failed ({err}), retrying every 2 s"));
                }
                tokio::time::sleep(FIRST_INSTANCE_RETRY).await;
            }
        }
    }
}

/// One instance of the pipe, open to the current user and SYSTEM only.
#[cfg(windows)]
fn create_instance(name: &str, security: &PipeSecurity, first: bool) -> std::io::Result<NamedPipeServer> {
    let mut options = ServerOptions::new();
    // reject_remote_clients is already tokio's default; set here so we do not
    // depend on it: a client from another machine (SMB) has no business here.
    options.first_pipe_instance(first).reject_remote_clients(true);
    // SAFETY: the pointer refers to a valid SECURITY_ATTRIBUTES for the whole
    // call, and CreateNamedPipeW does not keep it afterwards.
    security.with_attributes(|attributes| unsafe {
        options.create_with_security_attributes_raw(name, attributes)
    })
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
                    tokio::time::sleep(ACCEPT_RETRY).await;
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
    let Some(line) = read_request(&mut pipe, REQUEST_READ_TIMEOUT).await else { return };
    let Ok(mut payload) = serde_json::from_slice::<Value>(&line) else { return };
    if !payload.is_object() {
        return;
    }

    let event = payload
        .get("hook_event_name")
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string();

    note_session_window(&pipe, &payload, &event);
    // Counts for the weekly recap — never the command, path or prompt itself.
    crate::recap::observe(&app, &payload);

    if event != "PermissionRequest" {
        // The status line relay calls in with every Claude Code update: not log-worthy.
        if event != "StatusLine" {
            log::line(format!("hook {event}"));
        }
        let _ = app.emit_to(WINDOW_LABEL, "hook", payload);
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

    let decision = wait_for_decision(&id, &mut rx).await;
    app.state::<Pending>().0.lock().unwrap().remove(&id);

    // No decision: say nothing at all. coucou-hook then writes nothing to stdout
    // and Claude Code asks in the terminal, exactly as if Coucou were closed.
    if let Some(d) = decision {
        let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
        let _ = pipe.flush().await;
    }
    pipe.finish();
}

/// The client's first line without its newline, or everything it sent before
/// closing. Reading stops past MAX_PAYLOAD, and a request cut there does not
/// parse. None on a read error, or if nothing complete arrived within `limit`.
async fn read_request(pipe: &mut (impl AsyncRead + Unpin), limit: Duration) -> Option<Vec<u8>> {
    let read = async {
        let mut buf = Vec::new();
        let mut chunk = [0u8; 4096];
        loop {
            match pipe.read(&mut chunk).await {
                Ok(0) => break,
                Ok(n) => {
                    buf.extend_from_slice(&chunk[..n]);
                    if chunk[..n].contains(&b'\n') || buf.len() > MAX_PAYLOAD {
                        break;
                    }
                }
                Err(_) => return None,
            }
        }
        Some(buf)
    };
    let Ok(Some(mut buf)) = tokio::time::timeout(limit, read).await else { return None };
    if let Some(end) = buf.iter().position(|b| *b == b'\n') {
        buf.truncate(end);
    }
    Some(buf)
}

/// Finds, once per session, the window it runs in — see session_window.rs.
///
/// Only while the session is unknown, so the process snapshot is not taken on
/// every event. The relay must still be running for its parents to be found:
/// a permission request always is (it waits for us), a quick event may already
/// have exited, and then a later event of the session tries again.
fn note_session_window(pipe: &impl Relay, payload: &Value, event: &str) {
    let Some(session) = payload.get("session_id").and_then(Value::as_str) else { return };
    if event == "SessionEnd" {
        session_window::forget(session);
        return;
    }
    if session_window::known(session) {
        return;
    }
    let Some(relay) = pipe.client_pid() else { return };
    let ancestors = crate::platform::process_ancestors(relay);
    // No ancestors: the relay was already gone, so try again next time. Some,
    // but none with a window (a classic console): settled, VS Code it is.
    if !ancestors.is_empty() {
        session_window::remember(session, crate::platform::window_owners(&ancestors));
    }
}

/// Two waits: a short one for "the card is up", then the long one for a human.
async fn wait_for_decision(id: &str, rx: &mut mpsc::Receiver<Reply>) -> Option<String> {
    match tokio::time::timeout(ACK_TIMEOUT, rx.recv()).await {
        Ok(Some(Reply::Ack)) => {}
        // A click that beats the ack is still a click.
        Ok(Some(Reply::Decision(d))) => {
            log::line(format!("hook id={id} answered {}", loggable(&d)));
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
            log::line(format!("hook id={id} answered {}", loggable(&d)));
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
/// AskUserQuestion takes them in.
pub fn answer_question(app: &AppHandle, request_id: &str, answers: &HashMap<String, serde_json::Value>) {
    log::line(format!("decision id={request_id} answered a question"));
    // One line: the relay reads up to the first newline.
    let line = json!({ "answers": answers }).to_string();
    send(app, request_id, Reply::Decision(line), false);
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Instant;

    fn block_on<T>(f: impl std::future::Future<Output = T>) -> T {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[test]
    fn the_request_is_the_first_line() {
        block_on(async {
            let (mut client, mut server) = tokio::io::duplex(64);
            client.write_all(b"{\"a\":1}\n{\"b\":2}\n").await.unwrap();
            let line = read_request(&mut server, Duration::from_secs(1)).await;
            assert_eq!(line.as_deref(), Some(&b"{\"a\":1}"[..]));
        });
    }

    #[test]
    fn a_client_that_closes_without_a_newline_is_still_read() {
        block_on(async {
            let (mut client, mut server) = tokio::io::duplex(64);
            client.write_all(b"{\"a\":1}").await.unwrap();
            drop(client);
            let line = read_request(&mut server, Duration::from_secs(1)).await;
            assert_eq!(line.as_deref(), Some(&b"{\"a\":1}"[..]));
        });
    }

    #[test]
    fn a_silent_client_is_dropped_after_the_limit() {
        block_on(async {
            let (_client, mut server) = tokio::io::duplex(64);
            let started = Instant::now();
            assert_eq!(read_request(&mut server, Duration::from_millis(100)).await, None);
            assert!(started.elapsed() < Duration::from_secs(2));
        });
    }

    #[test]
    fn a_client_that_never_ends_its_line_is_dropped_after_the_limit() {
        block_on(async {
            let (mut client, mut server) = tokio::io::duplex(64);
            // One byte every 10 ms, never a newline.
            let drip = tokio::spawn(async move {
                while client.write_all(b"x").await.is_ok() {
                    tokio::time::sleep(Duration::from_millis(10)).await;
                }
            });
            let started = Instant::now();
            assert_eq!(read_request(&mut server, Duration::from_millis(150)).await, None);
            assert!(started.elapsed() < Duration::from_secs(2));
            drop(server);
            let _ = drip.await;
        });
    }

    /// A pipe created the way the relay creates it: a DACL holding only the user
    /// and SYSTEM, the name taken exclusively, and the same user's relay still
    /// gets through.
    #[cfg(windows)]
    #[test]
    fn the_relay_pipe_is_reserved_to_the_user_and_still_serves_them() {
        use std::io::Write;
        use std::os::windows::io::AsRawHandle;

        let sid = crate::platform::current_user_sid().expect("the current user's SID");
        let security = PipeSecurity::for_user(&sid).expect("a security descriptor");
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        // A name of its own, never the live relay's.
        let name = format!(r"\\.\pipe\coucou-test-{}-{nanos}", std::process::id());

        block_on(async {
            let mut server = create_instance(&name, &security, true).expect("first instance");

            let dacl = crate::platform::dacl_sddl(server.as_raw_handle()).expect("the pipe's DACL");
            assert!(dacl.starts_with("D:P"), "{dacl}");
            // Not `sid` as is: Windows writes some accounts as an alias (`LA` for
            // the built-in Administrator, `SY` for SYSTEM).
            let me = crate::platform::sddl_trustee(&sid).expect("the SID as SDDL writes it");
            assert!(dacl.contains(&format!(";;;{me})")), "{dacl}");
            assert!(dacl.contains(";;;SY)"), "{dacl}");
            assert_eq!(dacl.matches("(A;").count(), 2, "{dacl}");
            for nobody in [";;;WD)", ";;;AN)", ";;;BA)"] {
                assert!(!dacl.contains(nobody), "{dacl}");
            }

            // Like coucou-hook: opened for reading and writing, one line. Before
            // any other instance exists, so that `server` is the one that gets it.
            let mut client =
                std::fs::OpenOptions::new().read(true).write(true).open(&name).expect("client");
            client.write_all(b"{\"hook_event_name\":\"Stop\"}\n").unwrap();

            // The name is ours: another "first" instance is refused, a further
            // instance is accepted.
            assert!(create_instance(&name, &security, true).is_err());
            let _next = create_instance(&name, &security, false).expect("next instance");

            server.connect().await.expect("connect");
            let line = read_request(&mut server, Duration::from_secs(1)).await;
            assert_eq!(line.as_deref(), Some(&b"{\"hook_event_name\":\"Stop\"}"[..]));
        });
    }
}
