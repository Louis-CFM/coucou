// The phone link end to end: a real TLS server on loopback and a client that pins
// the certificate the way the Android app does. The Kotlin client is tried
// against this same server in android/.../RustDesktopInteropTest.kt.

use std::future::Future;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use ring::digest;
use serde_json::{json, Value};
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader, ReadHalf, WriteHalf};
use tokio::net::TcpStream;
use tokio_rustls::client::TlsStream;
use tokio_rustls::rustls::client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier};
use tokio_rustls::rustls::crypto::ring as provider;
use tokio_rustls::rustls::pki_types::{CertificateDer, ServerName, UnixTime};
use tokio_rustls::rustls::{ClientConfig, DigitallySignedStruct, Error, SignatureScheme};
use tokio_rustls::TlsConnector;

use super::hub::{hex, ApprovalIn, Host, Hub, SessionIn};
use super::pairing::{self, tests::MemStore};
use super::server::{self, MAX_LINE};

const TOKEN: &str = "test-token-0123456789abcdef";

fn block_on<F: Future>(f: F) -> F::Output {
    tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
}

#[derive(Default)]
struct Recorder(Mutex<Vec<(String, bool)>>, Mutex<Vec<(String, Value)>>, Mutex<Vec<(u64, String, u64)>>);
impl Host for Recorder {
    fn get_diff(&self, sub_id: u64, pill_id: &str, file_id: u64) {
        self.2.lock().unwrap().push((sub_id, pill_id.to_string(), file_id));
    }
    fn decide(&self, request_id: &str, allow: bool) {
        self.0.lock().unwrap().push((request_id.to_string(), allow));
    }
    fn answer(&self, request_id: &str, answers: &serde_json::Map<String, Value>) {
        self.1.lock().unwrap().push((request_id.to_string(), Value::Object(answers.clone())));
    }
}

struct Rig {
    port: u16,
    fingerprint: String,
    hub: Arc<Hub>,
    host: Arc<Recorder>,
    shared: Arc<server::Shared>,
    handle: Option<server::Handle>,
}

impl Rig {
    async fn start() -> Rig {
        Rig::start_with(None).await
    }

    async fn start_with(chat: Option<Arc<super::chat::ChatLink>>) -> Rig {
        Rig::start_full(chat, Arc::new(server::NoFeatures)).await
    }

    async fn start_full(chat: Option<Arc<super::chat::ChatLink>>, features: Arc<dyn server::Features>) -> Rig {
        let identity = pairing::load_or_create_identity(&MemStore::default()).unwrap();
        let host = Arc::new(Recorder::default());
        let hub = Hub::new(host.clone());
        let shared = server::Shared::with_features(hub.clone(), TOKEN.to_string(), "Test PC".to_string(), chat, features);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let handle = server::serve(listener, server::tls_acceptor(&identity).unwrap(), shared.clone());
        Rig { port, fingerprint: identity.fingerprint, hub, host, shared, handle: Some(handle) }
    }

    fn approval(&self, request: &str, command: &str, age_ms: u64) {
        let now = server::now_ms() - age_ms;
        self.hub.publish(
            vec![],
            Some(ApprovalIn {
                request_id: request.into(),
                session_id: "s1".into(),
                pill_id: "integration_claude".into(),
                tool: "Bash".into(),
                command: command.into(),
            }),
            now,
        );
    }

    fn decisions(&self) -> Vec<(String, bool)> {
        self.host.0.lock().unwrap().clone()
    }
}

impl Drop for Rig {
    fn drop(&mut self) {
        if let Some(h) = self.handle.take() {
            h.stop();
        }
    }
}

/// Accepts exactly one certificate, by its SHA-256 — the Android client's PinnedTrustManager.
#[derive(Debug)]
struct Pin(String);

impl ServerCertVerifier for Pin {
    fn verify_server_cert(
        &self,
        end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _name: &ServerName<'_>,
        _ocsp: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, Error> {
        if hex(digest::digest(&digest::SHA256, end_entity).as_ref()) == self.0 {
            Ok(ServerCertVerified::assertion())
        } else {
            Err(Error::General("certificate does not match the pairing".into()))
        }
    }
    fn verify_tls12_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, Error> {
        tokio_rustls::rustls::crypto::verify_tls12_signature(m, c, d, &provider::default_provider().signature_verification_algorithms)
    }
    fn verify_tls13_signature(&self, m: &[u8], c: &CertificateDer<'_>, d: &DigitallySignedStruct) -> Result<HandshakeSignatureValid, Error> {
        tokio_rustls::rustls::crypto::verify_tls13_signature(m, c, d, &provider::default_provider().signature_verification_algorithms)
    }
    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        provider::default_provider().signature_verification_algorithms.supported_schemes()
    }
}

struct Client {
    r: BufReader<ReadHalf<TlsStream<TcpStream>>>,
    w: WriteHalf<TlsStream<TcpStream>>,
}

impl Client {
    async fn connect(port: u16, pin: &str) -> Result<Client, String> {
        Client::connect_from("127.0.0.1", port, pin).await
    }

    /// From a chosen loopback address (127.0.0.2 and so on), to stand in for another device on the network.
    async fn connect_from(source: &str, port: u16, pin: &str) -> Result<Client, String> {
        let config = ClientConfig::builder_with_provider(Arc::new(provider::default_provider()))
            .with_safe_default_protocol_versions()
            .unwrap()
            .dangerous()
            .with_custom_certificate_verifier(Arc::new(Pin(pin.to_string())))
            .with_no_client_auth();
        let socket = tokio::net::TcpSocket::new_v4().map_err(|e| e.to_string())?;
        socket.bind(format!("{source}:0").parse().unwrap()).map_err(|e| e.to_string())?;
        let tcp = socket.connect(std::net::SocketAddr::from(([127, 0, 0, 1], port))).await.map_err(|e| e.to_string())?;
        let tls = TlsConnector::from(Arc::new(config))
            .connect(ServerName::try_from("coucou").unwrap(), tcp)
            .await
            .map_err(|e| e.to_string())?;
        let (r, w) = tokio::io::split(tls);
        Ok(Client { r: BufReader::new(r), w })
    }

