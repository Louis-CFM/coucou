// Vayli Drop zero-QR device-aware file transfer module (windows/src-tauri/src/coudrop/mod.rs)
// Directly uses the existing Coucou Desktop <-> Android authenticated connection.
// Upgraded to CouDrop Protocol V2: Direct high-performance binary streaming over local HTTP/TCP.

pub mod server;

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;
use std::time::Duration;

use ring::digest::SHA256;
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, State};
use tokio::sync::{Mutex, Notify};

use crate::phone_link::PhoneLink;
use server::{
    base64_decode, base64_encode, coudrop_dir, generate_token, hex_encode, unique_path,
    ReceivedFileInfo, TransferProgress,
};

#[derive(Clone, Serialize, Deserialize, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct VayliDropDevice {
    pub connected: bool,
    pub name: String,
    pub can_drop: bool,
}

#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ActiveTransferInfo {
    pub id: String,
    pub direction: String,
    pub name: String,
    pub total_bytes: u64,
    pub bytes_transferred: u64,
    pub progress: f64,
    pub speed_bytes_per_sec: u64,
    pub time_remaining_seconds: Option<u64>,
    pub is_paused: bool,
    pub status: String,
}

#[allow(dead_code)]
pub struct IncomingTransfer {
    pub transfer_id: String,
    pub name: String,
    pub size: u64,
    pub expected_sha256: String,
    pub temp_path: PathBuf,
    pub file: tokio::fs::File,
    pub digest_ctx: ring::digest::Context,
    pub bytes_received: u64,
    pub is_paused: bool,
    pub start_time: std::time::Instant,
    pub window_start: std::time::Instant,
    pub window_bytes: u64,
    pub current_speed: u64,
}

pub struct CoudropManager {
    pub is_sending: Arc<AtomicBool>,
    pub is_paused: Arc<AtomicBool>,
    pub is_cancelled: Arc<AtomicBool>,
    pub pause_notify: Arc<Notify>,
    pub current_transfer_id: Mutex<Option<String>>,
    pub current_transfer_name: Mutex<Option<String>>,
    pub current_transfer_size: Mutex<u64>,
    pub current_transfer_direction: Mutex<Option<String>>,
    pub incoming: Mutex<HashMap<String, IncomingTransfer>>,
    pub accept_notify: Arc<Notify>,
    pub last_accept_status: Mutex<Option<(String, bool, u64)>>, // (transferId, accepted, protocolVersion)
    pub done_notify: Arc<Notify>,
    pub last_done_status: Mutex<Option<(String, String)>>,
    pub last_reject_status: Mutex<Option<(String, String)>>,
    pub data_server: Mutex<Option<Arc<server::DataServer>>>,
}

impl Default for CoudropManager {
    fn default() -> Self {
        Self {
            is_sending: Arc::new(AtomicBool::new(false)),
            is_paused: Arc::new(AtomicBool::new(false)),
            is_cancelled: Arc::new(AtomicBool::new(false)),
            pause_notify: Arc::new(Notify::new()),
            current_transfer_id: Mutex::new(None),
            current_transfer_name: Mutex::new(None),
            current_transfer_size: Mutex::new(0),
            current_transfer_direction: Mutex::new(None),
            incoming: Mutex::new(HashMap::new()),
            accept_notify: Arc::new(Notify::new()),
            last_accept_status: Mutex::new(None),
            done_notify: Arc::new(Notify::new()),
            last_done_status: Mutex::new(None),
            last_reject_status: Mutex::new(None),
            data_server: Mutex::new(None),
        }
    }
}

/// Retrieves the existing dedicated DataServer or initializes a new instance on DEFAULT_DATA_PORT.
pub async fn get_or_init_data_server(app: &AppHandle, manager: &CoudropManager) -> Result<Arc<server::DataServer>, String> {
    let mut lock = manager.data_server.lock().await;
    if let Some(ref srv) = *lock {
        return Ok(srv.clone());
    }
    let tls_acceptor = app.try_state::<PhoneLink>().and_then(|l| l.tls_acceptor());
    let srv = server::DataServer::start(Some(app.clone()), server::DEFAULT_DATA_PORT, tls_acceptor).await?;
    *lock = Some(srv.clone());
    Ok(srv)
}

