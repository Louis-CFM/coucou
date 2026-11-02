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
/// coucou-hook writes its line as soon as it connects. A client that connects
/// and says nothing would otherwise hold its task forever.
const FIRST_LINE_TIMEOUT: Duration = Duration::from_secs(5);
/// Between attempts at a pipe instance Windows refused.
#[cfg(windows)]
const CREATE_RETRY: Duration = Duration::from_secs(2);

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

#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn a_long_answer_reaches_the_relay_whole() {
        use std::io::Read;
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let name = format!(r"\\.\pipe\coucou-test-{}-long-answer", std::process::id());
            let mut server = ServerOptions::new().first_pipe_instance(true).create(&name).unwrap();
            // A plain blocking handle, as coucou-hook opens it.
            let mut relay = std::fs::OpenOptions::new().read(true).write(true).open(&name).unwrap();
            server.connect().await.unwrap();
            // An answer to a question, several times longer than one of the relay's 1 KiB reads.
            let line = format!("{}\n", json!({ "answers": { "Which one?": "é".repeat(3000) } }));
            server.write_all(line.as_bytes()).await.unwrap();
            server.flush().await.unwrap();
            server.finish();
            drop(server);
            // The relay reads only now, 1 KiB at a time, after we are done with the pipe.
            let got = tokio::task::spawn_blocking(move || {
                let (mut got, mut chunk) = (Vec::new(), [0u8; 1024]);
                while let Ok(n @ 1..) = relay.read(&mut chunk) {
                    got.extend_from_slice(&chunk[..n]);
                    if got.contains(&b'\n') {
                        break;
                    }
                }
                got
            })
            .await
            .unwrap();
            assert_eq!(String::from_utf8_lossy(&got), line);
        });
    }

    #[test]
    fn only_our_own_account_may_open_the_pipe() {
        use std::os::windows::io::AsRawHandle;
        use windows::Win32::Foundation::{LocalFree, HANDLE, HLOCAL};
        use windows::Win32::Security::Authorization::{
            ConvertSecurityDescriptorToStringSecurityDescriptorW, GetSecurityInfo, SDDL_REVISION_1, SE_KERNEL_OBJECT,
        };
        use windows::Win32::Security::{DACL_SECURITY_INFORMATION, PSECURITY_DESCRIPTOR};
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let name = format!(r"\\.\pipe\coucou-test-{}-dacl", std::process::id());
            let server = create(&name, true).unwrap();
            let dacl = unsafe {
                let mut descriptor = PSECURITY_DESCRIPTOR::default();
                let handle = HANDLE(server.as_raw_handle());
                assert!(GetSecurityInfo(handle, SE_KERNEL_OBJECT, DACL_SECURITY_INFORMATION, None, None, None, None, Some(&mut descriptor)).is_ok());
                let mut text = windows::core::PWSTR::null();
                ConvertSecurityDescriptorToStringSecurityDescriptorW(descriptor, SDDL_REVISION_1, DACL_SECURITY_INFORMATION, &mut text, None)
                    .unwrap();
                let dacl = text.to_string().unwrap();
                let _ = LocalFree(Some(HLOCAL(text.0 as *mut _)));
                let _ = LocalFree(Some(HLOCAL(descriptor.0)));
                dacl
            };
            // One entry, ours: the default DACL would also let Everyone (WD) and Anonymous (AN) read.
            let sid = crate::platform::current_user_sid().unwrap();
            assert!(dacl.starts_with("D:P") && dacl.matches('(').count() == 1 && dacl.ends_with(')'), "{dacl}");
            // SDDL writes some accounts as aliases (the built-in Administrator a CI runner
            // uses is "LA"), so the entry's account is compared as a SID, not as text.
            let trustee = dacl.trim_end_matches(')').rsplit(';').next().unwrap();
            assert_eq!(full_sid(trustee), sid, "{dacl}");
            assert!(full_sid("LA").ends_with("-500"));
            // And we still get in, the way coucou-hook opens it.
            std::fs::OpenOptions::new().read(true).write(true).open(&name).expect("our own account connects");
        });
    }

    /// An SDDL account ("S-1-5-…" or an alias such as "LA") as its "S-1-5-…" form.
    fn full_sid(text: &str) -> String {
        use windows::core::{HSTRING, PWSTR};
        use windows::Win32::Foundation::{LocalFree, HLOCAL};
        use windows::Win32::Security::Authorization::{ConvertSidToStringSidW, ConvertStringSidToSidW};
        use windows::Win32::Security::PSID;
        unsafe {
            let mut sid = PSID::default();
            ConvertStringSidToSidW(&HSTRING::from(text), &mut sid).unwrap();
            let mut out = PWSTR::null();
            ConvertSidToStringSidW(sid, &mut out).unwrap();
            let full = out.to_string().unwrap();
            let _ = LocalFree(Some(HLOCAL(out.0 as *mut _)));
            let _ = LocalFree(Some(HLOCAL(sid.0)));
            full
        }
    }
}

