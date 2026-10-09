// Android companion: the PC owns a "box" on a relay worker the user deployed
// themselves (see relay/), the phone claims it with a QR code or a pasted
// string, and from then on the island pushes its state up and the phone's
// clicks come back down the same mailbox.
//
//   PC     POST /v1/phone/pair     once, when Pair is clicked
//   PC     POST /v1/phone/claimed  while pairing, until a phone answers
//   PC     POST /v1/phone/state    on every island change (alert = a card is up)
//   PC     POST /v1/phone/take     drains decisions and chat lines, every 3 s
//   PC     POST /v1/phone/unpair   the phone is forgotten, the box wiped
//
// The pc id lives in settings.json; the pairing secret lives in the keychain.
// Nothing in this file knows or stores what a session is doing beyond what the
// island already shows — the relay never sees a command, path or prompt either:
// the card's text is sent only inside the box the user owns.

use serde_json::{json, Value};
use std::sync::Mutex;
use std::time::{Duration, Instant};
use tauri::{AppHandle, Emitter, Manager};

use crate::i18n::t;
use crate::island::WINDOW_LABEL;

const POLL: Duration = Duration::from_secs(3);
const PAIR_WAIT: Duration = Duration::from_secs(3);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
const HTTP: Duration = Duration::from_secs(10);
/// The phone may go quiet between cards; a box is considered live while the
/// relay can still reach it.
const WORKER_PATH: &str = "/v1/phone";

/// The credentials a box is created with. `pc_id` identifies it (and is fine
/// in settings.json); `secret` authenticates every call and stays in the
/// keychain only.
pub struct Pairing {
    pub worker: String,
    pub pc_id: String,
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

/// A phone taking over the island: pair + start the background loop.
pub fn start_pair(worker: &str) -> Result<Pairing, String> {
    let worker = check_worker(worker)?;
    let Some(pc_id) = hex(12) else { return Err("no random source".into()) };
    let Some(sec) = hex(32) else { return Err("no random source".into()) };
    crate::secrets::set("phone-secret", &sec)?;

    let code = format!("{pc_id}|{sec}|{worker}");
    let qr_svg = qrcode::QrCode::new(code.as_bytes())
        .map_err(|e| e.to_string())?
        .render::<qrcode::render::svg::Color>()
        .build();
    Ok(Pairing { worker, pc_id, code, qr_svg })
}

/// Called once the code is on screen: creates the box, keeps id + worker in
/// settings, starts the loop so `claimed` is noticed.
pub fn finish_pair(app: &AppHandle, pair: &Pairing) -> Result<(), String> {
    tauri::async_runtime::block_on(post_async(
        &pair.worker,
        "pair",
        &json!({ "id": pair.pc_id, "secret": secret().unwrap_or_default() }),
    ))?;
    let shared = app.state::<crate::Shared>();
    let mut settings = shared.settings.lock().unwrap();
    settings.phone_worker = pair.worker.clone();
    settings.phone_pc_id = pair.pc_id.clone();
    settings.phone_paired = false;
    settings.phone_device.clear();
    settings.phone_enabled = true;
    let snapshot = settings.clone();
    drop(settings);
    let _ = crate::settings::save(&snapshot);
    spawn(app.clone());
    Ok(())
}

pub fn unpair(app: &AppHandle) {
    let (worker, id) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        (s.phone_worker.clone(), s.phone_pc_id.clone())
    };
    if let (Some(worker), Some(id)) = (nonempty(worker), nonempty(id)) {
        if let Some(secret) = secret() {
            let _ = tauri::async_runtime::block_on(post_async(
                &worker,
                "unpair",
                &json!({ "id": id, "secret": secret }),
            ));
        }
    }
    let _ = crate::secrets::clear("phone-secret");
    let shared = app.state::<crate::Shared>();
    let mut settings = shared.settings.lock().unwrap();
    settings.phone_paired = false;
    settings.phone_device.clear();
    settings.phone_pc_id.clear();
    let snapshot = settings.clone();
    drop(settings);
    let _ = crate::settings::save(&snapshot);
}

fn nonempty(s: String) -> Option<String> {
    (!s.is_empty()).then_some(s)
}

/// The poll loop: claim → outbox. Started at launch and after pairing; it
/// no-ops whenever the phone is not enabled, so it is safe to spawn twice —
/// a `RUNNING` flag makes sure only one instance ever actually loops.
static RUNNING: Mutex<bool> = Mutex::new(false);

