// Discord Rich Presence (RPC) via local named pipe (\\.\pipe\discord-ipc-0).
// Lets the user broadcast their Coucou status to Discord safely without needing any user token.

use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tauri::command;
#[cfg(windows)]
use tokio::io::{AsyncReadExt, AsyncWriteExt};
#[cfg(windows)]
use tokio::net::windows::named_pipe::ClientOptions;
use tokio::sync::watch;

// Default public Discord Client ID (VS Code application registered on Discord)
const DEFAULT_CLIENT_ID: &str = "383226320970055681";

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct DiscordStatus {
    pub enabled: bool,
    #[serde(default)]
    pub client_id: String,
    /// "mochi", "music", "code", "focus", "custom"
    pub mode: String,
    pub custom_details: String,
    pub custom_state: String,
    #[serde(default)]
    pub connected_user: Option<String>,
}

impl Default for DiscordStatus {
    fn default() -> Self {
        Self {
            enabled: false,
            client_id: "".into(),
            mode: "mochi".into(),
            custom_details: "Chilling with Mochi".into(),
            custom_state: "Coucou for Windows".into(),
            connected_user: None,
        }
    }
}

pub struct DiscordManager {
    pub status: Mutex<DiscordStatus>,
    pub tx: watch::Sender<DiscordStatus>,
}

static MANAGER: Mutex<Option<DiscordManager>> = Mutex::new(None);

pub fn init() {
    let mut m = MANAGER.lock().unwrap();
    if m.is_none() {
        let default_status = DiscordStatus::default();
        let (tx, rx) = watch::channel(default_status.clone());
        *m = Some(DiscordManager {
            status: Mutex::new(default_status),
            tx,
        });

        #[cfg(windows)]
        tokio::spawn(discord_worker(rx));
        #[cfg(not(windows))]
        let _ = rx;
    }
}

fn update_connected_user(user: Option<String>) {
    let m = MANAGER.lock().unwrap();
    if let Some(mgr) = m.as_ref() {
        mgr.status.lock().unwrap().connected_user = user;
    }
}

#[cfg(windows)]
async fn connect_pipe() -> Option<tokio::net::windows::named_pipe::NamedPipeClient> {
    for i in 0..10 {
        let path = format!(r"\\.\pipe\discord-ipc-{i}");
        if let Ok(client) = ClientOptions::new().open(&path) {
            return Some(client);
        }
    }
    None
}

#[cfg(windows)]
async fn send_packet(
    pipe: &mut tokio::net::windows::named_pipe::NamedPipeClient,
    opcode: u32,
    payload: &str,
) -> bool {
    let bytes = payload.as_bytes();
    let len = bytes.len() as u32;

    let mut buf = Vec::with_capacity(8 + bytes.len());
    buf.extend_from_slice(&opcode.to_le_bytes());
    buf.extend_from_slice(&len.to_le_bytes());
    buf.extend_from_slice(bytes);

    pipe.write_all(&buf).await.is_ok()
}

#[cfg(windows)]
async fn read_packet(
    pipe: &mut tokio::net::windows::named_pipe::NamedPipeClient,
) -> Option<(u32, String)> {
    let mut header = [0u8; 8];
    if pipe.read_exact(&mut header).await.is_err() {
        return None;
    }
    let opcode = u32::from_le_bytes([header[0], header[1], header[2], header[3]]);
    let len = u32::from_le_bytes([header[4], header[5], header[6], header[7]]) as usize;
    if len > 65536 {
        return None;
    }
    let mut buf = vec![0u8; len];
    if pipe.read_exact(&mut buf).await.is_err() {
        return None;
    }
    let text = String::from_utf8_lossy(&buf).to_string();
    Some((opcode, text))
}