#[cfg(windows)]
pub fn start(app: AppHandle) {
    tauri::async_runtime::spawn(async move {
        let name = pipe_name();
        // first_pipe_instance also means we refuse to join a pipe somebody else
        // already owns under our name, rather than serving on top of it. We keep
        // trying, so the relay comes up once they are gone.
        let mut server = instance(&name, true).await;
        loop {
            if server.connect().await.is_err() {
                // A failed instance never connects again (#853): listen on a fresh one.
                server = instance(&name, false).await;
                tokio::time::sleep(Duration::from_millis(200)).await;
                continue;
            }
            // Hand the connected instance to a task and listen on a fresh one,
            // made first so the pipe never goes away in between.
            let next = instance(&name, false).await;
            let connected = std::mem::replace(&mut server, next);
            let app = app.clone();
            tauri::async_runtime::spawn(async move { handle(app, connected).await });
        }
    });
}

/// A pipe instance, retried until Windows gives one: giving up would leave the
/// hooks dead until Coucou restarts. Logged once, not on every attempt.
#[cfg(windows)]
async fn instance(name: &str, first: bool) -> NamedPipeServer {
    let mut logged = false;
    loop {
        match create(name, first) {
            Ok(server) => return server,
            Err(err) if !logged => {
                log::line(format!("cannot open the relay pipe, retrying: {err}"));
                logged = true;
            }
            Err(_) => {}
        }
        tokio::time::sleep(CREATE_RETRY).await;
    }
}

/// One instance that only our own account can open. Without a security
/// descriptor the pipe gets the default one, which lets Everyone and Anonymous
/// read: enough to connect, hold an instance and read our replies.
#[cfg(windows)]
fn create(name: &str, first: bool) -> std::io::Result<NamedPipeServer> {
    use windows::core::HSTRING;
    use windows::Win32::Foundation::{LocalFree, HLOCAL};
    use windows::Win32::Security::Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1};
    use windows::Win32::Security::{PSECURITY_DESCRIPTOR, SECURITY_ATTRIBUTES};

    let sid = crate::platform::current_user_sid().ok_or_else(|| std::io::Error::other("cannot read our own SID"))?;
    // A protected DACL with one entry: full access for our SID, nothing inherited.
    let sddl = HSTRING::from(format!("D:P(A;;GA;;;{sid})"));
    let mut descriptor = PSECURITY_DESCRIPTOR::default();
    unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(&sddl, SDDL_REVISION_1, &mut descriptor, None)?;
        let mut attributes = SECURITY_ATTRIBUTES {
            nLength: std::mem::size_of::<SECURITY_ATTRIBUTES>() as u32,
            lpSecurityDescriptor: descriptor.0,
            bInheritHandle: false.into(),
        };
        let server = ServerOptions::new()
            .first_pipe_instance(first)
            .create_with_security_attributes_raw(name, (&mut attributes as *mut SECURITY_ATTRIBUTES).cast());
        let _ = LocalFree(Some(HLOCAL(descriptor.0)));
        server
    }
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

