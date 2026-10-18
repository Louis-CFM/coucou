// Android companion: the PC owns a "box" on a relay worker the user deployed
// themselves (see relay/), the phone claims it with a QR code or a pasted
// string, and from then on the island pushes its state up and the phone's
// clicks come back down the same mailbox.
//
//   PC     POST /v1/phone/pair     once, when Pair is clicked
//   PC     POST /v1/phone/claimed  while a pairing code is on screen
//   PC     POST /v1/phone/state    on every island change (alert = a card is up)
//   PC     POST /v1/phone/take     drains decisions and chat lines, every 3 s
//                                  while something is going on, else every 10 s
//   PC     POST /v1/phone/unpair   the phone is forgotten, the box wiped
//
// The pc id lives in settings.json; the pairing master lives in the keychain.
// Since mail_crypto.rs the box holds ciphertext only: the relay authenticates
// calls and stores blobs, but cannot read a command, a chat line or a decision
// — nor forge one, which is the point. A pairing cut before encryption existed
// keeps the old plaintext contract until it is re-paired.

use serde_json::{json, Value};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{LazyLock, Mutex};
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};
use tokio::sync::Notify;

use crate::i18n::t;
use crate::island::WINDOW_LABEL;
use crate::mail_crypto;

/// How often the outbox is read while something is going on: a card up, or
/// the phone having just said something.
const POLL: Duration = Duration::from_secs(3);
/// How often it is read while nothing is going on — no card up, the phone
/// quiet for a while. A message typed then waits at most this long.
const POLL_IDLE: Duration = Duration::from_secs(10);
/// After the phone last sent something, it is answered at the quick pace.
const ACTIVE_WINDOW: Duration = Duration::from_secs(120);
/// How long a pairing code on screen is watched for a phone to claim it.
const PAIR_WINDOW: Duration = Duration::from_secs(30 * 60);
const PAIR_WAIT: Duration = Duration::from_secs(3);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
const HTTP: Duration = Duration::from_secs(10);
/// The shortest gap between two state pushes that do not wake the phone.
const PUSH_GAP: Duration = Duration::from_millis(1500);
const WORKER_PATH: &str = "/v1/phone";

/// The credentials a box is created with. `pc_id` identifies it (and is fine
/// in settings.json); `master` is the crypto root the code carries: only its
/// HKDF derivative authenticates calls (the relay sees it), and the mailbox
/// keys derive from it (the relay never sees them). It reaches the keychain
/// only once the relay has created the box, so a pairing that fails leaves the
/// previous one working.
pub struct Pairing {
    pub worker: String,
    pub pc_id: String,
    /// The master secret, `secret` in the pairing code — never sent as-is.
    master: String,
    /// `id|secret|worker` — what the QR encodes and the manual fallback shows.
    pub code: String,
    /// The QR as SVG markup, for the settings window to drop into the page.
    pub qr_svg: String,
}

fn hex(n: usize) -> Option<String> {
    let mut buf = vec![0u8; n];
    getrandom::getrandom(&mut buf).ok()?;
    Some(buf.iter().map(|b| format!("{b:02x}")).collect())
}

fn secret() -> Option<String> {
    crate::secrets::get("phone-secret")
}

/// The relay base URL the user typed — https, or http only to this machine:
/// the pairing secret travels to it on every call.
pub fn check_worker(raw: &str) -> Result<String, String> {
    let url = crate::net::normalise_server_url(raw)?;
    if url.scheme() != "https" && !crate::net::is_loopback_url(&url) {
        return Err(t("The address must start with https:// (plain http only to this computer)."));
    }
    Ok(url.to_string().trim_end_matches('/').to_string())
}

/// A phone taking over the island: the code and its QR. Nothing is stored yet.
pub fn start_pair(worker: &str) -> Result<Pairing, String> {
    let worker = check_worker(worker)?;
    let Some(pc_id) = hex(12) else { return Err("no random source".into()) };
    let Some(master) = hex(32) else { return Err("no random source".into()) };
    let code = format!("{pc_id}|{master}|{worker}");
    let qr_svg = qrcode::QrCode::new(code.as_bytes())
        .map_err(|e| e.to_string())?
        .render::<qrcode::render::svg::Color>()
        .build();
    Ok(Pairing { worker, pc_id, master, code, qr_svg })
}

