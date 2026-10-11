// The phone link through a relay (docs/RELAY_LINK.md), computer side.
//
// Off unless the user turns on "Away from home Wi-Fi" in Settings → Android phone and gives a relay address and its
// access key. The computer then opens ONE outbound WebSocket to the user's own relay and waits. When the phone sends
// `init` (a MAC under a key only the pairing holds), the computer answers `accept`, derives fresh per-direction
// session keys and from then on runs the ordinary protocol v1 conversation (server.rs `run_with`) over the decrypted
// frames, exactly as it runs it over TLS on the LAN. Fingerprints, 120 s offers, decide-once and the per-feature
// switches are therefore the same code; the relay is only a pipe that cannot read or forge anything.
//
// Nothing here blocks the agent: it is its own task, a failure only changes the status line, and nothing secret is
// ever logged (a log line names a state, never a key, a room or an address).

use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use futures_util::{SinkExt, StreamExt};
use serde::Serialize;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::net::TcpStream;
use tokio::task::JoinHandle;
use tokio_rustls::rustls::pki_types::ServerName;
use tokio_rustls::rustls::version::{TLS12, TLS13};
use tokio_rustls::rustls::{crypto::ring as ring_provider, ClientConfig, RootCertStore};
use tokio_rustls::TlsConnector;
use tokio_tungstenite::tungstenite::client::IntoClientRequest;
use tokio_tungstenite::tungstenite::protocol::frame::coding::CloseCode;
use tokio_tungstenite::tungstenite::protocol::WebSocketConfig;
use tokio_tungstenite::tungstenite::Message;
use tokio_tungstenite::WebSocketStream;

use super::pairing::SecretStore;
use super::relay_crypto::{self as crypto, PairingKey, Session};
use super::server::{self, Shared};

pub(super) const ROOM_KEY: &str = "phone-relay-room";
pub(super) const PAIRING_KEY: &str = "phone-relay-key";
pub(super) const ACCESS_KEY: &str = "phone-relay-access";

/// How often the computer sends the text `ping` the relay answers by itself, and how long silence is tolerated.
const HEARTBEAT: Duration = Duration::from_secs(25);
const SILENCE: Duration = Duration::from_secs(80);
/// After this many bad handshake frames the computer stops answering `init` for [`QUIET`].
const BAD_HANDSHAKES: u32 = 3;
const QUIET: Duration = Duration::from_secs(10);
const FIRST_RETRY: Duration = Duration::from_secs(2);
const LONG_RETRY: Duration = Duration::from_secs(60);

// ── Where the relay is ───────────────────────────────────────────────────────────────────────────

/// A relay address: `wss://host[:port]`, nothing else. `ws://` is accepted for a relay on this same computer only
/// (development and the tests), never across a network.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    pub tls: bool,
    pub host: String,
    pub port: u16,
}

impl Target {
    pub fn parse(text: &str) -> Result<Target, &'static str> {
        let text = text.trim();
        let (tls, rest) = if let Some(r) = text.strip_prefix("wss://") {
            (true, r)
        } else if let Some(r) = text.strip_prefix("ws://") {
            (false, r)
        } else {
            return Err("The address must start with wss://");
        };
        let rest = rest.strip_suffix('/').unwrap_or(rest);
        if rest.is_empty() || rest.contains(['/', '?', '#', '@', ' ', '\\']) {
            return Err("Use only the address, like wss://relay.example.workers.dev");
        }
        let (host, port) = match rest.rsplit_once(':') {
            Some((h, p)) if !h.ends_with(':') && !h.is_empty() && !p.is_empty() && !h.starts_with('[') => {
                (h, p.parse::<u16>().map_err(|_| "That port is not valid")?)
            }
            Some((h, p)) if h.starts_with('[') && h.ends_with(']') => (h, p.parse::<u16>().map_err(|_| "That port is not valid")?),
            _ => (rest, if tls { 443 } else { 80 }),
        };
        let name_ok = host == "[::1]" || (host.len() <= 253 && host.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'.' || b == b'-'));
        if !name_ok || host.starts_with('.') || host.starts_with('-') || host.contains("..") {
            return Err("That is not a valid address");
        }
        if port == 0 {
            return Err("That port is not valid");
        }
        if !tls && !matches!(host, "localhost" | "127.0.0.1" | "[::1]") {
            return Err("The address must start with wss://");
        }
        Ok(Target { tls, host: host.to_string(), port })
    }

    /// The address as it is written into the pairing link (the default port is left out).
    pub fn display(&self) -> String {
        let scheme = if self.tls { "wss" } else { "ws" };
        let default = if self.tls { 443 } else { 80 };
        if self.port == default {
            format!("{scheme}://{}", self.host)
        } else {
            format!("{scheme}://{}:{}", self.host, self.port)
        }
    }
}

// ── The secrets (OS keystore only) ───────────────────────────────────────────────────────────────

/// The three things a relay connection needs. Never printed (Debug is redacted) and never written to a file.
pub struct Credentials {
    pub room: String,
    pub key: PairingKey,
    pub access: String,
}

impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Credentials(..)")
    }
}

fn random_bytes<const N: usize>() -> Result<[u8; N], String> {
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; N];
    SystemRandom::new().fill(&mut bytes).map_err(|_| "no secure random source".to_string())?;
    Ok(bytes)
}

fn is_room(s: &str) -> bool {
    s.len() == 22 && crypto::base64url_decode(s).is_some_and(|b| b.len() == 16)
}