    async fn paired(rig: &Rig) -> Client {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        c.send(json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" })).await;
        assert_eq!(c.recv().await.unwrap()["type"], "welcome");
        c
    }

    async fn send(&mut self, v: Value) {
        self.send_raw(v.to_string().as_bytes()).await;
    }

    async fn send_raw(&mut self, bytes: &[u8]) {
        self.send_unterminated(bytes).await;
        let _ = self.w.write_all(b"\n").await;
        let _ = self.w.flush().await;
    }

    /// Bytes with no end of line, as a misbehaving peer would send them.
    async fn send_unterminated(&mut self, bytes: &[u8]) {
        let _ = self.w.write_all(bytes).await;
        let _ = self.w.flush().await;
    }

    /// The next message, or None if the server closed (or said nothing for 3 s).
    async fn recv(&mut self) -> Option<Value> {
        let mut line = String::new();
        match tokio::time::timeout(Duration::from_secs(3), self.r.read_line(&mut line)).await {
            Ok(Ok(n)) if n > 0 => Some(serde_json::from_str(&line).unwrap()),
            _ => None,
        }
    }

    /// The next message of this type, skipping others.
    async fn expect(&mut self, kind: &str) -> Value {
        for _ in 0..10 {
            let m = self.recv().await.unwrap_or_else(|| panic!("closed while waiting for {kind}"));
            if m["type"] == kind {
                return m;
            }
        }
        panic!("no {kind} message");
    }

    /// True once the server has really closed this connection (an end of stream,
    /// not just a quiet one).
    async fn closed(&mut self) -> bool {
        loop {
            let mut line = String::new();
            match tokio::time::timeout(Duration::from_secs(3), self.r.read_line(&mut line)).await {
                Ok(Ok(0)) | Ok(Err(_)) => return true,
                Ok(Ok(_)) => continue, // a last word before closing
                Err(_) => return false,
            }
        }
    }
}

#[test]
fn a_paired_phone_gets_sessions_and_answers_the_request() {
    block_on(async {
        let rig = Rig::start().await;
        rig.hub.publish(
            vec![SessionIn { pill_id: "integration_claude".into(), agent: "Claude Code".into(), state: "working".into(), status_text: "Editing".into(), step_index: 2, step_count: 6, ..Default::default() }],
            None,
            server::now_ms(),
        );
        let mut c = Client::paired(&rig).await;
        let sessions = c.expect("sessions").await;
        assert_eq!(sessions["sessions"][0]["agent"], "Claude Code");
        assert_eq!(sessions["sessions"][0]["state"], "working");

        rig.approval("req-1", "npm run build", 0);
        let approval = c.expect("approval").await;
        assert_eq!(approval["pillId"], "integration_claude");
        assert_eq!(approval["tool"], "Bash");
        assert_eq!(approval["command"], "npm run build");
        let fp = approval["fingerprint"].as_str().unwrap().to_string();
        assert_eq!(fp, super::hub::fingerprint("integration_claude", "s1", "Bash", "npm run build", "req-1"));

        c.send(json!({ "type": "decision", "fingerprint": fp, "decision": "allow" })).await;
        let resolved = c.expect("approvalResolved").await;
        assert_eq!(resolved["fingerprint"], fp);
        assert_eq!(rig.decisions(), vec![("req-1".to_string(), true)]);

        c.send(json!({ "type": "ping" })).await;
        c.expect("pong").await;
        c.send(json!({ "type": "bye" })).await;
        assert!(c.closed().await);
    });
}

#[test]
fn a_wrong_token_is_refused_and_gets_nothing() {
    block_on(async {
        let rig = Rig::start().await;
        rig.approval("req-1", "rm -rf /", 0);
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        c.send(json!({ "type": "hello", "v": 1, "token": "x".repeat(TOKEN.len()), "device": "Intruder" })).await;
        let first = c.recv().await.unwrap();
        assert_eq!(first["type"], "error");
        assert_eq!(first["code"], "auth");
        assert!(c.closed().await);
        assert_eq!(rig.hub.clients(), 0);
        assert!(rig.decisions().is_empty());
    });
}

#[test]
fn a_token_of_another_length_or_a_missing_one_is_refused_too() {
    block_on(async {
        let rig = Rig::start().await;
        for hello in [
            json!({ "type": "hello", "v": 1, "token": "short", "device": "x" }),
            json!({ "type": "hello", "v": 1, "device": "x" }),
            json!({ "type": "hello", "v": 1, "token": 12345, "device": "x" }),
            json!({ "type": "hello", "v": 1, "token": format!("{TOKEN}extra"), "device": "x" }),
            // Right token, other protocol version: the phone would refuse the desktop anyway.
            json!({ "type": "hello", "v": 2, "token": TOKEN, "device": "x" }),
            json!({ "type": "hello", "token": TOKEN, "device": "x" }),
        ] {
            let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
            c.send(hello.clone()).await;
            assert_eq!(c.recv().await.unwrap()["code"], "auth", "{hello}");
        }
        assert_eq!(rig.hub.clients(), 0);
    });
}

#[test]
fn a_phone_that_does_not_say_hello_first_gets_nowhere() {
    block_on(async {
        let rig = Rig::start().await;
        rig.approval("req-1", "ls", 0);
        let fp = super::hub::fingerprint("integration_claude", "s1", "Bash", "ls", "req-1");
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        c.send(json!({ "type": "decision", "fingerprint": fp, "decision": "allow" })).await;
        assert!(c.closed().await);
        assert!(rig.decisions().is_empty(), "a decision before hello must never be applied");

        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        c.send_raw(b"this is not json").await;
        assert!(c.closed().await);
    });
}

#[test]
fn a_decision_for_another_request_changes_nothing() {
    block_on(async {
        let rig = Rig::start().await;
        rig.approval("req-2", "npm test", 0);
        let mut c = Client::paired(&rig).await;
        let real = c.expect("approval").await["fingerprint"].as_str().unwrap().to_string();

        // The same command, but the fingerprint of an earlier request.
        let stale = super::hub::fingerprint("integration_claude", "s1", "Bash", "npm test", "req-1");
        for odd in [stale.as_str(), "", "not-a-fingerprint", &real.to_uppercase()] {
            c.send(json!({ "type": "decision", "fingerprint": odd, "decision": "allow" })).await;
        }
        c.send(json!({ "type": "decision", "fingerprint": real, "decision": "always" })).await;
        c.send(json!({ "type": "decision", "fingerprint": real })).await;
        c.send(json!({ "type": "decision", "decision": "allow" })).await;
        // A round trip proves the server has read all of the above.
        c.send(json!({ "type": "ping" })).await;
        c.expect("pong").await;
        assert!(rig.decisions().is_empty());

        // And the real request is still waiting for the real answer.
        c.send(json!({ "type": "decision", "fingerprint": real, "decision": "deny" })).await;
        c.expect("approvalResolved").await;
        assert_eq!(rig.decisions(), vec![("req-2".to_string(), false)]);
    });
}

#[test]
fn a_decision_that_comes_too_late_is_ignored() {
    block_on(async {
        let rig = Rig::start().await;
        // The request has been waiting for two minutes: the desktop dismissed it long ago.
        rig.approval("req-1", "npm test", 120_000);
        let mut c = Client::paired(&rig).await;
        // It is not even offered to a phone that connects now.
        c.send(json!({ "type": "ping" })).await;
        let mut offered = false;
        loop {
            let m = c.recv().await.unwrap();
            offered |= m["type"] == "approval";
            if m["type"] == "pong" {
                break;
            }
        }
        assert!(!offered, "an expired request must not be offered");

        // A phone that still holds it from before answers anyway.
        let fp = super::hub::fingerprint("integration_claude", "s1", "Bash", "npm test", "req-1");
        c.send(json!({ "type": "decision", "fingerprint": fp, "decision": "allow" })).await;
        c.send(json!({ "type": "ping" })).await;
        c.expect("pong").await;
        assert!(rig.decisions().is_empty());
    });
}

#[test]
fn a_decision_after_the_desktop_answered_is_ignored() {
    block_on(async {
        let rig = Rig::start().await;
        rig.approval("req-1", "npm test", 0);
        let mut c = Client::paired(&rig).await;
        let fp = c.expect("approval").await["fingerprint"].as_str().unwrap().to_string();

        // Allowed at the desk: the island publishes no pending request any more.
        rig.hub.publish(vec![], None, server::now_ms());
        assert_eq!(c.expect("approvalResolved").await["fingerprint"], fp);

        c.send(json!({ "type": "decision", "fingerprint": fp, "decision": "allow" })).await;
        c.send(json!({ "type": "ping" })).await;
        c.expect("pong").await;
        assert!(rig.decisions().is_empty());
    });
}

#[test]
fn a_line_over_64_kib_closes_the_connection() {
    block_on(async {
        let rig = Rig::start().await;

        // Before hello.
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        c.send_raw(&vec![b'a'; MAX_LINE + 10]).await;
        assert!(c.closed().await);

        // After hello.
        let mut c = Client::paired(&rig).await;
        c.send_raw(&vec![b'a'; MAX_LINE + 10]).await;
        assert!(c.closed().await);

        // A flood with no newline at all is cut at the limit, not buffered for ever.
        let mut c = Client::paired(&rig).await;
        for _ in 0..8 {
            c.send_unterminated(&vec![b'b'; 32 * 1024]).await;
        }
        assert!(c.closed().await);
        assert_eq!(rig.hub.clients(), 0);

        // The server is fine afterwards.
        let mut c = Client::paired(&rig).await;
        c.send(json!({ "type": "ping" })).await;
        c.expect("pong").await;
    });
}

#[test]
fn a_line_of_exactly_64_kib_is_accepted() {
    block_on(async {
        let rig = Rig::start().await;
        let mut c = Client::paired(&rig).await;
        let head = r#"{"type":"ping","pad":""#;
        let tail = r#""}"#;
        let pad = "p".repeat(MAX_LINE - head.len() - tail.len());
        let line = format!("{head}{pad}{tail}");
        assert_eq!(line.len(), MAX_LINE);
        c.send_raw(line.as_bytes()).await;
        c.expect("pong").await;
    });
}

#[test]
fn a_phone_with_another_certificate_in_mind_does_not_connect() {
    block_on(async {
        let rig = Rig::start().await;
        let err = Client::connect(rig.port, &"0".repeat(64)).await.err().expect("the pin must fail");
        assert!(err.contains("does not match"), "{err}");
        assert_eq!(rig.hub.clients(), 0);
    });
}

#[test]
fn plain_text_is_not_spoken_here() {
    block_on(async {
        let rig = Rig::start().await;
        let mut tcp = TcpStream::connect(("127.0.0.1", rig.port)).await.unwrap();
        tcp.write_all(b"{\"type\":\"hello\",\"v\":1,\"token\":\"test-token-0123456789abcdef\"}\n").await.unwrap();
        let mut buf = Vec::new();
        let mut r = BufReader::new(tcp);
        let _ = tokio::time::timeout(Duration::from_secs(3), r.read_until(b'\n', &mut buf)).await;
        assert!(!String::from_utf8_lossy(&buf).contains("welcome"));
        assert_eq!(rig.hub.clients(), 0);
    });
}

#[test]
fn pairing_again_locks_the_old_phone_out() {
    block_on(async {
        let rig = Rig::start().await;
        let mut old = Client::paired(&rig).await;

        // What phone_link_new_pairing does.
        *rig.shared.token.lock().unwrap() = "a-brand-new-token-0123456789".to_string();
        rig.hub.kick_all("auth", "unpaired");
        let word = old.expect("error").await;
        assert_eq!(word["code"], "auth");
        assert!(old.closed().await);

        let mut again = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        again.send(json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "old" })).await;
        assert_eq!(again.recv().await.unwrap()["code"], "auth");
        let mut fresh = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        fresh.send(json!({ "type": "hello", "v": 1, "token": "a-brand-new-token-0123456789", "device": "new" })).await;
        assert_eq!(fresh.recv().await.unwrap()["type"], "welcome");
    });
}