/// One accepted relay connection, whatever carries it. Dropping it closes it and the relay still reads up to our
/// newline; on Windows that is why the pipe is never disconnected (DisconnectNamedPipe throws away what the relay
/// has not read yet, and it reads 1 KiB at a time). Each connection has its own pipe instance, so none is reused.
trait Relay: AsyncRead + AsyncWrite + Unpin {
    /// Called once everything has been written. Nothing to do on either platform: the drop that follows closes it.
    fn finish(&mut self) {}
    /// The relay process on the other end, where the OS says.
    fn client_pid(&self) -> Option<u32> {
        None
    }
}

#[cfg(windows)]
impl Relay for NamedPipeServer {
    fn client_pid(&self) -> Option<u32> {
        use std::os::windows::io::AsRawHandle;
        crate::platform::pipe_client_pid(self.as_raw_handle())
    }
}

#[cfg(target_os = "linux")]
impl Relay for tokio::net::UnixStream {
    /// SO_PEERCRED: the process that connected, as the kernel saw it.
    fn client_pid(&self) -> Option<u32> {
        let pid = self.peer_cred().ok()?.pid()?;
        u32::try_from(pid).ok().filter(|pid| *pid > 1)
    }
}

/// What the relay sent, up to its first newline (or `MAX_PAYLOAD`), if it sent it within `limit`.
async fn first_line(pipe: &mut (impl AsyncRead + Unpin), limit: Duration) -> Option<Vec<u8>> {
    let read = async {
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
                Err(_) => return None,
            }
        }
        Some(buf)
    };
    tokio::time::timeout(limit, read).await.ok().flatten()
}

async fn handle(app: AppHandle, mut pipe: impl Relay) {
    let Some(buf) = first_line(&mut pipe, FIRST_LINE_TIMEOUT).await else { return };
    let line = match buf.iter().position(|b| *b == b'\n') {
        Some(i) => &buf[..i],
        None => &buf[..],
    };
    let Ok(mut payload) = serde_json::from_slice::<Value>(line) else { return };
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
    // The island is told, so a card that came up late (or is still up after the
    // long wait) goes instead of holding the view with nobody to answer (#857).
    match decision {
        Some(d) => {
            let _ = pipe.write_all(format!("{d}\n").as_bytes()).await;
            let _ = pipe.flush().await;
        }
        None => {
            let _ = app.emit_to(WINDOW_LABEL, "approval-expired", &id);
        }
    }
    pipe.finish();
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

    let deadline = tokio::time::Instant::now() + DECISION_TIMEOUT;
    loop {
        match tokio::time::timeout_at(deadline, rx.recv()).await {
            // The island acks again when the same request reaches it twice; the card is still up.
            Ok(Some(Reply::Ack)) => continue,
            Ok(Some(Reply::Decision(d))) => {
                log::line(format!("hook id={id} answered {}", loggable(&d)));
                return Some(d);
            }
            Ok(Some(Reply::Decline)) => {
                log::line(format!("hook id={id} released without a decision"));
                return None;
            }
            Ok(None) => return None,
            Err(_) => {
                log::line(format!("hook id={id} timed out — terminal takes over"));
                return None;
            }
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
mod wait_tests {
    use super::*;

    #[test]
    fn a_repeated_ack_keeps_the_card_waiting_for_its_click() {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let (tx, mut rx) = mpsc::channel::<Reply>(4);
            // The island acks the same request twice (hooks.ts re-acks a duplicate), then the human clicks.
            tx.try_send(Reply::Ack).unwrap();
            tx.try_send(Reply::Ack).unwrap();
            tx.try_send(Reply::Decision("allow".into())).unwrap();
            assert_eq!(wait_for_decision("test-ack", &mut rx).await.as_deref(), Some("allow"));
        });
    }

    #[test]
    fn a_client_that_connects_and_says_nothing_is_dropped_at_the_deadline() {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(async {
            let (mut ours, _silent) = tokio::io::duplex(64);
            let started = std::time::Instant::now();
            assert_eq!(first_line(&mut ours, Duration::from_millis(50)).await, None);
            assert!(started.elapsed() < Duration::from_secs(5));

            let (mut ours, mut relay) = tokio::io::duplex(64);
            relay.write_all(b"{\"a\":1}\n").await.unwrap();
            assert_eq!(first_line(&mut ours, Duration::from_secs(5)).await.as_deref(), Some(&b"{\"a\":1}\n"[..]));
        });
    }
}
