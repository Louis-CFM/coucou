// The phone link's TLS server (docs/ANDROID_LINK.md, protocol v1).
//
// One accepted connection is two tasks: a reader that checks the phone's lines
// and a writer that sends what the hub queues. The reader owns the way in, so
// when it ends (the phone left, a protocol error, the idle timeout) the writer
// finishes what is queued, including a last `error`, and closes.
//
// What it refuses, on purpose:
//   * anyone who is not on the local network (private, loopback, link-local);
//   * a first message that is not a valid `hello` within a few seconds;
//   * a wrong token or protocol version (after a short pause, so guessing is slow);
//   * a line over 64 KiB, or silence for 20 minutes (the phone pings every 20 s while it is awake, and checks in every few minutes while it sleeps);
//   * more than a handful of connections at once, and more than two silent ones from one address: see
//     admission.rs (strangers share a small pool, a phone that authenticated before keeps its place, and the
//     TLS handshake and the hello get less time when the pool is filling up).
// It never touches the agent: a decision goes through `Hub::decide`, which only
// applies the request still pending.

use std::net::IpAddr;
use std::sync::atomic::Ordering;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::json;
use tokio::io::{AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, BufReader};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::mpsc;
use tokio::task::JoinHandle;
use tokio_rustls::rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio_rustls::rustls::version::{TLS12, TLS13};
use tokio_rustls::rustls::{crypto::ring as ring_provider, ServerConfig};
use tokio_rustls::TlsAcceptor;

use super::admission::{Admission, Ticket};
use super::chat::ChatLink;
use super::hub::{constant_eq, Hub, Out};
use super::pairing::Identity;

pub const PROTOCOL: u64 = 1;
pub const MAX_LINE: usize = 64 * 1024;
const HELLO_TIMEOUT: Duration = Duration::from_secs(10);
/// An authenticated phone may be silent this long. A sleeping phone cannot ping every 20 s (its timers stop with the CPU), so a
/// short limit here dropped it after 90 s and it only noticed on waking. Its alarm checks in every few minutes (Doze may stretch that
/// to about 15), so the limit is well above that. A conversation whose phone vanished without a goodbye (its address changed)
/// holds one of the 8 places until then.
const IDLE_TIMEOUT: Duration = Duration::from_secs(20 * 60);

#[cfg(test)]
mod idle_tests {
    #[test]
    fn the_idle_limit_is_well_above_what_a_sleeping_phone_needs() {
        // The phone's alarm asks for a check every 4 minutes and Doze can stretch that to about 15 (KeepAlivePolicy.kt).
        assert!(super::IDLE_TIMEOUT >= std::time::Duration::from_secs(16 * 60));
        // But not unbounded: a vanished phone must not hold a place for hours.
        assert!(super::IDLE_TIMEOUT <= std::time::Duration::from_secs(30 * 60));
    }
}
/// Pause before answering a wrong token.
const AUTH_PENALTY: Duration = Duration::from_millis(400);

/// Which optional features the user has switched on, read again for every connection.
pub trait Features: Send + Sync {
    /// Session details: the steps, the last line, the project's folder name and the colour.
    fn details(&self) -> bool;
    /// Answering the questions Claude Code asks, from the phone (the screen-lock check is the phone's).
    fn answers(&self) -> bool {
        false
    }
    /// File changes: the list of files of a session, and a file's diff on request.
    fn diffs(&self) -> bool {
        false
    }
    /// The plan usage (percentages and reset times of the Claude and Codex plans).
    fn usage(&self) -> bool {
        false
    }
    /// The relay is switched on (the phone then follows an access key rotation).
    fn relay(&self) -> bool {
        false
    }
    /// The services the user allowed for the phone (their ids); empty: none.
    fn services(&self) -> Vec<String> {
        Vec::new()
    }
}

/// Nothing extra: how the link behaved before capabilities existed.
#[cfg(test)]
pub struct NoFeatures;
#[cfg(test)]
impl Features for NoFeatures {
    fn details(&self) -> bool {
        false
    }
}

/// What a connection needs to know about the desktop.
pub struct Shared {
    pub hub: Arc<Hub>,
    /// Replaced when the user pairs again; read for every `hello`.
    pub token: Mutex<String>,
    pub name: String,
    /// Tests run on loopback and through a stand-in clock.
    pub clock: fn() -> u64,
    /// Chat from the phone; None where the feature is not wired in. Offered only to a phone that asks for it.
    pub chat: Option<Arc<ChatLink>>,
    pub features: Arc<dyn Features>,
    admission: Arc<Admission>,
}