#[test]
fn turning_it_off_closes_the_phones_and_stops_listening() {
    block_on(async {
        let mut rig = Rig::start().await;
        let mut c = Client::paired(&rig).await;
        let port = rig.port;
        rig.handle.take().unwrap().stop();
        assert!(c.closed().await);
        // Nobody answers any more (the listener was dropped with the task).
        tokio::time::sleep(Duration::from_millis(100)).await;
        assert!(Client::connect(port, &rig.fingerprint).await.is_err());
    });
}

/// True when this machine lets us use 127.0.0.2 and 127.0.0.3 as other devices (Linux and Windows do; some systems do not).
fn loopback_aliases() -> bool {
    ["127.0.0.2", "127.0.0.3"].iter().all(|a| std::net::TcpListener::bind((*a, 0)).is_ok())
}

/// Whether a connection that was admitted answers a hello (a dropped one is closed unserved or never completes TLS).
async fn served(c: Result<Client, String>) -> bool {
    match c {
        Err(_) => false,
        Ok(mut c) => {
            c.send(json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "probe" })).await;
            c.recv().await.is_some()
        }
    }
}

#[test]
fn the_total_number_of_connections_is_limited() {
    block_on(async {
        let rig = Rig::start().await;
        // Eight phones that said a valid hello fill the pool; the ninth is dropped.
        let mut phones = Vec::new();
        for _ in 0..8 {
            phones.push(Client::paired(&rig).await);
        }
        assert!(!served(Client::connect(rig.port, &rig.fingerprint).await).await, "the ninth connection");
        drop(phones);
    });
}

#[test]
fn one_address_cannot_hold_more_than_two_silent_connections() {
    block_on(async {
        let rig = Rig::start().await;
        let a = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let b = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        // A third that never says hello is refused before it can wait.
        assert!(!served(Client::connect(rig.port, &rig.fingerprint).await).await, "the third from one address");
        // Closing one frees its place.
        drop(a);
        tokio::time::sleep(Duration::from_millis(200)).await;
        assert!(served(Client::connect(rig.port, &rig.fingerprint).await).await);
        drop(b);
    });
}

#[test]
fn a_flood_from_one_address_cannot_lock_out_the_paired_phone() {
    if !loopback_aliases() {
        eprintln!("skipped: this machine has no 127.0.0.2/127.0.0.3");
        return;
    }
    block_on(async {
        let rig = Rig::start().await;
        // The phone (127.0.0.1) pairs once, so the computer knows its address.
        drop(Client::paired(&rig).await);
        tokio::time::sleep(Duration::from_millis(200)).await;
        // Another device floods with silent connections: only two are kept.
        let mut flood = Vec::new();
        for _ in 0..10 {
            if let Ok(c) = Client::connect_from("127.0.0.2", rig.port, &rig.fingerprint).await {
                flood.push(c);
            }
        }
        assert!(flood.len() <= 2, "the flood is capped at two, got {}", flood.len());
        // The paired phone connects and is served, again and again, while the flood goes on.
        for _ in 0..3 {
            let mut phone = Client::paired(&rig).await;
            phone.send(json!({ "type": "ping" })).await;
            phone.expect("pong").await;
        }
        drop(flood);
    });
}

#[test]
fn a_flood_from_several_addresses_still_leaves_room_for_the_known_phone() {
    if !loopback_aliases() {
        eprintln!("skipped: this machine has no 127.0.0.2/127.0.0.3");
        return;
    }
    block_on(async {
        let rig = Rig::start().await;
        drop(Client::paired(&rig).await);
        tokio::time::sleep(Duration::from_millis(200)).await;
        // Two other devices fill the whole stranger pool (2 + 2).
        let mut flood = Vec::new();
        for source in ["127.0.0.2", "127.0.0.3"] {
            for _ in 0..4 {
                if let Ok(c) = Client::connect_from(source, rig.port, &rig.fingerprint).await {
                    flood.push(c);
                }
            }
        }
        assert_eq!(flood.len(), 4, "strangers share four places");
        let mut phone = Client::paired(&rig).await;
        phone.send(json!({ "type": "ping" })).await;
        phone.expect("pong").await;
        drop(flood);
    });
}


// ── Chat from the phone: the rules, with a fake provider ──────────────────

mod chat_tests {
    use super::*;
    use crate::phone_link::chat::{
        reason, BoxFuture, ChatBackend, ChatConfig, ChatFail, ChatLink, ModelOption, DONE_TEXT_MAX, MAX_SENDS, MAX_TEXT_CHARS,
    };
    use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
    use tokio::sync::mpsc::UnboundedSender;

    #[derive(Clone)]
    enum Script {
        /// Streams these parts one after the other (the answer so far each time).
        Words(Vec<String>),
        /// Streams `streamed`, then returns `full` (which is not an extension of it).
        Rewrite { streamed: String, full: String },
        Fail(ChatFail),
        /// Never answers (a slow provider).
        Hang,
    }

    struct Fake {
        config: Mutex<ChatConfig>,
        script: Mutex<Script>,
        calls: Mutex<Vec<(String, String)>>,
        resets: AtomicUsize,
        dropped: Arc<AtomicBool>,
    }

    impl Fake {
        fn new(enabled: bool) -> Arc<Fake> {
            let models = vec![
                ModelOption { id: "anthropic/claude-x".into(), provider: "anthropic".into(), label: "Claude X".into() },
                ModelOption { id: "openai/gpt-y".into(), provider: "openai".into(), label: "GPT Y".into() },
            ];
            Arc::new(Fake {
                config: Mutex::new(ChatConfig { enabled, allowed: models }),
                script: Mutex::new(Script::Words(vec!["Hel".into(), "lo".into(), " world".into()])),
                calls: Mutex::new(Vec::new()),
                resets: AtomicUsize::new(0),
                dropped: Arc::new(AtomicBool::new(false)),
            })
        }
        fn script(&self, s: Script) {
            *self.script.lock().unwrap() = s;
        }
        fn enable(&self, on: bool) {
            self.config.lock().unwrap().enabled = on;
        }
    }

    impl ChatBackend for Fake {
        fn config(&self) -> ChatConfig {
            self.config.lock().unwrap().clone()
        }
        fn send(&self, model_id: &str, text: String, deltas: UnboundedSender<String>) -> BoxFuture<Result<String, ChatFail>> {
            self.calls.lock().unwrap().push((model_id.to_string(), text));
            let script = self.script.lock().unwrap().clone();
            let dropped = self.dropped.clone();
            self.dropped.store(false, Ordering::SeqCst);
            Box::pin(async move {
                struct Mark(Arc<AtomicBool>);
                impl Drop for Mark {
                    fn drop(&mut self) {
                        self.0.store(true, Ordering::SeqCst);
                    }
                }
                let _mark = Mark(dropped);
                match script {
                    Script::Words(parts) => {
                        let mut so_far = String::new();
                        for p in parts {
                            so_far.push_str(&p);
                            let _ = deltas.send(so_far.clone());
                            tokio::task::yield_now().await;
                        }
                        Ok(so_far)
                    }
                    Script::Rewrite { streamed, full } => {
                        let _ = deltas.send(streamed);
                        tokio::task::yield_now().await;
                        Ok(full)
                    }
                    Script::Fail(f) => Err(f),
                    Script::Hang => std::future::pending().await,
                }
            })
        }
        fn reset(&self) {
            self.resets.fetch_add(1, Ordering::SeqCst);
        }
    }