/// Dispatches an incoming drop protocol message received over the TLS link.
pub async fn handle_drop_message(app: &AppHandle, msg: &serde_json::Value) {
    let msg_type = msg["type"].as_str().unwrap_or("");
    let manager = app.state::<CoudropManager>();
    let link = match app.try_state::<PhoneLink>() {
        Some(l) => l,
        None => return,
    };

    match msg_type {
        "dropOffer" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            if transfer_id.is_empty() {
                return;
            }
            let protocol_version = msg["protocolVersion"].as_u64().unwrap_or(1);
            let raw_name = msg["name"].as_str().unwrap_or("file.bin");
            let sanitized_name = Path::new(raw_name)
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_else(|| "file.bin".to_string());
            let size = msg["size"].as_u64().unwrap_or(0);
            let sha256 = msg["sha256"].as_str().unwrap_or("").to_string();

            let dir = coudrop_dir();
            let temp_path = dir.join(format!(".coudrop_{}.tmp", &transfer_id));

            *manager.current_transfer_id.lock().await = Some(transfer_id.clone());
            *manager.current_transfer_name.lock().await = Some(sanitized_name.clone());
            *manager.current_transfer_size.lock().await = size;
            *manager.current_transfer_direction.lock().await = Some("receive".to_string());
            manager.is_paused.store(false, Ordering::SeqCst);
            manager.is_cancelled.store(false, Ordering::SeqCst);

            if protocol_version >= 2 {
                // ── COUDROP PROTOCOL V2: DIRECT HIGH-SPEED BINARY UPLOAD ─────
                let data_server = match get_or_init_data_server(app, &manager).await {
                    Ok(s) => s,
                    Err(e) => {
                        let reject_msg = serde_json::json!({
                            "type": "dropReject",
                            "transferId": transfer_id,
                            "reason": format!("server_init_error: {}", e)
                        }).to_string();
                        let _ = link.hub.send_drop_async(&reject_msg).await;
                        return;
                    }
                };

                let token = generate_token();
                data_server
                    .register_upload(
                        transfer_id.clone(),
                        sanitized_name.clone(),
                        temp_path.clone(),
                        token.clone(),
                        size,
                        sha256.clone(),
                    )
                    .await;

                // Send dropAccept back to phone with dataPort and token
                let accept_msg = serde_json::json!({
                    "type": "dropAccept",
                    "transferId": transfer_id.clone(),
                    "protocolVersion": 2,
                    "dataPort": data_server.port(),
                    "token": token
                }).to_string();
                let _ = link.hub.send_drop_async(&accept_msg).await;

                // Emit transfer started (receiving)
                let _ = app.emit("coudrop-transfer-started", serde_json::json!({
                    "transferId": transfer_id.clone(),
                    "name": sanitized_name.clone(),
                    "totalBytes": size,
                    "direction": "receive"
                }));

                let _ = app.emit("coudrop-progress", TransferProgress {
                    transfer_id: Some(transfer_id.clone()),
                    name: sanitized_name,
                    bytes_read: 0,
                    total_bytes: size,
                    progress: 0.0,
                    speed_bytes_per_sec: Some(0),
                    time_remaining_seconds: None,
                    direction: Some("receive".to_string()),
                    is_paused: Some(false),
                });
                return;
            }

            // ── FALLBACK: V1 CHUNKED BASE64 TLS FRAMING ──────────────────────
            match tokio::fs::File::create(&temp_path).await {
                Ok(file) => {
                    let now = std::time::Instant::now();
                    let transfer = IncomingTransfer {
                        transfer_id: transfer_id.clone(),
                        name: sanitized_name.clone(),
                        size,
                        expected_sha256: sha256,
                        temp_path,
                        file,
                        digest_ctx: ring::digest::Context::new(&SHA256),
                        bytes_received: 0,
                        is_paused: false,
                        start_time: now,
                        window_start: now,
                        window_bytes: 0,
                        current_speed: 0,
                    };
                    manager.incoming.lock().await.insert(transfer_id.clone(), transfer);

                    let accept_msg = serde_json::json!({
                        "type": "dropAccept",
                        "transferId": transfer_id.clone(),
                    }).to_string();
                    let _ = link.hub.send_drop_async(&accept_msg).await;

                    let _ = app.emit("coudrop-transfer-started", serde_json::json!({
                        "transferId": transfer_id.clone(),
                        "name": sanitized_name.clone(),
                        "totalBytes": size,
                        "direction": "receive"
                    }));

                    let _ = app.emit("coudrop-progress", TransferProgress {
                        transfer_id: Some(transfer_id.clone()),
                        name: sanitized_name,
                        bytes_read: 0,
                        total_bytes: size,
                        progress: 0.0,
                        speed_bytes_per_sec: Some(0),
                        time_remaining_seconds: None,
                        direction: Some("receive".to_string()),
                        is_paused: Some(false),
                    });
                }
                Err(e) => {
                    let reject_msg = serde_json::json!({
                        "type": "dropReject",
                        "transferId": transfer_id,
                        "reason": format!("io_error: {}", e)
                    }).to_string();
                    let _ = link.hub.send_drop_async(&reject_msg).await;
                }
            }
        }
        "dropChunk" => {
            if manager.is_cancelled.load(Ordering::SeqCst) {
                return;
            }

            let transfer_id = msg["transferId"].as_str().unwrap_or("");
            let data_b64 = msg["data"].as_str().unwrap_or("");

            let mut incoming = manager.incoming.lock().await;
            if let Some(transfer) = incoming.get_mut(transfer_id) {
                if let Ok(bytes) = base64_decode(data_b64) {
                    use tokio::io::AsyncWriteExt;
                    if transfer.file.write_all(&bytes).await.is_ok() {
                        transfer.digest_ctx.update(&bytes);
                        transfer.bytes_received += bytes.len() as u64;

                        let progress = if transfer.size > 0 {
                            (transfer.bytes_received as f64 / transfer.size as f64).min(0.99)
                        } else {
                            1.0
                        };

                        let now = std::time::Instant::now();
                        let elapsed = (now - transfer.window_start).as_secs_f64();
                        if elapsed >= 0.25 {
                            let diff = transfer.bytes_received.saturating_sub(transfer.window_bytes);
                            transfer.current_speed = (diff as f64 / elapsed) as u64;
                            transfer.window_start = now;
                            transfer.window_bytes = transfer.bytes_received;
                        }
                        let remaining_bytes = transfer.size.saturating_sub(transfer.bytes_received);
                        let eta = if transfer.current_speed > 0 && remaining_bytes > 0 {
                            Some(remaining_bytes / transfer.current_speed)
                        } else {
                            None
                        };

                        let is_paused = manager.is_paused.load(Ordering::SeqCst);

                        let _ = app.emit("coudrop-progress", TransferProgress {
                            transfer_id: Some(transfer.transfer_id.clone()),
                            name: transfer.name.clone(),
                            bytes_read: transfer.bytes_received,
                            total_bytes: transfer.size,
                            progress,
                            speed_bytes_per_sec: Some(transfer.current_speed),
                            time_remaining_seconds: eta,
                            direction: Some("receive".to_string()),
                            is_paused: Some(is_paused),
                        });
                    }
                }
            }
        }
        "dropPause" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            manager.is_paused.store(true, Ordering::SeqCst);
            let _ = app.emit("coudrop-transfer-paused", serde_json::json!({
                "transferId": transfer_id
            }));
        }
        "dropResume" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            manager.is_paused.store(false, Ordering::SeqCst);
            manager.pause_notify.notify_waiters();
            let _ = app.emit("coudrop-transfer-resumed", serde_json::json!({
                "transferId": transfer_id
            }));
        }
        "dropDone" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("");
            let reported_sha256 = msg["sha256"].as_str().unwrap_or("");

            // 1. Notify any outgoing transfer awaiting acknowledgement (Desktop -> Android)
            {
                *manager.last_done_status.lock().await = Some((transfer_id.to_string(), reported_sha256.to_string()));
                manager.done_notify.notify_waiters();
            }

            // 2. Finalize incoming V2 transfer if present
            let mut finalized_v2 = false;
            if let Ok(data_server) = get_or_init_data_server(app, &manager).await {
                if let Some(upload) = data_server.remove_upload(transfer_id).await {
                    finalized_v2 = true;
                    let computed_hash = upload.completed_sha256.lock().await.clone().unwrap_or_default();
                    let expected = if !upload.expected_sha256.is_empty() {
                        &upload.expected_sha256
                    } else {
                        reported_sha256
                    };

                    if !expected.is_empty() && !computed_hash.is_empty() && !computed_hash.eq_ignore_ascii_case(expected) {
                        eprintln!("[coudrop] Checksum mismatch for {}: expected {}, got {}", upload.name, expected, computed_hash);
                        let _ = tokio::fs::remove_file(&upload.temp_path).await;
                        let reject_msg = serde_json::json!({
                            "type": "dropReject",
                            "transferId": transfer_id,
                            "reason": "checksum_mismatch"
                        }).to_string();
                        let _ = link.hub.send_drop_async(&reject_msg).await;
                        let _ = app.emit("coudrop-cancel", ());
                        return;
                    }

                    let dir = coudrop_dir();
                    let target_path = unique_path(&dir, &upload.name);

                    let mut rename_ok = false;
                    for attempt in 0..10 {
                        if attempt > 0 {
                            tokio::time::sleep(Duration::from_millis(40)).await;
                        }
                        if tokio::fs::rename(&upload.temp_path, &target_path).await.is_ok() {
                            rename_ok = true;
                            break;
                        }
                    }
                    if !rename_ok {
                        if tokio::fs::copy(&upload.temp_path, &target_path).await.is_ok() {
                            let _ = tokio::fs::remove_file(&upload.temp_path).await;
                            rename_ok = true;
                        }
                    }

                    if rename_ok {
                        let done_ack = serde_json::json!({
                            "type": "dropDone",
                            "transferId": transfer_id,
                            "sha256": computed_hash
                        }).to_string();
                        let _ = link.hub.send_drop_async(&done_ack).await;

                        let final_name = target_path
                            .file_name()
                            .map(|f| f.to_string_lossy().to_string())
                            .unwrap_or(upload.name);

                        let file_size = tokio::fs::metadata(&target_path).await.map(|m| m.len()).unwrap_or(upload.size);

                        let _ = app.emit("coudrop-file-received", ReceivedFileInfo {
                            name: final_name,
                            path: target_path.to_string_lossy().to_string(),
                            size: file_size,
                        });
                    } else {
                        eprintln!("[coudrop] Failed to save received file to {:?}", target_path);
                        let _ = tokio::fs::remove_file(&upload.temp_path).await;
                        let reject_msg = serde_json::json!({
                            "type": "dropReject",
                            "transferId": transfer_id,
                            "reason": "io_error_rename"
                        }).to_string();
                        let _ = link.hub.send_drop_async(&reject_msg).await;
                        let _ = app.emit("coudrop-cancel", ());
                    }
                }
            }

            // 3. Finalize incoming V1 transfer if not V2
            if !finalized_v2 {
                let transfer_opt = manager.incoming.lock().await.remove(transfer_id);
                if let Some(mut transfer) = transfer_opt {
                    use tokio::io::AsyncWriteExt;
                    let _ = transfer.file.flush().await;
                    drop(transfer.file);

                    let computed_hash = hex_encode(transfer.digest_ctx.finish().as_ref());
                    let expected = if !transfer.expected_sha256.is_empty() {
                        &transfer.expected_sha256
                    } else {
                        reported_sha256
                    };

                    if !expected.is_empty() && !computed_hash.eq_ignore_ascii_case(expected) {
                        eprintln!("[coudrop] Checksum mismatch for {}: expected {}, got {}", transfer.name, expected, computed_hash);
                        let _ = tokio::fs::remove_file(&transfer.temp_path).await;
                        let reject_msg = serde_json::json!({
                            "type": "dropReject",
                            "transferId": transfer_id,
                            "reason": "checksum_mismatch"
                        }).to_string();
                        let _ = link.hub.send_drop_async(&reject_msg).await;
                        let _ = app.emit("coudrop-cancel", ());
                        return;
                    }

                    let dir = coudrop_dir();
                    let target_path = unique_path(&dir, &transfer.name);

                    let mut rename_ok = false;
                    for attempt in 0..10 {
                        if attempt > 0 {
                            tokio::time::sleep(Duration::from_millis(40)).await;
                        }
                        if tokio::fs::rename(&transfer.temp_path, &target_path).await.is_ok() {
                            rename_ok = true;
                            break;
                        }
                    }
                    if !rename_ok {
                        if tokio::fs::copy(&transfer.temp_path, &target_path).await.is_ok() {
                            let _ = tokio::fs::remove_file(&transfer.temp_path).await;
                            rename_ok = true;
                        }
                    }

                    if rename_ok {
                        let done_ack = serde_json::json!({
                            "type": "dropDone",
                            "transferId": transfer_id,
                            "sha256": computed_hash
                        }).to_string();
                        let _ = link.hub.send_drop_async(&done_ack).await;

                        let final_name = target_path
                            .file_name()
                            .map(|f| f.to_string_lossy().to_string())
                            .unwrap_or(transfer.name);

                        let _ = app.emit("coudrop-file-received", ReceivedFileInfo {
                            name: final_name,
                            path: target_path.to_string_lossy().to_string(),
                            size: transfer.bytes_received,
                        });
                    } else {
                        eprintln!("[coudrop] Failed to save received file to {:?}", target_path);
                        let _ = tokio::fs::remove_file(&transfer.temp_path).await;
                        let reject_msg = serde_json::json!({
                            "type": "dropReject",
                            "transferId": transfer_id,
                            "reason": "io_error_rename"
                        }).to_string();
                        let _ = link.hub.send_drop_async(&reject_msg).await;
                        let _ = app.emit("coudrop-cancel", ());
                    }
                }
            }
        }
        "dropAccept" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            let proto_v = msg["protocolVersion"].as_u64().unwrap_or(1);
            *manager.last_accept_status.lock().await = Some((transfer_id, true, proto_v));
            manager.accept_notify.notify_waiters();
            let _ = app.emit("coudrop-accept", msg);
        }
        "dropReject" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            let reason = msg["reason"].as_str().unwrap_or("rejected").to_string();
            *manager.last_accept_status.lock().await = Some((transfer_id.clone(), false, 1));
            *manager.last_reject_status.lock().await = Some((transfer_id, reason));
            manager.accept_notify.notify_waiters();
            manager.done_notify.notify_waiters();
            let _ = app.emit("coudrop-reject", msg);
        }
        "dropProgress" => {
            let _ = app.emit("coudrop-peer-progress", msg);
        }
        "dropCancel" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            let reason = msg["reason"].as_str().unwrap_or("cancelled").to_string();
            manager.is_cancelled.store(true, Ordering::SeqCst);
            *manager.last_reject_status.lock().await = Some((transfer_id.clone(), reason));
            manager.accept_notify.notify_waiters();
            manager.done_notify.notify_waiters();
            if let Some(transfer) = manager.incoming.lock().await.remove(&transfer_id) {
                drop(transfer.file);
                let _ = tokio::fs::remove_file(&transfer.temp_path).await;
            }
            if let Ok(data_server) = get_or_init_data_server(app, &manager).await {
                data_server.remove_download(&transfer_id).await;
                if let Some(upload) = data_server.remove_upload(&transfer_id).await {
                    let _ = tokio::fs::remove_file(&upload.temp_path).await;
                }
            }
            let _ = app.emit("coudrop-cancel", msg);
        }
        _ => {}
    }
}