impl Shared {
    pub fn with_features(hub: Arc<Hub>, token: String, name: String, chat: Option<Arc<ChatLink>>, features: Arc<dyn Features>) -> Arc<Shared> {
        Arc::new(Shared { hub, token: Mutex::new(token), name, clock: now_ms, chat, features, admission: Admission::new() })
    }
}

impl Shared {
    /// A slot for the relay link, which reaches the server as one source: the relay's own forwarding is not a LAN
    /// address, and the relay never shows who is behind it. One slot at a time, so a flood at the relay cannot
    /// use more of the pool than a flood from one LAN address could.
    #[cfg(test)]
    pub(super) fn admission_counts(&self) -> (usize, usize) {
        self.admission.counts()
    }

    pub(super) fn admit_relay(&self) -> Option<Ticket> {
        self.admission.admit(RELAY_SOURCE)
    }
}

/// The stand-in source address of everything that arrives through the relay (a documentation address, never routable).
pub(super) const RELAY_SOURCE: IpAddr = IpAddr::V4(std::net::Ipv4Addr::new(192, 0, 2, 255));

pub fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

/// A running server; dropping it does not stop it, `stop` does.
pub struct Handle {
    accept: JoinHandle<()>,
    shared: Arc<Shared>,
}

impl Handle {
    pub fn stop(self) {
        self.accept.abort();
        self.shared.hub.kick_all("closed", "the phone link was turned off");
        if let Some(chat) = &self.shared.chat {
            chat.shutdown();
        }
    }
}

/// TLS 1.2 and 1.3, the certificate made once. `ring` is named explicitly so
/// nothing depends on a process-wide default provider.
pub fn tls_acceptor(identity: &Identity) -> Result<TlsAcceptor, String> {
    let key = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(identity.key_der.clone()));
    let config = ServerConfig::builder_with_provider(Arc::new(ring_provider::default_provider()))
        .with_protocol_versions(&[&TLS13, &TLS12])
        .map_err(|e| e.to_string())?
        .with_no_client_auth()
        .with_single_cert(vec![CertificateDer::from(identity.cert_der.clone())], key)
        .map_err(|e| e.to_string())?;
    Ok(TlsAcceptor::from(Arc::new(config)))
}

/// Accepts connections until stopped. Must be called inside the async runtime.
pub fn serve(listener: TcpListener, acceptor: TlsAcceptor, shared: Arc<Shared>) -> Handle {
    let for_handle = shared.clone();
    let accept = tokio::spawn(async move {
        loop {
            let (tcp, peer) = match listener.accept().await {
                Ok(x) => x,
                Err(_) => {
                    tokio::time::sleep(Duration::from_millis(200)).await;
                    continue;
                }
            };
            if !is_local(peer.ip()) {
                continue; // dropped before any byte is read
            }
            // The slot is held until the connection ends (the ticket drops), whatever way it ends.
            let Some(ticket) = shared.admission.admit(peer.ip()) else { continue };
            let (shared, acceptor) = (shared.clone(), acceptor.clone());
            tokio::spawn(async move {
                let _ = tcp.set_nodelay(true);
                one_connection(tcp, acceptor, &shared, Arc::new(ticket)).await;
            });
        }
    });
    Handle { accept, shared: for_handle }
}

/// The local network only: private, loopback and link-local addresses.
pub fn is_local(ip: IpAddr) -> bool {
    match ip {
        IpAddr::V4(v4) => v4.is_private() || v4.is_loopback() || v4.is_link_local(),
        IpAddr::V6(v6) => {
            if let Some(v4) = v6.to_ipv4_mapped() {
                return is_local(IpAddr::V4(v4));
            }
            let first = v6.segments()[0];
            v6.is_loopback() || (first & 0xfe00) == 0xfc00 /* fc00::/7 */ || (first & 0xffc0) == 0xfe80 /* fe80::/10 */
        }
    }
}

async fn one_connection(tcp: TcpStream, acceptor: TlsAcceptor, shared: &Arc<Shared>, ticket: Arc<Ticket>) {
    let Ok(Ok(tls)) = tokio::time::timeout(ticket.wait(), acceptor.accept(tcp)).await else { return };
    run_with(tls, shared, Some(ticket)).await;
}