/// The box this PC is paired with now, if any.
struct BoxRef {
    worker: String,
    id: String,
    secret: String,
}

fn current_box(app: &AppHandle) -> Option<BoxRef> {
    let (worker, id) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        (s.phone_worker.clone(), s.phone_pc_id.clone())
    };
    Some(BoxRef { worker: nonempty(worker)?, id: nonempty(id)?, secret: secret()? })
}

/// Called once the code is on screen: creates the box, and only when the relay
/// has it does the new pairing replace the old one, whose box is then wiped.
pub async fn finish_pair(app: &AppHandle, pair: &Pairing) -> Result<(), String> {
    let bearer = mail_crypto::auth_bearer(&pair.master, &pair.pc_id).ok_or("bad pairing material")?;
    post_async(&pair.worker, "pair", &json!({ "id": pair.pc_id, "secret": bearer })).await?;
    let old = current_box(app);
    crate::secrets::set("phone-secret", &bearer)?;
    crate::secrets::set("phone-key", &pair.master)?;
    *PAIRING_SINCE.lock().unwrap() = Some(Instant::now());
    update_settings(app, |s| {
        s.phone_worker = pair.worker.clone();
        s.phone_pc_id = pair.pc_id.clone();
        s.phone_paired = false;
        s.phone_device.clear();
        s.phone_enabled = true;
    });
    spawn(app.clone());
    // The previous box would otherwise keep the old phone's token and the last state for good.
    if let Some(old) = old.filter(|o| o.id != pair.pc_id) {
        let _ = post_async(&old.worker, "unpair", &json!({ "id": old.id, "secret": old.secret })).await;
    }
    Ok(())
}

pub async fn unpair(app: &AppHandle) {
    if let Some(current) = current_box(app) {
        let _ = post_async(&current.worker, "unpair", &json!({ "id": current.id, "secret": current.secret })).await;
    }
    let _ = crate::secrets::clear("phone-secret");
    let _ = crate::secrets::clear("phone-key");
    update_settings(app, |s| {
        s.phone_paired = false;
        s.phone_device.clear();
        s.phone_pc_id.clear();
    });
}

fn nonempty(s: String) -> Option<String> {
    (!s.is_empty()).then_some(s)
}

/// Changes the phone fields, saves, and tells both webviews: their copies of
/// the settings would otherwise keep the old values and write them back.
fn update_settings(app: &AppHandle, change: impl FnOnce(&mut crate::settings::Settings)) {
    let snapshot = {
        let shared = app.state::<crate::Shared>();
        let mut s = shared.settings.lock().unwrap();
        change(&mut s);
        s.clone()
    };
    if let Err(err) = crate::settings::save(&snapshot) {
        crate::log::line(format!("could not save settings: {err}"));
    }
    let _ = app.emit("settings-changed", snapshot);
    wake();
}

/// Settings → "Control from the phone".
pub fn set_enabled(app: &AppHandle, on: bool) {
    update_settings(app, |s| s.phone_enabled = on);
    if on {
        spawn(app.clone());
    }
}

// ── The poll loop ─────────────────────────────────────────────────────────────

/// Rings when something the loop decides on changed: settings, a card, a pairing.
static WAKE: LazyLock<Notify> = LazyLock::new(Notify::new);
static CARD_UP: AtomicBool = AtomicBool::new(false);
static PHONE_SPOKE: Mutex<Option<Instant>> = Mutex::new(None);
static PAIRING_SINCE: Mutex<Option<Instant>> = Mutex::new(None);

fn wake() {
    WAKE.notify_one();
}

fn since(at: &Mutex<Option<Instant>>) -> Option<Duration> {
    at.lock().unwrap().map(|t| t.elapsed())
}