    async fn rig(fake: &Arc<Fake>) -> Rig {
        Rig::start_with(Some(ChatLink::new(fake.clone()))).await
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    fn send(id: &str, model: &str, text: &str) -> Value {
        json!({ "type": "chatSend", "id": id, "model": model, "text": text })
    }

    /// Everything of one answer until chatDone or chatError.
    async fn answer(c: &mut Client, id: &str) -> (String, Value) {
        let mut text = String::new();
        for _ in 0..200 {
            let m = c.recv().await.expect("the connection closed or went quiet");
            match m["type"].as_str() {
                Some("chatDelta") if m["id"] == id => text.push_str(m["text"].as_str().unwrap()),
                Some("chatDone") | Some("chatError") if m["id"] == id => return (text, m),
                _ => {}
            }
        }
        panic!("no end of answer");
    }

    #[test]
    fn a_phone_that_asks_is_offered_chat_and_gets_only_the_allowed_models() {
        block_on(async {
            let fake = Fake::new(true);
            let rig = rig(&fake).await;
            let (mut c, welcome) = phone(&rig, Some(json!(["chat"]))).await;
            assert_eq!(welcome["caps"], json!(["chat"]));
            c.send(json!({ "type": "chatModels" })).await;
            let m = c.expect("chatModels").await;
            assert_eq!(m["models"][0], json!({ "id": "anthropic/claude-x", "provider": "anthropic", "label": "Claude X" }));
            assert_eq!(m["models"].as_array().unwrap().len(), 2);
            // only ids, providers and labels: nothing else is in the message
            assert_eq!(m["models"][0].as_object().unwrap().len(), 3);
        });
    }

    #[test]
    fn an_older_phone_is_never_offered_nor_answered_anything_about_chat() {
        block_on(async {
            let fake = Fake::new(true);
            let rig = rig(&fake).await;
            let (mut c, welcome) = phone(&rig, None).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
            c.send(send("a1", "anthropic/claude-x", "hi")).await;
            c.send(json!({ "type": "chatModels" })).await;
            c.send(json!({ "type": "ping" })).await;
            // the first thing back is the pong: nothing was said about chat in between
            loop {
                let m = c.recv().await.unwrap();
                assert!(!m["type"].as_str().unwrap().starts_with("chat"), "{m}");
                if m["type"] == "pong" {
                    break;
                }
            }
            assert!(fake.calls.lock().unwrap().is_empty());
        });
    }

    #[test]
    fn an_older_computer_is_the_same_as_chat_being_off_no_caps_in_welcome() {
        block_on(async {
            // No chat wired in at all (as before this feature): the welcome has no caps even if the phone asks.
            let rig = Rig::start().await;
            let (_c, welcome) = phone(&rig, Some(json!(["chat", "details"]))).await;
            assert!(welcome.get("caps").is_none());
            assert_eq!(welcome["v"], 1);
        });
    }

    #[test]
    fn with_the_switch_off_nothing_is_offered_and_a_send_is_ignored() {
        block_on(async {
            let fake = Fake::new(false);
            let rig = rig(&fake).await;
            let (mut c, welcome) = phone(&rig, Some(json!(["chat"]))).await;
            assert!(welcome.get("caps").is_none());
            c.send(send("a1", "anthropic/claude-x", "hi")).await;
            c.send(json!({ "type": "ping" })).await;
            loop {
                let m = c.recv().await.unwrap();
                assert!(!m["type"].as_str().unwrap().starts_with("chat"), "{m}");
                if m["type"] == "pong" {
                    break;
                }
            }
            assert!(fake.calls.lock().unwrap().is_empty());
        });
    }

    #[test]
    fn an_answer_arrives_in_pieces_that_add_up_and_the_model_gets_the_text() {
        block_on(async {
            let fake = Fake::new(true);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "Say hello")).await;
            let (text, end) = answer(&mut c, "a1").await;
            assert_eq!(text, "Hello world");
            assert_eq!(end["type"], "chatDone");
            assert!(end.get("text").is_none(), "no correction needed");
            assert_eq!(*fake.calls.lock().unwrap(), vec![("openai/gpt-y".to_string(), "Say hello".to_string())]);
        });
    }

    #[test]
    fn a_rewritten_answer_is_corrected_in_done() {
        block_on(async {
            let fake = Fake::new(true);
            fake.script(Script::Rewrite { streamed: "<think>hmm".into(), full: "Answer".into() });
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "q")).await;
            let (_, end) = answer(&mut c, "a1").await;
            assert_eq!(end["type"], "chatDone");
            assert_eq!(end["text"], "Answer");
        });
    }

    #[test]
    fn a_huge_answer_is_cut_into_lines_under_64_kib() {
        block_on(async {
            let fake = Fake::new(true);
            let big = "é".repeat(60_000); // 120 KB in one go
            fake.script(Script::Words(vec![big.clone()]));
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "q")).await;
            let (text, end) = answer(&mut c, "a1").await;
            assert_eq!(end["type"], "chatDone");
            assert_eq!(text, big);
        });
    }

    #[test]
    fn failures_carry_a_fixed_code_and_message_only() {
        block_on(async {
            for (fail, code) in [
                (ChatFail::NoKey, "no_key"),
                (ChatFail::Unreachable, "unreachable"),
                (ChatFail::Auth, "auth"),
                (ChatFail::Provider, "provider"),
                (ChatFail::Internal, "internal"),
            ] {
                let fake = Fake::new(true);
                fake.script(Script::Fail(fail));
                let rig = rig(&fake).await;
                let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
                c.send(send("a1", "openai/gpt-y", "q")).await;
                let (_, end) = answer(&mut c, "a1").await;
                assert_eq!(end["type"], "chatError");
                assert_eq!(end["reason"], code);
                assert_eq!(end["message"], reason(code));
                assert_eq!(end.as_object().unwrap().len(), 4, "type, id, reason, message and nothing else: {end}");
            }
        });
    }

    #[test]
    fn the_text_the_model_and_the_id_are_checked() {
        block_on(async {
            let fake = Fake::new(true);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("e1", "openai/gpt-y", &"x".repeat(MAX_TEXT_CHARS + 1))).await;
            assert_eq!(answer(&mut c, "e1").await.1["reason"], "too_long");
            c.send(send("e2", "openai/gpt-y", "   ")).await;
            assert_eq!(answer(&mut c, "e2").await.1["reason"], "empty");
            c.send(send("e3", "openai/not-allowed", "hi")).await;
            assert_eq!(answer(&mut c, "e3").await.1["reason"], "not_allowed");
            c.send(send("e4", "", "hi")).await;
            assert_eq!(answer(&mut c, "e4").await.1["reason"], "not_allowed");
            // exactly the limit is fine
            c.send(send("ok", "openai/gpt-y", &"é".repeat(MAX_TEXT_CHARS))).await;
            assert_eq!(answer(&mut c, "ok").await.1["type"], "chatDone");
            // an id that is empty, too long or odd is not answered at all
            for bad in ["", &"a".repeat(65), "a b", "a\u{0}b"] {
                c.send(send(bad, "openai/gpt-y", "hi")).await;
            }
            c.send(json!({ "type": "ping" })).await;
            c.expect("pong").await;
            assert_eq!(fake.calls.lock().unwrap().len(), 1, "only the valid send reached the provider");
        });
    }

    #[test]
    fn only_one_answer_runs_at_a_time_and_cancel_frees_the_slot() {
        block_on(async {
            let fake = Fake::new(true);
            fake.script(Script::Hang);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "slow")).await;
            // wait until the provider call has started
            for _ in 0..100 {
                if !fake.calls.lock().unwrap().is_empty() {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            c.send(send("a2", "openai/gpt-y", "second")).await;
            assert_eq!(answer(&mut c, "a2").await.1["reason"], "busy");
            c.send(json!({ "type": "chatCancel", "id": "a1" })).await;
            assert_eq!(answer(&mut c, "a1").await.1["reason"], "canceled");
            assert!(wait_for(|| fake.dropped.load(Ordering::SeqCst)).await, "the provider call was dropped");
            fake.script(Script::Words(vec!["ok".into()]));
            c.send(send("a3", "openai/gpt-y", "third")).await;
            assert_eq!(answer(&mut c, "a3").await.0, "ok");
        });
    }

    #[test]
    fn a_cancel_for_another_id_changes_nothing() {
        block_on(async {
            let fake = Fake::new(true);
            fake.script(Script::Hang);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "slow")).await;
            c.send(json!({ "type": "chatCancel", "id": "other" })).await;
            c.send(send("a2", "openai/gpt-y", "x")).await;
            assert_eq!(answer(&mut c, "a2").await.1["reason"], "busy", "a1 is still running");
        });
    }

    #[test]
    fn the_rate_limit_stops_the_thirteenth_send() {
        block_on(async {
            let fake = Fake::new(true);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            for i in 0..MAX_SENDS {
                let id = format!("m{i}");
                c.send(send(&id, "openai/gpt-y", "hi")).await;
                assert_eq!(answer(&mut c, &id).await.1["type"], "chatDone", "send {i}");
            }
            c.send(send("over", "openai/gpt-y", "hi")).await;
            assert_eq!(answer(&mut c, "over").await.1["reason"], "rate");
            assert_eq!(fake.calls.lock().unwrap().len(), MAX_SENDS);
        });
    }

    #[test]
    fn leaving_stops_the_answer_and_frees_the_slot_for_the_next_phone() {
        block_on(async {
            let fake = Fake::new(true);
            fake.script(Script::Hang);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "slow")).await;
            assert!(wait_for(|| !fake.calls.lock().unwrap().is_empty()).await);
            c.send(json!({ "type": "bye" })).await;
            assert!(c.closed().await);
            assert!(wait_for(|| fake.dropped.load(Ordering::SeqCst)).await, "no answer keeps running for a phone that left");
            fake.script(Script::Words(vec!["fine".into()]));
            let (mut d, _) = phone(&rig, Some(json!(["chat"]))).await;
            d.send(send("b1", "openai/gpt-y", "hi")).await;
            assert_eq!(answer(&mut d, "b1").await.0, "fine");
        });
    }

    #[test]
    fn switching_chat_off_while_connected_refuses_further_sends() {
        block_on(async {
            let fake = Fake::new(true);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            fake.enable(false);
            c.send(send("a1", "openai/gpt-y", "hi")).await;
            let (_, end) = answer(&mut c, "a1").await;
            assert_eq!(end["reason"], "off");
            assert!(fake.calls.lock().unwrap().is_empty());
            c.send(json!({ "type": "chatModels" })).await;
            assert_eq!(c.expect("chatModels").await["models"], json!([]));
        });
    }

    #[test]
    fn turning_the_link_off_cancels_the_answer_and_forgets_the_conversation() {
        block_on(async {
            let fake = Fake::new(true);
            fake.script(Script::Hang);
            let mut rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "slow")).await;
            assert!(wait_for(|| !fake.calls.lock().unwrap().is_empty()).await);
            rig.handle.take().unwrap().stop();
            assert!(wait_for(|| fake.dropped.load(Ordering::SeqCst)).await);
            assert_eq!(fake.resets.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn new_chat_forgets_the_computers_side_and_stops_a_running_answer() {
        block_on(async {
            let fake = Fake::new(true);
            fake.script(Script::Hang);
            let rig = rig(&fake).await;
            let (mut c, _) = phone(&rig, Some(json!(["chat"]))).await;
            c.send(send("a1", "openai/gpt-y", "slow")).await;
            assert!(wait_for(|| !fake.calls.lock().unwrap().is_empty()).await);
            c.send(json!({ "type": "chatReset" })).await;
            assert_eq!(answer(&mut c, "a1").await.1["reason"], "canceled");
            assert_eq!(fake.resets.load(Ordering::SeqCst), 1);
        });
    }

    #[test]
    fn nothing_that_leaves_the_computer_can_contain_a_key_or_a_provider_message() {
        block_on(async {
            // The backend has no way to hand text to the link besides the answer itself, so
            // a failure cannot carry any; this pins the messages that exist.
            for code in ["off", "not_allowed", "busy", "rate", "too_long", "empty", "no_key", "unreachable", "auth", "provider", "canceled", "internal"] {
                let m = reason(code);
                assert!(!m.contains("sk-") && !m.to_lowercase().contains("bearer") && !m.contains("key:"), "{m}");
            }
            assert!(DONE_TEXT_MAX < 64 * 1024);
        });
    }

    async fn wait_for(cond: impl Fn() -> bool) -> bool {
        for _ in 0..200 {
            if cond() {
                return true;
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        false
    }
}


// ── Session details (cap `details`) end to end ───────────────────────────────────────────────

mod details_tests {
    use super::*;
    use crate::phone_link::server::Features;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Switch(AtomicBool);
    impl Features for Switch {
        fn details(&self) -> bool {
            self.0.load(Ordering::SeqCst)
        }
    }

    fn rich() -> SessionIn {
        SessionIn {
            pill_id: "integration_claude".into(),
            agent: "Claude Code".into(),
            state: "finished".into(),
            status_text: "Done".into(),
            step_index: 2,
            step_count: 3,
            steps: vec!["Read · a.rs".into(), "Edit · a.rs".into()],
            final_line: Some("Fixed the bug".into()),
            project: Some("/home/me/secret-folder/coucou".into()),
            color: Some("#2DD4BF".into()),
            ..Default::default()
        }
    }

    async fn rig(on: bool) -> Rig {
        let rig = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(on)))).await;
        rig.hub.publish(vec![rich()], None, server::now_ms());
        rig
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        let sessions = c.expect("sessions").await;
        (c, welcome, sessions)
    }

    #[test]
    fn a_phone_that_asks_gets_the_details_when_the_switch_is_on() {
        block_on(async {
            let rig = rig(true).await;
            let (_c, welcome, sessions) = phone(&rig, Some(json!(["details"]))).await;
            assert_eq!(welcome["caps"], json!(["details"]));
            let s = &sessions["sessions"][0];
            assert_eq!(s["steps"], json!(["Read · a.rs", "Edit · a.rs"]));
            assert_eq!(s["finalLine"], "Fixed the bug");
            assert_eq!(s["project"], "coucou", "the folder name, never the path");
            assert_eq!(s["color"], "#2DD4BF");
            assert!(!sessions.to_string().contains("secret-folder"));
        });
    }

    #[test]
    fn an_older_phone_gets_the_v1_sessions_and_no_caps() {
        block_on(async {
            let rig = rig(true).await;
            let (_c, welcome, sessions) = phone(&rig, None).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
            let s = sessions["sessions"][0].as_object().unwrap();
            let mut keys: Vec<&str> = s.keys().map(String::as_str).collect();
            keys.sort_unstable();
            assert_eq!(keys, ["agent", "pillId", "state", "statusText", "stepCount", "stepIndex", "updatedAt"]);
            assert!(!sessions.to_string().contains("coucou") && !sessions.to_string().contains("Fixed the bug"));
        });
    }

    #[test]
    fn with_the_switch_off_nothing_extra_is_offered_even_to_a_phone_that_asks() {
        block_on(async {
            let rig = rig(false).await;
            let (_c, welcome, sessions) = phone(&rig, Some(json!(["details", "chat"]))).await;
            assert!(welcome.get("caps").is_none());
            assert!(sessions["sessions"][0].get("steps").is_none());
            assert!(sessions["sessions"][0].get("project").is_none());
        });
    }

    #[test]
    fn a_phone_gets_a_live_update_with_details_and_another_phone_without() {
        block_on(async {
            let rig = rig(true).await;
            let (mut with, _, _) = phone(&rig, Some(json!(["details"]))).await;
            let (mut without, _, _) = phone(&rig, None).await;
            let mut next = rich();
            next.final_line = Some("A second line".into());
            rig.hub.publish(vec![next], None, server::now_ms());
            let a = with.expect("sessions").await;
            let b = without.expect("sessions").await;
            assert_eq!(a["sessions"][0]["finalLine"], "A second line");
            assert!(b["sessions"][0].get("finalLine").is_none());
        });
    }

    #[test]
    fn a_full_load_of_details_still_arrives_under_the_line_limit() {
        block_on(async {
            let rig = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let sessions: Vec<SessionIn> = (0..16)
                .map(|i| SessionIn { pill_id: format!("agent_{i}"), steps: (0..20).map(|n| format!("{n} {}", "x".repeat(250))).collect(), ..rich() })
                .collect();
            rig.hub.publish(sessions, None, server::now_ms());
            let (_c, _, line) = phone(&rig, Some(json!(["details"]))).await;
            assert_eq!(line["sessions"].as_array().unwrap().len(), 16);
        });
    }
}


