// WhatsApp in the island — port of WhatsAppController.swift (Mac 0.5.0/0.5.1,
// experimental). Talks to a local gateway (GOWA, which Coucou can install and
// start, or OpenWA), receives new messages on a webhook bound to 127.0.0.1,
// falls back to polling when no webhook comes, and keeps the conversations in
// memory only: nothing of a message is ever written to disk or to a log, and
// everything is forgotten when Coucou quits or the integration is turned off.
// Runs only while the integration is on and its pill is declared.

pub mod gateway;
pub mod gowa;
pub mod models;
pub mod provider;

use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager};

use gateway::{Kind, Link as GatewayLink};
use models::{check_reply, normalized, Conversation, Filters, Inbox, Message, Outcome, RateLimit, Refusal};
use provider::{Error, Provider};

pub const PILL_ID: &str = "integration_whatsapp";
const WEBHOOK_PATH: &str = "/whatsapp";
pub const DEFAULT_PORT: u16 = 47823;
const URL_KEY: &str = "whatsapp-url";
const CREDENTIAL_KEY: &str = "whatsapp-api-key";
const SECRET_KEY: &str = "whatsapp-webhook-secret";
const EVENT: &str = "whatsapp";

// ── Preferences ───────────────────────────────────────────────────────────────

/// WhatsApp's choices (Settings → Integrations → WhatsApp). The gateway's address
/// and credential live in the credential store; only harmless choices are here.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Prefs {
    pub enabled: bool,
    pub gateway: Kind,
    pub port: u16,
    /// Read receipts when a conversation is opened (on), or only when replying.
    pub mark_read_on_open: bool,
    /// Quiet while Windows' Do not disturb / Focus is on.
    pub respect_focus: bool,
    pub mute_groups: bool,
    pub ignored: Vec<String>,
    /// Coucou starts the GOWA it installed (Install WhatsApp turns this on).
    pub autostart: bool,
    /// GOWA's version, once installed by Coucou.
    pub installed_version: Option<String>,
}

impl Default for Prefs {
    fn default() -> Self {
        Prefs {
            enabled: false,
            gateway: Kind::Gowa,
            port: DEFAULT_PORT,
            mark_read_on_open: true,
            respect_focus: true,
            mute_groups: true,
            ignored: Vec::new(),
            autostart: false,
            installed_version: None,
        }
    }
}

fn prefs_path() -> PathBuf {
    crate::platform::config_dir().join("whatsapp.json")
}

pub fn load_prefs() -> Prefs {
    std::fs::read(prefs_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_prefs(p: &Prefs) {
    if let Ok(json) = serde_json::to_vec_pretty(p) {
        let _ = std::fs::write(prefs_path(), json);
    }
}

fn url_of(p: &Prefs) -> String {
    crate::secrets::get(URL_KEY).unwrap_or_else(|| p.gateway.default_url().to_string())
}

/// The webhook's signing secret, made once (random, 64 hex characters).
fn webhook_secret() -> String {
    if let Some(s) = crate::secrets::get_internal(SECRET_KEY).filter(|s| s.len() >= 16) {
        return s;
    }
    let mut bytes = [0u8; 32];
    let _ = ring::rand::SecureRandom::fill(&ring::rand::SystemRandom::new(), &mut bytes);
    let s = models::hex(&bytes);
    let _ = crate::secrets::set_internal(SECRET_KEY, &s);
    s
}

fn filters(p: &Prefs) -> Filters {
    Filters { mute_groups: p.mute_groups, ignored: p.ignored.iter().cloned().collect::<HashSet<_>>() }
}

fn now() -> f64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs_f64()).unwrap_or(0.0)
}

// ── The state the windows see ─────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state", content = "detail")]
pub enum Link {
    Off,
    Connecting,
    NeedsQr,
    Connected,
    Unreachable,
    Unauthorized,
    Failed(String),
}

