// WhatsApp in the island (experimental), the Windows and Linux port of the Mac's WhatsAppController.swift.
//
// Talks to the local gateway the user runs (GOWA, which Coucou can install and start itself, or
// OpenWA), receives new messages on a webhook bound to 127.0.0.1, falls back to polling every 20 s
// when no webhook comes, and keeps the conversations in memory only: nothing of a message is ever
// written to disk or to a log, and everything is forgotten when Coucou quits or the integration is
// turned off. Runs only while the integration is on and its pill is active: otherwise there is no
// timer, no listener and no request at all.
//
// The rules (inbox, filters, signatures, limits) are in model.rs and gateway.rs, the HTTP calls in
// provider.rs, the listener in webhook.rs, GOWA's install and process in install.rs and process.rs.
// The island draws what `IslandView` says (src/views/whatsapp.ts), Settings what `SettingsView`
// says (src/settings/whatsapp.ts); both only ever see status codes, which they translate.

pub mod archive;
pub mod gateway;
pub mod install;
pub mod model;
pub mod prefs;
pub mod process;
pub mod provider;
pub mod webhook;

use std::collections::HashSet;
use std::sync::atomic::Ordering;
use std::sync::{Arc, LazyLock, Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, WebviewWindow};

use gateway::{Kind, Link, WebhookEvent};
use install::Step;
use model::{Conversation, Filters, Inbox, Message, Outcome, RateLimit, Refusal};
use prefs::Prefs;
use provider::{Provider, WaError};
use webhook::Listener;

pub const PILL_ID: &str = "integration_whatsapp";
const WEBHOOK_PATH: &str = "/whatsapp";
/// Credential store entries, Rust-only (secrets.rs INTERNAL_KEYS): the webview never reads them.
pub const URL_KEY: &str = "whatsapp-url";
pub const CREDENTIAL_KEY: &str = "whatsapp-api-key";
pub const SECRET_KEY: &str = "whatsapp-webhook-secret";

const ISLAND_EVENT: &str = "whatsapp";
const PILL_EVENT: &str = "whatsapp-pill";
const SETTINGS_EVENT: &str = "whatsapp-settings";

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum LinkState {
    Off,
    /// The gateway's address can't be used.
    BadUrl,
    Connecting,
    /// The gateway runs, WhatsApp isn't linked: the QR is shown in Settings.
    NeedsQr,
    Connected,
    Unreachable,
    Unauthorized,
    /// The gateway's own error message.
    Failed { detail: String },
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "state", rename_all = "camelCase")]
pub enum WebhookState {
    Off,
    /// Listening on the port, not yet accepted by the gateway.
    Listening,
    /// The gateway accepted the address: messages come on their own.
    Registered,
    /// The gateway refused it (its message): polling instead.
    Refused { detail: String },
    /// The port is taken.
    PortBusy { port: u16 },
}

/// Why the last reply didn't go (shown under the field until the next try).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "code", rename_all = "camelCase")]
pub enum SendError {
    TooLong,
    TooFast,
    Unreachable,
    Unauthorized,
    NeedsQr,
    Refused { detail: String },
}

/// What happens to the pill (src/island/whatsapp.ts).
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
enum PillEvent {
    /// A new message reaches you: only the conversation's name, never the text.
    Message { name: String },
    /// Nothing unread is left: the badge goes.
    Read,
    /// Turned off: the pill goes back to idle.
    Reset,
}

/// What the island shows.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IslandView {
    pub on: bool,
    pub link: LinkState,
    /// Newest first, filters applied.
    pub conversations: Vec<Conversation>,
    pub unread: u32,
    pub sending: bool,
    pub send_error: Option<SendError>,
    /// The gateway failed twice in a row: a small red dot on the pill.
    pub down: bool,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct IgnoredChat {
    pub id: String,
    pub name: String,
}

/// What Settings shows.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SettingsView {
    pub prefs: Prefs,
    /// The address typed in Settings, "" for the gateway's default.
    pub url: String,
    pub default_url: String,
    pub has_credential: bool,
    pub link: LinkState,
    pub webhook: WebhookState,
    /// A `data:image/png;base64,…` URL while WhatsApp waits for the scan.
    pub qr: Option<String>,
    /// This account's number once linked.
    pub me: Option<String>,
    pub install: Step,
    /// A GOWA binary Coucou can start (the one it installed, or one the user gave).
    pub installed: bool,
    /// Where GOWA keeps its WhatsApp session (and Coucou the binary it installed).
    pub gowa_dir: String,
    pub pill_active: bool,
    pub ignored: Vec<IgnoredChat>,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(tag = "result", rename_all = "camelCase")]
pub enum TestResult {
    Connected { who: String },
    NeedsQr,
    Connecting,
    BadUrl,
    Unreachable,
    Unauthorized,
    Refused { detail: String },
}

struct Ctl {
    prefs: Prefs,
    url: String,
    has_credential: bool,
    pill_active: bool,
    provider: Option<Arc<Provider>>,
    /// Bumped at each start and stop: an answer from before a restart is dropped.
    generation: u64,
    link: LinkState,
    webhook: WebhookState,
    secret: String,
    qr: Option<String>,
    qr_expiry: Option<Instant>,
    me: Option<String>,
    inbox: Inbox,
    listener: Option<Listener>,
    tick: u64,
    refreshing: bool,
    polling: bool,
    backfilled: bool,
    last_webhook: Option<Instant>,
    last_poll_ms: i64,
    naming: HashSet<String>,
    /// The conversation open in the card: what arrives there is seen, so it isn't unread.
    open_chat: Option<String>,
    rate: RateLimit,
    /// Failed checks in a row (the gateway down, refusing, unreachable).
    failures: u32,
    down: bool,
    sending: bool,
    send_error: Option<SendError>,
    install: Step,
}