// ── Answering questions (cap `answers`) end to end ───────────────────────────────────────────

mod answers_tests {
    use super::*;
    use crate::phone_link::hub::{OptionIn, QuestionIn, QuestionItemIn};
    use crate::phone_link::server::Features;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Switch(AtomicBool);
    impl Features for Switch {
        fn details(&self) -> bool {
            false
        }
        fn answers(&self) -> bool {
            self.0.load(Ordering::SeqCst)
        }
    }

    fn opt(l: &str) -> OptionIn {
        OptionIn { label: l.into(), description: format!("about {l}") }
    }

    fn question(request: &str) -> QuestionIn {
        QuestionIn {
            request_id: request.into(),
            session_id: "s1".into(),
            pill_id: "integration_claude".into(),
            questions: vec![
                QuestionItemIn { question: "Which engine?".into(), options: vec![opt("Postgres"), opt("Meilisearch")], multi_select: false },
                QuestionItemIn { question: "Which extras?".into(), options: vec![opt("Typos"), opt("Facets"), opt("Synonyms")], multi_select: true },
            ],
        }
    }

    async fn rig(on: bool) -> Rig {
        Rig::start_full(None, Arc::new(Switch(AtomicBool::new(on)))).await
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    /// Everything the phone is sent up to the answer to a ping: proves what it was and was not told.
    async fn types_until_pong(c: &mut Client) -> Vec<String> {
        c.send(json!({ "type": "ping" })).await;
        let mut seen = Vec::new();
        for _ in 0..10 {
            let m = c.recv().await.expect("closed");
            let t = m["type"].as_str().unwrap_or("").to_string();
            if t == "pong" {
                return seen;
            }
            seen.push(t);
        }
        panic!("no pong");
    }

    fn answers_of(rig: &Rig) -> Vec<(String, Value)> {
        rig.host.1.lock().unwrap().clone()
    }

    #[test]
    fn a_phone_that_asks_is_offered_answers_only_while_the_switch_is_on() {
        block_on(async {
            let on = rig(true).await;
            let (_c, welcome) = phone(&on, Some(json!(["answers"]))).await;
            assert_eq!(welcome["caps"], json!(["answers"]));
            let off = rig(false).await;
            let (_c, welcome) = phone(&off, Some(json!(["answers"]))).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
        });
    }

    #[test]
    fn the_question_reaches_a_phone_with_the_capability_and_no_other() {
        block_on(async {
            let rig = rig(true).await;
            let (mut with, _) = phone(&rig, Some(json!(["answers"]))).await;
            let (mut old, _) = phone(&rig, None).await;
            rig.hub.publish_question(Some(question("r1")), server::now_ms());
            let q = with.expect("question").await;
            assert_eq!(q["questions"][0]["question"], "Which engine?");
            assert_eq!(q["questions"][1]["multiSelect"], true);
            assert_eq!(q["questions"][0]["options"][1]["label"], "Meilisearch");
            assert!(q["fingerprint"].as_str().unwrap().len() == 64);
            assert!(q.get("requestId").is_none() && !q.to_string().contains("r1"), "the island's request id stays on the computer");
            // the older phone is told nothing, not even that something was resolved
            rig.hub.publish_question(None, server::now_ms());
            assert_eq!(with.expect("approvalResolved").await["fingerprint"], q["fingerprint"]);
            let told = types_until_pong(&mut old).await;
            assert!(!told.iter().any(|t| t == "question" || t == "approvalResolved"), "{told:?}");
        });
    }

    #[test]
    fn a_phone_that_connects_late_still_gets_the_question_that_waits() {
        block_on(async {
            let rig = rig(true).await;
            rig.hub.publish_question(Some(question("r1")), server::now_ms());
            let (mut c, _) = phone(&rig, Some(json!(["answers"]))).await;
            assert_eq!(c.expect("question").await["questions"].as_array().unwrap().len(), 2);
        });
    }

    #[test]
    fn a_valid_answer_goes_back_to_the_agent_in_the_shape_of_the_island() {
        block_on(async {
            let rig = rig(true).await;
            let (mut c, _) = phone(&rig, Some(json!(["answers"]))).await;
            rig.hub.publish_question(Some(question("r1")), server::now_ms());
            let q = c.expect("question").await;
            c.send(json!({ "type": "answer", "fingerprint": q["fingerprint"], "picks": [["Meilisearch"], ["Typos", "Synonyms"]] })).await;
            c.expect("approvalResolved").await;
            let got = answers_of(&rig);
            assert_eq!(got.len(), 1);
            assert_eq!(got[0].0, "r1");
            assert_eq!(got[0].1, json!({ "Which engine?": "Meilisearch", "Which extras?": ["Typos", "Synonyms"] }));
            // once only
            c.send(json!({ "type": "answer", "fingerprint": q["fingerprint"], "picks": [["Postgres"], ["Facets"]] })).await;
            c.send(json!({ "type": "ping" })).await;
            c.expect("pong").await;
            assert_eq!(answers_of(&rig).len(), 1);
        });
    }

    #[test]
    fn a_wrong_answer_changes_nothing_and_the_question_stays_open() {
        block_on(async {
            let rig = rig(true).await;
            let (mut c, _) = phone(&rig, Some(json!(["answers"]))).await;
            rig.hub.publish_question(Some(question("r1")), server::now_ms());
            let fp = c.expect("question").await["fingerprint"].clone();
            let bad = [
                json!([["Postgres"]]),                              // one pick too few
                json!([["Mongo"], ["Typos"]]),                      // not an option
                json!([["postgres"], ["Typos"]]),                   // not the exact label
                json!([["Postgres", "Meilisearch"], ["Typos"]]),    // two for a single choice
                json!([["Postgres"], []]),                          // nothing for a multiple choice
                json!([["Postgres"], ["Typos", "Typos"]]),          // the same twice
                json!([["Postgres"], "Typos"]),                     // wrong shape
                json!("Postgres"),
                json!([[1], [2]]),
            ];
            for picks in bad {
                c.send(json!({ "type": "answer", "fingerprint": fp, "picks": picks })).await;
            }
            c.send(json!({ "type": "answer", "fingerprint": "0".repeat(64), "picks": [["Postgres"], ["Typos"]] })).await;
            c.send(json!({ "type": "ping" })).await;
            c.expect("pong").await;
            assert!(answers_of(&rig).is_empty());
            // and the right one still works afterwards
            c.send(json!({ "type": "answer", "fingerprint": fp, "picks": [["Postgres"], ["Facets"]] })).await;
            c.expect("approvalResolved").await;
            assert_eq!(answers_of(&rig).len(), 1);
        });
    }

    #[test]
    fn a_phone_without_the_capability_cannot_answer_even_with_the_right_fingerprint() {
        block_on(async {
            let rig = rig(true).await;
            let (mut with, _) = phone(&rig, Some(json!(["answers"]))).await;
            let (mut old, _) = phone(&rig, None).await;
            rig.hub.publish_question(Some(question("r1")), server::now_ms());
            let fp = with.expect("question").await["fingerprint"].clone();
            old.send(json!({ "type": "answer", "fingerprint": fp, "picks": [["Postgres"], ["Typos"]] })).await;
            old.send(json!({ "type": "ping" })).await;
            old.expect("pong").await;
            assert!(answers_of(&rig).is_empty());
        });
    }

    #[test]
    fn a_question_that_does_not_fit_the_limits_stays_on_the_island() {
        block_on(async {
            let rig = rig(true).await;
            let (mut c, _) = phone(&rig, Some(json!(["answers"]))).await;
            let mut long = question("r1");
            long.questions[0].options[0].label = "x".repeat(200);
            rig.hub.publish_question(Some(long), server::now_ms());
            let mut twins = question("r2");
            twins.questions[0].options = vec![opt("Same"), opt("Same")];
            rig.hub.publish_question(Some(twins), server::now_ms());
            let told = types_until_pong(&mut c).await;
            assert!(!told.iter().any(|t| t == "question"), "nothing was offered: {told:?}");
        });
    }

    #[test]
    fn a_permission_request_still_reaches_every_phone_as_before() {
        block_on(async {
            let rig = rig(true).await;
            let (mut with, _) = phone(&rig, Some(json!(["answers"]))).await;
            let (mut old, _) = phone(&rig, None).await;
            rig.approval("r9", "ls", 0);
            assert_eq!(with.expect("approval").await["tool"], "Bash");
            assert_eq!(old.expect("approval").await["tool"], "Bash");
        });
    }
}

mod prefs_tests {
    use super::*;

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    #[test]
    fn prefs_is_offered_to_a_phone_that_asks_and_the_outfit_follows() {
        block_on(async {
            let rig = Rig::start().await;
            rig.hub.publish_outfit("witchHat");
            let (mut c, welcome) = phone(&rig, Some(json!(["prefs"]))).await;
            assert_eq!(welcome["caps"], json!(["prefs"]));
            assert_eq!(c.expect("sessions").await["type"], "sessions");
            let prefs = c.expect("prefs").await;
            assert_eq!(prefs["outfit"], "witchHat");
            rig.hub.publish_outfit("auto");
            assert_eq!(c.expect("prefs").await["outfit"], "auto");
        });
    }

