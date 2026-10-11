// Copyright (c) 2026 Rhytam Biswas. MIT License, like the rest of Coucou; see android/LICENSE for the text.
// The phone link: lets the Android app ("Coucou for Android") see the agents'
// sessions and answer permission requests from the phone.
// Protocol: docs/ANDROID_LINK.md.
//
// Off by default and opt-in (Settings → Phone). While it is on, a TLS server
// listens on the local network; while it is off nothing listens, nothing is
// published and no timer runs. No telemetry: the only traffic is between this
// computer and the phone paired with it.
//
// The island keeps owning the sessions and the pending request. It publishes a
// picture of them (`phone_link_publish`), the hub works out what changed, and a
// phone's decision comes back through `TauriHost`, which answers the waiting
// `coucou-hook` exactly as a click on the island would — but only for the request
// that is still pending (hub.rs). The desktop's own card keeps working all along.

mod admission;
mod chat;
mod chat_backend;
mod discovery;
mod hub;
#[cfg(test)]
mod interop;
mod pairing;
mod relay_client;
mod relay_crypto;
mod server;
#[cfg(test)]
mod tests;

use std::net::{Ipv4Addr, SocketAddr, TcpListener as StdListener};
use std::sync::{Arc, Mutex};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager, State, WebviewWindow};

use crate::{island, log, pipe, recap, secrets, settings, Shared};
use hub::{ApprovalIn, Host, Hub, SessionIn};
use pairing::SecretStore;

/// The port the pairing link offers; another is taken if it is busy.
pub const DEFAULT_PORT: u16 = 47821;

/// The OS keystore (secrets.rs).
struct Keystore;

impl SecretStore for Keystore {
    fn get(&self, key: &str) -> Option<String> {
        secrets::get_internal(key)
    }
    fn set(&self, key: &str, value: &str) -> Result<(), String> {
        secrets::set_internal(key, value)
    }
}

/// A phone's decision, applied as a click on the island would be.
struct TauriHost {
    app: AppHandle,
}

impl Host for TauriHost {
    fn get_diff(&self, sub_id: u64, pill_id: &str, file_id: u64) {
        // The island has the diffs; it answers with phone_link_send_diff. Nothing about the file is logged.
        let _ = self.app.emit_to(island::WINDOW_LABEL, "phone-link-getdiff", serde_json::json!({ "conn": sub_id, "pillId": pill_id, "fileId": file_id }));
    }

    fn answer(&self, request_id: &str, answers: &serde_json::Map<String, serde_json::Value>) {
        log::line(format!("phone link: answered a question id={request_id}")); // never what was picked
        recap::forget_request(&self.app, request_id);
        let map: std::collections::HashMap<String, serde_json::Value> = answers.clone().into_iter().collect();
        pipe::answer_question(&self.app, request_id, &map);
        let _ = self.app.emit_to(island::WINDOW_LABEL, "phone-link-decided", request_id.to_string());
    }

    fn decide(&self, request_id: &str, allow: bool) {
        let word = if allow { "allow" } else { "deny" };
        log::line(format!("phone link: decision id={request_id} {word}"));
        recap::record_decision(&self.app, request_id, word);
        pipe::answer(&self.app, request_id, word);
        // The card on the island closes; it was answered elsewhere.
        let _ = self.app.emit_to(island::WINDOW_LABEL, "phone-link-decided", request_id.to_string());
    }
}

struct Running {
    handle: server::Handle,
    shared: Arc<server::Shared>,
    port: u16,
    identity: pairing::Identity,
}

/// The switches in Settings → Android phone, read when a phone connects.
struct TauriFeatures {
    app: AppHandle,
}