/// The access key as the user pastes it: 32 bytes, base64url without padding (43 characters).
pub fn is_access_key(s: &str) -> bool {
    s.len() == 43 && crypto::base64url_decode(s).is_some_and(|b| b.len() == 32)
}

/// This pairing's room and K: the stored ones, else new ones (made once, kept until "Pair again").
pub fn pairing(store: &dyn SecretStore) -> Result<(String, PairingKey), String> {
    let room = store.get(ROOM_KEY).filter(|r| is_room(r));
    let key = store.get(PAIRING_KEY).and_then(|k| PairingKey::from_base64url(&k));
    if let (Some(room), Some(key)) = (room, key) {
        return Ok((room, key));
    }
    new_pairing(store)
}

/// A new room and a new K. Whatever phone held the old ones can no longer read or write anything.
pub fn new_pairing(store: &dyn SecretStore) -> Result<(String, PairingKey), String> {
    let room = crypto::base64url_encode(&random_bytes::<16>()?);
    let key = PairingKey::from_bytes(random_bytes::<32>()?);
    store.set(ROOM_KEY, &room)?;
    store.set(PAIRING_KEY, &key.to_base64url())?;
    Ok((room, key))
}

pub fn access_key(store: &dyn SecretStore) -> Option<String> {
    store.get(ACCESS_KEY).filter(|a| is_access_key(a))
}

/// Stores a new access key (write-only in the UI). Empty clears it.
pub fn set_access_key(store: &dyn SecretStore, value: &str) -> Result<(), String> {
    let value = value.trim();
    if !value.is_empty() && !is_access_key(value) {
        return Err("The access key is 43 characters of letters, digits, - and _".into());
    }
    store.set(ACCESS_KEY, value)
}

pub fn credentials(store: &dyn SecretStore) -> Result<Credentials, String> {
    let access = access_key(store).ok_or("no access key")?;
    let (room, key) = pairing(store)?;
    Ok(Credentials { room, key, access })
}

// ── Status ───────────────────────────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum State {
    Off,
    /// Reaching the relay.
    Connecting,
    /// Connected to the relay, no phone yet.
    Waiting,
    /// A phone completed the handshake.
    Linked,
    /// The relay did not accept the access key (or it was rotated).
    AccessRefused,
    /// The relay could not be reached.
    Unreachable,
    /// The room is held by someone else, or another copy of this computer took its place.
    RoomTaken,
    /// The relay is limiting new connections from here.
    TooMany,
}

#[derive(Clone)]
pub struct StatusCell(Arc<Mutex<State>>);

impl StatusCell {
    fn new(s: State) -> Self {
        StatusCell(Arc::new(Mutex::new(s)))
    }
    pub fn get(&self) -> State {
        *self.0.lock().unwrap()
    }
    fn set(&self, s: State) {
        *self.0.lock().unwrap() = s;
    }
}

// ── The running client ───────────────────────────────────────────────────────────────────────────

/// A running relay client; dropping it does not stop it, `stop` does.
pub struct Handle {
    task: JoinHandle<()>,
    status: StatusCell,
}

impl Handle {
    pub fn state(&self) -> State {
        self.status.get()
    }
    pub fn stop(self) {
        self.task.abort();
        self.status.set(State::Off);
    }
}

/// Starts the client. Must be called inside the async runtime.
pub fn start(shared: Arc<Shared>, target: Target, creds: Credentials) -> Handle {
    let status = StatusCell::new(State::Connecting);
    let task = tokio::spawn(supervise(shared, target, Arc::new(creds), status.clone()));
    Handle { task, status }
}

trait Io: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send {}
impl<T: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send> Io for T {}
type Ws = WebSocketStream<Box<dyn Io>>;

enum Failure {
    Refused,
    Unreachable,
    TooMany,
}

async fn supervise(shared: Arc<Shared>, target: Target, creds: Arc<Credentials>, status: StatusCell) {
    let mut delay = FIRST_RETRY;
    loop {
        status.set(State::Connecting);
        let started = Instant::now();
        let next = match connect(&target, &creds).await {
            Ok(ws) => {
                status.set(State::Waiting);
                match run_connection(ws, &shared, &creds, &status).await {
                    End::Refused => {
                        status.set(State::AccessRefused);
                        LONG_RETRY
                    }
                    End::Taken => {
                        status.set(State::RoomTaken);
                        LONG_RETRY
                    }
                    End::Lost => {
                        // A connection that lasted is not a failing relay: start the back-off again.
                        if started.elapsed() > Duration::from_secs(30) {
                            delay = FIRST_RETRY;
                        }
                        status.set(State::Unreachable);
                        delay
                    }
                }
            }
            Err(Failure::Refused) => {
                status.set(State::AccessRefused);
                LONG_RETRY
            }
            Err(Failure::TooMany) => {
                status.set(State::TooMany);
                LONG_RETRY
            }
            Err(Failure::Unreachable) => {
                status.set(State::Unreachable);
                delay
            }
        };
        tokio::time::sleep(next).await;
        delay = (delay * 2).min(LONG_RETRY);
    }
}

fn tls_config() -> Arc<ClientConfig> {
    let roots = RootCertStore::from_iter(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());
    let config = ClientConfig::builder_with_provider(Arc::new(ring_provider::default_provider()))
        .with_protocol_versions(&[&TLS13, &TLS12])
        .expect("the ring provider supports TLS 1.2 and 1.3")
        .with_root_certificates(roots)
        .with_no_client_auth();
    Arc::new(config)
}

