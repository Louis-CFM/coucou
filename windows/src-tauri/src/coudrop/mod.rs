// Vayli Drop zero-QR device-aware file transfer module (windows/src-tauri/src/coudrop/mod.rs)
// Directly uses the existing Coucou Desktop <-> Android authenticated connection.

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
    base64_decode, base64_encode, coudrop_dir, generate_token, unique_path,
    ReceivedFileInfo, TransferProgress,
};

#[derive(Clone, Serialize, Deserialize, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct VayliDropDevice {
    pub connected: bool,
    pub name: String,
    pub can_drop: bool,
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
}

pub struct CoudropManager {
    is_sending: Arc<AtomicBool>,
    current_transfer_id: Mutex<Option<String>>,
    incoming: Mutex<HashMap<String, IncomingTransfer>>,
    accept_notify: Arc<Notify>,
    last_accept_status: Mutex<Option<(String, bool)>>,
    done_notify: Arc<Notify>,
    last_done_status: Mutex<Option<(String, String)>>,
}

impl Default for CoudropManager {
    fn default() -> Self {
        Self {
            is_sending: Arc::new(AtomicBool::new(false)),
            current_transfer_id: Mutex::new(None),
            incoming: Mutex::new(HashMap::new()),
            accept_notify: Arc::new(Notify::new()),
            last_accept_status: Mutex::new(None),
            done_notify: Arc::new(Notify::new()),
            last_done_status: Mutex::new(None),
        }
    }
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
            let raw_name = msg["name"].as_str().unwrap_or("file.bin");
            let sanitized_name = Path::new(raw_name)
                .file_name()
                .map(|f| f.to_string_lossy().to_string())
                .unwrap_or_else(|| "file.bin".to_string());
            let size = msg["size"].as_u64().unwrap_or(0);
            let sha256 = msg["sha256"].as_str().unwrap_or("").to_string();

            let dir = coudrop_dir();
            let temp_path = dir.join(format!(".coudrop_{}.tmp", &transfer_id));