impl server::Features for TauriFeatures {
    fn details(&self) -> bool {
        self.app.state::<Shared>().settings.lock().unwrap().phone_details
    }
    fn answers(&self) -> bool {
        self.app.state::<Shared>().settings.lock().unwrap().phone_answers
    }
    fn diffs(&self) -> bool {
        self.app.state::<Shared>().settings.lock().unwrap().phone_diffs
    }
    fn usage(&self) -> bool {
        self.app.state::<Shared>().settings.lock().unwrap().phone_usage
    }
    fn relay(&self) -> bool {
        self.app.state::<Shared>().settings.lock().unwrap().phone_relay
    }
    fn services(&self) -> Vec<String> {
        // Only ids the link knows, whatever the file held.
        let ticked = self.app.state::<Shared>().settings.lock().unwrap().phone_services.clone();
        hub::SERVICE_IDS.iter().filter(|id| ticked.iter().any(|t| t == *id)).map(|id| id.to_string()).collect()
    }
}

pub struct PhoneLink {
    app: AppHandle,
    hub: Arc<Hub>,
    /// Chat from the phone; offered to phones only while the user's switch is on (chat.rs).
    chat: Arc<chat::ChatLink>,
    store: Arc<dyn SecretStore>,
    /// The announcement on the local network (discovery.rs): exists only while the link runs.
    advertiser: discovery::Advertiser,
    running: Mutex<Option<Running>>,
    error: Mutex<Option<String>>,
    /// The connection to the user's relay (relay_client.rs): exists only while the link runs AND the relay switch is on.
    relay: Mutex<Option<relay_client::Handle>>,
}

impl PhoneLink {
    pub fn new(app: AppHandle) -> Self {
        Self {
            chat: chat::ChatLink::new(Arc::new(chat_backend::AppChat::new(app.clone()))),
            hub: Hub::new(Arc::new(TauriHost { app: app.clone() })),
            app,
            store: Arc::new(Keystore),
            advertiser: discovery::Advertiser::new(Arc::new(discovery::MdnsPublisher::new())),
            running: Mutex::new(None),
            error: Mutex::new(None),
            relay: Mutex::new(None),
        }
    }

    /// (Re)starts the relay connection from the settings and the keystore, or stops it. Never fails the link: a
    /// problem is only a status the user can read in Settings.
    fn sync_relay(&self) {
        if let Some(old) = self.relay.lock().unwrap().take() {
            old.stop();
        }
        let Some(shared) = self.running.lock().unwrap().as_ref().map(|r| r.shared.clone()) else { return };
        let (on, url) = {
            let s = self.app.state::<Shared>();
            let s = s.settings.lock().unwrap();
            (s.phone_relay, s.phone_relay_url.clone())
        };
        if !on {
            return;
        }
        let Ok(target) = relay_client::Target::parse(&url) else {
            log::line("phone link: relay address not valid, not connecting");
            return;
        };
        let Ok(creds) = relay_client::credentials(&*self.store) else {
            log::line("phone link: relay needs an access key, not connecting");
            return;
        };
        let handle = tauri::async_runtime::block_on(async move { relay_client::start(shared, target, creds) });
        log::line("phone link: connecting to the relay");
        *self.relay.lock().unwrap() = Some(handle);
    }

    /// Starts listening. Fails without side effects if the keystore is missing:
    /// nothing is ever kept on disk instead.
    pub fn start(&self) -> Result<(), String> {
        let mut running = self.running.lock().unwrap();
        if running.is_some() {
            return Ok(());
        }
        let result = self.start_inner();
        match result {
            Ok(r) => {
                log::line(format!("phone link: listening on port {}", r.port));
                // So the phone can find this computer again after a Wi-Fi change. The link works without it.
                match self.advertiser.start(&pairing::computer_name(), r.port, &r.identity.fingerprint) {
                    Ok(()) => log::line("phone link: announced on the local network"),
                    Err(e) => log::line(format!("phone link: not announced on the local network: {e}")),
                }
                *running = Some(r);
                *self.error.lock().unwrap() = None;
                drop(running);
                self.sync_relay();
                Ok(())
            }
            Err(e) => {
                log::line(format!("phone link: could not start: {e}"));
                *self.error.lock().unwrap() = Some(e.clone());
                Err(e)
            }
        }
    }