    #[test]
    fn an_older_phone_is_offered_nothing_and_hears_nothing() {
        block_on(async {
            let rig = Rig::start().await;
            rig.hub.publish_outfit("bow");
            let (mut c, welcome) = phone(&rig, None).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
            rig.hub.publish_outfit("scarf");
            c.send(json!({ "type": "ping" })).await;
            let mut seen = Vec::new();
            loop {
                let m = c.recv().await.expect("closed");
                let t = m["type"].as_str().unwrap_or("").to_string();
                if t == "pong" {
                    break;
                }
                seen.push(t);
            }
            assert_eq!(seen, vec!["sessions".to_string()]);
        });
    }
}

mod diffs_tests {
    use super::*;
    use crate::phone_link::hub::{DiffIn, FileIn, SessionIn};
    use crate::phone_link::server::Features;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Switch(AtomicBool);
    impl Features for Switch {
        fn details(&self) -> bool {
            false
        }
        fn diffs(&self) -> bool {
            self.0.load(Ordering::SeqCst)
        }
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    fn working() -> SessionIn {
        SessionIn {
            pill_id: "integration_claude".into(),
            state: "working".into(),
            files: vec![FileIn { id: 7, name: "/home/me/secret/app.ts".into(), added: 3, removed: 1, ..FileIn::default() }],
            ..SessionIn::default()
        }
    }

    #[test]
    fn diffs_are_offered_only_while_the_switch_is_on_and_the_phone_asked() {
        block_on(async {
            let on = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let (_c, welcome) = phone(&on, Some(json!(["diffs"]))).await;
            assert_eq!(welcome["caps"], json!(["diffs"]));
            let (_c, welcome) = phone(&on, None).await;
            assert!(welcome.get("caps").is_none());
            let off = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(false)))).await;
            let (_c, welcome) = phone(&off, Some(json!(["diffs"]))).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
        });
    }

    #[test]
    fn a_phone_asks_for_a_file_and_gets_it_and_nobody_else_does() {
        block_on(async {
            let rig = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let (mut c, _) = phone(&rig, Some(json!(["diffs"]))).await;
            let (mut other, _) = phone(&rig, Some(json!(["diffs"]))).await;
            c.expect("sessions").await;
            other.expect("sessions").await;
            rig.hub.publish(vec![working()], None, server::now_ms());
            let list = c.expect("sessions").await;
            assert_eq!(list["sessions"][0]["files"][0]["name"], "app.ts");
            c.send(json!({ "type": "getDiff", "pillId": "integration_claude", "fileId": 7 })).await;
            let conn = loop {
                if let Some(first) = rig.host.2.lock().unwrap().first().cloned() {
                    break first;
                }
                tokio::time::sleep(std::time::Duration::from_millis(10)).await;
            };
            assert_eq!((conn.1.as_str(), conn.2), ("integration_claude", 7));
            rig.hub.send_diff(conn.0, DiffIn { pill_id: conn.1.clone(), file_id: 7, name: "app.ts".into(), added: 3, removed: 1, lines: vec![("+".into(), "let x = 1;".into())], ..DiffIn::default() });
            let diff = c.expect("diff").await;
            assert_eq!(diff["lines"][0], json!(["+", "let x = 1;"]));
            // the other phone hears nothing of it
            other.send(json!({ "type": "ping" })).await;
            assert_eq!(other.recv().await.unwrap()["type"], "sessions");
            assert_eq!(other.recv().await.unwrap()["type"], "pong");
        });
    }

    #[test]
    fn a_malformed_request_or_one_without_the_capability_never_reaches_the_island() {
        block_on(async {
            let rig = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let (mut c, _) = phone(&rig, Some(json!(["diffs"]))).await;
            let (mut plain, _) = phone(&rig, None).await;
            for bad in [
                json!({ "type": "getDiff" }),
                json!({ "type": "getDiff", "pillId": "", "fileId": 1 }),
                json!({ "type": "getDiff", "pillId": "x", "fileId": "1" }),
                json!({ "type": "getDiff", "pillId": "x", "fileId": -1 }),
                json!({ "type": "getDiff", "pillId": "x".repeat(65), "fileId": 1 }),
            ] {
                c.send(bad).await;
            }
            plain.send(json!({ "type": "getDiff", "pillId": "integration_claude", "fileId": 7 })).await;
            c.send(json!({ "type": "ping" })).await;
            loop {
                if c.recv().await.unwrap()["type"] == "pong" {
                    break;
                }
            }
            plain.send(json!({ "type": "ping" })).await;
            loop {
                if plain.recv().await.unwrap()["type"] == "pong" {
                    break;
                }
            }
            assert!(rig.host.2.lock().unwrap().is_empty());
        });
    }
}