static CTL: LazyLock<Mutex<Ctl>> = LazyLock::new(|| {
    Mutex::new(Ctl {
        prefs: Prefs::default(),
        url: String::new(),
        has_credential: false,
        pill_active: false,
        provider: None,
        generation: 0,
        link: LinkState::Off,
        webhook: WebhookState::Off,
        secret: String::new(),
        qr: None,
        qr_expiry: None,
        me: None,
        inbox: Inbox::default(),
        listener: None,
        tick: 0,
        refreshing: false,
        polling: false,
        backfilled: false,
        last_webhook: None,
        last_poll_ms: 0,
        naming: HashSet::new(),
        open_chat: None,
        rate: RateLimit::default(),
        failures: 0,
        down: false,
        sending: false,
        send_error: None,
        install: Step::Idle,
    })
});

static APP: OnceLock<AppHandle> = OnceLock::new();

fn ctl() -> MutexGuard<'static, Ctl> {
    CTL.lock().unwrap_or_else(PoisonError::into_inner)
}

impl Ctl {
    fn kind(&self) -> Kind {
        Kind::from_name(&self.prefs.gateway)
    }

    fn should_run(&self) -> bool {
        self.prefs.enabled && self.pill_active
    }

    fn filters(&self) -> Filters {
        Filters { mute_groups: self.prefs.mute_groups, ignored: self.prefs.ignored.iter().cloned().collect() }
    }

    fn effective_url(&self) -> String {
        if self.url.is_empty() { self.kind().default_url().to_string() } else { self.url.clone() }
    }

    fn webhook_alive(&self) -> bool {
        self.last_webhook.is_some_and(|t| t.elapsed() < Duration::from_secs(300))
    }

    fn island_view(&self) -> IslandView {
        let filters = self.filters();
        IslandView {
            on: self.provider.is_some(),
            link: self.link.clone(),
            conversations: self.inbox.visible(&filters).into_iter().cloned().collect(),
            unread: self.inbox.visible_unread(&filters),
            sending: self.sending,
            send_error: self.send_error.clone(),
            down: self.down,
        }
    }

    fn settings_view(&self) -> SettingsView {
        let path = self.prefs.gowa_path.trim();
        SettingsView {
            prefs: self.prefs.clone(),
            url: self.url.clone(),
            default_url: self.kind().default_url().to_string(),
            has_credential: self.has_credential,
            link: self.link.clone(),
            webhook: self.webhook.clone(),
            qr: self.qr.clone(),
            me: self.me.as_deref().map(model::display_number),
            install: self.install.clone(),
            installed: !path.is_empty() && process::is_runnable(std::path::Path::new(path)),
            gowa_dir: process::working_dir().to_string_lossy().into_owned(),
            pill_active: self.pill_active,
            ignored: self
                .prefs
                .ignored
                .iter()
                .map(|id| IgnoredChat {
                    id: id.clone(),
                    name: self.inbox.conversations.get(id).map(|c| c.name.clone()).unwrap_or_else(|| model::display_number(id)),
                })
                .collect(),
        }
    }
}

// ── Telling the pages ─────────────────────────────────────────────────────────

/// Both pages redraw from what changed. Never called with the lock held.
fn changed() {
    let Some(app) = APP.get() else { return };
    let (island, settings) = {
        let c = ctl();
        (c.island_view(), c.settings_view())
    };
    let _ = app.emit_to(crate::island::WINDOW_LABEL, ISLAND_EVENT, island);
    let _ = app.emit_to(crate::HUB_LABEL, SETTINGS_EVENT, settings);
}

fn pill(event: PillEvent) {
    if let Some(app) = APP.get() {
        let _ = app.emit_to(crate::island::WINDOW_LABEL, PILL_EVENT, event);
    }
}

fn spawn<F: std::future::Future<Output = ()> + Send + 'static>(f: F) {
    tauri::async_runtime::spawn(f);
}

/// GOWA started or stopped to match Settings, off the async threads (stopping it waits a second).
fn sync_gowa(c: &Ctl) {
    let wanted = c.prefs.auto_start && c.kind() == Kind::Gowa;
    let (binary, url) = (c.prefs.gowa_path.clone(), c.effective_url());
    let credential = if wanted { crate::secrets::get_internal(CREDENTIAL_KEY).unwrap_or_default() } else { String::new() };
    tauri::async_runtime::spawn_blocking(move || {
        process::sync(wanted, &binary, &url, &credential);
    });
}