fn take_interval(card_up: bool, since_phone: Option<Duration>) -> Duration {
    if card_up || since_phone.is_some_and(|d| d < ACTIVE_WINDOW) { POLL } else { POLL_IDLE }
}

fn pairing_open(since_pairing: Option<Duration>) -> bool {
    since_pairing.is_some_and(|d| d < PAIR_WINDOW)
}

/// The poll loop: claim → outbox. Started at launch and after pairing; until a
/// phone is set up it only waits to be woken (no timer, no keychain read), so
/// it is safe to spawn twice — a `RUNNING` flag makes sure only one instance
/// ever actually loops.
static RUNNING: Mutex<bool> = Mutex::new(false);

pub fn spawn(app: AppHandle) {
    {
        let mut running = RUNNING.lock().unwrap();
        if *running {
            return;
        }
        *running = true;
    }
    // A pairing the last run left half-way is watched for a while again.
    {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        if s.phone_enabled && !s.phone_paired && !s.phone_pc_id.is_empty() {
            *PAIRING_SINCE.lock().unwrap() = Some(Instant::now());
        }
    }
    tauri::async_runtime::spawn(async move {
        let mut backoff = POLL;
        loop {
            let (enabled, paired, worker, id) = {
                let shared = app.state::<crate::Shared>();
                let s = shared.settings.lock().unwrap();
                (s.phone_enabled, s.phone_paired, s.phone_worker.clone(), s.phone_pc_id.clone())
            };
            // Nothing to do until the settings change: no timer, no keychain read.
            let ready = enabled && (paired || pairing_open(since(&PAIRING_SINCE)));
            let (true, Some(worker), Some(id)) = (ready, nonempty(worker), nonempty(id)) else {
                WAKE.notified().await;
                continue;
            };
            let Some(sec) = secret() else {
                WAKE.notified().await;
                continue;
            };
            let result = if paired {
                take(&app, &worker, &id, &sec).await
            } else {
                claimed(&app, &worker, &id, &sec).await
            };
            if result.is_err() {
                // The worker or the network is down: keep trying, quietly,
                // widening the gap so a phone-less afternoon is cheap.
                let _ = tokio::time::timeout(backoff, WAKE.notified()).await;
                backoff = (backoff * 2).min(BACKOFF_MAX);
                continue;
            }
            backoff = POLL;
            let wait = if paired {
                take_interval(CARD_UP.load(Ordering::Relaxed), since(&PHONE_SPOKE))
            } else {
                PAIR_WAIT
            };
            let _ = tokio::time::timeout(wait, WAKE.notified()).await;
        }
    });
}

/// Has a phone claimed the box yet? When it does, mark it and tell the
/// settings window so "waiting…" turns into the device name.
async fn claimed(app: &AppHandle, worker: &str, id: &str, sec: &str) -> Result<(), String> {
    let reply = post_async(worker, "claimed", &json!({ "id": id, "secret": sec })).await?;
    if reply.get("paired").and_then(Value::as_bool) == Some(true) {
        let device = reply
            .get("device")
            .and_then(Value::as_str)
            .unwrap_or("Android")
            .to_string();
        *PAIRING_SINCE.lock().unwrap() = None;
        update_settings(app, |s| {
            s.phone_paired = true;
            s.phone_device = device.clone();
        });
        crate::log::line(format!("phone paired: {device}"));
        let _ = app.emit_to("settings", "phone-paired", json!({ "device": device }));
    }
    Ok(())
}

/// The mailbox crypto for this pairing: both directions' ciphers when the
/// keychain holds the master (`phone-key`), None on a legacy pairing whose
/// secret is the bearer itself — that one stays plaintext, as it always was.
struct Mail {
    p2h: mail_crypto::Cipher,
    h2p: mail_crypto::Cipher,
}

fn mail(box_id: &str) -> Option<Mail> {
    let master = crate::secrets::get("phone-key")?;
    let (p2h, h2p) = mail_crypto::ciphers(&master, box_id)?;
    Some(Mail { p2h, h2p })
}