mod usage_tests {
    use super::*;
    use crate::phone_link::hub::{PlanIn, UsageIn, WindowIn};
    use crate::phone_link::server::Features;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Switch(AtomicBool);
    impl Features for Switch {
        fn details(&self) -> bool {
            false
        }
        fn usage(&self) -> bool {
            self.0.load(Ordering::SeqCst)
        }
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    fn usage() -> UsageIn {
        UsageIn { claude: Some(PlanIn { five_hour: Some(WindowIn { used_pct: 61.0, resets_at: 1_900_000_000_000 }), ..PlanIn::default() }), codex: None }
    }

    #[test]
    fn usage_is_offered_only_while_the_switch_is_on_and_the_phone_asked() {
        block_on(async {
            let on = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let (_c, welcome) = phone(&on, Some(json!(["usage"]))).await;
            assert_eq!(welcome["caps"], json!(["usage"]));
            let (_c, welcome) = phone(&on, None).await;
            assert!(welcome.get("caps").is_none());
            let off = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(false)))).await;
            let (_c, welcome) = phone(&off, Some(json!(["usage"]))).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
        });
    }

    #[test]
    fn the_phone_hears_the_usage_and_its_changes() {
        block_on(async {
            let rig = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            rig.hub.publish_usage(usage());
            let (mut c, _) = phone(&rig, Some(json!(["usage"]))).await;
            c.expect("sessions").await;
            assert_eq!(c.expect("usage").await["claude"]["fiveHour"]["pct"], 61);
            rig.hub.publish_usage(UsageIn { claude: Some(PlanIn { five_hour: Some(WindowIn { used_pct: 80.0, resets_at: 1_900_000_000_000 }), ..PlanIn::default() }), codex: None });
            assert_eq!(c.expect("usage").await["claude"]["fiveHour"]["pct"], 80);
        });
    }
}

mod recap_tests {
    use super::*;
    use crate::phone_link::hub::RecapIn;
    use crate::phone_link::server::Features;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Switch {
        recap: AtomicBool,
        details: AtomicBool,
    }
    impl Features for Switch {
        fn details(&self) -> bool {
            self.details.load(Ordering::SeqCst)
        }
        fn recap(&self) -> bool {
            self.recap.load(Ordering::SeqCst)
        }
    }

    fn switch(recap: bool, details: bool) -> Arc<Switch> {
        Arc::new(Switch { recap: AtomicBool::new(recap), details: AtomicBool::new(details) })
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    fn week() -> RecapIn {
        RecapIn {
            week: "2026-10-05".into(),
            minutes: 340.0,
            sessions: 12.0,
            files: 40.0,
            lines_added: 900.0,
            lines_removed: 210.0,
            commands: 55.0,
            allowed: 20.0,
            denied: 3.0,
            top_agent: Some("Claude Code".into()),
            top_project: Some("/home/someone/private/coucou".into()),
        }
    }

    #[test]
    fn recap_is_offered_only_while_the_switch_is_on_and_the_phone_asked() {
        block_on(async {
            let on = Rig::start_full(None, switch(true, false)).await;
            let (_c, welcome) = phone(&on, Some(json!(["recap"]))).await;
            assert_eq!(welcome["caps"], json!(["recap"]));
            let (_c, welcome) = phone(&on, None).await;
            assert!(welcome.get("caps").is_none(), "a phone that did not ask is offered nothing");
            let off = Rig::start_full(None, switch(false, false)).await;
            let (_c, welcome) = phone(&off, Some(json!(["recap"]))).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
        });
    }

    #[test]
    fn the_switch_is_read_again_for_every_connection() {
        block_on(async {
            let features = switch(false, false);
            let rig = Rig::start_full(None, features.clone()).await;
            let (_c, welcome) = phone(&rig, Some(json!(["recap"]))).await;
            assert!(welcome.get("caps").is_none());
            features.recap.store(true, Ordering::SeqCst);
            let (_c, welcome) = phone(&rig, Some(json!(["recap"]))).await;
            assert_eq!(welcome["caps"], json!(["recap"]));
            features.recap.store(false, Ordering::SeqCst);
            let (_c, welcome) = phone(&rig, Some(json!(["recap"]))).await;
            assert!(welcome.get("caps").is_none());
        });
    }

    #[test]
    fn the_phone_hears_the_week_with_counts_only_and_a_change() {
        block_on(async {
            let rig = Rig::start_full(None, switch(true, false)).await;
            rig.hub.publish_recap(week());
            let (mut c, _) = phone(&rig, Some(json!(["recap"]))).await;
            c.expect("sessions").await;
            let line = c.expect("recap").await;
            assert_eq!(line["sessions"], 12);
            assert_eq!(line["minutes"], 340);
            assert_eq!(line["topAgent"], "Claude Code");
            assert!(line.get("project").is_none(), "no project without the details switch: {line}");
            let mut next = week();
            next.week = "2026-10-12".into();
            rig.hub.publish_recap(next);
            assert_eq!(c.expect("recap").await["week"], "2026-10-12");
            rig.hub.publish_recap(RecapIn::default());
            assert_eq!(c.expect("recap").await, json!({ "type": "recap" }));
        });
    }

    #[test]
    fn the_project_folder_goes_only_with_details_and_never_as_a_path() {
        block_on(async {
            let rig = Rig::start_full(None, switch(true, true)).await;
            rig.hub.publish_recap(week());
            let (mut c, welcome) = phone(&rig, Some(json!(["recap", "details"]))).await;
            assert_eq!(welcome["caps"], json!(["details", "recap"]));
            c.expect("sessions").await;
            let line = c.expect("recap").await;
            assert_eq!(line["project"], "coucou");
            assert!(!line.to_string().contains("someone"), "{line}");
        });
    }

    #[test]
    fn a_phone_without_the_capability_never_hears_of_a_recap() {
        block_on(async {
            let rig = Rig::start_full(None, switch(true, false)).await;
            let (mut plain, _) = phone(&rig, None).await;
            plain.expect("sessions").await;
            rig.hub.publish_recap(week());
            plain.send(json!({ "type": "ping" })).await;
            loop {
                let line = plain.recv().await.unwrap();
                assert_ne!(line["type"], "recap");
                if line["type"] == "pong" {
                    break;
                }
            }
        });
    }
}

mod services_tests {
    use super::*;
    use crate::phone_link::hub::{ServiceIn, ServiceItemIn};
    use crate::phone_link::server::Features;
    use std::sync::Mutex as StdMutex;

    struct Ticks(StdMutex<Vec<String>>);
    impl Features for Ticks {
        fn details(&self) -> bool {
            false
        }
        fn services(&self) -> Vec<String> {
            self.0.lock().unwrap().clone()
        }
    }