/// Returns device presence of the paired phone connected over the Coucou TLS link.
#[tauri::command]
pub async fn coudrop_get_device(link: State<'_, PhoneLink>) -> Result<VayliDropDevice, String> {
    if let Some(dev) = link.hub.connected_device() {
        Ok(VayliDropDevice {
            connected: true,
            name: dev.name,
            can_drop: dev.can_drop,
        })
    } else {
        Ok(VayliDropDevice {
            connected: false,
            name: String::new(),
            can_drop: false,
        })
    }
}

fn detect_mime_type(path: &Path) -> &'static str {
    let ext = path.extension().and_then(|e| e.to_str()).unwrap_or("").to_lowercase();
    match ext.as_str() {
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "svg" => "image/svg+xml",
        "pdf" => "application/pdf",
        "mp4" => "video/mp4",
        "mov" => "video/quicktime",
        "mp3" => "audio/mpeg",
        "zip" => "application/zip",
        "tar" | "gz" => "application/gzip",
        "json" => "application/json",
        "txt" | "md" | "rs" | "ts" | "js" | "kt" => "text/plain",
        _ => "application/octet-stream",
    }
}

fn collect_dir_files(dir: &Path, list: &mut Vec<PathBuf>) {
    if let Ok(entries) = std::fs::read_dir(dir) {
        for entry in entries.flatten() {
            let p = entry.path();
            if p.is_file() {
                list.push(p);
            } else if p.is_dir() {
                collect_dir_files(&p, list);
            }
        }
    }
}