/// The phone's own timestamp must sit inside the ciphertext — the relay's `at`
/// says when it stored the copy, not when the phone wrote it. A blob older
/// than the outbox's own TTL or from the future is a replay, not a message.
const MAX_CLOCK_SKEW_MS: u64 = 5 * 60 * 1000;
const MAX_ITEM_AGE_MS: u64 = 10 * 60 * 1000;

/// Blobs already applied, by ciphertext — a relay replaying a stored item gets
/// nothing the second time. Bounded; the outbox itself is at most 50 items.
static SEEN: LazyLock<Mutex<std::collections::HashSet<String>>> =
    LazyLock::new(|| Mutex::new(std::collections::HashSet::new()));

/// The outbox items as they should reach the island: `enc` items decrypted
/// (forgeries and replays dropped), plaintext kept only on a legacy pairing
/// where encryption was never negotiated.
fn decode_outbox(mail: Option<&Mail>, items: Vec<Value>, now_ms: u64) -> Vec<Value> {
    let mut out = Vec::new();
    for item in items {
        if item.get("type").and_then(Value::as_str) == Some("enc") {
            let Some(mail) = mail else { continue };
            let Some(ct) = item.get("ct").and_then(Value::as_str).map(str::to_string) else { continue };
            if !seen_insert(ct) {
                continue;
            }
            let Some(bytes) = mail.p2h.open(&item) else { continue };
            let Ok(inner) = serde_json::from_slice::<Value>(&bytes) else { continue };
            let Some(at) = inner.get("at").and_then(Value::as_u64) else { continue };
            if now_ms.saturating_sub(at) > MAX_ITEM_AGE_MS || at > now_ms + MAX_CLOCK_SKEW_MS {
                continue;
            }
            out.push(inner);
        } else if mail.is_none() {
            // Legacy pairing, before encryption existed: no master on either
            // side, so plaintext is the honest contract.
            out.push(item);
        } else {
            crate::log::line("phone: dropped a plaintext outbox item on an encrypted box");
        }
    }
    out
}

fn seen_insert(ct: String) -> bool {
    let mut seen = SEEN.lock().unwrap();
    if seen.len() > 1024 {
        seen.clear();
    }
    seen.insert(ct)
}

/// Phone → PC: drain the outbox and hand it to the island, which applies
/// decisions through the same commands its own buttons use.
async fn take(app: &AppHandle, worker: &str, id: &str, sec: &str) -> Result<(), String> {
    let reply = post_async(worker, "take", &json!({ "id": id, "secret": sec })).await?;
    let raw = reply.get("out").and_then(Value::as_array).cloned().unwrap_or_default();
    if raw.is_empty() {
        return Ok(());
    }
    let now_ms = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0);
    let out = decode_outbox(mail(id).as_ref(), raw, now_ms);
    if out.is_empty() {
        return Ok(());
    }
    *PHONE_SPOKE.lock().unwrap() = Some(Instant::now());
    crate::log::line(format!("phone: {} message(s) from the phone", out.len()));
    let _ = app.emit_to(WINDOW_LABEL, "phone-remote", Value::Array(out));
    Ok(())
}

// ── State pushes ──────────────────────────────────────────────────────────────

#[derive(Debug, PartialEq)]
enum Plan {
    Now,
    After(Duration),
}

/// When a push may go: an alert at once, anything else at most every
/// PUSH_GAP — and the last one of a burst after the gap, never not at all.
fn plan(last: Option<Instant>, now: Instant, alert: bool) -> Plan {
    match last {
        Some(t) if !alert && now.duration_since(t) < PUSH_GAP => Plan::After(PUSH_GAP - now.duration_since(t)),
        _ => Plan::Now,
    }
}

struct Outgoing {
    last: Option<Instant>,
    /// The newest state held back by the gap; a later one replaces it.
    held: Option<Value>,
    flush_scheduled: bool,
}

static OUTGOING: Mutex<Outgoing> = Mutex::new(Outgoing { last: None, held: None, flush_scheduled: false });