    async fn phone(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    fn cards() -> Vec<ServiceIn> {
        vec![
            ServiceIn { id: "integration_stripe".into(), title: "Stripe".into(), headline: "12.50 EUR".into(), reason: None, items: vec![ServiceItemIn { label: "Payment".into(), detail: "+9.00".into() }] },
            ServiceIn { id: "integration_notion".into(), title: "Notion".into(), headline: "2".into(), reason: None, items: vec![ServiceItemIn { label: "Private page".into(), detail: "1m".into() }] },
        ]
    }

    #[test]
    fn services_are_offered_only_when_the_phone_asked_and_something_is_ticked() {
        block_on(async {
            let ticked = Rig::start_full(None, Arc::new(Ticks(StdMutex::new(vec!["integration_stripe".into()])))).await;
            let (_c, welcome) = phone(&ticked, Some(json!(["services"]))).await;
            assert_eq!(welcome["caps"], json!(["services"]));
            let (_c, welcome) = phone(&ticked, None).await;
            assert!(welcome.get("caps").is_none());
            let none = Rig::start_full(None, Arc::new(Ticks(StdMutex::new(vec![])))).await;
            let (_c, welcome) = phone(&none, Some(json!(["services"]))).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
        });
    }

    #[test]
    fn the_phone_gets_the_ticked_services_only() {
        block_on(async {
            let rig = Rig::start_full(None, Arc::new(Ticks(StdMutex::new(vec!["integration_stripe".into()])))).await;
            rig.hub.publish_services(cards());
            let (mut c, _) = phone(&rig, Some(json!(["services"]))).await;
            c.expect("sessions").await;
            let m = c.expect("services").await;
            assert_eq!(m["services"].as_array().unwrap().len(), 1);
            assert_eq!(m["services"][0]["id"], "integration_stripe");
            assert!(!m.to_string().contains("Private page"));
        });
    }
}

mod relay_cap_tests {
    use super::*;
    use crate::phone_link::server::Features;
    use std::sync::atomic::{AtomicBool, Ordering};

    struct Switch(AtomicBool);
    impl Features for Switch {
        fn details(&self) -> bool {
            false
        }
        fn relay(&self) -> bool {
            self.0.load(Ordering::SeqCst)
        }
    }

    async fn welcome_for(rig: &Rig, caps: Option<Value>) -> (Client, Value) {
        let mut c = Client::connect(rig.port, &rig.fingerprint).await.unwrap();
        let mut hello = json!({ "type": "hello", "v": 1, "token": TOKEN, "device": "Test phone" });
        if let Some(caps) = caps {
            hello["caps"] = caps;
        }
        c.send(hello).await;
        let welcome = c.expect("welcome").await;
        (c, welcome)
    }

    #[test]
    fn relay_is_offered_only_while_the_switch_is_on_and_the_phone_asked() {
        block_on(async {
            let on = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let (_c, welcome) = welcome_for(&on, Some(json!(["relay"]))).await;
            assert_eq!(welcome["caps"], json!(["relay"]));
            let (_c, welcome) = welcome_for(&on, None).await;
            assert!(welcome.get("caps").is_none(), "an older phone is never offered it");
            let off = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(false)))).await;
            let (_c, welcome) = welcome_for(&off, Some(json!(["relay"]))).await;
            assert!(welcome.get("caps").is_none(), "{welcome}");
        });
    }

    #[test]
    fn a_rotated_access_key_reaches_a_phone_that_negotiated_relay() {
        block_on(async {
            let rig = Rig::start_full(None, Arc::new(Switch(AtomicBool::new(true)))).await;
            let (mut c, _) = welcome_for(&rig, Some(json!(["relay"]))).await;
            let (mut other, _) = welcome_for(&rig, None).await;
            let access = "D".repeat(43);
            assert_eq!(rig.hub.send_relay_access(&access), 1);
            let m = c.expect("relayAccess").await;
            assert_eq!(m["access"], access);
            other.send(json!({ "type": "ping" })).await;
            other.expect("pong").await; // it only ever sees ordinary traffic
        });
    }
}

// ── The keystore's key list (secrets::INTERNAL_KEYS) ──

/// Every key the phone link stores must be in the real keystore's list: the keystore refuses the others with "unknown key".
/// MemStore accepts anything, which is how a missing key once went unnoticed.
#[test]
fn every_secret_the_phone_link_stores_is_in_the_keystores_key_list() {
    for key in [
        pairing::CERT_KEY,
        pairing::PRIVATE_KEY,
        pairing::TOKEN_KEY,
        super::relay_client::ROOM_KEY,
        super::relay_client::PAIRING_KEY,
        super::relay_client::ACCESS_KEY,
    ] {
        assert!(crate::secrets::INTERNAL_KEYS.contains(&key), "{key} is not in secrets::INTERNAL_KEYS");
    }
    // And nothing in the list is a stray: each one is used by the phone link, or by WhatsApp
    // (checked in whatsapp/mod.rs).
    let whatsapp = crate::secrets::INTERNAL_KEYS.iter().filter(|k| k.starts_with("whatsapp-")).count();
    assert_eq!(crate::secrets::INTERNAL_KEYS.len() - whatsapp, 6);
}

#[test]
fn the_whole_pairing_life_works_through_the_real_key_list() {
    use pairing::tests::StrictStore;
    use super::relay_client as relay;
    let store = StrictStore::default();
    pairing::load_or_create_identity(&store).unwrap();
    let t1 = pairing::token(&store).unwrap();
    let (room1, _) = relay::pairing(&store).unwrap();
    relay::set_access_key(&store, &super::relay_crypto::base64url_encode(&[7u8; 32])).unwrap();
    assert!(relay::access_key(&store).is_some());
    // "Pair again"
    let hub = Hub::new(Arc::new(Recorder::default()));
    let token = Mutex::new(t1.clone());
    super::renew_pairing(&hub, &token, &store).unwrap();
    assert_ne!(*token.lock().unwrap(), t1);
    assert_ne!(relay::pairing(&store).unwrap().0, room1);
    // Clearing the access key goes through too.
    relay::set_access_key(&store, "").unwrap();
}

#[test]
fn a_key_outside_the_list_is_refused_by_the_strict_store() {
    use pairing::tests::StrictStore;
    use pairing::SecretStore;
    assert!(StrictStore::default().set("phone-something-new", "x").is_err());
}

#[test]
fn pairing_again_disconnects_the_phones_even_when_the_keystore_refuses_to_save() {
    use pairing::tests::StrictStore;
    use std::sync::atomic::Ordering;
    block_on(async {
        let rig = Rig::start().await;
        let mut phone = Client::paired(&rig).await;
        let store = StrictStore::default();
        store.refuse_writes.store(true, Ordering::SeqCst);
        let token = Mutex::new(TOKEN.to_string());
        assert!(super::renew_pairing(&rig.hub, &token, &store).is_err());
        // The error is reported, and the phone was cut off all the same.
        assert_eq!(phone.expect("error").await["code"], "auth");
        assert!(phone.closed().await);
    });
}

#[test]
fn over_the_wire_a_10000_character_command_is_flagged_and_allow_does_nothing() {
    block_on(async {
        let rig = Rig::start().await;
        let mut c = Client::paired(&rig).await;
        c.expect("sessions").await;
        let command = format!("echo {}", "x".repeat(10_000));
        rig.approval("req-long", &command, 0);
        let approval = c.expect("approval").await;
        assert_eq!(approval["truncated"], true);
        assert_eq!(approval["command"].as_str().unwrap().chars().count(), 500);
        let fp = approval["fingerprint"].as_str().unwrap().to_string();

        c.send(json!({ "type": "decision", "fingerprint": fp, "decision": "allow" })).await;
        c.send(json!({ "type": "ping" })).await;
        c.expect("pong").await; // the decision before it was read, and ignored
        assert!(rig.decisions().is_empty(), "Allow from the phone must not reach the agent");

        // Deny still works.
        c.send(json!({ "type": "decision", "fingerprint": fp, "decision": "deny" })).await;
        c.expect("approvalResolved").await;
        assert_eq!(rig.decisions(), vec![("req-long".to_string(), false)]);
    });
}

// ── Which window may call which command ──

#[test]
fn only_the_right_window_may_call_a_command_that_changes_something() {
    use super::{caller_allowed, Caller};
    assert!(caller_allowed("settings", Caller::Settings));
    assert!(caller_allowed("island", Caller::Island));
    for other in ["island", "mochi", "", "Settings", "settings ", "main", "settings2"] {
        assert!(!caller_allowed(other, Caller::Settings), "{other:?} must not act as the settings window");
    }
    for other in ["settings", "mochi", "", "Island", "island ", "main"] {
        assert!(!caller_allowed(other, Caller::Island), "{other:?} must not act as the island");
    }
}

/// Reads mod.rs: every `#[tauri::command]` that is not a plain read of a status must check the calling window. A command added later
/// without the check fails here, which is how phone_link_set_enabled (it starts a network server) was found.
#[test]
fn every_command_that_changes_something_checks_the_calling_window() {
    // The Windows runner checks files out with CRLF line endings.
    let source = include_str!("mod.rs").replace("\r\n", "\n");
    let mut seen = 0;
    for chunk in source.split("#[tauri::command]\n").skip(1) {
        let name = chunk.split("pub fn ").nth(1).and_then(|r| r.split('(').next()).expect("a command has a name");
        let end = chunk.find("\n}\n").expect("a command ends");
        let body = &chunk[..end];
        seen += 1;
        if name.ends_with("_status") {
            // Reads only. None of them returns a secret: the relay's access key is reported as a yes/no.
            assert!(!body.contains("settings::save") && !body.contains(".start()") && !body.contains(".stop()"), "{name} changes something");
            continue;
        }
        assert!(
            body.contains("window: WebviewWindow") && (body.contains("only_settings(&window)") || body.contains("only_island(&window)")),
            "{name} changes something but does not check the calling window"
        );
    }
    assert!(seen >= 25, "the test must see the commands (saw {seen})");
}