/// Send one or more files from Desktop to the connected Android device in streaming chunks or direct binary stream.
#[tauri::command]
pub async fn coudrop_send_files(
    app: AppHandle,
    link: State<'_, PhoneLink>,
    state: State<'_, CoudropManager>,
    paths: Vec<String>,
) -> Result<(), String> {
    let _dev = link
        .hub
        .connected_device()
        .ok_or_else(|| "No paired phone connected. Make sure your phone is connected on the same Wi-Fi network.".to_string())?;

    let mut resolved_paths: Vec<PathBuf> = Vec::new();
    for p_str in paths {
        let cleaned = p_str.trim().trim_matches('"');
        let path = if cleaned.starts_with("file:///") {
            PathBuf::from(&cleaned[8..])
        } else if cleaned.starts_with("file://") {
            PathBuf::from(&cleaned[7..])
        } else {
            PathBuf::from(cleaned)
        };

        if !path.exists() {
            crate::log::line(format!("coudrop_send_files: path does not exist: {:?}", path));
            continue;
        }

        if path.is_file() {
            resolved_paths.push(path);
        } else if path.is_dir() {
            collect_dir_files(&path, &mut resolved_paths);
        }
    }

    if resolved_paths.is_empty() {
        return Err("No valid files found to send.".to_string());
    }

    state.is_sending.store(true, Ordering::SeqCst);

    for path in resolved_paths {
        if !state.is_sending.load(Ordering::SeqCst) {
            break;
        }

        let file_name = path
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_else(|| "file.bin".to_string());

        let total_bytes = tokio::fs::metadata(&path).await.map(|m| m.len()).unwrap_or(0);
        let mime_type = detect_mime_type(&path);
        let transfer_id = generate_token();
        let token = generate_token();

        *state.current_transfer_id.lock().await = Some(transfer_id.clone());
        *state.current_transfer_name.lock().await = Some(file_name.clone());
        *state.current_transfer_size.lock().await = total_bytes;
        *state.current_transfer_direction.lock().await = Some("send".to_string());
        state.is_paused.store(false, Ordering::SeqCst);
        state.is_cancelled.store(false, Ordering::SeqCst);

        let data_server = get_or_init_data_server(&app, &state).await?;
        let _completed_hash_handle = data_server
            .register_download(
                transfer_id.clone(),
                file_name.clone(),
                path.clone(),
                token.clone(),
                total_bytes,
            )
            .await;

        // 1. Send dropOffer to phone advertising Protocol V2
        let offer_msg = serde_json::json!({
            "type": "dropOffer",
            "transferId": transfer_id.clone(),
            "name": file_name.clone(),
            "size": total_bytes,
            "sha256": "", // Verified on the fly in single pass
            "mimeType": mime_type,
            "protocolVersion": 2,
            "dataPort": data_server.port(),
            "token": token
        }).to_string();

        link.hub
            .send_drop_async(&offer_msg)
            .await
            .map_err(|e| {
                state.is_sending.store(false, Ordering::SeqCst);
                format!("Failed to deliver transfer offer to phone: {}", e)
            })?;

        let _ = app.emit("coudrop-transfer-started", serde_json::json!({
            "transferId": transfer_id.clone(),
            "name": file_name.clone(),
            "totalBytes": total_bytes,
            "direction": "send"
        }));

        // 2. Wait for dropAccept (or reject) with timeout
        let accept_fut = async {
            loop {
                if let Some((id, accepted, proto_ver)) = state.last_accept_status.lock().await.take() {
                    if id == transfer_id {
                        return (accepted, proto_ver);
                    }
                }
                state.accept_notify.notified().await;
            }
        };

        let (accepted, peer_proto_ver) = match tokio::time::timeout(Duration::from_secs(8), accept_fut).await {
            Ok((true, ver)) => (true, ver),
            Ok((false, _)) => {
                state.is_sending.store(false, Ordering::SeqCst);
                data_server.remove_download(&transfer_id).await;
                return Err("Phone rejected the file transfer.".to_string());
            }
            Err(_) => {
                // Timeout or older version, proceed with v1 fallback
                (true, 1)
            }
        };

        let done_res: Result<(), String> = if accepted && peer_proto_ver >= 2 {
            // ── COUDROP PROTOCOL V2: DIRECT HIGH-SPEED BINARY STREAM ─────────
            // Phone connects to GET /coudrop/v2/download/{transfer_id}
            // DataServer handles streaming with adaptive buffer and updates progress.
            let done_fut = async {
                loop {
                    if state.is_cancelled.load(Ordering::SeqCst) {
                        return Err("Transfer cancelled by user".to_string());
                    }
                    if let Some((id, reason)) = state.last_reject_status.lock().await.take() {
                        if id == transfer_id {
                            return Err(format!("Transfer rejected by phone: {reason}"));
                        }
                    }
                    if let Some((id, _hash)) = state.last_done_status.lock().await.take() {
                        if id == transfer_id {
                            return Ok(());
                        }
                    }
                    state.done_notify.notified().await;
                }
            };

            let res = match tokio::time::timeout(Duration::from_secs(3600), done_fut).await {
                Ok(r) => r,
                Err(_) => Err("Transfer timed out waiting for phone completion".to_string()),
            };
            data_server.remove_download(&transfer_id).await;
            res
        } else {
            // ── FALLBACK: V1 CHUNKED BASE64 TLS FRAMING ───────────────────────
            data_server.remove_download(&transfer_id).await;

            const CHUNK_SIZE: usize = 32 * 1024;
            let total_chunks = if total_bytes == 0 {
                1
            } else {
                ((total_bytes + CHUNK_SIZE as u64 - 1) / CHUNK_SIZE as u64) as usize
            };

            let mut file = match tokio::fs::File::open(&path).await {
                Ok(f) => f,
                Err(e) => {
                    state.is_sending.store(false, Ordering::SeqCst);
                    return Err(format!("Failed to read file {}: {}", file_name, e));
                }
            };

            let mut digest_ctx = ring::digest::Context::new(&SHA256);
            let mut buffer = vec![0u8; CHUNK_SIZE];
            let mut chunk_index = 0usize;
            let mut bytes_sent = 0u64;

            let start_time = std::time::Instant::now();
            let mut window_start = start_time;
            let mut window_bytes = 0u64;
            let mut current_speed = 0u64;

            loop {
                if !state.is_sending.load(Ordering::SeqCst) || state.is_cancelled.load(Ordering::SeqCst) {
                    let cancel_msg = serde_json::json!({
                        "type": "dropCancel",
                        "transferId": transfer_id.clone(),
                        "reason": "cancelled_by_desktop"
                    }).to_string();
                    let _ = link.hub.send_drop_async(&cancel_msg).await;
                    let _ = app.emit("coudrop-cancel", ());
                    return Ok(());
                }

                while state.is_paused.load(Ordering::SeqCst) {
                    if !state.is_sending.load(Ordering::SeqCst) || state.is_cancelled.load(Ordering::SeqCst) {
                        break;
                    }
                    state.pause_notify.notified().await;
                }

                if !state.is_sending.load(Ordering::SeqCst) || state.is_cancelled.load(Ordering::SeqCst) {
                    let cancel_msg = serde_json::json!({
                        "type": "dropCancel",
                        "transferId": transfer_id.clone(),
                        "reason": "cancelled_by_desktop"
                    }).to_string();
                    let _ = link.hub.send_drop_async(&cancel_msg).await;
                    let _ = app.emit("coudrop-cancel", ());
                    return Ok(());
                }

                let n = if total_bytes == 0 {
                    0
                } else {
                    use tokio::io::AsyncReadExt;
                    file.read(&mut buffer)
                        .await
                        .map_err(|e| format!("Read error on {}: {}", file_name, e))?
                };

                if n == 0 && total_bytes > 0 {
                    break;
                }

                digest_ctx.update(&buffer[..n]);
                let b64 = base64_encode(&buffer[..n]);
                let chunk_msg = serde_json::json!({
                    "type": "dropChunk",
                    "transferId": transfer_id.clone(),
                    "index": chunk_index,
                    "total": total_chunks,
                    "data": b64
                }).to_string();

                link.hub
                    .send_drop_async(&chunk_msg)
                    .await
                    .map_err(|e| format!("Chunk send failed: {}", e))?;

                bytes_sent += n as u64;
                let progress = if total_bytes > 0 {
                    (bytes_sent as f64 / total_bytes as f64).min(1.0)
                } else {
                    1.0
                };

                let now = std::time::Instant::now();
                let elapsed = (now - window_start).as_secs_f64();
                if elapsed >= 0.25 {
                    let diff = bytes_sent.saturating_sub(window_bytes);
                    current_speed = (diff as f64 / elapsed) as u64;
                    window_start = now;
                    window_bytes = bytes_sent;
                }
                let remaining_bytes = total_bytes.saturating_sub(bytes_sent);
                let eta = if current_speed > 0 && remaining_bytes > 0 {
                    Some(remaining_bytes / current_speed)
                } else {
                    None
                };
                let is_paused = state.is_paused.load(Ordering::SeqCst);

                let _ = app.emit("coudrop-progress", TransferProgress {
                    transfer_id: Some(transfer_id.clone()),
                    name: file_name.clone(),
                    bytes_read: bytes_sent,
                    total_bytes,
                    progress,
                    speed_bytes_per_sec: Some(current_speed),
                    time_remaining_seconds: eta,
                    direction: Some("send".to_string()),
                    is_paused: Some(is_paused),
                });

                chunk_index += 1;
                if total_bytes == 0 || bytes_sent >= total_bytes {
                    break;
                }

                tokio::task::yield_now().await;
            }

            let computed_hash = hex_encode(digest_ctx.finish().as_ref());
            let done_msg = serde_json::json!({
                "type": "dropDone",
                "transferId": transfer_id.clone(),
                "sha256": computed_hash
            }).to_string();
            let _ = link.hub.send_drop_async(&done_msg).await;

            let done_fut = async {
                loop {
                    if state.is_cancelled.load(Ordering::SeqCst) {
                        return Err("Transfer cancelled by user".to_string());
                    }
                    if let Some((id, reason)) = state.last_reject_status.lock().await.take() {
                        if id == transfer_id {
                            return Err(format!("Transfer rejected by phone: {reason}"));
                        }
                    }
                    if let Some((id, _hash)) = state.last_done_status.lock().await.take() {
                        if id == transfer_id {
                            return Ok(());
                        }
                    }
                    state.done_notify.notified().await;
                }
            };
            match tokio::time::timeout(Duration::from_secs(15), done_fut).await {
                Ok(r) => r,
                Err(_) => Err("Transfer timed out waiting for phone acknowledgement".to_string()),
            }
        };

        if let Err(e) = done_res {
            state.is_sending.store(false, Ordering::SeqCst);
            *state.current_transfer_id.lock().await = None;
            return Err(e);
        }

        let path_str = path.to_string_lossy().to_string();

        let _ = app.emit("coudrop-file-sent", ReceivedFileInfo {
            name: file_name,
            path: path_str,
            size: total_bytes,
        });
    }

    state.is_sending.store(false, Ordering::SeqCst);
    *state.current_transfer_id.lock().await = None;

    Ok(())
}