    fn start_inner(&self) -> Result<Running, String> {
        let identity = pairing::load_or_create_identity(&*self.store)
            .map_err(|e| format!("no secure storage for the certificate: {e}"))?;
        let token = pairing::token(&*self.store).map_err(|e| format!("no secure storage for the pairing code: {e}"))?;
        let std_listener = StdListener::bind(SocketAddr::from((Ipv4Addr::UNSPECIFIED, DEFAULT_PORT)))
            .or_else(|_| StdListener::bind(SocketAddr::from((Ipv4Addr::UNSPECIFIED, 0))))
            .map_err(|e| format!("cannot listen: {e}"))?;
        std_listener.set_nonblocking(true).map_err(|e| e.to_string())?;
        let port = std_listener.local_addr().map_err(|e| e.to_string())?.port();
        let acceptor = server::tls_acceptor(&identity)?;
        let shared = server::Shared::with_features(
            self.hub.clone(), token, pairing::computer_name(), Some(self.chat.clone()), Arc::new(TauriFeatures { app: self.app.clone() }),
        );
        let handle = {
            let shared = shared.clone();
            tauri::async_runtime::block_on(async move {
                let listener = tokio::net::TcpListener::from_std(std_listener).map_err(|e| e.to_string())?;
                Ok::<_, String>(server::serve(listener, acceptor, shared))
            })?
        };
        Ok(Running { handle, shared, port, identity })
    }