async fn connect(target: &Target, creds: &Credentials) -> Result<Ws, Failure> {
    let attempt = async {
        let tcp = TcpStream::connect((target.host.trim_matches(['[', ']']), target.port)).await.map_err(|_| Failure::Unreachable)?;
        let _ = tcp.set_nodelay(true);
        let stream: Box<dyn Io> = if target.tls {
            let name = ServerName::try_from(target.host.clone()).map_err(|_| Failure::Unreachable)?;
            Box::new(TlsConnector::from(tls_config()).connect(name, tcp).await.map_err(|_| Failure::Unreachable)?)
        } else {
            Box::new(tcp)
        };
        let url = format!("{}://{}:{}/v1/room/{}?role=pc", if target.tls { "wss" } else { "ws" }, target.host, target.port, creds.room);
        let mut request = url.into_client_request().map_err(|_| Failure::Unreachable)?;
        let headers = request.headers_mut();
        let bad = |_| Failure::Unreachable;
        headers.insert("Authorization", format!("Bearer {}", creds.access).parse().map_err(bad)?);
        headers.insert(
            "Sec-WebSocket-Protocol",
            format!("coucou.v1, coucou.join.{}", crypto::join_proof(&creds.key)).parse().map_err(bad)?,
        );
        let config = WebSocketConfig::default().max_message_size(Some(crypto::MAX_FRAME + 1024)).max_frame_size(Some(crypto::MAX_FRAME + 1024));
        match tokio_tungstenite::client_async_with_config(request, stream, Some(config)).await {
            Ok((ws, _)) => Ok(ws),
            Err(tokio_tungstenite::tungstenite::Error::Http(response)) => Err(match response.status().as_u16() {
                401 | 403 => Failure::Refused,
                429 => Failure::TooMany,
                _ => Failure::Unreachable,
            }),
            Err(_) => Err(Failure::Unreachable),
        }
    };
    tokio::time::timeout(Duration::from_secs(15), attempt).await.unwrap_or(Err(Failure::Unreachable))
}

enum End {
    /// The relay no longer accepts the access key.
    Refused,
    /// The room is held by someone else, or this computer's place was taken.
    Taken,
    /// The connection ended; try again.
    Lost,
}

/// One phone's encrypted conversation: the session keys and the in-memory pipe into the protocol server.
struct Live {
    session: Session,
    /// Decrypted lines go to the server here.
    to_server: tokio::io::WriteHalf<tokio::io::DuplexStream>,
    /// Lines the server produced come from here.
    from_server: tokio::io::Lines<BufReader<tokio::io::ReadHalf<tokio::io::DuplexStream>>>,
    server: JoinHandle<()>,
    /// The phone proved it holds K (a data frame decrypted).
    proven: bool,
}

impl Drop for Live {
    fn drop(&mut self) {
        self.server.abort();
    }
}

async fn next_out(live: &mut Option<Live>) -> Option<String> {
    match live {
        Some(l) => l.from_server.next_line().await.ok().flatten(),
        None => std::future::pending().await,
    }
}

async fn run_connection(mut ws: Ws, shared: &Arc<Shared>, creds: &Credentials, status: &StatusCell) -> End {
    let mut live: Option<Live> = None;
    let mut bad = 0u32;
    let mut quiet_until: Option<Instant> = None;
    let mut last_heard = Instant::now();
    let mut heartbeat = tokio::time::interval(HEARTBEAT);
    heartbeat.tick().await;
    loop {
        tokio::select! {
            incoming = ws.next() => {
                let Some(Ok(message)) = incoming else { return End::Lost };
                last_heard = Instant::now();
                match message {
                    Message::Binary(frame) => {
                        let frame: &[u8] = &frame;
                        if frame.len() > 1 && frame[1] == crypto::T_INIT {
                            if quiet_until.is_some_and(|t| Instant::now() < t) {
                                continue;
                            }
                            match crypto::accept_init(&creds.key, &creds.room, frame, crypto::fresh_nonce()) {
                                Ok((accept, session)) => {
                                    bad = 0;
                                    // Only the newest init is answered; the previous conversation ends.
                                    live = None;
                                    let Some(ticket) = shared.admit_relay() else { continue };
                                    let (near, far) = tokio::io::duplex(2 * crypto::MAX_FRAME);
                                    let (read, write) = tokio::io::split(near);
                                    let shared = shared.clone();
                                    let server = tokio::spawn(async move {
                                        server::run_with(far, &shared, Some(Arc::new(ticket))).await;
                                    });
                                    live = Some(Live { session, to_server: write, from_server: BufReader::new(read).lines(), server, proven: false });
                                    status.set(State::Waiting);
                                    if ws.send(Message::Binary(accept.into())).await.is_err() {
                                        return End::Lost;
                                    }
                                }
                                Err(_) => {
                                    bad += 1;
                                    if bad >= BAD_HANDSHAKES {
                                        bad = 0;
                                        quiet_until = Some(Instant::now() + QUIET);
                                    }
                                }
                            }
                        } else if let Some(l) = live.as_mut() {
                            match l.session.open(frame) {
                                Ok(line) => {
                                    if !l.proven {
                                        l.proven = true;
                                        status.set(State::Linked);
                                    }
                                    if l.to_server.write_all(&line).await.is_err() || l.to_server.write_all(b"\n").await.is_err() {
                                        live = None;
                                        status.set(State::Waiting);
                                    }
                                }
                                Err(_) => {
                                    // Any fault ends the conversation; the phone starts again with a new init.
                                    live = None;
                                    status.set(State::Waiting);
                                }
                            }
                        } else {
                            bad += 1;
                            if bad >= BAD_HANDSHAKES {
                                bad = 0;
                                quiet_until = Some(Instant::now() + QUIET);
                            }
                        }
                    }
                    Message::Text(text) => {
                        // The relay's hints (never trusted for anything but the status line) and its `pong`.
                        if text.as_str().contains("\"offline\"") && live.is_some() {
                            live = None;
                            status.set(State::Waiting);
                        }
                    }
                    Message::Close(frame) => {
                        let reason = frame.map(|f| (f.code, f.reason.to_string()));
                        return match reason {
                            Some((_, r)) if r == "join proof" || r == "replaced" => End::Taken,
                            Some((_, r)) if r == "access key changed" => End::Refused,
                            Some((CloseCode::Policy, _)) => End::Taken,
                            _ => End::Lost,
                        };
                    }
                    _ => {}
                }
            }
            out = next_out(&mut live) => {
                let Some(line) = out else {
                    // The server ended this conversation (a bad token, the link turned off…); its last line was sent.
                    live = None;
                    status.set(State::Waiting);
                    continue;
                };
                if let Some(l) = live.as_mut() {
                    match l.session.seal(line.as_bytes()) {
                        Ok(frame) => {
                            if ws.send(Message::Binary(frame.into())).await.is_err() {
                                return End::Lost;
                            }
                        }
                        Err(_) => {
                            live = None; // too long or the counter is used up: the phone re-handshakes
                            status.set(State::Waiting);
                        }
                    }
                }
            }
            _ = heartbeat.tick() => {
                if last_heard.elapsed() > SILENCE {
                    return End::Lost;
                }
                if ws.send(Message::Text("ping".into())).await.is_err() {
                    return End::Lost;
                }
            }
        }
    }
}