/// Cancels an ongoing send operation.
#[tauri::command]
pub async fn coudrop_cancel_send(
    app: AppHandle,
    link: State<'_, PhoneLink>,
    state: State<'_, CoudropManager>,
) -> Result<(), String> {
    coudrop_cancel_transfer(app, link, state, None).await
}

/// Pauses an active transfer (either send or receive).
#[tauri::command]
pub async fn coudrop_pause_transfer(
    app: AppHandle,
    link: State<'_, PhoneLink>,
    state: State<'_, CoudropManager>,
    transfer_id: Option<String>,
) -> Result<(), String> {
    state.is_paused.store(true, Ordering::SeqCst);
    let id = match transfer_id {
        Some(i) => i,
        None => state.current_transfer_id.lock().await.clone().unwrap_or_default(),
    };
    if !id.is_empty() {
        let pause_msg = serde_json::json!({
            "type": "dropPause",
            "transferId": id.clone(),
        }).to_string();
        let _ = link.hub.send_drop_async(&pause_msg).await;
    }
    let _ = app.emit("coudrop-transfer-paused", serde_json::json!({ "transferId": id }));
    Ok(())
}

/// Resumes a paused transfer (either send or receive).
#[tauri::command]
pub async fn coudrop_resume_transfer(
    app: AppHandle,
    link: State<'_, PhoneLink>,
    state: State<'_, CoudropManager>,
    transfer_id: Option<String>,
) -> Result<(), String> {
    state.is_paused.store(false, Ordering::SeqCst);
    state.pause_notify.notify_waiters();
    let id = match transfer_id {
        Some(i) => i,
        None => state.current_transfer_id.lock().await.clone().unwrap_or_default(),
    };
    if !id.is_empty() {
        let resume_msg = serde_json::json!({
            "type": "dropResume",
            "transferId": id.clone(),
        }).to_string();
        let _ = link.hub.send_drop_async(&resume_msg).await;
    }
    let _ = app.emit("coudrop-transfer-resumed", serde_json::json!({ "transferId": id }));
    Ok(())
}