pub fn spawn(app: AppHandle) {
    {
        let mut running = RUNNING.lock().unwrap();
        if *running {
            return;
        }
        *running = true;
    }
    tauri::async_runtime::spawn(async move {
        let mut backoff = POLL;
        loop {
            let (enabled, paired, worker, id) = {
                let shared = app.state::<crate::Shared>();
                let s = shared.settings.lock().unwrap();
                (
                    s.phone_enabled,
                    s.phone_paired,
                    s.phone_worker.clone(),
                    s.phone_pc_id.clone(),
                )
            };
            let (Some(worker), Some(id), Some(sec)) =
                (nonempty(worker), nonempty(id), secret())
            else {
                tokio::time::sleep(POLL).await;
                continue;
            };
            if !enabled {
                tokio::time::sleep(POLL).await;
                continue;
            }

            let result = if paired {
                take(&app, &worker, &id, &sec).await
            } else {
                claimed(&app, &worker, &id, &sec).await
            };
            match result {
                Ok(()) => backoff = POLL,
                Err(_) => {
                    // The worker or the network is down: keep trying, quietly,
                    // widening the gap so a phone-less afternoon is cheap.
                    tokio::time::sleep(backoff).await;
                    backoff = (backoff * 2).min(BACKOFF_MAX);
                    continue;
                }
            }
            tokio::time::sleep(if paired { POLL } else { PAIR_WAIT }).await;
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
        {
            let shared = app.state::<crate::Shared>();
            let mut s = shared.settings.lock().unwrap();
            s.phone_paired = true;
            s.phone_device = device.clone();
            let snapshot = s.clone();
            drop(s);
            let _ = crate::settings::save(&snapshot);
        }
        crate::log::line(format!("phone paired: {device}"));
        let _ = app.emit_to("settings", "phone-paired", json!({ "device": device }));
    }
    Ok(())
}

/// Phone → PC: drain the outbox and hand it to the island, which applies
/// decisions through the same commands its own buttons use.
async fn take(app: &AppHandle, worker: &str, id: &str, sec: &str) -> Result<(), String> {
    let reply = post_async(worker, "take", &json!({ "id": id, "secret": sec })).await?;
    let out = reply.get("out").and_then(Value::as_array).cloned().unwrap_or_default();
    if out.is_empty() {
        return Ok(());
    }
    crate::log::line(format!("phone: {} message(s) from the phone", out.len()));
    let _ = app.emit_to(WINDOW_LABEL, "phone-remote", Value::Array(out));
    Ok(())
}

/// PC → phone: the island's latest state. `alert` gets an FCM wake; the rest
/// is for when the app is already open. The worker validates the shape.
pub async fn push_state(app: &AppHandle, payload: Value, alert: bool) -> Result<(), String> {
    static LAST: Mutex<Option<Instant>> = Mutex::new(None);
    {
        let mut last = LAST.lock().unwrap();
        if !alert && last.is_some_and(|t| t.elapsed() < Duration::from_millis(1500)) {
            return Ok(());
        }
        *last = Some(Instant::now());
    }
    let (worker, id) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        if !s.phone_enabled || !s.phone_paired {
            return Ok(());
        }
        (s.phone_worker.clone(), s.phone_pc_id.clone())
    };
    let (Some(worker), Some(id), Some(sec)) = (nonempty(worker), nonempty(id), secret())
    else {
        return Ok(());
    };
    let mut body = json!({ "id": id, "secret": sec, "state": payload });
    if alert {
        // What wakes the phone: the card kind, nothing else.
        body["alert"] = payload
            .get("awaiting")
            .and_then(|a| a.get("kind"))
            .and_then(Value::as_str)
            .map(|k| if k == "question" { json!("question") } else { json!("approval") })
            .unwrap_or(json!("approval"));
    }
    post_async(&worker, "state", &body).await.map(|_| ())
}

async fn post_async(worker: &str, action: &str, body: &Value) -> Result<Value, String> {
    let worker = worker.trim_end_matches('/');
    let url = format!("{worker}{WORKER_PATH}/{action}");
    let client = crate::net::client(
        &crate::net::normalise_server_url(&url)?,
        HTTP,
    )?;
    let resp = client.post(&url).json(body).send().await.map_err(|e| e.to_string())?;
    if !resp.status().is_success() {
        return Err(format!("relay {}", resp.status()));
    }
    resp.json::<Value>().await.map_err(|e| e.to_string())
}