/// PC → phone: the island's latest state. `alert` gets an FCM wake; the rest is
/// for when the app is already open. Ok when sent, held for the end of the gap,
/// or not needed (no phone paired); Err when the relay could not be reached.
pub async fn push_state(app: &AppHandle, payload: Value, alert: bool) -> Result<(), String> {
    // A card on screen: the phone's answer is read at the quick pace.
    let card_up = payload.get("awaiting").is_some_and(|a| !a.is_null());
    if CARD_UP.swap(card_up, Ordering::Relaxed) != card_up && card_up {
        wake();
    }

    let now = Instant::now();
    let wait = {
        let mut out = OUTGOING.lock().unwrap();
        match plan(out.last, now, alert) {
            Plan::Now => {
                out.last = Some(now);
                out.held = None;
                None
            }
            Plan::After(wait) => {
                out.held = Some(payload.clone());
                if out.flush_scheduled {
                    return Ok(());
                }
                out.flush_scheduled = true;
                Some(wait)
            }
        }
    };
    let Some(wait) = wait else { return send_state(app, payload, alert).await };
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(wait).await;
        let held = {
            let mut out = OUTGOING.lock().unwrap();
            out.flush_scheduled = false;
            out.last = Some(Instant::now());
            out.held.take()
        };
        if let Some(payload) = held {
            let _ = send_state(&app, payload, false).await;
        }
    });
    Ok(())
}

async fn send_state(app: &AppHandle, payload: Value, alert: bool) -> Result<(), String> {
    let (worker, id) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        if !s.phone_enabled || !s.phone_paired {
            return Ok(());
        }
        (s.phone_worker.clone(), s.phone_pc_id.clone())
    };
    let (Some(worker), Some(id), Some(sec)) = (nonempty(worker), nonempty(id), secret()) else {
        return Ok(());
    };
    // What wakes the phone: the card kind, nothing else. Read before the
    // payload becomes ciphertext.
    let alert_kind = alert.then(|| {
        payload
            .get("awaiting")
            .and_then(|a| a.get("kind"))
            .and_then(Value::as_str)
            .map(|k| if k == "question" { json!("question") } else { json!("approval") })
            .unwrap_or(json!("approval"))
    });
    // On an encrypted box the relay stores ciphertext only: the card's command
    // and the chat tail are for the phone, not for the mailbox operator.
    let state = match mail(&id) {
        Some(m) => m.h2p.seal(payload.to_string().as_bytes()),
        None => payload,
    };
    let mut body = json!({ "id": id, "secret": sec, "state": state });
    if let Some(kind) = alert_kind {
        body["alert"] = kind;
    }
    post_async(&worker, "state", &body).await.map(|_| ())
}

// ── HTTP ──────────────────────────────────────────────────────────────────────

/// One HTTP client per relay address, kept: a fresh one per call meant a new
/// TLS handshake every poll.
fn client_for(worker: &str) -> Result<reqwest::Client, String> {
    static CLIENT: Mutex<Option<(String, reqwest::Client)>> = Mutex::new(None);
    let mut slot = CLIENT.lock().unwrap();
    if let Some((addr, client)) = slot.as_ref() {
        if addr == worker {
            return Ok(client.clone());
        }
    }
    let client = crate::net::client(&crate::net::normalise_server_url(worker)?, HTTP)?;
    *slot = Some((worker.to_string(), client.clone()));
    Ok(client)
}