/// Cancels an ongoing transfer (either send or receive).
#[tauri::command]
pub async fn coudrop_cancel_transfer(
    app: AppHandle,
    link: State<'_, PhoneLink>,
    state: State<'_, CoudropManager>,
    transfer_id: Option<String>,
) -> Result<(), String> {
    state.is_sending.store(false, Ordering::SeqCst);
    state.is_cancelled.store(true, Ordering::SeqCst);
    state.is_paused.store(false, Ordering::SeqCst);
    state.pause_notify.notify_waiters();
    state.done_notify.notify_waiters();
    state.accept_notify.notify_waiters();

    let id = match transfer_id {
        Some(i) => i,
        None => state.current_transfer_id.lock().await.take().unwrap_or_default(),
    };

    if !id.is_empty() {
        // Clean up any incoming partial file in manager
        if let Some(transfer) = state.incoming.lock().await.remove(&id) {
            drop(transfer.file);
            let _ = tokio::fs::remove_file(&transfer.temp_path).await;
        }

        // Clean up DataServer if V2 was used
        if let Ok(data_server) = get_or_init_data_server(&app, &state).await {
            data_server.remove_download(&id).await;
            if let Some(upload) = data_server.remove_upload(&id).await {
                let _ = tokio::fs::remove_file(&upload.temp_path).await;
            }
        }

        let cancel_msg = serde_json::json!({
            "type": "dropCancel",
            "transferId": id.clone(),
            "reason": "cancelled_by_user"
        }).to_string();
        let _ = link.hub.send_drop_async(&cancel_msg).await;
    } else {
        // Clean up any remaining incoming transfers
        let mut incoming = state.incoming.lock().await;
        for (_, transfer) in incoming.drain() {
            drop(transfer.file);
            let _ = tokio::fs::remove_file(&transfer.temp_path).await;
        }
    }

    *state.current_transfer_id.lock().await = None;
    *state.current_transfer_name.lock().await = None;
    *state.current_transfer_size.lock().await = 0;
    *state.current_transfer_direction.lock().await = None;

    let _ = app.emit("coudrop-cancel", serde_json::json!({ "transferId": id }));
    Ok(())
}