/// The webhook's signing secret, made once (random, 64 hex characters), kept in the credential store.
fn webhook_secret() -> String {
    if let Some(s) = crate::secrets::get_internal(SECRET_KEY).filter(|s| s.len() >= 16) {
        return s;
    }
    use ring::rand::{SecureRandom, SystemRandom};
    let mut bytes = [0u8; 32];
    if SystemRandom::new().fill(&mut bytes).is_err() {
        return String::new(); // no secret, no webhook: polling only
    }
    let s = gateway::hex(&bytes);
    let _ = crate::secrets::set_internal(SECRET_KEY, &s);
    s
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

/// Called once at launch.
pub fn start(app: &AppHandle, active_integrations: &[String]) {
    let _ = APP.set(app.clone());
    {
        let mut c = ctl();
        c.prefs = prefs::load();
        c.url = crate::secrets::get_internal(URL_KEY).unwrap_or_default();
        c.has_credential = crate::secrets::get_internal(CREDENTIAL_KEY).is_some();
        c.pill_active = active_integrations.iter().any(|x| x == PILL_ID);
    }
    update();
}

/// Settings were saved: the pill turned on or off from anywhere is followed.
pub fn sync(active_integrations: &[String]) {
    let active = active_integrations.iter().any(|x| x == PILL_ID);
    let moved = {
        let mut c = ctl();
        let moved = c.pill_active != active;
        c.pill_active = active;
        moved
    };
    if moved {
        update();
    }
}

/// Coucou quits: GOWA goes with it, and so does everything in memory.
pub fn shutdown() {
    {
        let mut c = ctl();
        c.generation += 1;
        if let Some(l) = c.listener.take() {
            l.stop();
        }
        c.provider = None;
        c.inbox.clear();
    }
    process::stop_now();
}

fn update() {
    let (run, running) = {
        let c = ctl();
        (c.should_run(), c.provider.is_some())
    };
    if run && !running {
        begin();
    } else if !run && running {
        stop(true);
        changed();
    } else {
        changed();
    }
}

/// Settings changed (on/off, gateway, URL, credentials, port): start over.
fn settings_changed() {
    let forget = !ctl().should_run();
    stop(forget);
    update();
}

fn begin() {
    let secret = webhook_secret();
    let (gen, port, kind) = {
        let mut c = ctl();
        let kind = c.kind();
        let Some(base) = provider::parse_base(&c.effective_url()) else {
            c.link = LinkState::BadUrl;
            drop(c);
            changed();
            return;
        };
        let credential = crate::secrets::get_internal(CREDENTIAL_KEY);
        let Ok(provider) = Provider::new(kind, base, credential) else {
            c.link = LinkState::Unreachable;
            drop(c);
            changed();
            return;
        };
        c.provider = Some(Arc::new(provider));
        c.generation += 1;
        c.link = LinkState::Connecting;
        c.secret = secret.clone();
        c.tick = 0;
        // GOWA started by Coucou when asked to, before the first check.
        sync_gowa(&c);
        (c.generation, c.prefs.port, kind)
    };
    start_listener(gen, port, kind, secret);
    spawn_ticker(gen);
    changed();
    refresh();
}

/// Stops talking to the gateway. `forget`: the conversations go too.
fn stop(forget: bool) {
    let mut c = ctl();
    c.generation += 1;
    c.refreshing = false;
    c.polling = false;
    if let Some(l) = c.listener.take() {
        l.stop();
    }
    c.provider = None;
    c.link = LinkState::Off;
    c.webhook = WebhookState::Off;
    c.qr = None;
    c.qr_expiry = None;
    c.me = None;
    c.backfilled = false;
    c.last_webhook = None;
    c.naming.clear();
    c.failures = 0;
    c.down = false;
    c.sending = false;
    c.send_error = None;
    // Turned off: GOWA goes too. Otherwise begin() keeps it, or restarts it if its settings changed.
    if !c.should_run() {
        tauri::async_runtime::spawn_blocking(process::stop_now);
    }
    if forget {
        c.open_chat = None;
        c.inbox.clear();
        drop(c);
        pill(PillEvent::Reset);
    }
}

fn start_listener(gen: u64, port: u16, kind: Kind, secret: String) {
    let handler: webhook::Handler = Arc::new(move |request| {
        if request.method != "POST" || !request.path.starts_with(WEBHOOK_PATH) {
            return 404;
        }
        // Signed by the gateway with Coucou's secret, over the exact bytes received.
        if !gateway::verify(kind, &request.headers, &request.body, &secret) {
            return 401;
        }
        let body = request.body;
        spawn(async move { received(gen, kind, &body) });
        200
    });
    let listener = Listener::start(port, handler);
    let mut c = ctl();
    if c.generation != gen {
        if let Ok(l) = listener {
            l.stop();
        }
        return;
    }
    match listener {
        Ok(l) => {
            c.listener = Some(l);
            c.webhook = WebhookState::Listening;
        }
        Err(()) => c.webhook = WebhookState::PortBusy { port },
    }
}

fn spawn_ticker(gen: u64) {
    spawn(async move {
        let mut last = Instant::now();
        loop {
            tokio::time::sleep(Duration::from_secs(5)).await;
            if ctl().generation != gen {
                break;
            }
            // Back from sleep (the 5 s took far longer): nothing is trusted, the gateway may have
            // restarted without Coucou's webhook.
            if last.elapsed() > Duration::from_secs(30) {
                let mut c = ctl();
                if c.webhook == WebhookState::Registered {
                    c.webhook = WebhookState::Listening;
                }
                c.last_webhook = None;
            }
            last = Instant::now();
            on_tick();
        }
    });
}

fn on_tick() {
    // Paused from the tray: nothing reaches the network.
    if crate::integrations::PAUSED.load(Ordering::Relaxed) {
        return;
    }
    let (refresh_now, poll_now) = {
        let mut c = ctl();
        c.tick += 1;
        if c.link != LinkState::Connected {
            // Every 5 s while linking (QR, gateway coming up); every 30 s once the gateway has
            // been down for a minute.
            (!(c.failures > 12 && c.tick % 6 != 0), false)
        } else {
            // Every minute: still linked? Every 20 s: new messages, unless the webhook delivers.
            (c.tick % 12 == 0, c.tick % 4 == 0)
        }
    };
    if refresh_now {
        refresh();
    }
    if poll_now {
        poll();
    }
}

// ── Status and QR ─────────────────────────────────────────────────────────────

fn refresh() {
    let (provider, gen) = {
        let mut c = ctl();
        let Some(p) = c.provider.clone() else { return };
        if c.refreshing {
            return;
        }
        c.refreshing = true;
        (p, c.generation)
    };
    spawn(async move {
        let result = provider.status().await;
        let (mut register, mut backfill_now, mut ask_qr) = (false, false, false);
        {
            let mut c = ctl();
            if c.generation != gen {
                return;
            }
            match result {
                Ok(status) => {
                    if c.failures > 0 {
                        c.failures = 0;
                        c.down = false;
                    }
                    c.me = status.me;
                    match status.link {
                        Link::Connected => {
                            if c.link != LinkState::Connected {
                                c.qr = None;
                            }
                            c.link = LinkState::Connected;
                            register = c.webhook == WebhookState::Listening;
                            if !c.backfilled {
                                c.backfilled = true;
                                backfill_now = true;
                            }
                        }
                        Link::NeedsQr => {
                            c.link = LinkState::NeedsQr;
                            if c.qr.is_none() || c.qr_expiry.is_none_or(|t| Instant::now() > t) {
                                // Not asked again for 15 s even when nothing came: each GOWA login
                                // call restarts the pairing.
                                c.qr_expiry = Some(Instant::now() + Duration::from_secs(15));
                                ask_qr = true;
                            }
                        }
                        Link::Connecting => c.link = LinkState::Connecting,
                    }
                }
                Err(err) => apply(&mut c, err),
            }
        }
        changed();
        if register {
            register_webhook(&provider, gen).await;
        }
        if backfill_now {
            backfill(&provider, gen).await;
        }
        if ask_qr {
            let qr = provider.qr().await;
            let mut c = ctl();
            if c.generation == gen {
                match qr {
                    Ok(Some(qr)) => {
                        c.qr = Some(qr.data_url);
                        c.qr_expiry = Some(Instant::now() + Duration::from_secs(qr.seconds));
                    }
                    Ok(None) => {}
                    Err(err) => apply(&mut c, err),
                }
            }
            drop(c);
            changed();
        }
        let mut c = ctl();
        if c.generation == gen {
            c.refreshing = false;
        }
    });
}

fn apply(c: &mut Ctl, error: WaError) {
    c.link = match &error {
        WaError::Unreachable => LinkState::Unreachable,
        WaError::Unauthorized => LinkState::Unauthorized,
        WaError::NotLoggedIn => LinkState::NeedsQr,
        WaError::Refused(why) => LinkState::Failed { detail: why.clone() },
    };
    if error == WaError::NotLoggedIn {
        return;
    }
    c.failures += 1;
    // Twice in a row (not a gateway still starting): a small red dot on the pill, nothing more.
    if c.failures == 2 {
        c.down = true;
    }
    // GOWA started by Coucou and gone (crash, killed): started again, once a minute at most.
    if error == WaError::Unreachable {
        sync_gowa(c);
    }
}

/// One check from Settings' "Test connection": what the gateway says.
async fn test_connection() -> TestResult {
    // The running connection when there is one (a second one could race it for OpenWA's session).
    let provider = {
        let c = ctl();
        match c.provider.clone() {
            Some(p) => p,
            None => {
                let Some(base) = provider::parse_base(&c.effective_url()) else { return TestResult::BadUrl };
                match Provider::new(c.kind(), base, crate::secrets::get_internal(CREDENTIAL_KEY)) {
                    Ok(p) => Arc::new(p),
                    Err(_) => return TestResult::Unreachable,
                }
            }
        }
    };
    let mut attempt = 0;
    let status = loop {
        match provider.status().await {
            // GOWA just started by Coucou: a few seconds to come up.
            Err(WaError::Unreachable) if process::is_running() && attempt < 8 => {
                attempt += 1;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            other => break other,
        }
    };
    match status {
        Ok(s) => match s.link {
            Link::Connected => TestResult::Connected { who: s.me.as_deref().map(model::display_number).unwrap_or_default() },
            Link::NeedsQr => TestResult::NeedsQr,
            Link::Connecting => TestResult::Connecting,
        },
        Err(WaError::Unreachable) => TestResult::Unreachable,
        Err(WaError::Unauthorized) => TestResult::Unauthorized,
        Err(WaError::NotLoggedIn) => TestResult::NeedsQr,
        Err(WaError::Refused(detail)) => TestResult::Refused { detail },
    }
}

// ── Webhook ───────────────────────────────────────────────────────────────────

async fn register_webhook(provider: &Provider, gen: u64) {
    let (url, secret) = {
        let c = ctl();
        (format!("http://127.0.0.1:{}{WEBHOOK_PATH}", c.prefs.port), c.secret.clone())
    };
    if secret.is_empty() {
        return;
    }
    let result = provider.register_webhook(&url, &secret).await;
    {
        let mut c = ctl();
        if c.generation != gen {
            return;
        }
        match result {
            Ok(()) => c.webhook = WebhookState::Registered,
            Err(WaError::Refused(why)) => {
                crate::log::line(format!("whatsapp: the gateway refused the webhook: {why}"));
                c.webhook = WebhookState::Refused { detail: why };
            }
            // Tried again on the next minute's check.
            Err(_) => {}
        }
    }
    changed();
}

fn received(gen: u64, kind: Kind, body: &[u8]) {
    let (fresh, groups) = {
        let mut c = ctl();
        if c.generation != gen || c.provider.is_none() {
            return;
        }
        c.last_webhook = Some(Instant::now());
        if c.webhook != WebhookState::Registered {
            c.webhook = WebhookState::Registered;
        }
        let me = c.me.clone();
        let Some(WebhookEvent::Message(message)) = gateway::parse_webhook(kind, body, me.as_deref()) else { return };
        ingest(&mut c, vec![message])
    };
    after_ingest(gen, fresh, groups);
}

// ── Messages ──────────────────────────────────────────────────────────────────

/// The last hours of history, once linked: kept, but nothing counts as new.
async fn backfill(provider: &Arc<Provider>, gen: u64) {
    let me = ctl().me.clone();
    let since = gateway::now_ms() - 12 * 3600 * 1000;
    let Ok(messages) = provider.recent_messages(since, me.as_deref()).await else { return };
    let groups = {
        let mut c = ctl();
        if c.generation != gen {
            return;
        }
        let filters = c.filters();
        // History: kept, never counted as unread, never announced.
        let chats: Vec<String> = messages.iter().map(|m| model::normalized(&m.chat)).collect();
        for message in messages {
            c.inbox.add(message, &filters, None, true);
        }
        let groups = chats.iter().filter_map(|chat| needs_name(&mut c, chat)).collect::<Vec<_>>();
        c.last_poll_ms = gateway::now_ms();
        groups
    };
    name_groups(provider.clone(), gen, groups);
    changed();
}

fn poll() {
    let (provider, gen, since, me) = {
        let mut c = ctl();
        let Some(p) = c.provider.clone() else { return };
        if c.polling || c.webhook_alive() || !c.backfilled {
            return;
        }
        c.polling = true;
        // A little overlap; duplicates are dropped.
        (p, c.generation, c.last_poll_ms - 30_000, c.me.clone())
    };
    spawn(async move {
        let started = gateway::now_ms();
        let result = provider.recent_messages(since, me.as_deref()).await;
        let (fresh, groups) = {
            let mut c = ctl();
            if c.generation != gen {
                return;
            }
            c.polling = false;
            let Ok(messages) = result else { return };
            c.last_poll_ms = started;
            ingest(&mut c, messages)
        };
        after_ingest(gen, fresh, groups);
    });
}

/// Adds what arrived. Returns the conversation to announce (its name), and the groups to name.
fn ingest(c: &mut Ctl, messages: Vec<Message>) -> (Option<String>, Vec<String>) {
    let filters = c.filters();
    let mut fresh: Option<String> = None;
    let mut groups = Vec::new();
    for message in messages {
        let key = model::normalized(&message.chat);
        let from_me = message.from_me;
        let outcome = c.inbox.add(message, &filters, None, false);
        if let Some(g) = needs_name(c, &key) {
            groups.push(g);
        }
        if c.open_chat.as_deref() == Some(key.as_str()) {
            // Read on screen: no unread, no Mochi. The receipt waits for a reply (or the next
            // opening), as Settings says.
            c.inbox.mark_read(&key);
            continue;
        }
        if outcome == Outcome::Notify && !from_me {
            fresh = Some(key);
        }
    }
    let name = fresh.map(|key| c.inbox.conversations.get(&key).map(|conv| conv.name.clone()).unwrap_or_else(|| model::display_number(&key)));
    (name, groups)
}

fn after_ingest(gen: u64, fresh: Option<String>, groups: Vec<String>) {
    if let Some(name) = fresh {
        pill(PillEvent::Message { name });
    }
    if let Some(provider) = ctl().provider.clone() {
        name_groups(provider, gen, groups);
    }
    changed();
}

/// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
fn needs_name(c: &mut Ctl, chat: &str) -> Option<String> {
    if !model::is_group(chat) || c.naming.contains(chat) {
        return None;
    }
    let conv = c.inbox.conversations.get(chat)?;
    if conv.name != model::display_number(chat) {
        return None;
    }
    c.naming.insert(chat.to_string());
    Some(chat.to_string())
}

fn name_groups(provider: Arc<Provider>, gen: u64, groups: Vec<String>) {
    if groups.is_empty() {
        return;
    }
    spawn(async move {
        for chat in groups {
            let Some(name) = provider.group_name(&chat).await else { continue };
            let mut c = ctl();
            if c.generation != gen {
                return;
            }
            c.inbox.rename(&chat, &name);
            drop(c);
            changed();
        }
    });
}

// ── The conversation ──────────────────────────────────────────────────────────

/// Marks the chat read here and, when it had something unread, on WhatsApp too (up to its newest
/// received message). Returns the receipt to send.
fn mark_read(c: &mut Ctl, chat: &str) -> Option<(String, Option<String>)> {
    let key = model::normalized(chat);
    let conv = c.inbox.conversations.get(&key)?;
    let had_unread = conv.unread > 0;
    let last = conv.messages.iter().rev().find(|m| !m.from_me).map(|m| m.id.clone());
    c.inbox.mark_read(&key);
    if c.inbox.visible_unread(&c.filters()) == 0 {
        pill(PillEvent::Read);
    }
    // Nothing new: no receipt to send.
    had_unread.then_some((key, last))
}

/// A conversation opened in the card: its latest messages from the gateway, and the read receipt
/// when Settings says so.
fn open(chat: &str) {
    let (provider, gen, receipt, me) = {
        let mut c = ctl();
        c.send_error = None;
        c.open_chat = Some(model::normalized(chat));
        let Some(p) = c.provider.clone() else { return };
        let receipt = if c.prefs.mark_read_on_open { mark_read(&mut c, chat) } else { None };
        (p, c.generation, receipt, c.me.clone())
    };
    changed();
    let chat = chat.to_string();
    spawn(async move {
        if let Some((key, last)) = receipt {
            let _ = provider.mark_read(&key, last.as_deref()).await;
        }
        let Ok(history) = provider.messages(&chat, 10, me.as_deref()).await else { return };
        {
            let mut c = ctl();
            if c.generation != gen {
                return;
            }
            let filters = c.filters();
            for message in history {
                c.inbox.add(message, &filters, None, true);
            }
        }
        changed();
    });
}

fn close(chat: &str) {
    let mut c = ctl();
    if c.open_chat.as_deref() == Some(model::normalized(chat).as_str()) {
        c.open_chat = None;
    }
}

/// Sends a reply: only to a conversation already in the inbox, one at a time, a few a minute, and
/// only from the user's own Enter or click in the card. True once the gateway took it.
async fn send(chat: &str, text: &str) -> bool {
    let key = model::normalized(chat);
    let (provider, gen, body, me) = {
        let mut c = ctl();
        let Some(p) = c.provider.clone() else { return false };
        if c.sending {
            return false;
        }
        match model::check_reply(text, &key, &c.inbox) {
            Some(Refusal::TooLong) => {
                c.send_error = Some(SendError::TooLong);
                drop(c);
                changed();
                return false;
            }
            Some(_) => return false,
            None => {}
        }
        if !c.rate.allow(Instant::now()) {
            c.send_error = Some(SendError::TooFast);
            drop(c);
            changed();
            return false;
        }
        c.sending = true;
        c.send_error = None;
        (p, c.generation, text.trim().to_string(), c.me.clone())
    };
    changed();
    let result = provider.send(&body, &key).await;
    let receipt = {
        let mut c = ctl();
        // Turned off or restarted meanwhile: the inbox it belonged to is gone.
        if c.generation != gen {
            return result.is_ok();
        }
        c.sending = false;
        match result {
            Ok(id) => {
                let id = id.unwrap_or_else(|| format!("coucou-{}-{}", gateway::now_ms(), c.inbox.conversations.len()));
                let mut mine = Message::new(&id, &key, me.as_deref().unwrap_or(""), &body, gateway::now_ms());
                mine.from_me = true;
                mine.chat_name = c.inbox.conversations.get(&key).map(|conv| conv.name.clone());
                let filters = c.filters();
                c.inbox.add(mine, &filters, None, false);
                // Replying reads the conversation, whatever the setting.
                let last = c.inbox.conversations.get(&key).and_then(|conv| conv.messages.iter().rev().find(|m| !m.from_me)).map(|m| m.id.clone());
                if c.inbox.visible_unread(&filters) == 0 {
                    pill(PillEvent::Read);
                }
                Some(last)
            }
            Err(err) => {
                c.send_error = Some(match err {
                    WaError::Unreachable => SendError::Unreachable,
                    WaError::Unauthorized => SendError::Unauthorized,
                    WaError::NotLoggedIn => SendError::NeedsQr,
                    WaError::Refused(detail) => SendError::Refused { detail },
                });
                None
            }
        }
    };
    changed();
    match receipt {
        Some(last) => {
            let _ = provider.mark_read(&key, last.as_deref()).await;
            true
        }
        None => false,
    }
}

fn ignore(chat: &str) {
    let key = model::normalized(chat);
    {
        let mut c = ctl();
        c.prefs.ignored.push(key.clone());
        c.prefs = c.prefs.clone().cleaned();
        prefs::save(&c.prefs);
        c.inbox.remove(&key);
        if c.open_chat.as_deref() == Some(key.as_str()) {
            c.open_chat = None;
        }
    }
    changed();
}

/// What Settings' "Add" turns into a chat id: a phone number ("+33 6 12…") or a full id ("…@g.us").
pub fn chat_from_entry(raw: &str) -> Option<String> {
    let raw = raw.trim();
    if raw.contains('@') {
        return (raw.len() > 3 && !raw.chars().any(char::is_whitespace)).then(|| raw.to_string());
    }
    let digits: String = raw.chars().filter(char::is_ascii_digit).collect();
    (!digits.is_empty()).then(|| format!("{digits}@s.whatsapp.net"))
}

// ── GOWA install ──────────────────────────────────────────────────────────────

fn set_install(step: Step) {
    ctl().install = step;
    changed();
}

fn install() {
    {
        let mut c = ctl();
        if c.install.busy() {
            return;
        }
        c.install = Step::Checking;
    }
    changed();
    spawn(async move {
        match install::run(set_install).await {
            Ok(version) => {
                {
                    let mut c = ctl();
                    c.prefs.gowa_version = Some(version.clone());
                    c.prefs.gateway = "gowa".into();
                    c.prefs.gowa_path = process::installed_binary().to_string_lossy().into_owned();
                    c.prefs.auto_start = true;
                    prefs::save(&c.prefs);
                    // Back to http://127.0.0.1:3000.
                    let _ = crate::secrets::set_internal(URL_KEY, "");
                    c.url.clear();
                    c.install = Step::Done { version: version.clone() };
                }
                crate::log::line(format!("whatsapp: GOWA {version} installed ({} {})", gateway::release::this_os(), gateway::release::this_arch()));
                // Starts it; the QR follows.
                settings_changed();
            }
            Err(reason) => {
                crate::log::line(format!("whatsapp: GOWA install failed: {reason}"));
                set_install(Step::Failed { reason });
            }
        }
    });
}

// ── Commands ──────────────────────────────────────────────────────────────────

fn only(window: &WebviewWindow, label: &str) -> Result<(), String> {
    if window.label() == label { Ok(()) } else { Err("not from this window".into()) }
}

#[tauri::command]
pub fn whatsapp_island(window: WebviewWindow) -> Result<IslandView, String> {
    only(&window, crate::island::WINDOW_LABEL)?;
    Ok(ctl().island_view())
}

#[tauri::command]
pub fn whatsapp_open(window: WebviewWindow, chat: String) -> Result<(), String> {
    only(&window, crate::island::WINDOW_LABEL)?;
    open(&chat);
    Ok(())
}

#[tauri::command]
pub fn whatsapp_close(window: WebviewWindow, chat: String) -> Result<(), String> {
    only(&window, crate::island::WINDOW_LABEL)?;
    close(&chat);
    Ok(())
}

/// Enter or the send button in the island's card: the only way a message leaves Coucou.
#[tauri::command]
pub async fn whatsapp_send(window: WebviewWindow, chat: String, text: String) -> Result<bool, String> {
    only(&window, crate::island::WINDOW_LABEL)?;
    Ok(send(&chat, &text).await)
}

#[tauri::command]
pub fn whatsapp_ignore(window: WebviewWindow, chat: String) -> Result<(), String> {
    if window.label() != crate::island::WINDOW_LABEL {
        only(&window, crate::HUB_LABEL)?;
    }
    let chat = chat_from_entry(&chat).ok_or("not a chat")?;
    ignore(&chat);
    Ok(())
}

#[tauri::command]
pub fn whatsapp_unignore(window: WebviewWindow, chat: String) -> Result<(), String> {
    only(&window, crate::HUB_LABEL)?;
    {
        let mut c = ctl();
        c.prefs.ignored.retain(|x| x != &chat);
        prefs::save(&c.prefs);
    }
    changed();
    Ok(())
}

#[tauri::command]
pub fn whatsapp_settings(window: WebviewWindow) -> Result<SettingsView, String> {
    only(&window, crate::HUB_LABEL)?;
    Ok(ctl().settings_view())
}

/// The switches: on/off, mute groups, read receipts on opening.
#[tauri::command]
pub fn whatsapp_set_options(window: WebviewWindow, enabled: bool, mute_groups: bool, mark_read_on_open: bool) -> Result<(), String> {
    only(&window, crate::HUB_LABEL)?;
    let restart = {
        let mut c = ctl();
        let restart = c.prefs.enabled != enabled;
        c.prefs.enabled = enabled;
        c.prefs.mute_groups = mute_groups;
        c.prefs.mark_read_on_open = mark_read_on_open;
        prefs::save(&c.prefs);
        restart
    };
    if restart { settings_changed() } else { changed() }
    Ok(())
}

/// Advanced → Save: the gateway, its address and credential (None keeps the stored one, "" removes
/// it), the webhook's port, and GOWA started by Coucou.
#[tauri::command]
pub fn whatsapp_save_gateway(
    window: WebviewWindow,
    gateway: String,
    url: String,
    credential: Option<String>,
    port: u16,
    auto_start: bool,
    gowa_path: String,
) -> Result<(), String> {
    only(&window, crate::HUB_LABEL)?;
    let url = url.trim().to_string();
    if url.len() > 512 || credential.as_ref().is_some_and(|c| c.len() > 1024) {
        return Err("too long".into());
    }
    crate::secrets::set_internal(URL_KEY, &url)?;
    if let Some(credential) = &credential {
        crate::secrets::set_internal(CREDENTIAL_KEY, credential.trim())?;
    }
    {
        let mut c = ctl();
        c.url = url;
        if let Some(credential) = credential {
            c.has_credential = !credential.trim().is_empty();
        }
        let mut next = c.prefs.clone();
        next.gateway = gateway;
        if (1024..=65535).contains(&port) {
            next.port = port;
        }
        next.auto_start = auto_start;
        next.gowa_path = gowa_path;
        c.prefs = next.cleaned();
        prefs::save(&c.prefs);
    }
    settings_changed();
    Ok(())
}

#[tauri::command]
pub async fn whatsapp_test(window: WebviewWindow) -> Result<TestResult, String> {
    only(&window, crate::HUB_LABEL)?;
    Ok(test_connection().await)
}

/// "Install WhatsApp" / "Update": the one network call to GitHub, on this click only.
#[tauri::command]
pub fn whatsapp_install(window: WebviewWindow) -> Result<(), String> {
    only(&window, crate::HUB_LABEL)?;
    install();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn msg(id: &str, chat: &str, text: &str) -> Message {
        Message::new(id, chat, chat, text, gateway::now_ms())
    }

    fn fresh_ctl() -> Ctl {
        Ctl {
            prefs: Prefs::default(),
            url: String::new(),
            has_credential: false,
            pill_active: true,
            provider: None,
            generation: 0,
            link: LinkState::Off,
            webhook: WebhookState::Off,
            secret: String::new(),
            qr: None,
            qr_expiry: None,
            me: None,
            inbox: Inbox::default(),
            listener: None,
            tick: 0,
            refreshing: false,
            polling: false,
            backfilled: false,
            last_webhook: None,
            last_poll_ms: 0,
            naming: HashSet::new(),
            open_chat: None,
            rate: RateLimit::default(),
            failures: 0,
            down: false,
            sending: false,
            send_error: None,
            install: Step::Idle,
        }
    }

    #[test]
    fn what_arrives_is_announced_by_name_only_and_never_in_the_open_chat() {
        let mut c = fresh_ctl();
        let mut m = msg("1", "33612345678@s.whatsapp.net", "secret text");
        m.sender_name = "Marie".into();
        let (fresh, groups) = ingest(&mut c, vec![m]);
        assert_eq!(fresh.as_deref(), Some("Marie"));
        assert!(groups.is_empty());
        // Open on screen: seen, not unread, not announced.
        c.open_chat = Some("33612345678@s.whatsapp.net".into());
        let (fresh, _) = ingest(&mut c, vec![msg("2", "33612345678@c.us", "again")]);
        assert_eq!(fresh, None);
        assert_eq!(c.inbox.conversations["33612345678@s.whatsapp.net"].unread, 0, "read on screen");
        assert_eq!(c.inbox.conversations["33612345678@s.whatsapp.net"].messages.len(), 2);
        c.open_chat = None;
        let (fresh, _) = ingest(&mut c, vec![msg("2b", "33612345678@s.whatsapp.net", "and again")]);
        assert_eq!(fresh.as_deref(), Some("Marie"), "the person still names the chat");
        // A muted group without a mention stays quiet, but is asked its name once.
        let (fresh, groups) = ingest(&mut c, vec![msg("3", "120363@g.us", "hi all")]);
        assert_eq!(fresh, None);
        assert_eq!(groups, ["120363@g.us"]);
        let (_, groups) = ingest(&mut c, vec![msg("4", "120363@g.us", "hi again")]);
        assert!(groups.is_empty(), "asked once");
        // The island only sees the visible conversations.
        let view = c.island_view();
        assert_eq!(view.conversations.len(), 1);
        assert_eq!(view.unread, 1);
        // Ignored: never shown again.
        c.prefs.ignored = vec!["33612345678@s.whatsapp.net".into()];
        let (fresh, _) = ingest(&mut c, vec![msg("5", "33612345678@s.whatsapp.net", "x")]);
        assert_eq!(fresh, None);
        assert!(c.island_view().conversations.is_empty());
    }

    #[test]
    fn errors_light_the_pill_on_the_second_failure_only() {
        let mut c = fresh_ctl();
        apply(&mut c, WaError::NotLoggedIn);
        assert_eq!((c.link.clone(), c.failures, c.down), (LinkState::NeedsQr, 0, false));
        apply(&mut c, WaError::Unauthorized);
        assert_eq!((c.failures, c.down), (1, false));
        apply(&mut c, WaError::Refused("NOPE".into()));
        assert_eq!((c.link.clone(), c.failures, c.down), (LinkState::Failed { detail: "NOPE".into() }, 2, true));
    }

    #[test]
    fn mark_read_sends_a_receipt_only_for_something_unread() {
        let mut c = fresh_ctl();
        ingest(&mut c, vec![msg("a", "336@s.whatsapp.net", "1"), msg("b", "336@s.whatsapp.net", "2")]);
        assert_eq!(mark_read(&mut c, "336@s.whatsapp.net"), Some(("336@s.whatsapp.net".into(), Some("b".into()))));
        assert_eq!(c.inbox.conversations["336@s.whatsapp.net"].unread, 0);
        assert_eq!(mark_read(&mut c, "336@s.whatsapp.net"), None, "nothing new: no receipt");
        assert_eq!(mark_read(&mut c, "999@s.whatsapp.net"), None);
    }

    #[test]
    fn the_gateways_secrets_never_reach_a_webview() {
        for key in [URL_KEY, CREDENTIAL_KEY, SECRET_KEY] {
            assert!(crate::secrets::is_internal(key), "{key}");
            assert!(!crate::secrets::KNOWN_KEYS.contains(&key), "{key}");
            assert!(crate::secrets::set(key, "x").is_err(), "{key}: secret_set must refuse it");
            assert!(!crate::secrets::present(key), "{key}");
        }
        assert_eq!(crate::secrets::INTERNAL_KEYS.iter().filter(|k| k.starts_with("whatsapp-")).count(), 3);
    }

    #[test]
    fn ignore_entries() {
        assert_eq!(chat_from_entry("+33 6 12 34 56 78").as_deref(), Some("33612345678@s.whatsapp.net"));
        assert_eq!(chat_from_entry(" 120363@g.us ").as_deref(), Some("120363@g.us"));
        assert_eq!(chat_from_entry("abc"), None);
        assert_eq!(chat_from_entry("a b@g.us"), None);
        assert_eq!(chat_from_entry(""), None);
    }

    #[test]
    fn views_say_codes_never_sentences() {
        let c = fresh_ctl();
        let json = serde_json::to_value(c.island_view()).unwrap();
        assert_eq!(json["link"]["state"], "off");
        let json = serde_json::to_value(c.settings_view()).unwrap();
        assert_eq!(json["webhook"]["state"], "off");
        assert_eq!(json["install"]["step"], "idle");
        assert_eq!(json["defaultUrl"], "http://127.0.0.1:3000");
        assert_eq!(serde_json::to_value(SendError::Refused { detail: "x".into() }).unwrap()["code"], "refused");
        assert_eq!(serde_json::to_value(WebhookState::PortBusy { port: 1 }).unwrap()["state"], "portBusy");
        assert_eq!(serde_json::to_value(LinkState::NeedsQr).unwrap()["state"], "needsQr");
        assert_eq!(serde_json::to_value(TestResult::Connected { who: "+1".into() }).unwrap()["result"], "connected");
    }
}