async fn post_async(worker: &str, action: &str, body: &Value) -> Result<Value, String> {
    let worker = worker.trim_end_matches('/');
    let url = format!("{worker}{WORKER_PATH}/{action}");
    let client = client_for(worker)?;
    let resp = client.post(&url).json(body).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("relay {}", resp.status()));
    }
    resp.json::<Value>().await.map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_pairing_code_carries_the_box_id_its_secret_and_the_relay() {
        let p = start_pair("https://relay.example.workers.dev").unwrap();
        let parts: Vec<&str> = p.code.split('|').collect();
        assert_eq!(parts.len(), 3);
        assert!(parts[0].len() == 24 && parts[0].bytes().all(|b| b.is_ascii_hexdigit()));
        assert!(parts[1].len() == 64 && parts[1].bytes().all(|b| b.is_ascii_hexdigit()));
        // The master travels in the code and is only stored once the box exists.
        assert_eq!(parts[1], p.master);
        assert_eq!(parts[2], "https://relay.example.workers.dev");
        assert!(p.qr_svg.contains("<svg"));
    }

    #[test]
    fn a_relay_must_be_https_or_this_machine() {
        assert!(start_pair("http://relay.example").is_err());
        assert!(start_pair("http://127.0.0.1:8787").is_ok());
    }

    #[test]
    fn a_push_inside_the_gap_is_delayed_not_dropped() {
        let t0 = Instant::now();
        assert_eq!(plan(None, t0, false), Plan::Now);
        assert_eq!(
            plan(Some(t0), t0 + Duration::from_millis(400), false),
            Plan::After(Duration::from_millis(1100))
        );
        // A card waking the phone never waits.
        assert_eq!(plan(Some(t0), t0 + Duration::from_millis(400), true), Plan::Now);
        assert_eq!(plan(Some(t0), t0 + PUSH_GAP, false), Plan::Now);
    }

    #[test]
    fn the_outbox_is_read_quickly_only_while_something_is_going_on() {
        assert_eq!(take_interval(true, None), POLL);
        assert_eq!(take_interval(false, Some(Duration::from_secs(30))), POLL);
        assert_eq!(take_interval(false, Some(ACTIVE_WINDOW + Duration::from_secs(1))), POLL_IDLE);
        assert_eq!(take_interval(false, None), POLL_IDLE);
    }

    /// A mailbox the phone sealed for us, for decode_outbox tests.
    fn sealed_item(cipher: &mail_crypto::Cipher, inner: Value) -> Value {
        let mut blob = cipher.seal(inner.to_string().as_bytes());
        blob.as_object_mut().unwrap().insert("type".into(), Value::from("enc"));
        blob.as_object_mut().unwrap().insert("at".into(), Value::from(1));
        blob
    }

    #[test]
    fn encrypted_items_decrypt_and_plaintext_forgery_is_dropped() {
        let (p2h, _h2p) = mail_crypto::ciphers(
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            "0123456789abcdef01234567",
        )
        .unwrap();
        let now = 1_800_000_000_000u64;
        let mail = Mail { p2h, h2p: _h2p };
        let good = sealed_item(&mail.p2h, json!({"type":"decision","requestId":"r1","decision":"allow","at":now}));
        let forged = json!({"type":"decision","requestId":"r1","decision":"allow","at":now});
        let out = decode_outbox(Some(&mail), vec![good, forged], now);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["decision"], "allow");
    }

    #[test]
    fn stale_and_replayed_items_are_dropped() {
        let (p2h, _h2p) = mail_crypto::ciphers(
            "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff",
            "0123456789abcdef01234567",
        )
        .unwrap();
        let now = 1_800_000_000_000u64;
        let mail = Mail { p2h, h2p: _h2p };
        // Older than the outbox TTL: a replay the relay is showing again.
        let stale = sealed_item(&mail.p2h, json!({"type":"chat","text":"old","at": now - MAX_ITEM_AGE_MS - 1}));
        // The same blob twice: applied once.
        let item = sealed_item(&mail.p2h, json!({"type":"chat","text":"hi","at": now}));
        let out = decode_outbox(Some(&mail), vec![stale, item.clone(), item], now);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["text"], "hi");
    }

    #[test]
    fn a_legacy_pairing_keeps_plaintext() {
        let item = json!({"type":"chat","text":"hi","at":1});
        let out = decode_outbox(None, vec![item], 1_800_000_000_000);
        assert_eq!(out.len(), 1);
        assert_eq!(out[0]["text"], "hi");
    }

    #[test]
    fn a_pairing_code_is_watched_for_half_an_hour() {
        assert!(pairing_open(Some(Duration::from_secs(60))));
        assert!(!pairing_open(Some(PAIR_WINDOW + Duration::from_secs(1))));
        assert!(!pairing_open(None));
    }
}