#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase", tag = "state", content = "detail")]
pub enum Webhook {
    Off,
    Listening,
    Registered,
    Refused(String),
    PortBusy,
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Snapshot {
    pub prefs: Prefs,
    pub url: String,
    pub has_credential: bool,
    pub link: Link,
    pub webhook: Webhook,
    /// The QR to scan, as a data URL.
    pub qr: Option<String>,
    pub me: Option<String>,
    pub conversations: Vec<Conversation>,
    pub unread: u32,
    pub sending: bool,
    pub send_error: Option<String>,
    /// The gateway down twice in a row: the pill's small red dot.
    pub down: bool,
    pub install: gowa::Step,
    pub installed: bool,
    /// Windows' Do not disturb can be read.
    pub focus_readable: bool,
}

struct Inner {
    prefs: Prefs,
    provider: Option<Arc<Provider>>,
    listener: Option<gowa::Listener>,
    inbox: Inbox,
    link: Link,
    webhook: Webhook,
    qr: Option<Vec<u8>>,
    qr_expiry: Instant,
    me: Option<String>,
    sending: bool,
    send_error: Option<String>,
    open_chat: Option<String>,
    rate: RateLimit,
    failures: u32,
    backfilled: bool,
    last_webhook: Option<Instant>,
    last_poll: f64,
    last_announce: Option<Instant>,
    naming: HashSet<String>,
    install: gowa::Step,
    tick: u64,
}

pub struct WhatsApp {
    inner: Mutex<Inner>,
    /// Bumped at each start and stop: an answer from before a restart is dropped.
    generation: AtomicU64,
    busy: AtomicBool,
}

static STATE: std::sync::OnceLock<Arc<WhatsApp>> = std::sync::OnceLock::new();

fn get() -> &'static Arc<WhatsApp> {
    STATE.get_or_init(|| {
        Arc::new(WhatsApp {
            inner: Mutex::new(Inner {
                prefs: load_prefs(),
                provider: None,
                listener: None,
                inbox: Inbox::default(),
                link: Link::Off,
                webhook: Webhook::Off,
                qr: None,
                qr_expiry: Instant::now(),
                me: None,
                sending: false,
                send_error: None,
                open_chat: None,
                rate: RateLimit::new(6, 60.0),
                failures: 0,
                backfilled: false,
                last_webhook: None,
                last_poll: now(),
                last_announce: None,
                naming: HashSet::new(),
                install: gowa::Step::Idle,
                tick: 0,
            }),
            generation: AtomicU64::new(0),
            busy: AtomicBool::new(false),
        })
    })
}

fn snapshot() -> Snapshot {
    let wa = get();
    let i = wa.inner.lock().unwrap();
    let f = filters(&i.prefs);
    let conversations: Vec<Conversation> = i
        .inbox
        .visible(&f)
        .into_iter()
        .cloned()
        .map(|mut c| {
            let keep = c.messages.len().saturating_sub(10);
            c.messages.drain(..keep);
            c
        })
        .collect();
    Snapshot {
        url: url_of(&i.prefs),
        has_credential: crate::secrets::present(CREDENTIAL_KEY),
        prefs: i.prefs.clone(),
        link: i.link.clone(),
        webhook: i.webhook.clone(),
        qr: i.qr.as_ref().map(|png| format!("data:image/png;base64,{}", crate::claude::base64_for(png))),
        me: i.me.clone(),
        unread: i.inbox.visible_unread(&f),
        conversations,
        sending: i.sending,
        send_error: i.send_error.clone(),
        down: i.failures >= 2,
        install: i.install.clone(),
        installed: gowa::binary().is_file(),
        focus_readable: cfg!(windows),
    }
}

fn publish(app: &AppHandle) {
    let _ = app.emit(EVENT, snapshot());
}