/// The conversation over a byte stream (TLS in the app), holding its admission ticket until it ends.
pub(super) async fn run_with<S>(stream: S, shared: &Arc<Shared>, ticket: Option<Arc<Ticket>>)
where
    S: AsyncRead + AsyncWrite + Send + Unpin + 'static,
{
    let (read, mut write) = tokio::io::split(stream);
    let (tx, mut rx) = mpsc::channel::<Out>(64);

    let reader = tokio::spawn(read_loop(read, tx, shared.clone(), ticket));

    while let Some(out) = rx.recv().await {
        let (line, last) = match out {
            Out::Line(l) => (l.to_string(), false),
            Out::Close { code, message } => (json!({ "type": "error", "code": code, "message": message }).to_string(), true),
        };
        if write.write_all(line.as_bytes()).await.is_err() || write.write_all(b"\n").await.is_err() || write.flush().await.is_err() || last {
            break;
        }
    }
    reader.abort();
    let _ = write.shutdown().await;
}

async fn read_loop<R>(read: R, tx: mpsc::Sender<Out>, shared: Arc<Shared>, ticket: Option<Arc<Ticket>>)
where
    R: AsyncRead + Unpin,
{
    let mut lines = LineReader::new(read);
    let say = |v: serde_json::Value| tx.send(Out::Line(v.to_string().into()));

    // 1. hello
    let hello_wait = ticket.as_ref().map_or(HELLO_TIMEOUT, |t| t.wait());
    let hello = match tokio::time::timeout(hello_wait, lines.next()).await {
        Ok(Next::Line(l)) => l,
        Ok(Next::TooLong) => {
            let _ = tx.send(Out::Close { code: "protocol", message: "line too long" }).await;
            return;
        }
        _ => return,
    };
    let Ok(hello) = serde_json::from_slice::<serde_json::Value>(&hello) else { return };
    if hello["type"] != "hello" {
        return;
    }
    let sent_token = hello["token"].as_str().unwrap_or("").to_string();
    let expected = shared.token.lock().unwrap().clone();
    let good = hello["v"].as_u64() == Some(PROTOCOL) && constant_eq(sent_token.as_bytes(), expected.as_bytes());
    if !good {
        tokio::time::sleep(AUTH_PENALTY).await;
        let _ = tx.send(Out::Close { code: "auth", message: "bad token or version" }).await;
        return;
    }
    // A valid hello: from here on this connection no longer counts against the unauthenticated limits, and the
    // address is remembered so a flood from elsewhere cannot keep this phone out.
    if let Some(t) = &ticket {
        t.authenticated();
    }
    // Capabilities: offered only if the phone asked and the user's switch is on right now. A phone
    // that sends none (an older app) is never sent, and never answered, anything about chat.
    let asked_chat = hello["caps"].as_array().is_some_and(|c| c.iter().any(|x| x == "chat"));
    let chat = shared.chat.clone().filter(|c| asked_chat && c.enabled());
    let asked = |cap: &str| hello["caps"].as_array().is_some_and(|c| c.iter().any(|x| x == cap));
    let details = asked("details") && shared.features.details();
    let answers = asked("answers") && shared.features.answers();
    // The outfit is no secret and says nothing about the user's work: offered whenever the phone asks.
    let prefs = asked("prefs");
    let diffs = asked("diffs") && shared.features.diffs();
    let usage = asked("usage") && shared.features.usage();
    let relay = asked("relay") && shared.features.relay();
    let services: Vec<String> = if asked("services") { shared.features.services() } else { Vec::new() };
    let mut offered: Vec<&str> = Vec::new();
    if chat.is_some() {
        offered.push("chat");
    }
    if details {
        offered.push("details");
    }
    if answers {
        offered.push("answers");
    }
    if prefs {
        offered.push("prefs");
    }
    if diffs {
        offered.push("diffs");
    }
    if usage {
        offered.push("usage");
    }
    if relay {
        offered.push("relay");
    }
    if !services.is_empty() {
        offered.push("services");
    }
    let mut welcome = json!({ "type": "welcome", "v": PROTOCOL, "desktop": shared.name, "os": std::env::consts::OS });
    if !offered.is_empty() {
        welcome["caps"] = json!(offered);
    }
    let _ = say(welcome).await;
    let (id, evicted) = shared.hub.subscribe_with(tx.clone(), (shared.clock)(), crate::phone_link::hub::Caps { details, answers, prefs, diffs, usage, relay, services });

    // 2. the conversation
    loop {
        let line = match tokio::time::timeout(IDLE_TIMEOUT, lines.next()).await {
            Ok(Next::Line(l)) => l,
            Ok(Next::TooLong) => {
                let _ = tx.send(Out::Close { code: "protocol", message: "line too long" }).await;
                break;
            }
            _ => break, // closed, failed or silent for too long
        };
        let Ok(msg) = serde_json::from_slice::<serde_json::Value>(&line) else { break };
        // The hub stopped sending to this phone because it could not keep up:
        // close, and the phone reconnects to a fresh picture (it pings every 20 s).
        if evicted.load(Ordering::SeqCst) {
            break;
        }
        match msg["type"].as_str() {
            Some("ping") => {
                let _ = say(json!({ "type": "pong" })).await;
            }
            Some("decision") => {
                let fingerprint = msg["fingerprint"].as_str().unwrap_or("");
                let decision = msg["decision"].as_str().unwrap_or("");
                // The hub tells every phone when it applies one; an ignored
                // decision changes nothing at all.
                let _ = shared.hub.decide(fingerprint, decision, (shared.clock)());
            }
            Some("answer") if answers => {
                // One list of labels per question. A malformed one, or one that does not match the pending question
                // exactly, changes nothing (hub.rs).
                let fingerprint = msg["fingerprint"].as_str().unwrap_or("");
                if let Some(picks) = parse_picks(&msg["picks"]) {
                    let _ = shared.hub.answer(fingerprint, &picks, (shared.clock)());
                }
            }
            Some("getDiff") if diffs => {
                // Which file of which session; what it holds is the island's (hub.rs checks the rate and the limits).
                let pill = msg["pillId"].as_str().unwrap_or("");
                if let (false, true, Some(file)) = (pill.is_empty(), pill.len() <= 64, msg["fileId"].as_u64()) {
                    shared.hub.request_diff(id, pill, file, (shared.clock)());
                }
            }
            Some("bye") => break,
            Some(t) if t.starts_with("chat") => {
                if let Some(chat) = &chat {
                    chat.handle(id, &tx, &msg, (shared.clock)());
                }
            }
            _ => {} // unknown types are ignored
        }
    }
    shared.hub.unsubscribe(id);
    if let Some(chat) = &chat {
        chat.cancel_conn(id);
    }
}