/// Returns the currently active transfer if there is one ongoing.
#[tauri::command]
pub async fn coudrop_get_active_transfer(
    state: State<'_, CoudropManager>,
) -> Result<Option<ActiveTransferInfo>, String> {
    let id_opt = state.current_transfer_id.lock().await.clone();
    if let Some(id) = id_opt {
        let is_paused = state.is_paused.load(Ordering::SeqCst);
        let direction = state.current_transfer_direction.lock().await.clone().unwrap_or_else(|| "send".to_string());

        if direction == "receive" {
            let incoming = state.incoming.lock().await;
            if let Some(t) = incoming.get(&id) {
                let progress = if t.size > 0 {
                    (t.bytes_received as f64 / t.size as f64).min(1.0)
                } else {
                    0.0
                };
                let rem = t.size.saturating_sub(t.bytes_received);
                let eta = if t.current_speed > 0 && rem > 0 {
                    Some(rem / t.current_speed)
                } else {
                    None
                };
                return Ok(Some(ActiveTransferInfo {
                    id: t.transfer_id.clone(),
                    direction: "receive".to_string(),
                    name: t.name.clone(),
                    total_bytes: t.size,
                    bytes_transferred: t.bytes_received,
                    progress,
                    speed_bytes_per_sec: t.current_speed,
                    time_remaining_seconds: eta,
                    is_paused,
                    status: if is_paused { "paused".to_string() } else { "transferring".to_string() },
                }));
            }
        } else {
            let name = state.current_transfer_name.lock().await.clone().unwrap_or_else(|| "file.bin".to_string());
            let total = *state.current_transfer_size.lock().await;
            return Ok(Some(ActiveTransferInfo {
                id,
                direction: "send".to_string(),
                name,
                total_bytes: total,
                bytes_transferred: 0,
                progress: 0.0,
                speed_bytes_per_sec: 0,
                time_remaining_seconds: None,
                is_paused,
                status: if is_paused { "paused".to_string() } else { "transferring".to_string() },
            }));
        }
    }
    Ok(None)
}