            match tokio::fs::File::create(&temp_path).await {
                Ok(file) => {
                    let transfer = IncomingTransfer {
                        transfer_id: transfer_id.clone(),
                        name: sanitized_name.clone(),
                        size,
                        expected_sha256: sha256,
                        temp_path,
                        file,
                        digest_ctx: ring::digest::Context::new(&SHA256),
                        bytes_received: 0,
                    };
                    manager.incoming.lock().await.insert(transfer_id.clone(), transfer);

                    // Send dropAccept back to phone
                    let accept_msg = serde_json::json!({
                        "type": "dropAccept",
                        "transferId": transfer_id.clone(),
                    }).to_string();
                    let _ = link.hub.send_drop_async(&accept_msg).await;

                    // Emit transfer started (receiving)
                    let _ = app.emit("coudrop-transfer-started", serde_json::json!({
                        "transferId": transfer_id.clone(),
                        "name": sanitized_name.clone(),
                        "totalBytes": size,
                        "direction": "receive"
                    }));

                    // Emit starting progress
                    let _ = app.emit("coudrop-progress", TransferProgress {
                        transfer_id: Some(transfer_id.clone()),
                        name: sanitized_name,
                        bytes_read: 0,
                        total_bytes: size,
                        progress: 0.0,
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
                            (transfer.bytes_received as f64 / transfer.size as f64).min(1.0)
                        } else {
                            1.0
                        };

                        let _ = app.emit("coudrop-progress", TransferProgress {
                            transfer_id: Some(transfer.transfer_id.clone()),
                            name: transfer.name.clone(),
                            bytes_read: transfer.bytes_received,
                            total_bytes: transfer.size,
                            progress,
                        });
                    }
                }
            }
        }
        "dropDone" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("");
            let reported_sha256 = msg["sha256"].as_str().unwrap_or("");

            // 1. Notify any outgoing transfer awaiting acknowledgement (Desktop -> Android)
            {
                *manager.last_done_status.lock().await = Some((transfer_id.to_string(), reported_sha256.to_string()));
                manager.done_notify.notify_waiters();
            }

            // 2. Finalize any incoming transfer (Android -> Desktop)
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

                // On Windows, handle file locks / delay before rename with small retry backoff
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
        "dropAccept" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            *manager.last_accept_status.lock().await = Some((transfer_id, true));
            manager.accept_notify.notify_waiters();
            let _ = app.emit("coudrop-accept", msg);
        }
        "dropReject" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("").to_string();
            *manager.last_accept_status.lock().await = Some((transfer_id, false));
            manager.accept_notify.notify_waiters();
            let _ = app.emit("coudrop-reject", msg);
        }
        "dropProgress" => {
            // Android sends dropProgress as an inbound acknowledgement while receiving chunks.
            // The desktop sender loop already emits verified monotonically increasing TransferProgress
            // with exact bytesSent, totalBytes, and fileName. Emitting raw unmapped msg here was causing
            // progress to flicker between 0% and actual progress due to missing/differing field names.
            let _ = app.emit("coudrop-peer-progress", msg);
        }
        "dropCancel" => {
            let transfer_id = msg["transferId"].as_str().unwrap_or("");
            if let Some(transfer) = manager.incoming.lock().await.remove(transfer_id) {
                drop(transfer.file);
                let _ = tokio::fs::remove_file(&transfer.temp_path).await;
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

/// Computes the SHA-256 hex string and byte count of a file via chunked async streaming.
async fn compute_file_sha256(path: &Path) -> Result<(u64, String), String> {
    use tokio::io::AsyncReadExt;
    let mut file = tokio::fs::File::open(path)
        .await
        .map_err(|e| format!("Failed to open file {}: {}", path.display(), e))?;
    let mut context = ring::digest::Context::new(&SHA256);
    let mut buffer = [0u8; 64 * 1024];
    let mut total_bytes = 0u64;

    loop {
        let n = file
            .read(&mut buffer)
            .await
            .map_err(|e| format!("Failed to read file {}: {}", path.display(), e))?;
        if n == 0 {
            break;
        }
        context.update(&buffer[..n]);
        total_bytes += n as u64;
    }

    let digest = context.finish();
    Ok((total_bytes, hex_encode(digest.as_ref())))
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

/// Send one or more files from Desktop to the connected Android device in streaming chunks over the TLS link.
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

    state.is_sending.store(true, Ordering::SeqCst);

    for path_str in paths {
        if !state.is_sending.load(Ordering::SeqCst) {
            break;
        }

        let path = PathBuf::from(&path_str);
        if !path.exists() {
            continue;
        }

        let file_name = path
            .file_name()
            .map(|f| f.to_string_lossy().to_string())
            .unwrap_or_else(|| "file.bin".to_string());

        let (total_bytes, sha256_hex) = compute_file_sha256(&path).await?;
        let mime_type = detect_mime_type(&path);
        let transfer_id = generate_token();

        *state.current_transfer_id.lock().await = Some(transfer_id.clone());

        // 1. Send dropOffer to phone
        let offer_msg = serde_json::json!({
            "type": "dropOffer",
            "transferId": transfer_id.clone(),
            "name": file_name.clone(),
            "size": total_bytes,
            "sha256": sha256_hex,
            "mimeType": mime_type
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
                if let Some((id, accepted)) = state.last_accept_status.lock().await.take() {
                    if id == transfer_id {
                        return accepted;
                    }
                }
                state.accept_notify.notified().await;
            }
        };
        match tokio::time::timeout(Duration::from_secs(8), accept_fut).await {
            Ok(true) => {} // Phone accepted
            Ok(false) => {
                state.is_sending.store(false, Ordering::SeqCst);
                return Err("Phone rejected the file transfer.".to_string());
            }
            _ => {
                // Timeout or older version, proceed with streaming
            }
        }

        // 3. Stream chunks directly from disk (32 KiB chunks)
        const CHUNK_SIZE: usize = 32 * 1024;
        let total_chunks = if total_bytes == 0 {
            1
        } else {
            ((total_bytes + CHUNK_SIZE as u64 - 1) / CHUNK_SIZE as u64) as usize
        };

        let mut file = tokio::fs::File::open(&path)
            .await
            .map_err(|e| format!("Failed to read file {}: {}", file_name, e))?;

        let mut buffer = vec![0u8; CHUNK_SIZE];
        let mut chunk_index = 0usize;
        let mut bytes_sent = 0u64;

        loop {
            if !state.is_sending.load(Ordering::SeqCst) {
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

            let _ = app.emit("coudrop-progress", TransferProgress {
                transfer_id: Some(transfer_id.clone()),
                name: file_name.clone(),
                bytes_read: bytes_sent,
                total_bytes,
                progress,
            });

            chunk_index += 1;
            if total_bytes == 0 || bytes_sent >= total_bytes {
                break;
            }

            tokio::task::yield_now().await;
        }

        // 4. Wait for phone's completion acknowledgement
        let done_fut = async {
            loop {
                if let Some((id, _hash)) = state.last_done_status.lock().await.take() {
                    if id == transfer_id {
                        return true;
                    }
                }
                state.done_notify.notified().await;
            }
        };
        let _ = tokio::time::timeout(Duration::from_secs(8), done_fut).await;

        // Notify desktop frontend that sending completed successfully
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
    link: State<'_, PhoneLink>,
    state: State<'_, CoudropManager>,
) -> Result<(), String> {
    state.is_sending.store(false, Ordering::SeqCst);
    if let Some(transfer_id) = state.current_transfer_id.lock().await.take() {
        let cancel_msg = serde_json::json!({
            "type": "dropCancel",
            "transferId": transfer_id,
            "reason": "cancelled_by_desktop"
        }).to_string();
        let _ = link.hub.send_drop_async(&cancel_msg).await;
    }
    Ok(())
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
    state: State<'_, CoudropManager>,
    link: State<'_, PhoneLink>,
) -> Result<(), String> {
    coudrop_cancel_send(link, state).await
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

fn hex_encode(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
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