/// `[["a"], ["b", "c"]]` as lists of strings, at most MAX_QUESTIONS lists of at most MAX_OPTIONS labels.
fn parse_picks(v: &serde_json::Value) -> Option<Vec<Vec<String>>> {
    let outer = v.as_array()?;
    if outer.is_empty() || outer.len() > super::hub::MAX_QUESTIONS {
        return None;
    }
    outer
        .iter()
        .map(|inner| {
            let list = inner.as_array()?;
            if list.len() > super::hub::MAX_OPTIONS {
                return None;
            }
            list.iter().map(|x| x.as_str().map(str::to_string)).collect::<Option<Vec<String>>>()
        })
        .collect()
}

enum Next {
    Line(Vec<u8>),
    TooLong,
    Closed,
}

/// Newline-delimited lines, none longer than MAX_LINE.
struct LineReader<R> {
    inner: BufReader<R>,
}

impl<R: AsyncRead + Unpin> LineReader<R> {
    fn new(read: R) -> Self {
        Self { inner: BufReader::new(read) }
    }

    async fn next(&mut self) -> Next {
        loop {
            let mut buf = Vec::new();
            // Never reads more than one byte past the limit, however much is sent.
            let mut limited = (&mut self.inner).take(MAX_LINE as u64 + 2);
            match limited.read_until(b'\n', &mut buf).await {
                Ok(0) | Err(_) => return Next::Closed,
                Ok(_) => {}
            }
            if buf.last() != Some(&b'\n') {
                // No newline within the limit: too long (or the phone vanished mid-line).
                return if buf.len() > MAX_LINE { Next::TooLong } else { Next::Closed };
            }
            buf.pop();
            if buf.last() == Some(&b'\r') {
                buf.pop();
            }
            if buf.len() > MAX_LINE {
                return Next::TooLong;
            }
            if !buf.is_empty() {
                return Next::Line(buf);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_the_local_network_may_connect() {
        for ok in ["192.168.1.20", "10.0.0.5", "172.16.3.4", "172.31.255.255", "127.0.0.1", "169.254.7.7", "::1", "fd12:3456::1", "fe80::1", "::ffff:192.168.0.9"] {
            assert!(is_local(ok.parse().unwrap()), "{ok}");
        }
        for no in ["8.8.8.8", "172.32.0.1", "100.64.0.1", "2001:db8::1", "::ffff:8.8.8.8", "0.0.0.0"] {
            assert!(!is_local(no.parse().unwrap()), "{no}");
        }
    }
}