/// Returns history of transferred files in Vayli Drop downloads directory.
#[tauri::command]
pub async fn coudrop_get_history() -> Result<Vec<ReceivedFileInfo>, String> {
    let dir = coudrop_dir();
    let mut files = Vec::new();

    if let Ok(mut entries) = tokio::fs::read_dir(&dir).await {
        while let Ok(Some(entry)) = entries.next_entry().await {
            let path = entry.path();
            if path.is_file() {
                let name = path.file_name().unwrap_or_default().to_string_lossy().to_string();
                if name.starts_with('.') || name.ends_with(".tmp") {
                    continue;
                }
                let size = entry.metadata().await.map(|m| m.len()).unwrap_or(0);
                files.push(ReceivedFileInfo {
                    name,
                    path: path.to_string_lossy().to_string(),
                    size,
                });
            }
        }
    }

    Ok(files)
}

#[tauri::command]
pub async fn coudrop_open_folder() -> Result<(), String> {
    let dir = coudrop_dir();
    #[cfg(target_os = "windows")]
    {
        let _ = std::process::Command::new("explorer")
            .arg(&dir)
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = std::process::Command::new("xdg-open").arg(&dir).spawn();
    }
    Ok(())
}

#[tauri::command]
pub async fn coudrop_open_file(path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err(format!("File does not exist: {path}"));
    }
    server::open_file(&p)
}

// Opens native system file picker dialog to pick one or more files to send
#[tauri::command]
pub async fn coudrop_pick_files(app: AppHandle) -> Result<Vec<String>, String> {
    let current = crate::settings::load().coudrop_download_dir;
    let start = if current.is_empty() { None } else { Some(current.as_str()) };
    let chosen = crate::platform::pick_files(&app, start, "Select files to send to phone");
    Ok(chosen.unwrap_or_default())
}

// Backward compatibility commands
#[tauri::command]
pub async fn coudrop_start_receive(
    link: State<'_, PhoneLink>,
) -> Result<VayliDropDevice, String> {
    coudrop_get_device(link).await
}

#[tauri::command]
pub async fn coudrop_cancel(
    app: AppHandle,
    state: State<'_, CoudropManager>,
    link: State<'_, PhoneLink>,
) -> Result<(), String> {
    coudrop_cancel_transfer(app, link, state, None).await
}

#[tauri::command]
pub async fn coudrop_status(
    link: State<'_, PhoneLink>,
) -> Result<VayliDropDevice, String> {
    coudrop_get_device(link).await
}

#[tauri::command]
pub async fn coudrop_stage_send_files(paths: Vec<String>) -> Result<Vec<String>, String> {
    Ok(paths)
}

/// Opens the system folder picker and returns the chosen path, or null if cancelled.
#[tauri::command]
pub async fn coudrop_pick_download_dir(app: AppHandle) -> Result<Option<String>, String> {
    let current = crate::settings::load().coudrop_download_dir;
    let start = if current.is_empty() { None } else { Some(current.as_str()) };
    let chosen = crate::platform::pick_folder(&app, start, "Choose Coudrop download folder");
    Ok(chosen)
}

/// Persists the user-chosen Coudrop download folder (empty string = use default).
#[tauri::command]
pub async fn coudrop_set_download_dir(path: String) -> Result<(), String> {
    let mut settings = crate::settings::load();
    settings.coudrop_download_dir = path.trim().to_string();
    crate::settings::save(&settings).map_err(|e| e.to_string())
}

/// Returns the currently configured Coudrop download folder path.
#[tauri::command]
pub async fn coudrop_get_download_dir() -> Result<String, String> {
    Ok(crate::settings::load().coudrop_download_dir)
}