    pub fn stop(&self) {
        if let Some(relay) = self.relay.lock().unwrap().take() {
            relay.stop();
        }
        self.advertiser.stop();
        if let Some(r) = self.running.lock().unwrap().take() {
            r.handle.stop();
            log::line("phone link: stopped");
        }
    }
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    pub enabled: bool,
    pub running: bool,
    pub port: u16,
    /// This computer's address on the local network, as the phone will be told.
    pub host: String,
    pub name: String,
    pub clients: usize,
    pub error: Option<String>,
    /// The relay connection ("Away from home Wi-Fi"); `off` when it is not switched on.
    pub relay_state: relay_client::State,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Pairing {
    pub link: String,
    pub qr_svg: String,
    pub host: String,
    pub port: u16,
    pub name: String,
    /// The relay's address when the link also carries the relay fields; the phone shows it as the host.
    pub relay: Option<String>,
}

fn status_of(link: &PhoneLink, enabled: bool) -> Status {
    let running = link.running.lock().unwrap();
    Status {
        enabled,
        running: running.is_some(),
        port: running.as_ref().map_or(0, |r| r.port),
        host: pairing::lan_address().map(|ip| ip.to_string()).unwrap_or_default(),
        name: pairing::computer_name(),
        clients: link.hub.clients(),
        error: link.error.lock().unwrap().clone(),
        relay_state: link.relay.lock().unwrap().as_ref().map_or(relay_client::State::Off, |h| h.state()),
    }
}

#[tauri::command]
pub fn phone_link_status(link: State<PhoneLink>, shared: State<Shared>) -> Status {
    let enabled = shared.settings.lock().unwrap().phone_link;
    status_of(&link, enabled)
}

/// Turns the link on or off. Only ever from the switch in Settings → Phone (the calling window is checked).
#[tauri::command]
pub fn phone_link_set_enabled(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
) -> Result<Status, String> {
    // It starts a network server: only the switch in Settings may do it.
    only_settings(&window)?;
    if enabled {
        link.start()?;
    } else {
        link.stop();
    }
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_link = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    let _ = app.emit("settings-changed", updated);
    Ok(status_of(&link, enabled))
}

/// The pairing link and its QR code. Only the settings window may ask: the token
/// is the secret that lets a phone in.
#[tauri::command]
pub fn phone_link_pairing(window: WebviewWindow, link: State<PhoneLink>) -> Result<Pairing, String> {
    only_settings(&window)?;
    let running = link.running.lock().unwrap();
    let r = running.as_ref().ok_or("the phone link is off")?;
    pairing_of(&link, r)
}

fn pairing_of(link: &PhoneLink, r: &Running) -> Result<Pairing, String> {
    let host = pairing::lan_address().map(|ip| ip.to_string()).ok_or("no local network address found")?;
    let name = r.shared.name.clone();
    let token = r.shared.token.lock().unwrap().clone();
    let (on, url) = {
        let s = link.app.state::<Shared>();
        let s = s.settings.lock().unwrap();
        (s.phone_relay, s.phone_relay_url.clone())
    };
    // The relay fields go in only when the switch is on and everything for it is there.
    let relay = if on { relay_client::Target::parse(&url).ok().zip(relay_client::credentials(&*link.store).ok()) } else { None };
    let (link_text, relay_host) = match &relay {
        Some((target, creds)) => {
            let shown = target.display();
            let key = creds.key.to_base64url();
            let fields = pairing::RelayLink { url: &shown, room: &creds.room, key: &key, access: &creds.access };
            (pairing::pairing_link_with_relay(&host, r.port, &r.identity.fingerprint, &token, &name, &fields), Some(target.host.clone()))
        }
        None => (pairing::pairing_link(&host, r.port, &r.identity.fingerprint, &token, &name), None),
    };
    let qr_svg = pairing::qr_svg(&link_text).unwrap_or_default();
    Ok(Pairing { link: link_text, qr_svg, host, port: r.port, name, relay: relay_host })
}

/// Cuts every connected phone off, then makes a new token and a new relay room and key. The phones go first and unconditionally: if a
/// secret cannot be stored (a locked keystore), the user must still see "Pair again" take effect on the connections, and the error is
/// reported afterwards instead of leaving the phones connected.
fn renew_pairing(hub: &Hub, token: &Mutex<String>, store: &dyn SecretStore) -> Result<(), String> {
    hub.kick_all("auth", "unpaired");
    *token.lock().unwrap() = pairing::new_token(store)?;
    // "Pair again" also makes a new room and a new K: a phone that held the old ones can no longer reach this computer
    // through the relay, whatever it still remembers.
    relay_client::new_pairing(store)?;
    Ok(())
}

/// A new pairing code: the phone that had the old one is disconnected and must
/// pair again.
#[tauri::command]
pub fn phone_link_new_pairing(window: WebviewWindow, link: State<PhoneLink>) -> Result<Pairing, String> {
    only_settings(&window)?;
    let running = link.running.lock().unwrap();
    let r = running.as_ref().ok_or("the phone link is off")?;
    renew_pairing(&link.hub, &r.shared.token, &*link.store)?;
    log::line("phone link: new pairing code, phones disconnected");
    let result = pairing_of(&link, r);
    drop(running);
    link.sync_relay();
    result
}

// ── Away from home Wi-Fi: the relay (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RelayStatus {
    pub enabled: bool,
    /// The relay's address as entered (not a secret).
    pub url: String,
    /// An access key is stored. The key itself is never sent back to the window.
    pub has_access: bool,
    pub state: relay_client::State,
}

fn relay_status_of(link: &PhoneLink, shared: &Shared) -> RelayStatus {
    let s = shared.settings.lock().unwrap();
    RelayStatus {
        enabled: s.phone_relay,
        url: s.phone_relay_url.clone(),
        has_access: relay_client::access_key(&*link.store).is_some(),
        state: link.relay.lock().unwrap().as_ref().map_or(relay_client::State::Off, |h| h.state()),
    }
}

#[tauri::command]
pub fn phone_relay_status(link: State<PhoneLink>, shared: State<Shared>) -> RelayStatus {
    relay_status_of(&link, &shared)
}