/// Whether the pill is declared (Settings → Active pills).
fn pill_active(app: &AppHandle) -> bool {
    app.try_state::<crate::Shared>()
        .is_some_and(|s| s.settings.lock().unwrap().active_integrations.iter().any(|id| id == PILL_ID))
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

/// Called once at launch: a tick every 5 s follows the settings and the gateway.
pub fn start(app: &AppHandle) {
    let app = app.clone();
    std::thread::Builder::new()
        .name("coucou-whatsapp".into())
        .spawn(move || loop {
            update(&app);
            on_tick(&app);
            std::thread::sleep(Duration::from_secs(5));
        })
        .ok();
}

/// Coucou quits: GOWA goes with it, the conversations are forgotten.
pub fn shutdown() {
    gowa::stop();
}

fn should_run(app: &AppHandle) -> bool {
    get().inner.lock().unwrap().prefs.enabled && pill_active(app)
}

/// Starts or stops talking to the gateway to follow the settings.
fn update(app: &AppHandle) {
    let run = should_run(app);
    let running = get().inner.lock().unwrap().provider.is_some();
    if run && !running {
        begin(app);
    } else if !run && running {
        stop(app, true);
    }
}

fn begin(app: &AppHandle) {
    let wa = get();
    let (prefs, url) = {
        let i = wa.inner.lock().unwrap();
        (i.prefs.clone(), url_of(&i.prefs))
    };
    let credential = crate::secrets::get(CREDENTIAL_KEY);
    let Some(provider) = Provider::new(prefs.gateway, &url, credential.as_deref()) else {
        wa.inner.lock().unwrap().link = Link::Failed(crate::i18n::t("The gateway URL isn’t valid (http://…)"));
        publish(app);
        return;
    };
    wa.generation.fetch_add(1, Ordering::SeqCst);
    // GOWA started by Coucou when asked to, before the first check.
    sync_gowa(&prefs, &url, credential.as_deref().unwrap_or(""));
    let secret = webhook_secret();
    let kind = prefs.gateway;
    let handler_app = app.clone();
    let listener = gowa::Listener::start(prefs.port, move |r| {
        if r.method != "POST" || !r.path.starts_with(WEBHOOK_PATH) {
            return 404;
        }
        // Signed by the gateway with Coucou's secret, over the exact bytes received.
        if !gateway::verify(kind, &r.headers, &r.body, &secret) {
            return 401;
        }
        received(&handler_app, kind, &r.body);
        200
    });
    {
        let mut i = wa.inner.lock().unwrap();
        i.provider = Some(Arc::new(provider));
        i.link = Link::Connecting;
        match listener {
            Ok(l) => {
                i.listener = Some(l);
                i.webhook = Webhook::Listening;
            }
            Err(_) => i.webhook = Webhook::PortBusy,
        }
    }
    publish(app);
    refresh(app);
}

/// GOWA installed by Coucou: started (or restarted when its settings changed).
fn sync_gowa(prefs: &Prefs, url: &str, credential: &str) {
    if !prefs.autostart || prefs.gateway != Kind::Gowa {
        gowa::stop();
        return;
    }
    let Ok(parsed) = reqwest::Url::parse(url) else { return };
    // Only ever on this computer: an address elsewhere is someone else's gateway.
    if !matches!(parsed.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")) {
        gowa::stop();
        return;
    }
    gowa::sync(parsed.port().unwrap_or(3000), credential);
}

/// Stops talking to the gateway. `forget`: the conversations go too.
fn stop(app: &AppHandle, forget: bool) {
    let wa = get();
    wa.generation.fetch_add(1, Ordering::SeqCst);
    let enabled = {
        let mut i = wa.inner.lock().unwrap();
        i.provider = None;
        i.listener = None;
        i.link = Link::Off;
        i.webhook = Webhook::Off;
        i.qr = None;
        i.me = None;
        i.backfilled = false;
        i.last_webhook = None;
        i.naming.clear();
        i.failures = 0;
        if forget {
            i.open_chat = None;
            i.inbox.clear();
        }
        i.prefs.enabled
    };
    if !enabled || !pill_active(app) {
        gowa::stop();
    }
    publish(app);
}

fn on_tick(app: &AppHandle) {
    let (link, failures, tick, running) = {
        let mut i = get().inner.lock().unwrap();
        i.tick += 1;
        (i.link.clone(), i.failures, i.tick, i.provider.is_some())
    };
    if !running {
        return;
    }
    if link != Link::Connected {
        // Every 5 s while linking; every 30 s once the gateway has been down a minute.
        if failures > 12 && tick % 6 != 0 {
            return;
        }
        refresh(app);
    } else {
        if tick % 12 == 0 {
            refresh(app); // every minute: still linked?
        }
        if tick % 4 == 0 {
            poll(app); // every 20 s, unless the webhook delivers
        }
    }
}

// ── Status and QR ─────────────────────────────────────────────────────────────

fn current_provider() -> Option<(Arc<Provider>, u64)> {
    let wa = get();
    let p = wa.inner.lock().unwrap().provider.clone()?;
    Some((p, wa.generation.load(Ordering::SeqCst)))
}

fn still(gen: u64) -> bool {
    get().generation.load(Ordering::SeqCst) == gen
}

pub fn refresh(app: &AppHandle) {
    let wa = get();
    let Some((provider, gen)) = current_provider() else { return };
    if wa.busy.swap(true, Ordering::SeqCst) {
        return;
    }
    let result = tauri::async_runtime::block_on(provider.status());
    match result {
        Ok(status) => {
            if !still(gen) {
                wa.busy.store(false, Ordering::SeqCst);
                return;
            }
            let (register, backfill, ask_qr) = {
                let mut i = wa.inner.lock().unwrap();
                i.failures = 0;
                i.me = status.me.clone();
                match status.link {
                    GatewayLink::Connected => {
                        if i.link != Link::Connected {
                            i.qr = None;
                        }
                        i.link = Link::Connected;
                        (i.webhook == Webhook::Listening, !i.backfilled, false)
                    }
                    GatewayLink::NeedsQr => {
                        i.link = Link::NeedsQr;
                        let ask = i.qr.is_none() || Instant::now() > i.qr_expiry;
                        if ask {
                            // Not asked again for 15 s even when nothing came: each GOWA
                            // login call restarts the pairing.
                            i.qr_expiry = Instant::now() + Duration::from_secs(15);
                        }
                        (false, false, ask)
                    }
                    GatewayLink::Connecting => {
                        i.link = Link::Connecting;
                        (false, false, false)
                    }
                }
            };
            if ask_qr {
                if let Ok(Some((png, seconds))) = tauri::async_runtime::block_on(provider.qr_code()) {
                    if still(gen) {
                        let mut i = wa.inner.lock().unwrap();
                        i.qr = Some(png);
                        i.qr_expiry = Instant::now() + Duration::from_secs(seconds);
                    }
                }
            }
            if register {
                register_webhook(&provider, gen);
            }
            if backfill && still(gen) {
                backfill_history(app, &provider, gen);
            }
        }
        Err(err) => {
            if still(gen) {
                apply(&err);
            }
        }
    }
    wa.busy.store(false, Ordering::SeqCst);
    publish(app);
}

fn apply(err: &Error) {
    let wa = get();
    let (unreachable, autostart) = {
        let mut i = wa.inner.lock().unwrap();
        i.link = match err {
            Error::Unreachable => Link::Unreachable,
            Error::Unauthorized => Link::Unauthorized,
            Error::NotLoggedIn => Link::NeedsQr,
            Error::Refused(why) => Link::Failed(why.clone()),
        };
        if *err != Error::NotLoggedIn {
            i.failures += 1;
        }
        (*err == Error::Unreachable, i.prefs.autostart)
    };
    // GOWA started by Coucou and gone (crash, killed): started again, once a minute at most.
    if unreachable && autostart {
        let prefs = wa.inner.lock().unwrap().prefs.clone();
        sync_gowa(&prefs, &url_of(&prefs), &crate::secrets::get(CREDENTIAL_KEY).unwrap_or_default());
    }
}

// ── Webhook ───────────────────────────────────────────────────────────────────

fn webhook_url(port: u16) -> String {
    format!("http://127.0.0.1:{port}{WEBHOOK_PATH}")
}

fn register_webhook(provider: &Provider, gen: u64) {
    let port = get().inner.lock().unwrap().prefs.port;
    match tauri::async_runtime::block_on(provider.register_webhook(&webhook_url(port), &webhook_secret())) {
        Ok(()) => {
            if still(gen) {
                get().inner.lock().unwrap().webhook = Webhook::Registered;
            }
        }
        Err(Error::Refused(why)) => {
            if still(gen) {
                crate::log::line(format!("whatsapp: the gateway refused the webhook: {why}"));
                get().inner.lock().unwrap().webhook = Webhook::Refused(why);
            }
        }
        // Tried again on the next minute's check.
        Err(_) => {}
    }
}

fn received(app: &AppHandle, kind: Kind, body: &[u8]) {
    let me = {
        let mut i = get().inner.lock().unwrap();
        if i.provider.is_none() {
            return;
        }
        i.last_webhook = Some(Instant::now());
        if i.webhook != Webhook::Registered {
            i.webhook = Webhook::Registered;
        }
        i.me.clone()
    };
    if let Some(gateway::Event::Message(m)) = gateway::parse_webhook(kind, body, me.as_deref()) {
        ingest(app, vec![*m], true);
    }
    publish(app);
}

// ── Messages ──────────────────────────────────────────────────────────────────

/// The last hours of history, once linked: kept, but nothing counts as new.
fn backfill_history(app: &AppHandle, provider: &Provider, gen: u64) {
    let me = {
        let mut i = get().inner.lock().unwrap();
        i.backfilled = true;
        i.me.clone()
    };
    let since = now() - 12.0 * 3600.0;
    let Ok(messages) = tauri::async_runtime::block_on(provider.recent_messages(since, me.as_deref())) else { return };
    if !still(gen) {
        return;
    }
    let chats: Vec<String> = {
        let mut i = get().inner.lock().unwrap();
        let f = filters(&i.prefs);
        let chats = messages.iter().map(|m| normalized(&m.chat)).collect();
        for m in messages {
            i.inbox.add(m, &f, None, true);
        }
        i.last_poll = now();
        chats
    };
    for chat in chats {
        name_group(app, provider, &chat, gen);
    }
}

fn poll(app: &AppHandle) {
    let Some((provider, gen)) = current_provider() else { return };
    let (since, me) = {
        let i = get().inner.lock().unwrap();
        let alive = i.last_webhook.is_some_and(|t| t.elapsed() < Duration::from_secs(300));
        if alive || !i.backfilled {
            return;
        }
        (i.last_poll - 30.0, i.me.clone())
    };
    let started = now();
    let Ok(messages) = tauri::async_runtime::block_on(provider.recent_messages(since, me.as_deref())) else { return };
    if !still(gen) {
        return;
    }
    get().inner.lock().unwrap().last_poll = started;
    ingest(app, messages, true);
    publish(app);
}

fn ingest(app: &AppHandle, messages: Vec<Message>, announce: bool) {
    let mut fresh: Option<String> = None;
    let mut chats = Vec::new();
    {
        let mut i = get().inner.lock().unwrap();
        let f = filters(&i.prefs);
        for m in messages {
            let key = normalized(&m.chat);
            let from_me = m.from_me;
            let outcome = i.inbox.add(m, &f, None, false);
            chats.push(key.clone());
            if i.open_chat.as_deref() == Some(key.as_str()) {
                // Read on screen: no unread, no Mochi.
                i.inbox.mark_read(&key);
                continue;
            }
            if outcome == Outcome::Notify && !from_me {
                fresh = Some(key);
            }
        }
    }
    if let Some((provider, gen)) = current_provider() {
        for chat in chats {
            name_group(app, &provider, &chat, gen);
        }
    }
    if announce {
        if let Some(chat) = fresh {
            announce_message(app, &chat);
        }
    }
}

/// Groups arrive under their id (GOWA's webhook carries no group name): asked once.
fn name_group(app: &AppHandle, provider: &Provider, chat: &str, gen: u64) {
    {
        let mut i = get().inner.lock().unwrap();
        let Some(c) = i.inbox.conversations.get(chat) else { return };
        if !models::is_group(chat) || c.name != models::display_number(chat) || i.naming.contains(chat) {
            return;
        }
        i.naming.insert(chat.to_string());
    }
    if let Some(name) = tauri::async_runtime::block_on(provider.group_name(chat)) {
        if still(gen) {
            get().inner.lock().unwrap().inbox.rename(chat, &name);
            publish(app);
        }
    }
}

/// A new message reaches you: the island's pill lights up and Mochi reacts (the
/// page plays it). Only the conversation's name, never the text. Silent while
/// Windows' Do not disturb is on, when Settings says so.
fn announce_message(app: &AppHandle, chat: &str) {
    let (name, burst) = {
        let mut i = get().inner.lock().unwrap();
        if i.prefs.respect_focus && focus_is_on() {
            return;
        }
        let name = i.inbox.conversations.get(chat).map(|c| c.name.clone()).unwrap_or_else(|| models::display_number(chat));
        // A burst of messages is one reaction, not ten.
        let burst = i.last_announce.is_some_and(|t| t.elapsed() < Duration::from_secs(4));
        if !burst {
            i.last_announce = Some(Instant::now());
        }
        (name, burst)
    };
    #[derive(Serialize, Clone)]
    struct Announce {
        name: String,
        /// The conversation, for the island to open it.
        chat: String,
        react: bool,
    }
    let _ = app.emit_to(
        crate::island::WINDOW_LABEL,
        "whatsapp-announce",
        Announce { name, chat: chat.to_string(), react: !burst },
    );
}

/// Windows' Do not disturb, presentation mode or a full-screen app.
#[cfg(windows)]
fn focus_is_on() -> bool {
    use windows::Win32::UI::Shell::{SHQueryUserNotificationState, QUNS_ACCEPTS_NOTIFICATIONS};
    match unsafe { SHQueryUserNotificationState() } {
        Ok(state) => state != QUNS_ACCEPTS_NOTIFICATIONS,
        Err(_) => false,
    }
}

#[cfg(not(windows))]
fn focus_is_on() -> bool {
    false
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// The card's ↗: WhatsApp's own app when it is installed (it registers the
/// whatsapp: link), WhatsApp Web otherwise. The Mac opens its WhatsApp app.
#[tauri::command]
pub fn whatsapp_open_app() {
    if app_installed() {
        crate::platform::open_url("whatsapp:");
    } else {
        crate::platform::open_url("https://web.whatsapp.com");
    }
}

#[cfg(windows)]
fn app_installed() -> bool {
    use windows::core::w;
    use windows::Win32::System::Registry::{RegCloseKey, RegOpenKeyExW, HKEY, HKEY_CLASSES_ROOT, KEY_READ};
    let mut key = HKEY::default();
    let found = unsafe { RegOpenKeyExW(HKEY_CLASSES_ROOT, w!("whatsapp"), Some(0), KEY_READ, &mut key) }.is_ok();
    if found {
        let _ = unsafe { RegCloseKey(key) };
    }
    found
}

#[cfg(not(windows))]
fn app_installed() -> bool {
    false
}

#[tauri::command]
pub fn whatsapp_state() -> Snapshot {
    snapshot()
}

/// Settings saved: the choices here, the address and credential in the credential
/// store (`None` leaves them as they are, "" clears them). Starts over.
#[tauri::command]
pub fn whatsapp_set_prefs(app: AppHandle, prefs: Prefs, url: Option<String>, credential: Option<String>) {
    let port_ok = (1024..=65535).contains(&prefs.port);
    let mut prefs = prefs;
    if !port_ok {
        prefs.port = DEFAULT_PORT;
    }
    if let Some(url) = url {
        let url = url.trim();
        let default = prefs.gateway.default_url();
        let _ = crate::secrets::set(URL_KEY, if url == default { "" } else { url });
    }
    if let Some(credential) = credential {
        let _ = crate::secrets::set(CREDENTIAL_KEY, credential.trim());
    }
    {
        let mut i = get().inner.lock().unwrap();
        if !prefs.enabled {
            i.inbox.clear();
        }
        i.prefs = prefs.clone();
    }
    save_prefs(&prefs);
    std::thread::spawn(move || {
        stop(&app, !should_run(&app));
        update(&app);
        publish(&app);
    });
}

/// "Test connection": what the gateway says, in a sentence.
#[tauri::command]
pub async fn whatsapp_test() -> String {
    use crate::i18n::{t, tf};
    let (prefs, running) = {
        let i = get().inner.lock().unwrap();
        (i.prefs.clone(), i.provider.clone())
    };
    let provider = match running {
        Some(p) => p,
        None => match Provider::new(prefs.gateway, &url_of(&prefs), crate::secrets::get(CREDENTIAL_KEY).as_deref()) {
            Some(p) => Arc::new(p),
            None => return t("The gateway URL isn’t valid (http://…)"),
        },
    };
    let mut attempt = 0;
    let status = loop {
        match provider.status().await {
            Err(Error::Unreachable) if gowa::is_running() && attempt < 8 => {
                // GOWA just started by Coucou: a few seconds to come up.
                attempt += 1;
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
            other => break other,
        }
    };
    match status {
        Ok(s) => match s.link {
            GatewayLink::Connected => tf("Connected as {0}.", &[("0", &s.me.map(|m| models::display_number(&m)).unwrap_or_default())]),
            GatewayLink::NeedsQr => t("The gateway answers. Scan the QR code below with your phone."),
            GatewayLink::Connecting => t("The gateway answers and is connecting to WhatsApp…"),
        },
        Err(Error::Unreachable) => t("The gateway doesn’t answer: is it running?"),
        Err(Error::Unauthorized) => t("The gateway refuses the credentials"),
        Err(Error::NotLoggedIn) => t("The gateway answers. Scan the QR code below with your phone."),
        Err(Error::Refused(why)) => why,
    }
}

/// "Install WhatsApp": GOWA downloaded, checked, put in place and started.
#[tauri::command]
pub fn whatsapp_install(app: AppHandle) {
    let wa = get();
    if matches!(
        wa.inner.lock().unwrap().install,
        gowa::Step::Checking | gowa::Step::Downloading { .. } | gowa::Step::Verifying | gowa::Step::Installing
    ) {
        return;
    }
    tauri::async_runtime::spawn(async move {
        let progress_app = app.clone();
        let result = gowa::install(move |step| {
            get().inner.lock().unwrap().install = step;
            publish(&progress_app);
        })
        .await;
        match result {
            Ok(version) => {
                let prefs = {
                    let mut i = get().inner.lock().unwrap();
                    i.prefs.gateway = Kind::Gowa;
                    i.prefs.autostart = true;
                    i.prefs.installed_version = Some(version.clone());
                    i.install = gowa::Step::Done { version };
                    i.prefs.clone()
                };
                // Back to http://127.0.0.1:3000.
                let _ = crate::secrets::set(URL_KEY, "");
                save_prefs(&prefs);
                let app2 = app.clone();
                std::thread::spawn(move || {
                    stop(&app2, false);
                    update(&app2);
                });
            }
            Err(message) => {
                crate::log::line(format!("whatsapp: GOWA install failed: {message}"));
                get().inner.lock().unwrap().install = gowa::Step::Failed { message };
            }
        }
        publish(&app);
    });
}

/// A conversation opened in the card: its latest messages, and the read
/// receipt when Settings says so.
#[tauri::command]
pub fn whatsapp_open(app: AppHandle, chat: String) {
    let key = normalized(&chat);
    let mark = {
        let mut i = get().inner.lock().unwrap();
        i.send_error = None;
        i.open_chat = Some(key.clone());
        i.prefs.mark_read_on_open
    };
    std::thread::spawn(move || {
        if mark {
            mark_read(&key);
        }
        if let Some((provider, gen)) = current_provider() {
            let me = get().inner.lock().unwrap().me.clone();
            if let Ok(history) = tauri::async_runtime::block_on(provider.messages(&key, 10, me.as_deref())) {
                if still(gen) {
                    let mut i = get().inner.lock().unwrap();
                    let f = filters(&i.prefs);
                    for m in history {
                        i.inbox.add(m, &f, None, true);
                    }
                }
            }
        }
        publish(&app);
    });
}

/// The conversation closed (back to the list, Escape, the island folded).
#[tauri::command]
pub fn whatsapp_close(chat: String) {
    let mut i = get().inner.lock().unwrap();
    if i.open_chat.as_deref() == Some(normalized(&chat).as_str()) {
        i.open_chat = None;
    }
}

/// Marks the chat read here and on WhatsApp (up to its newest received message).
fn mark_read(chat: &str) {
    let key = normalized(chat);
    let (had_unread, last) = {
        let mut i = get().inner.lock().unwrap();
        let Some(c) = i.inbox.conversations.get(&key) else { return };
        let had = c.unread > 0;
        let last = c.messages.iter().rev().find(|m| !m.from_me).map(|m| m.id.clone());
        i.inbox.mark_read(&key);
        (had, last)
    };
    // Nothing new: no receipt to send.
    if !had_unread {
        return;
    }
    if let Some((provider, _)) = current_provider() {
        let _ = tauri::async_runtime::block_on(provider.mark_read(&key, last.as_deref()));
    }
}

/// Sends a reply. Only to a conversation already in the inbox, one at a time,
/// a few a minute. True once the gateway took it.
#[tauri::command]
pub async fn whatsapp_send(app: AppHandle, chat: String, text: String) -> bool {
    use crate::i18n::t;
    let key = normalized(&chat);
    let Some((provider, gen)) = current_provider() else { return false };
    {
        let mut i = get().inner.lock().unwrap();
        if i.sending {
            return false;
        }
        if let Some(refusal) = check_reply(&text, &key, &i.inbox) {
            if refusal == Refusal::TooLong {
                i.send_error = Some(t("Too long for one message (4,096 characters at most)."));
            }
            drop(i);
            publish(&app);
            return false;
        }
        if !i.rate.allow(now()) {
            i.send_error = Some(t("A few replies a minute at most: wait a moment."));
            drop(i);
            publish(&app);
            return false;
        }
        i.sending = true;
        i.send_error = None;
    }
    publish(&app);
    let body = text.trim().to_string();
    let result = provider.send(&body, &key).await;
    let ok = {
        let mut i = get().inner.lock().unwrap();
        i.sending = false;
        match result {
            Ok(id) => {
                if still(gen) {
                    let mut mine = Message::new(
                        &id.unwrap_or_else(|| format!("coucou-{}", crate::flow::text::new_id())),
                        &key,
                        i.me.as_deref().unwrap_or(""),
                        "",
                        &body,
                        now(),
                    );
                    mine.from_me = true;
                    mine.chat_name = i.inbox.conversations.get(&key).map(|c| c.name.clone());
                    let f = filters(&i.prefs);
                    i.inbox.add(mine, &f, None, false);
                }
                true
            }
            Err(err) => {
                i.send_error = Some(match err {
                    Error::Unreachable => t("The gateway doesn’t answer: is it running?"),
                    Error::Unauthorized => t("The gateway refuses the credentials"),
                    Error::NotLoggedIn => t("Scan the QR code in Settings"),
                    Error::Refused(why) => why,
                });
                false
            }
        }
    };
    if ok {
        // Replying reads the conversation, whatever the setting.
        let last = get()
            .inner
            .lock()
            .unwrap()
            .inbox
            .conversations
            .get(&key)
            .and_then(|c| c.messages.iter().rev().find(|m| !m.from_me).map(|m| m.id.clone()));
        let _ = provider.mark_read(&key, last.as_deref()).await;
    }
    publish(&app);
    ok
}

#[tauri::command]
pub fn whatsapp_ignore(app: AppHandle, chat: String) {
    let key = normalized(&chat);
    let prefs = {
        let mut i = get().inner.lock().unwrap();
        if !i.prefs.ignored.contains(&key) {
            i.prefs.ignored.push(key.clone());
        }
        i.inbox.remove(&key);
        if i.open_chat.as_deref() == Some(key.as_str()) {
            i.open_chat = None;
        }
        i.prefs.clone()
    };
    save_prefs(&prefs);
    publish(&app);
}

#[tauri::command]
pub fn whatsapp_unignore(app: AppHandle, chat: String) {
    let prefs = {
        let mut i = get().inner.lock().unwrap();
        i.prefs.ignored.retain(|c| *c != chat);
        i.prefs.clone()
    };
    save_prefs(&prefs);
    publish(&app);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_preferences_start_off_and_read_old_files() {
        let p = Prefs::default();
        assert!(!p.enabled && p.mute_groups && p.mark_read_on_open && p.respect_focus && !p.autostart);
        assert_eq!(p.port, 47823);
        let old: Prefs = serde_json::from_str(r#"{"enabled":true,"gateway":"openwa"}"#).unwrap();
        assert!(old.enabled && old.gateway == Kind::Openwa && old.port == DEFAULT_PORT);
        assert_eq!(webhook_url(47823), "http://127.0.0.1:47823/whatsapp");
    }
}