// ── Tests ────────────────────────────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;
    use crate::phone_link::hub::{ApprovalIn, Hub};
    use crate::phone_link::pairing::tests::MemStore;
    use serde_json::{json, Value};
    use std::future::Future;
    use tokio::net::TcpListener;
    use tokio::sync::mpsc;
    use tokio_tungstenite::tungstenite::handshake::server::{ErrorResponse, Request, Response};
    use tokio_tungstenite::tungstenite::http::StatusCode;

    const TOKEN: &str = "test-token-0123456789abcdef";

    fn block_on<F: Future>(f: F) -> F::Output {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(f)
    }

    #[derive(Default)]
    struct Recorder(Mutex<Vec<(String, bool)>>);
    impl super::super::hub::Host for Recorder {
        fn decide(&self, request_id: &str, allow: bool) {
            self.0.lock().unwrap().push((request_id.to_string(), allow));
        }
    }

    // ── a stand-in relay: it hands each socket the computer opens to the test, which plays the phone ──

    #[derive(Default, Clone)]
    struct Seen {
        auth: Arc<Mutex<Vec<String>>>,
        protocols: Arc<Mutex<Vec<String>>>,
        paths: Arc<Mutex<Vec<String>>>,
    }

    type Server = WebSocketStream<TcpStream>;

    async fn fake_relay(refuse: Option<u16>) -> (u16, Seen, mpsc::UnboundedReceiver<Server>) {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let seen = Seen::default();
        let (tx, rx) = mpsc::unbounded_channel();
        let seen2 = seen.clone();
        tokio::spawn(async move {
            loop {
                let Ok((tcp, _)) = listener.accept().await else { return };
                let seen = seen2.clone();
                let callback = move |req: &Request, mut resp: Response| -> Result<Response, ErrorResponse> {
                    let header = |n: &str| req.headers().get(n).and_then(|v| v.to_str().ok()).unwrap_or("").to_string();
                    seen.auth.lock().unwrap().push(header("authorization"));
                    seen.protocols.lock().unwrap().push(header("sec-websocket-protocol"));
                    seen.paths.lock().unwrap().push(req.uri().to_string());
                    if let Some(code) = refuse {
                        let mut r = ErrorResponse::new(None);
                        *r.status_mut() = StatusCode::from_u16(code).unwrap();
                        return Err(r);
                    }
                    resp.headers_mut().insert("sec-websocket-protocol", "coucou.v1".parse().unwrap());
                    Ok(resp)
                };
                if let Ok(ws) = tokio_tungstenite::accept_hdr_async(tcp, callback).await {
                    let _ = tx.send(ws);
                }
            }
        });
        (port, seen, rx)
    }

    struct Rig {
        creds_key: String,
        room: String,
        access: String,
        seen: Seen,
        conns: mpsc::UnboundedReceiver<Server>,
        hub: Arc<Hub>,
        host: Arc<Recorder>,
        shared: Arc<Shared>,
        handle: Handle,
    }

    impl Rig {
        async fn start() -> Rig {
            let (port, seen, conns) = fake_relay(None).await;
            Rig::start_at(port, seen, conns).await
        }

        async fn start_at(port: u16, seen: Seen, conns: mpsc::UnboundedReceiver<Server>) -> Rig {
            let store = MemStore::default();
            set_access_key(&store, &crypto::base64url_encode(&[7u8; 32])).unwrap();
            let creds = credentials(&store).unwrap();
            let (room, creds_key, access) = (creds.room.clone(), creds.key.to_base64url(), creds.access.clone());
            let host = Arc::new(Recorder::default());
            let hub = Hub::new(host.clone());
            let shared = Shared::with_features(hub.clone(), TOKEN.to_string(), "Test PC".to_string(), None, Arc::new(server::NoFeatures));
            let handle = start(shared.clone(), Target { tls: false, host: "127.0.0.1".into(), port }, creds);
            Rig { creds_key, room, access, seen, conns, hub, host, shared, handle }
        }

        fn key(&self) -> PairingKey {
            PairingKey::from_base64url(&self.creds_key).unwrap()
        }

        async fn socket(&mut self) -> Server {
            tokio::time::timeout(Duration::from_secs(5), self.conns.recv()).await.expect("the computer connects").unwrap()
        }

        async fn wait_state(&self, want: State) {
            for _ in 0..200 {
                if self.handle.state() == want {
                    return;
                }
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
            panic!("state is {:?}, wanted {:?}", self.handle.state(), want);
        }
    }

    /// The test as the phone: it completes the handshake over a relay socket.
    struct Phone {
        ws: Server,
        session: Session,
    }

    impl Phone {
        async fn join(rig: &Rig, mut ws: Server) -> Phone {
            let n = crypto::fresh_nonce();
            ws.send(Message::Binary(crypto::init_frame(&rig.key(), &rig.room, n).into())).await.unwrap();
            let accept = loop {
                match tokio::time::timeout(Duration::from_secs(5), ws.next()).await.expect("accept arrives").unwrap().unwrap() {
                    Message::Binary(b) => break b,
                    _ => continue,
                }
            };
            let session = crypto::finish_handshake(&rig.key(), &rig.room, &n, &accept).unwrap();
            Phone { ws, session }
        }

        async fn send(&mut self, v: Value) {
            let frame = self.session.seal(v.to_string().as_bytes()).unwrap();
            self.ws.send(Message::Binary(frame.into())).await.unwrap();
        }

        async fn recv(&mut self) -> Value {
            loop {
                match tokio::time::timeout(Duration::from_secs(5), self.ws.next()).await.expect("a frame arrives").unwrap().unwrap() {
                    Message::Binary(b) => return serde_json::from_slice(&self.session.open(&b).unwrap()).unwrap(),
                    _ => continue,
                }
            }
        }

        async fn expect(&mut self, kind: &str) -> Value {
            for _ in 0..20 {
                let v = self.recv().await;
                if v["type"] == kind {
                    return v;
                }
            }
            panic!("no {kind}");
        }

        async fn hello(&mut self) -> Value {
            self.send(json!({ "type": "hello", "v": 1, "token": TOKEN, "caps": [] })).await;
            self.expect("welcome").await
        }

        /// True when nothing arrives for a moment.
        async fn silent(&mut self) -> bool {
            tokio::time::timeout(Duration::from_millis(300), self.ws.next()).await.is_err()
        }
    }

    // ── addresses and secrets ──

    #[test]
    fn only_a_wss_address_with_nothing_else_is_accepted() {
        let ok = |s: &str| Target::parse(s).unwrap();
        assert_eq!(ok("wss://relay.example.workers.dev"), Target { tls: true, host: "relay.example.workers.dev".into(), port: 443 });
        assert_eq!(ok("  wss://relay.example.workers.dev/  ").port, 443);
        assert_eq!(ok("wss://relay.example.com:8443").port, 8443);
        assert_eq!(ok("wss://relay.example.com:8443").display(), "wss://relay.example.com:8443");
        assert_eq!(ok("wss://relay.example.com").display(), "wss://relay.example.com");
        // Plain ws:// is for a relay on this same computer only.
        assert!(!ok("ws://127.0.0.1:8787").tls);
        assert!(!ok("ws://localhost:8787").tls);
        for bad in [
            "", "relay.example.com", "https://relay.example.com", "http://relay.example.com", "ws://relay.example.com",
            "ws://192.168.1.5:8787", "wss://", "wss://user:pw@relay.example.com", "wss://relay.example.com/path", "wss://relay.example.com/?x=1",
            "wss://relay.example.com#frag", "wss://relay example.com", "wss://-bad.example.com", "wss://a..b", "wss://relay.example.com:0",
            "wss://relay.example.com:99999", "wss://relay.example.com:", "wss://rélay.example.com", "wss://relay.example.com\\x",
        ] {
            assert!(Target::parse(bad).is_err(), "{bad:?} must be refused");
        }
    }

    #[test]
    fn the_pairing_is_made_once_kept_and_replaced_on_demand() {
        let store = MemStore::default();
        let (room, key) = pairing(&store).unwrap();
        assert!(is_room(&room));
        let (room2, key2) = pairing(&store).unwrap();
        assert_eq!((room.clone(), key.to_base64url()), (room2, key2.to_base64url()), "kept");
        let (room3, key3) = new_pairing(&store).unwrap();
        assert_ne!(room, room3);
        assert_ne!(key.to_base64url(), key3.to_base64url());
        assert_eq!(pairing(&store).unwrap().0, room3);
        // A damaged value is replaced, never used.
        store.set(ROOM_KEY, "short").unwrap();
        assert!(is_room(&pairing(&store).unwrap().0));
    }

    #[test]
    fn the_access_key_is_checked_stored_and_never_printed() {
        let store = MemStore::default();
        assert!(access_key(&store).is_none());
        assert!(credentials(&store).is_err(), "no access key, no connection");
        let good = crypto::base64url_encode(&[9u8; 32]);
        assert_eq!(good.len(), 43);
        set_access_key(&store, &format!("  {good}  ")).unwrap();
        assert_eq!(access_key(&store).as_deref(), Some(good.as_str()));
        for bad in ["short", &"a".repeat(44), &format!("{}=", &good[..42]), &format!("{}!", &good[..42])] {
            assert!(set_access_key(&store, bad).is_err(), "{bad:?}");
        }
        assert_eq!(access_key(&store).as_deref(), Some(good.as_str()), "a refused value changes nothing");
        let creds = credentials(&store).unwrap();
        let shown = format!("{creds:?}");
        assert!(!shown.contains(&good) && !shown.contains(&creds.room) && !shown.contains(&creds.key.to_base64url()), "{shown}");
        set_access_key(&store, "").unwrap();
        assert!(access_key(&store).is_none(), "empty clears it");
    }

    // ── the connection ──

    #[test]
    fn it_presents_the_access_key_the_join_proof_and_the_room() {
        block_on(async {
            let mut rig = Rig::start().await;
            let _ws = rig.socket().await;
            assert_eq!(rig.seen.auth.lock().unwrap()[0], format!("Bearer {}", rig.access));
            assert_eq!(rig.seen.protocols.lock().unwrap()[0], format!("coucou.v1, coucou.join.{}", crypto::join_proof(&rig.key())));
            assert_eq!(rig.seen.paths.lock().unwrap()[0], format!("/v1/room/{}?role=pc", rig.room));
            rig.wait_state(State::Waiting).await;
            rig.handle.stop();
        });
    }

    #[test]
    fn a_phone_pairs_through_the_relay_and_the_usual_conversation_runs() {
        block_on(async {
            let mut rig = Rig::start().await;
            let ws = rig.socket().await;
            let mut phone = Phone::join(&rig, ws).await;
            let welcome = phone.hello().await;
            assert_eq!(welcome["desktop"], "Test PC");
            assert_eq!(rig.handle.state(), State::Linked);
            phone.send(json!({ "type": "ping" })).await;
            phone.expect("pong").await;

            rig.hub.publish(
                vec![],
                Some(ApprovalIn {
                    request_id: "req-1".into(),
                    session_id: "s1".into(),
                    pill_id: "integration_claude".into(),
                    tool: "Bash".into(),
                    command: "npm run build".into(),
                }),
                server::now_ms(),
            );
            let approval = phone.expect("approval").await;
            let fp = approval["fingerprint"].as_str().unwrap().to_string();
            assert_eq!(fp, super::super::hub::fingerprint("integration_claude", "s1", "Bash", "npm run build", "req-1"));
            // A decision for another fingerprint does nothing; the right one is applied once.
            phone.send(json!({ "type": "decision", "fingerprint": "0".repeat(64), "decision": "allow" })).await;
            phone.send(json!({ "type": "decision", "fingerprint": fp, "decision": "allow" })).await;
            phone.expect("approvalResolved").await;
            assert_eq!(rig.host.0.lock().unwrap().clone(), vec![("req-1".to_string(), true)]);
            rig.handle.stop();
        });
    }

    #[test]
    fn the_wrong_token_is_refused_through_the_relay_like_on_the_lan() {
        block_on(async {
            let mut rig = Rig::start().await;
            let ws = rig.socket().await;
            let mut phone = Phone::join(&rig, ws).await;
            phone.send(json!({ "type": "hello", "v": 1, "token": "wrong-token-0123456789abcdef", "caps": [] })).await;
            let err = phone.expect("error").await;
            assert_eq!(err["code"], "auth");
            assert!(rig.host.0.lock().unwrap().is_empty());
            rig.handle.stop();
        });
    }

    #[test]
    fn nothing_is_served_before_the_phone_proves_it_holds_the_key() {
        block_on(async {
            let mut rig = Rig::start().await;
            let mut ws = rig.socket().await;
            // Data without a handshake, a wrong-MAC init, and garbage: all ignored, no answer.
            let mut other = crypto::init_frame(&PairingKey::from_bytes([1u8; 32]), &rig.room, crypto::fresh_nonce());
            ws.send(Message::Binary(other.clone().into())).await.unwrap();
            other[2] ^= 1;
            ws.send(Message::Binary(other.into())).await.unwrap();
            ws.send(Message::Binary(vec![1, 3, 0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3].into())).await.unwrap();
            ws.send(Message::Binary(vec![].into())).await.unwrap();
            assert!(tokio::time::timeout(Duration::from_millis(300), ws.next()).await.is_err(), "no answer to a stranger");
            assert_eq!(rig.shared.admission_counts().0, 0, "no slot was used");
            assert_eq!(rig.hub.clients(), 0);
            rig.handle.stop();
        });
    }

    #[test]
    fn three_bad_handshakes_silence_init_for_a_while() {
        block_on(async {
            let mut rig = Rig::start().await;
            let mut ws = rig.socket().await;
            let wrong = PairingKey::from_bytes([2u8; 32]);
            for _ in 0..3 {
                ws.send(Message::Binary(crypto::init_frame(&wrong, &rig.room, crypto::fresh_nonce()).into())).await.unwrap();
            }
            // Even the right key is not answered during the quiet period.
            let n = crypto::fresh_nonce();
            ws.send(Message::Binary(crypto::init_frame(&rig.key(), &rig.room, n).into())).await.unwrap();
            assert!(tokio::time::timeout(Duration::from_millis(400), ws.next()).await.is_err());
            rig.handle.stop();
        });
    }

    #[test]
    fn a_tampered_replayed_or_reordered_frame_ends_the_conversation() {
        block_on(async {
            let mut rig = Rig::start().await;
            let ws = rig.socket().await;
            let mut phone = Phone::join(&rig, ws).await;
            phone.hello().await;
            // A recorded frame sent again.
            let frame = phone.session.seal(json!({ "type": "ping" }).to_string().as_bytes()).unwrap();
            phone.ws.send(Message::Binary(frame.clone().into())).await.unwrap();
            phone.expect("pong").await;
            phone.ws.send(Message::Binary(frame.into())).await.unwrap();
            // The server connection was dropped: the slot is given back and nothing more is answered.
            for _ in 0..100 {
                if rig.hub.clients() == 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert_eq!(rig.hub.clients(), 0);
            assert_eq!(rig.shared.admission_counts().0, 0, "the slot is given back");
            phone.send(json!({ "type": "ping" })).await; // the old session is dead (its counter is unexpected now)
            assert!(phone.silent().await);
            // Only a fresh handshake starts a conversation again.
            let ws = phone.ws;
            let mut again = Phone::join(&rig, ws).await;
            again.hello().await;
            rig.handle.stop();
        });
    }

    #[test]
    fn a_new_init_replaces_the_conversation_and_old_keys_are_useless() {
        block_on(async {
            let mut rig = Rig::start().await;
            let ws = rig.socket().await;
            let mut first = Phone::join(&rig, ws).await;
            first.hello().await;
            let old_session = std::mem::replace(&mut first.session, {
                // Keep the old keys to try them after the new handshake.
                let n = crypto::fresh_nonce();
                first.ws.send(Message::Binary(crypto::init_frame(&rig.key(), &rig.room, n).into())).await.unwrap();
                let accept = loop {
                    // Frames of the old conversation may still be in flight; the accept is the one of type 2.
                    if let Message::Binary(b) = first.ws.next().await.unwrap().unwrap() {
                        if b[1] == crypto::T_ACCEPT {
                            break b;
                        }
                    }
                };
                crypto::finish_handshake(&rig.key(), &rig.room, &n, &accept).unwrap()
            });
            // The new session works…
            first.hello().await;
            assert_eq!(rig.hub.clients(), 1, "exactly one conversation");
            assert_eq!(rig.shared.admission_counts().0, 1);
            // …and a frame sealed under the old keys does not.
            let mut stale = old_session;
            let frame = stale.seal(json!({ "type": "ping" }).to_string().as_bytes()).unwrap();
            first.ws.send(Message::Binary(frame.into())).await.unwrap();
            for _ in 0..100 {
                if rig.hub.clients() == 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert_eq!(rig.hub.clients(), 0, "a fault ends the conversation");
            assert_eq!(rig.shared.admission_counts().0, 0);
            rig.handle.stop();
        });
    }

    #[test]
    fn when_the_relay_says_the_phone_left_the_conversation_ends() {
        block_on(async {
            let mut rig = Rig::start().await;
            let ws = rig.socket().await;
            let mut phone = Phone::join(&rig, ws).await;
            phone.hello().await;
            assert_eq!(rig.hub.clients(), 1);
            phone.ws.send(Message::Text(r#"{"peer":"offline"}"#.into())).await.unwrap();
            for _ in 0..100 {
                if rig.hub.clients() == 0 {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(20)).await;
            }
            assert_eq!(rig.hub.clients(), 0);
            assert_eq!(rig.shared.admission_counts().0, 0);
            rig.wait_state(State::Waiting).await;
            rig.handle.stop();
        });
    }

    #[test]
    fn the_relay_connection_counts_as_one_source_in_the_admission_policy() {
        block_on(async {
            let mut rig = Rig::start().await;
            let ws = rig.socket().await;
            let mut phone = Phone::join(&rig, ws).await;
            assert_eq!(rig.shared.admission_counts().0, 1, "one slot for the conversation");
            phone.hello().await;
            assert_eq!(rig.shared.admission_counts().0, 1);
            // A flood of inits does not grow it: only the newest conversation holds a slot.
            for _ in 0..5 {
                let n = crypto::fresh_nonce();
                phone.ws.send(Message::Binary(crypto::init_frame(&rig.key(), &rig.room, n).into())).await.unwrap();
            }
            tokio::time::sleep(Duration::from_millis(300)).await;
            assert!(rig.shared.admission_counts().0 <= 1);
            rig.handle.stop();
        });
    }

    #[test]
    fn the_status_names_why_the_relay_was_not_reached() {
        block_on(async {
            for (code, want) in [(401u16, State::AccessRefused), (429, State::TooMany), (404, State::Unreachable)] {
                let (port, seen, conns) = fake_relay(Some(code)).await;
                let rig = Rig::start_at(port, seen, conns).await;
                rig.wait_state(want).await;
                rig.handle.stop();
            }
            // Nothing listening at all.
            let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
            let port = listener.local_addr().unwrap().port();
            drop(listener);
            let rig = Rig::start_at(port, Seen::default(), mpsc::unbounded_channel().1).await;
            rig.wait_state(State::Unreachable).await;
            rig.handle.stop();
        });
    }

    #[test]
    fn stopping_cuts_the_connection_and_shows_off() {
        block_on(async {
            let mut rig = Rig::start().await;
            let mut ws = rig.socket().await;
            let status = rig.handle.status.clone();
            rig.handle.stop();
            assert_eq!(status.get(), State::Off);
            let ended = tokio::time::timeout(Duration::from_secs(5), async {
                loop {
                    match ws.next().await {
                        None | Some(Err(_)) | Some(Ok(Message::Close(_))) => return,
                        _ => {}
                    }
                }
            })
            .await;
            assert!(ended.is_ok(), "the socket is closed when the client stops");
        });
    }

    #[test]
    fn the_source_never_logs_or_prints() {
        let source = include_str!("relay_client.rs");
        let code = &source[..source.find("// ── Tests").unwrap()];
        for forbidden in ["log::", "println!", "eprintln!", "dbg!", "tracing::", "format!(\"{:?}\", creds", "{creds:?}"] {
            assert!(!code.contains(forbidden), "relay_client.rs must not use {forbidden}");
        }
    }

    #[test]
    fn after_pair_again_the_old_pairing_gets_no_answer_and_the_new_one_works() {
        block_on(async {
            let (port, _seen, mut conns) = fake_relay(None).await;
            let store = MemStore::default();
            set_access_key(&store, &crypto::base64url_encode(&[7u8; 32])).unwrap();
            let old = credentials(&store).unwrap();
            let (old_room, old_key) = (old.room.clone(), PairingKey::from_base64url(&old.key.to_base64url()).unwrap());
            // "Pair again": a new room and key, then the client reconnects with them (what the PC does).
            let (new_room, _) = new_pairing(&store).unwrap();
            assert_ne!(old_room, new_room);
            let host = Arc::new(Recorder::default());
            let hub = Hub::new(host.clone());
            let shared = Shared::with_features(hub.clone(), TOKEN.to_string(), "Test PC".to_string(), None, Arc::new(server::NoFeatures));
            let handle = start(shared.clone(), Target { tls: false, host: "127.0.0.1".into(), port }, credentials(&store).unwrap());
            let mut ws = tokio::time::timeout(Duration::from_secs(5), conns.recv()).await.unwrap().unwrap();
            // The phone that still holds the old room and K is not answered.
            ws.send(Message::Binary(crypto::init_frame(&old_key, &old_room, crypto::fresh_nonce()).into())).await.unwrap();
            ws.send(Message::Binary(crypto::init_frame(&old_key, &new_room, crypto::fresh_nonce()).into())).await.unwrap();
            assert!(tokio::time::timeout(Duration::from_millis(300), ws.next()).await.is_err(), "no answer for the old pairing");
            assert_eq!(shared.admission_counts().0, 0);
            // The new pairing is answered.
            let new_key = credentials(&store).unwrap().key;
            let n = crypto::fresh_nonce();
            ws.send(Message::Binary(crypto::init_frame(&new_key, &new_room, n).into())).await.unwrap();
            let accept = loop {
                if let Message::Binary(b) = tokio::time::timeout(Duration::from_secs(5), ws.next()).await.unwrap().unwrap().unwrap() {
                    break b;
                }
            };
            assert!(crypto::finish_handshake(&new_key, &new_room, &n, &accept).is_ok());
            handle.stop();
        });
    }

    // ── End to end through a real relay (run by android/relay/tools/e2e.sh, never by `cargo test`) ──

    /// The computer's half of the end-to-end check: connects to the relay at `COUCOU_E2E_RELAY_URL` with the fixed test
    /// credentials the Kotlin phone test also has, offers one approval and waits for the phone's decision. Ignored by
    /// default; the script runs it together with the phone side, against the real Worker or the Node twin.
    #[test]
    #[ignore = "needs a running relay and the Kotlin phone test: android/relay/tools/e2e.sh"]
    fn e2e_the_computer_side_for_the_phone_test() {
        let url = std::env::var("COUCOU_E2E_RELAY_URL").expect("COUCOU_E2E_RELAY_URL");
        let store = MemStore::default();
        store.set(ROOM_KEY, &crypto::base64url_encode(&[0x11; 16])).unwrap();
        store.set(PAIRING_KEY, &crypto::base64url_encode(&[0x22; 32])).unwrap();
        set_access_key(&store, &crypto::base64url_encode(&[0x33; 32])).unwrap();
        block_on(async {
            let host = Arc::new(Recorder::default());
            let hub = Hub::new(host.clone());
            let shared = Shared::with_features(hub.clone(), "e2e-token-0123456789abcdef".to_string(), "E2E PC".to_string(), None, Arc::new(server::NoFeatures));
            let handle = start(shared, Target::parse(&url).unwrap(), credentials(&store).unwrap());
            // The phone side is a Gradle run that may take minutes to compile on a cold runner, and an approval expires after about two
            // minutes: ask for the decision only once the phone is connected.
            let mut connecting = 0;
            while hub.clients() == 0 && connecting < 6000 {
                tokio::time::sleep(Duration::from_millis(100)).await;
                connecting += 1;
            }
            hub.publish(
                vec![],
                Some(ApprovalIn {
                    request_id: "e2e-req".into(),
                    session_id: "s1".into(),
                    pill_id: "integration_claude".into(),
                    tool: "Bash".into(),
                    command: "echo end-to-end".into(),
                }),
                server::now_ms(),
            );
            let mut waited = 0;
            while host.0.lock().unwrap().is_empty() && waited < 1200 {
                tokio::time::sleep(Duration::from_millis(100)).await;
                waited += 1;
            }
            assert_eq!(host.0.lock().unwrap().clone(), vec![("e2e-req".to_string(), true)], "the phone's decision reached the computer");
            handle.stop();
        });
    }
}