#[cfg(windows)]
async fn send_activity(
    pipe: &mut tokio::net::windows::named_pipe::NamedPipeClient,
    status: &DiscordStatus,
    start_ts: u64,
) -> bool {
    let pid = std::process::id();
    let (details, state) = match status.mode.as_str() {
        "mochi" => ("Chilling with Mochi", "Coucou for Windows"),
        "code" => ("Coding Session", "Pair programming with AI"),
        "focus" => ("Focus Mode", "Deep Work · Do Not Disturb"),
        "music" => ("Listening to Music", "Coucou Sound System"),
        "custom" => (status.custom_details.as_str(), status.custom_state.as_str()),
        _ => ("Exploring with Mochi", "Coucou for Windows"),
    };

    let frame = serde_json::json!({
        "cmd": "SET_ACTIVITY",
        "args": {
            "pid": pid,
            "activity": {
                "details": details,
                "state": state,
                "timestamps": { "start": start_ts }
            }
        },
        "nonce": "1",
    })
    .to_string();

    send_packet(pipe, 1, &frame).await
}

#[cfg(windows)]
async fn discord_worker(mut rx: watch::Receiver<DiscordStatus>) {
    loop {
        let status = rx.borrow().clone();
        if !status.enabled {
            update_connected_user(None);
            if rx.changed().await.is_err() {
                break;
            }
            continue;
        }

        let mut pipe = match connect_pipe().await {
            Some(p) => p,
            None => {
                update_connected_user(None);
                tokio::select! {
                    _ = tokio::time::sleep(tokio::time::Duration::from_secs(3)) => {},
                    _ = rx.changed() => {},
                }
                continue;
            }
        };

        let client_id = if status.client_id.trim().is_empty() {
            DEFAULT_CLIENT_ID
        } else {
            status.client_id.trim()
        };

        let handshake = serde_json::json!({
            "v": 1,
            "client_id": client_id,
        })
        .to_string();

        if !send_packet(&mut pipe, 0, &handshake).await {
            tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
            continue;
        }

        let (op, resp) = match read_packet(&mut pipe).await {
            Some(res) => res,
            None => {
                tokio::time::sleep(tokio::time::Duration::from_secs(2)).await;
                continue;
            }
        };

        if op == 2 {
            crate::log::line(format!("Discord RPC error: {resp}"));
            update_connected_user(None);
            tokio::select! {
                _ = tokio::time::sleep(tokio::time::Duration::from_secs(5)) => {},
                _ = rx.changed() => {},
            }
            continue;
        }

        if let Ok(val) = serde_json::from_str::<serde_json::Value>(&resp) {
            if let Some(user) = val.get("data").and_then(|d| d.get("user")) {
                let name = user
                    .get("global_name")
                    .and_then(|v| v.as_str())
                    .or_else(|| user.get("username").and_then(|v| v.as_str()))
                    .unwrap_or("Discord User");
                update_connected_user(Some(name.to_string()));
            }
        }

        let now_sec = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map(|d| d.as_secs())
            .unwrap_or(0);
        send_activity(&mut pipe, &status, now_sec).await;

        loop {
            tokio::select! {
                res = rx.changed() => {
                    if res.is_err() {
                        return;
                    }
                    let new_status = rx.borrow().clone();
                    if !new_status.enabled {
                        let pid = std::process::id();
                        let frame = serde_json::json!({
                            "cmd": "SET_ACTIVITY",
                            "args": { "pid": pid, "activity": null },
                            "nonce": "1",
                        })
                        .to_string();
                        let _ = send_packet(&mut pipe, 1, &frame).await;
                        update_connected_user(None);
                        break;
                    }
                    if new_status.client_id.trim() != status.client_id.trim() {
                        break;
                    }
                    send_activity(&mut pipe, &new_status, now_sec).await;
                }
                packet = read_packet(&mut pipe) => {
                    match packet {
                        Some((_, _)) => {},
                        None => {
                            update_connected_user(None);
                            break;
                        }
                    }
                }
            }
        }
    }
}

#[command]
pub async fn discord_get_status() -> DiscordStatus {
    init();
    let m = MANAGER.lock().unwrap();
    m.as_ref()
        .map(|mgr| mgr.status.lock().unwrap().clone())
        .unwrap_or_default()
}

#[command]
pub async fn discord_set_status(status: DiscordStatus) -> Result<(), String> {
    init();
    let m = MANAGER.lock().unwrap();
    if let Some(mgr) = m.as_ref() {
        *mgr.status.lock().unwrap() = status.clone();
        let _ = mgr.tx.send(status);
    }
    Ok(())
}