/// The relay switch and its address. Off by default and never on without a valid address and an access key.
/// Turning it on or changing the address reconnects; the phones already paired over the LAN keep working.
#[tauri::command]
pub fn phone_relay_set(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
    url: String,
) -> Result<RelayStatus, String> {
    only_settings(&window)?;
    let url = url.trim().to_string();
    let clean = if url.is_empty() { String::new() } else { relay_client::Target::parse(&url).map_err(String::from)?.display() };
    if enabled {
        if clean.is_empty() {
            return Err("Enter the relay address first".into());
        }
        if relay_client::access_key(&*link.store).is_none() {
            return Err("Enter the relay's access key first".into());
        }
    }
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_relay = enabled;
        current.phone_relay_url = clean;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    link.sync_relay();
    log::line(format!("phone link: relay {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(relay_status_of(&link, &shared))
}

/// The relay's access key, write-only: stored in the OS keystore and never sent back to the window. Empty clears it
/// (and switches the relay off, since it cannot connect without one).
#[tauri::command]
pub fn phone_relay_set_access(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    access: String,
) -> Result<RelayStatus, String> {
    only_settings(&window)?;
    relay_client::set_access_key(&*link.store, &access)?;
    if relay_client::access_key(&*link.store).is_none() {
        let updated = {
            let mut current = shared.settings.lock().unwrap();
            current.phone_relay = false;
            if let Err(err) = settings::save(&current) {
                log::line(format!("could not save settings: {err}"));
            }
            current.clone()
        };
        let _ = app.emit("settings-changed", updated);
    }
    // Phones paired for the relay follow the new key by themselves (LAN or relay); others re-scan.
    if let Some(access) = relay_client::access_key(&*link.store) {
        let told = link.hub.send_relay_access(&access);
        log::line(format!("phone link: relay access key changed, {told} phone(s) told"));
    }
    link.sync_relay();
    Ok(relay_status_of(&link, &shared))
}

// ── Session details for the phone: the switch (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DetailsStatus {
    pub enabled: bool,
}

#[tauri::command]
pub fn phone_details_status(shared: State<Shared>) -> DetailsStatus {
    DetailsStatus { enabled: shared.settings.lock().unwrap().phone_details }
}

/// "Show session details on the phone". Off by default. A change disconnects the phones once so they
/// reconnect and are told (or not) about the capability.
#[tauri::command]
pub fn phone_details_set_enabled(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
) -> Result<DetailsStatus, String> {
    only_settings(&window)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_details = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    link.hub.kick_all("closed", "details setting changed");
    log::line(format!("phone link: details {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(DetailsStatus { enabled })
}

// ── Answering questions from the phone: the switch (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AnswersStatus {
    pub enabled: bool,
}

#[tauri::command]
pub fn phone_answers_status(shared: State<Shared>) -> AnswersStatus {
    AnswersStatus { enabled: shared.settings.lock().unwrap().phone_answers }
}

/// "Let the phone answer Claude Code's questions". Off by default. A change disconnects the phones once so they
/// reconnect and are told (or not) about the capability. The phone confirms every answer with its screen lock.
#[tauri::command]
pub fn phone_answers_set_enabled(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
) -> Result<AnswersStatus, String> {
    only_settings(&window)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_answers = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    link.hub.kick_all("closed", "answers setting changed");
    log::line(format!("phone link: answering questions {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(AnswersStatus { enabled })
}

// ── File changes on the phone: the switch (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DiffsStatus {
    pub enabled: bool,
}

#[tauri::command]
pub fn phone_diffs_status(shared: State<Shared>) -> DiffsStatus {
    DiffsStatus { enabled: shared.settings.lock().unwrap().phone_diffs }
}

/// "Show the files an agent changed on the phone". Off by default. A change disconnects the phones once so they
/// reconnect and are told (or not) about the capability.
#[tauri::command]
pub fn phone_diffs_set_enabled(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
) -> Result<DiffsStatus, String> {
    only_settings(&window)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_diffs = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    link.hub.kick_all("closed", "diffs setting changed");
    log::line(format!("phone link: file changes on the phone {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(DiffsStatus { enabled })
}

// ── Plan usage on the phone: the switch (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct UsageStatus {
    pub enabled: bool,
}

#[tauri::command]
pub fn phone_usage_status(shared: State<Shared>) -> UsageStatus {
    UsageStatus { enabled: shared.settings.lock().unwrap().phone_usage }
}

/// "Show my Claude and Codex plan usage on the phone". Off by default. A change disconnects the phones once so they
/// reconnect and are told (or not) about the capability.
#[tauri::command]
pub fn phone_usage_set_enabled(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
) -> Result<UsageStatus, String> {
    only_settings(&window)?;
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_usage = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    link.hub.kick_all("closed", "usage setting changed");
    log::line(format!("phone link: plan usage on the phone {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(UsageStatus { enabled })
}

// ── Service cards on the phone: one tick per service (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ServicesStatus {
    /// The services allowed for the phone.
    pub services: Vec<String>,
}

#[tauri::command]
pub fn phone_services_status(shared: State<Shared>) -> ServicesStatus {
    let ticked = shared.settings.lock().unwrap().phone_services.clone();
    ServicesStatus { services: hub::SERVICE_IDS.iter().filter(|id| ticked.iter().any(|t| t == *id)).map(|id| id.to_string()).collect() }
}

/// "Show these services on the phone". None by default, read-only. A change disconnects the phones once so they
/// reconnect and are told (or not) about the capability.
#[tauri::command]
pub fn phone_services_set(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    services: Vec<String>,
) -> Result<ServicesStatus, String> {
    only_settings(&window)?;
    let allowed: Vec<String> = hub::SERVICE_IDS.iter().filter(|id| services.iter().any(|s| s == *id)).map(|id| id.to_string()).collect();
    let updated = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_services = allowed.clone();
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        current.clone()
    };
    link.hub.kick_all("closed", "services setting changed");
    log::line(format!("phone link: {} service(s) on the phone", allowed.len()));
    let _ = app.emit("settings-changed", updated);
    Ok(ServicesStatus { services: allowed })
}

/// What the island's service pills show, for phones whose user allowed those services.
#[tauri::command]
pub fn phone_link_publish_services(window: WebviewWindow, link: State<PhoneLink>, services: Vec<hub::ServiceIn>) -> Result<(), String> {
    only_island(&window)?;
    if link.running.lock().unwrap().is_none() {
        return Ok(());
    }
    link.hub.publish_services(services);
    Ok(())
}

/// The plan usage the island shows, for phones that have `usage`.
#[tauri::command]
pub fn phone_link_publish_usage(window: WebviewWindow, link: State<PhoneLink>, usage: hub::UsageIn) -> Result<(), String> {
    only_island(&window)?;
    if link.running.lock().unwrap().is_none() {
        return Ok(());
    }
    link.hub.publish_usage(usage);
    Ok(())
}

/// The island's answer to a phone's request for a file's diff (event "phone-link-getdiff").
#[tauri::command]
pub fn phone_link_send_diff(window: WebviewWindow, link: State<PhoneLink>, conn: u64, diff: hub::DiffIn) -> Result<(), String> {
    only_island(&window)?;
    if link.running.lock().unwrap().is_none() {
        return Ok(());
    }
    link.hub.send_diff(conn, diff);
    Ok(())
}

// ── Chat from the phone: the switch and the list of models (Settings → Android phone) ──

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatStatus {
    pub enabled: bool,
    /// Allowed models as "provider/model".
    pub models: Vec<String>,
}

/// The window a command that changes something may be called from. Every such command checks it, and `tests.rs` reads this file to
/// prove that none was added without a check.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Caller {
    Settings,
    Island,
}

fn caller_allowed(label: &str, who: Caller) -> bool {
    match who {
        Caller::Settings => label == "settings",
        Caller::Island => label == island::WINDOW_LABEL,
    }
}

fn only_settings(window: &WebviewWindow) -> Result<(), String> {
    if caller_allowed(window.label(), Caller::Settings) {
        Ok(())
    } else {
        Err("only the settings window may change what the phone can use".into())
    }
}

/// The island is the one window that knows the sessions and the pending request; what it publishes goes to phones, so no other
/// window may publish.
fn only_island(window: &WebviewWindow) -> Result<(), String> {
    if caller_allowed(window.label(), Caller::Island) {
        Ok(())
    } else {
        Err("only the island may publish to the phone".into())
    }
}

#[tauri::command]
pub fn phone_chat_status(shared: State<Shared>) -> ChatStatus {
    let s = shared.settings.lock().unwrap();
    ChatStatus { enabled: s.phone_chat, models: chat_backend::clean_models(&s.phone_chat_models) }
}

/// The switch "Let the phone chat with my AI providers". Off by default. A change disconnects the
/// phones so they reconnect and are told (or not) about the capability; turning it off also stops a
/// running answer and forgets the phone's conversation.
#[tauri::command]
pub fn phone_chat_set_enabled(
    app: AppHandle,
    window: WebviewWindow,
    link: State<PhoneLink>,
    shared: State<Shared>,
    enabled: bool,
) -> Result<ChatStatus, String> {
    only_settings(&window)?;
    let (updated, status) = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_chat = enabled;
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        let status = ChatStatus { enabled, models: chat_backend::clean_models(&current.phone_chat_models) };
        (current.clone(), status)
    };
    if !enabled {
        link.chat.shutdown();
    }
    link.hub.kick_all("closed", "chat setting changed");
    log::line(format!("phone link: chat {}", if enabled { "on" } else { "off" }));
    let _ = app.emit("settings-changed", updated);
    Ok(status)
}

/// Which models the phone may use. Anything that is not a known provider's model is dropped.
#[tauri::command]
pub fn phone_chat_set_models(
    app: AppHandle,
    window: WebviewWindow,
    shared: State<Shared>,
    models: Vec<String>,
) -> Result<ChatStatus, String> {
    only_settings(&window)?;
    let cleaned = chat_backend::clean_models(&models);
    let (updated, status) = {
        let mut current = shared.settings.lock().unwrap();
        current.phone_chat_models = cleaned.clone();
        if let Err(err) = settings::save(&current) {
            log::line(format!("could not save settings: {err}"));
        }
        (current.clone(), ChatStatus { enabled: current.phone_chat, models: cleaned })
    };
    let _ = app.emit("settings-changed", updated);
    Ok(status)
}

/// The question Claude Code is waiting on (None: none), for phones that may answer it.
#[tauri::command]
pub fn phone_link_publish_question(window: WebviewWindow, link: State<PhoneLink>, question: Option<hub::QuestionIn>) -> Result<(), String> {
    only_island(&window)?;
    if link.running.lock().unwrap().is_none() {
        return Ok(());
    }
    link.hub.publish_question(question, server::now_ms());
    Ok(())
}

/// What Mochi wears on the computer, for phones that asked for `prefs`.
#[tauri::command]
pub fn phone_link_publish_prefs(window: WebviewWindow, link: State<PhoneLink>, outfit: String) -> Result<(), String> {
    only_island(&window)?;
    if link.running.lock().unwrap().is_none() {
        return Ok(());
    }
    link.hub.publish_outfit(&outfit);
    Ok(())
}

/// The island's picture of its sessions and of the request waiting for an answer.
#[tauri::command]
pub fn phone_link_publish(window: WebviewWindow, link: State<PhoneLink>, sessions: Vec<SessionIn>, approval: Option<ApprovalIn>) -> Result<(), String> {
    only_island(&window)?;
    if link.running.lock().unwrap().is_none() {
        return Ok(());
    }
    link.hub.publish(sessions, approval, server::now_ms());
    Ok(())
}

/// The app is quitting: withdraw the announcement so phones forget this computer at once.
pub fn stop_on_exit(app: &AppHandle) {
    if let Some(link) = app.try_state::<PhoneLink>() {
        link.stop();
    }
}

/// Called once at launch: the link comes back if the user had turned it on.
pub fn start_if_enabled(app: &AppHandle) {
    let enabled = app.state::<Shared>().settings.lock().unwrap().phone_link;
    if enabled {
        let link = app.state::<PhoneLink>();
        // A failure is kept in the status and the log; the setting stays on so
        // the user sees why in Settings instead of finding it silently off.
        let _ = link.start();
    }
}
