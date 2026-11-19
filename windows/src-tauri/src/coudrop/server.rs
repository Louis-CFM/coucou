// Vayli Drop — high-performance binary streaming data server and utilities
// windows/src-tauri/src/coudrop/server.rs

use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::Arc;

use ring::digest::SHA256;
use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncReadExt, AsyncSeekExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::Mutex;

// ── Shared transfer data types ────────────────────────────────────────────────

#[derive(Clone, Serialize, Deserialize, Debug)]
#[serde(rename_all = "camelCase")]
pub struct ReceivedFileInfo {
    pub name: String,
    pub path: String,
    pub size: u64,
}

#[derive(Clone, Serialize, Deserialize, Debug, Default)]
#[serde(rename_all = "camelCase")]
pub struct TransferProgress {
    #[serde(skip_serializing_if = "Option::is_none")]
    pub transfer_id: Option<String>,
    pub name: String,
    pub bytes_read: u64,
    pub total_bytes: u64,
    pub progress: f64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub speed_bytes_per_sec: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub time_remaining_seconds: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub direction: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub is_paused: Option<bool>,
}

// ── Destination directory ─────────────────────────────────────────────────────

/// Returns the user-configured Coudrop download folder, or the default
/// `%USERPROFILE%\Downloads\Coudrop` when none is configured.
/// Creates the directory if it does not yet exist.
pub fn coudrop_dir() -> PathBuf {
    let configured = crate::settings::load().coudrop_download_dir;
    if !configured.is_empty() {
        let dir = PathBuf::from(&configured);
        let _ = std::fs::create_dir_all(&dir);
        return dir;
    }
    let base = std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .map(|h| h.join("Downloads"))
        .unwrap_or_else(|| crate::platform::local_dir());
    let dir = base.join("Coudrop");
    let _ = std::fs::create_dir_all(&dir);
    dir
}

// ── Cryptographic helpers ─────────────────────────────────────────────────────

/// Generates a cryptographically secure 128-bit (32 hex character) transfer token.
pub fn generate_token() -> String {
    let rng = SystemRandom::new();
    let mut bytes = [0u8; 16];
    let _ = rng.fill(&mut bytes);
    hex_encode(&bytes)
}

pub fn hex_encode(data: &[u8]) -> String {
    data.iter().map(|b| format!("{b:02x}")).collect()
}

/// Standard Base64 encoder used for fallback V1 chunk framing over TLS link.
pub fn base64_encode(data: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    let mut i = 0;
    while i < data.len() {
        let b0 = data[i];
        let b1 = if i + 1 < data.len() { data[i + 1] } else { 0 };
        let b2 = if i + 2 < data.len() { data[i + 2] } else { 0 };

        out.push(ALPHABET[(b0 >> 2) as usize] as char);
        out.push(ALPHABET[(((b0 & 3) << 4) | (b1 >> 4)) as usize] as char);
        if i + 1 < data.len() {
            out.push(ALPHABET[(((b1 & 0x0f) << 2) | (b2 >> 6)) as usize] as char);
        } else {
            out.push('=');
        }
        if i + 2 < data.len() {
            out.push(ALPHABET[(b2 & 0x3f) as usize] as char);
        } else {
            out.push('=');
        }
        i += 3;
    }
    out
}

/// Standard Base64 decoder used for incoming fallback V1 chunk framing over TLS link.
pub fn base64_decode(input: &str) -> Result<Vec<u8>, String> {
    let mut out = Vec::with_capacity((input.len() * 3) / 4);
    let mut buf = 0u32;
    let mut bits = 0u32;

    for byte in input.bytes() {
        let val = match byte {
            b'A'..=b'Z' => (byte - b'A') as u32,
            b'a'..=b'z' => (byte - b'a' + 26) as u32,
            b'0'..=b'9' => (byte - b'0' + 52) as u32,
            b'+' => 62,
            b'/' => 63,
            b'=' | b'\r' | b'\n' | b' ' | b'\t' => continue,
            other => return Err(format!("Invalid base64 character: {}", other as char)),
        };
        buf = (buf << 6) | val;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((buf >> bits) as u8);
            buf &= (1 << bits) - 1;
        }
    }
    Ok(out)
}

/// Generates a collision-free unique path in `dir` based on `name`.
pub fn unique_path(dir: &Path, name: &str) -> PathBuf {
    let sanitized = Path::new(name)
        .file_name()
        .map(|f| f.to_string_lossy().to_string())
        .unwrap_or_else(|| "file.bin".to_string());

    let target = dir.join(&sanitized);
    if !target.exists() {
        return target;
    }
    let p = Path::new(&sanitized);
    let stem = p.file_stem().and_then(|s| s.to_str()).unwrap_or("file");
    let ext = p.extension().and_then(|e| e.to_str()).map(|e| format!(".{e}")).unwrap_or_default();
    let mut i = 1;
    loop {
        let candidate = dir.join(format!("{stem} ({i}){ext}"));
        if !candidate.exists() {
            return candidate;
        }
        i += 1;
    }
}

/// Opens a file in the default registered application.
pub fn open_file(path: &Path) -> Result<(), String> {
    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        std::process::Command::new("cmd")
            .args(&["/c", "start", "", &path.to_string_lossy()])
            .creation_flags(0x08000000) // CREATE_NO_WINDOW
            .spawn()
            .map_err(|e| e.to_string())?;
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = std::process::Command::new("xdg-open").arg(path).spawn();
    }
    Ok(())
}

// ── CouDrop Protocol V2: High-Performance Dedicated DataServer ────────────────

pub const STREAMING_BUFFER_SIZE: usize = 512 * 1024; // 512 KiB buffer
pub const DEFAULT_DATA_PORT: u16 = 47822;

#[derive(Clone)]
pub struct ActiveDownload {
    pub transfer_id: String,
    pub name: String,
    pub path: PathBuf,
    pub token: String,
    pub size: u64,
    pub completed_sha256: Arc<Mutex<Option<String>>>,
}

#[derive(Clone)]
pub struct ActiveUpload {
    pub transfer_id: String,
    pub name: String,
    pub temp_path: PathBuf,
    pub token: String,
    pub size: u64,
    pub expected_sha256: String,
    pub completed_sha256: Arc<Mutex<Option<String>>>,
}

pub struct DataServer {
    port: u16,
    app: Option<AppHandle>,
    active_downloads: Arc<Mutex<HashMap<String, ActiveDownload>>>,
    active_uploads: Arc<Mutex<HashMap<String, ActiveUpload>>>,
    #[allow(dead_code)]
    shutdown_tx: tokio::sync::broadcast::Sender<()>,
}

impl DataServer {
    /// Starts the DataServer on `preferred_port` (default 47822).
    /// If preferred port is in use, seamlessly binds to an OS-assigned free port (port 0).
    pub async fn start(app: Option<AppHandle>, preferred_port: u16) -> Result<Arc<Self>, String> {
        let listener = match TcpListener::bind(("0.0.0.0", preferred_port)).await {
            Ok(l) => l,
            Err(_) => TcpListener::bind(("0.0.0.0", 0))
                .await
                .map_err(|e| format!("Failed to bind DataServer to any port: {e}"))?,
        };

        let port = listener.local_addr().map_err(|e| e.to_string())?.port();
        let (shutdown_tx, _) = tokio::sync::broadcast::channel(1);

        let active_downloads = Arc::new(Mutex::new(HashMap::new()));
        let active_uploads = Arc::new(Mutex::new(HashMap::new()));

        let server = Arc::new(Self {
            port,
            app,
            active_downloads: active_downloads.clone(),
            active_uploads: active_uploads.clone(),
            shutdown_tx: shutdown_tx.clone(),
        });

        let srv = server.clone();
        tokio::spawn(async move {
            let mut shutdown_rx = shutdown_tx.subscribe();
            loop {
                tokio::select! {
                    accept_res = listener.accept() => {
                        match accept_res {
                            Ok((stream, _peer_addr)) => {
                                let srv_clone = srv.clone();
                                tokio::spawn(async move {
                                    srv_clone.handle_connection(stream).await;
                                });
                            }
                            Err(e) => {
                                eprintln!("[coudrop-server] accept error: {e}");
                            }
                        }
                    }
                    _ = shutdown_rx.recv() => {
                        break;
                    }
                }
            }
        });

        Ok(server)
    }

    pub fn port(&self) -> u16 {
        self.port
    }

    pub async fn register_download(&self, transfer_id: String, name: String, path: PathBuf, token: String, size: u64) -> Arc<Mutex<Option<String>>> {
        let completed_sha256 = Arc::new(Mutex::new(None));
        self.active_downloads.lock().await.insert(
            transfer_id.clone(),
            ActiveDownload {
                transfer_id,
                name,
                path,
                token,
                size,
                completed_sha256: completed_sha256.clone(),
            },
        );
        completed_sha256
    }

    pub async fn register_upload(
        &self,
        transfer_id: String,
        name: String,
        temp_path: PathBuf,
        token: String,
        size: u64,
        expected_sha256: String,
    ) -> Arc<Mutex<Option<String>>> {
        let completed_sha256 = Arc::new(Mutex::new(None));
        self.active_uploads.lock().await.insert(
            transfer_id.clone(),
            ActiveUpload {
                transfer_id,
                name,
                temp_path,
                token,
                size,
                expected_sha256,
                completed_sha256: completed_sha256.clone(),
            },
        );
        completed_sha256
    }

    pub async fn remove_download(&self, transfer_id: &str) -> Option<ActiveDownload> {
        self.active_downloads.lock().await.remove(transfer_id)
    }

    pub async fn remove_upload(&self, transfer_id: &str) -> Option<ActiveUpload> {
        self.active_uploads.lock().await.remove(transfer_id)
    }

    #[allow(dead_code)]
    pub async fn get_upload_completed_hash(&self, transfer_id: &str) -> Option<String> {
        let uploads = self.active_uploads.lock().await;
        if let Some(upload) = uploads.get(transfer_id) {
            upload.completed_sha256.lock().await.clone()
        } else {
            None
        }
    }

    async fn handle_connection(&self, mut stream: TcpStream) {
        let _ = stream.set_nodelay(true);

        // Read HTTP request header
        let mut header_buf = Vec::with_capacity(4096);
        let mut temp_buf = [0u8; 1024];
        let mut header_end_idx = None;

        while header_buf.len() < 16384 {
            match stream.read(&mut temp_buf).await {
                Ok(0) => return,
                Ok(n) => {
                    header_buf.extend_from_slice(&temp_buf[..n]);
                    if let Some(pos) = find_subsequence(&header_buf, b"\r\n\r\n") {
                        header_end_idx = Some(pos);
                        break;
                    }
                }
                Err(_) => return,
            }
        }

        let header_end = match header_end_idx {
            Some(idx) => idx,
            None => {
                let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n").await;
                return;
            }
        };

        let header_str = match std::str::from_utf8(&header_buf[..header_end]) {
            Ok(s) => s,
            Err(_) => {
                let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n").await;
                return;
            }
        };

        let mut lines = header_str.lines();
        let request_line = match lines.next() {
            Some(line) => line,
            None => return,
        };

        let parts: Vec<&str> = request_line.split_whitespace().collect();
        if parts.len() < 2 {
            let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nConnection: close\r\n\r\n").await;
            return;
        }

        let method = parts[0];
        let path = parts[1];

        // Parse headers
        let mut token = String::new();
        let mut offset = 0u64;
        let mut content_length: Option<u64> = None;

        for line in lines {
            let (key, val) = match line.split_once(':') {
                Some((k, v)) => (k.trim().to_lowercase(), v.trim()),
                None => continue,
            };
            if key == "x-coudrop-token" {
                token = val.to_string();
            } else if key == "x-coudrop-offset" {
                offset = val.parse::<u64>().unwrap_or(0);
            } else if key == "range" {
                // e.g. bytes=1000-
                if let Some(pos) = val.strip_prefix("bytes=") {
                    if let Some(idx) = pos.find('-') {
                        offset = pos[..idx].trim().parse::<u64>().unwrap_or(offset);
                    }
                }
            } else if key == "content-length" {
                content_length = val.parse::<u64>().ok();
            }
        }

        // Routing:
        // POST /coudrop/v2/upload/{id}
        // GET  /coudrop/v2/download/{id}
        if method == "POST" && path.starts_with("/coudrop/v2/upload/") {
            let transfer_id = &path["/coudrop/v2/upload/".len()..];
            self.handle_upload(stream, transfer_id, &token, offset, content_length, &header_buf[header_end + 4..]).await;
        } else if method == "GET" && path.starts_with("/coudrop/v2/download/") {
            let transfer_id = &path["/coudrop/v2/download/".len()..];
            self.handle_download(stream, transfer_id, &token, offset).await;
        } else {
            let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n").await;
        }
    }

    async fn handle_upload(
        &self,
        mut stream: TcpStream,
        transfer_id: &str,
        token: &str,
        offset: u64,
        content_length: Option<u64>,
        leftover: &[u8],
    ) {
        let upload = {
            let uploads = self.active_uploads.lock().await;
            match uploads.get(transfer_id).cloned() {
                Some(u) => u,
                None => {
                    let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n").await;
                    return;
                }
            }
        };

        if upload.token != token {
            eprintln!("[coudrop-server] 403 Forbidden on upload: token mismatch for {}", transfer_id);
            let _ = stream.write_all(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n").await;
            return;
        }

        let total_bytes = content_length.unwrap_or(upload.size);

        let mut file = match tokio::fs::OpenOptions::new()
            .write(true)
            .create(true)
            .truncate(offset == 0)
            .append(offset > 0)
            .open(&upload.temp_path)
            .await
        {
            Ok(f) => f,
            Err(e) => {
                eprintln!("[coudrop-server] Error opening temp file {:?}: {}", upload.temp_path, e);
                let _ = stream.write_all(b"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n").await;
                return;
            }
        };

        let mut digest_ctx = ring::digest::Context::new(&SHA256);
        let mut body_bytes_read = offset;

        // Process leftover bytes from initial buffer
        if !leftover.is_empty() {
            if file.write_all(leftover).await.is_err() {
                return;
            }
            digest_ctx.update(leftover);
            body_bytes_read += leftover.len() as u64;
        }

        let mut buf = vec![0u8; STREAMING_BUFFER_SIZE];
        let mut last_progress_time = std::time::Instant::now();
        let mut last_progress_bytes = body_bytes_read;

        while total_bytes == 0 || body_bytes_read < total_bytes {
            let n = match stream.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };

            if file.write_all(&buf[..n]).await.is_err() {
                break;
            }
            digest_ctx.update(&buf[..n]);
            body_bytes_read += n as u64;

            let now = std::time::Instant::now();
            let elapsed = (now - last_progress_time).as_secs_f64();
            if elapsed >= 0.25 {
                let speed = ((body_bytes_read.saturating_sub(last_progress_bytes)) as f64 / elapsed) as u64;
                let progress = if total_bytes > 0 {
                    (body_bytes_read as f64 / total_bytes as f64).min(0.99)
                } else {
                    0.0
                };
                let eta = if speed > 0 && total_bytes > body_bytes_read {
                    Some((total_bytes - body_bytes_read) / speed)
                } else {
                    None
                };

                if let Some(ref a) = self.app {
                    let _ = a.emit("coudrop-progress", TransferProgress {
                        transfer_id: Some(upload.transfer_id.clone()),
                        name: upload.name.clone(),
                        bytes_read: body_bytes_read,
                        total_bytes,
                        progress,
                        speed_bytes_per_sec: Some(speed),
                        time_remaining_seconds: eta,
                        direction: Some("receive".to_string()),
                        is_paused: Some(false),
                    });
                }
                last_progress_time = now;
                last_progress_bytes = body_bytes_read;
            }
        }

        let _ = file.flush().await;
        drop(file);

        let hash_str = hex_encode(digest_ctx.finish().as_ref());
        *upload.completed_sha256.lock().await = Some(hash_str.clone());

        // Send 200 OK back to phone
        let resp = format!(
            "HTTP/1.1 200 OK\r\nX-Coudrop-Sha256: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
            hash_str
        );
        let _ = stream.write_all(resp.as_bytes()).await;
        let _ = stream.flush().await;
    }

    async fn handle_download(
        &self,
        mut stream: TcpStream,
        transfer_id: &str,
        token: &str,
        offset: u64,
    ) {
        let download = {
            let downloads = self.active_downloads.lock().await;
            match downloads.get(transfer_id).cloned() {
                Some(d) => d,
                None => {
                    let _ = stream.write_all(b"HTTP/1.1 404 Not Found\r\nConnection: close\r\n\r\n").await;
                    return;
                }
            }
        };

        if download.token != token {
            eprintln!("[coudrop-server] 403 Forbidden on download: token mismatch for {}", transfer_id);
            let _ = stream.write_all(b"HTTP/1.1 403 Forbidden\r\nConnection: close\r\n\r\n").await;
            return;
        }

        let mut file = match tokio::fs::File::open(&download.path).await {
            Ok(f) => f,
            Err(e) => {
                eprintln!("[coudrop-server] Error opening file {:?}: {}", download.path, e);
                let _ = stream.write_all(b"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n").await;
                return;
            }
        };

        if offset > 0 {
            if file.seek(std::io::SeekFrom::Start(offset)).await.is_err() {
                let _ = stream.write_all(b"HTTP/1.1 416 Range Not Satisfiable\r\nConnection: close\r\n\r\n").await;
                return;
            }
        }

        let remaining = download.size.saturating_sub(offset);
        let resp_header = format!(
            "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            remaining
        );

        if stream.write_all(resp_header.as_bytes()).await.is_err() {
            return;
        }

        let mut digest_ctx = ring::digest::Context::new(&SHA256);
        let mut buf = vec![0u8; STREAMING_BUFFER_SIZE];
        let mut bytes_sent = 0u64;
        let mut last_progress_time = std::time::Instant::now();
        let mut last_progress_bytes = 0u64;

        while bytes_sent < remaining {
            let to_read = std::cmp::min(buf.len() as u64, remaining - bytes_sent) as usize;
            let n = match file.read(&mut buf[..to_read]).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };

            if stream.write_all(&buf[..n]).await.is_err() {
                break;
            }
            digest_ctx.update(&buf[..n]);
            bytes_sent += n as u64;

            let now = std::time::Instant::now();
            let elapsed = (now - last_progress_time).as_secs_f64();
            if elapsed >= 0.25 {
                let speed = ((bytes_sent.saturating_sub(last_progress_bytes)) as f64 / elapsed) as u64;
                let progress = if download.size > 0 {
                    ((offset + bytes_sent) as f64 / download.size as f64).min(0.99)
                } else {
                    1.0
                };
                let eta = if speed > 0 && remaining > bytes_sent {
                    Some((remaining - bytes_sent) / speed)
                } else {
                    None
                };

                if let Some(ref a) = self.app {
                    let _ = a.emit("coudrop-progress", TransferProgress {
                        transfer_id: Some(download.transfer_id.clone()),
                        name: download.name.clone(),
                        bytes_read: offset + bytes_sent,
                        total_bytes: download.size,
                        progress,
                        speed_bytes_per_sec: Some(speed),
                        time_remaining_seconds: eta,
                        direction: Some("send".to_string()),
                        is_paused: Some(false),
                    });
                }
                last_progress_time = now;
                last_progress_bytes = bytes_sent;
            }
        }

        let _ = stream.flush().await;

        let hash_str = hex_encode(digest_ctx.finish().as_ref());
        *download.completed_sha256.lock().await = Some(hash_str);
    }
}

fn find_subsequence(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}

// ── Unit Tests ────────────────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generate_token_is_32_hex_chars() {
        let tok = generate_token();
        assert_eq!(tok.len(), 32, "token must be exactly 32 hex characters");
        assert!(tok.chars().all(|c| c.is_ascii_hexdigit()), "token must be hex");
    }

    #[test]
    fn base64_encode_known_vector() {
        assert_eq!(base64_encode(b"Man"), "TWFu");
        assert_eq!(base64_encode(b""), "");
        assert_eq!(base64_encode(&[0x00]), "AA==");
    }

    #[test]
    fn base64_decode_round_trip() {
        let original = b"Hello, Coucou file transfer over TLS! \x00\x01\x02\xff\xfe";
        let encoded = base64_encode(original);
        let decoded = base64_decode(&encoded).expect("valid base64");
        assert_eq!(decoded, original);
    }

    #[tokio::test]
    async fn test_dataserver_upload_download() {
        let server = DataServer::start(None, 0).await.expect("start server");
        let port = server.port();
        assert!(port > 0);

        let temp_dir = std::env::temp_dir().join(format!("coudrop_test_{}", port));
        let _ = std::fs::create_dir_all(&temp_dir);

        let upload_temp = temp_dir.join("test_upload.tmp");
        let token = "test_token_1234567890abcdef".to_string();
        let payload = b"CouDrop high-performance binary streaming payload! Testing Wi-Fi 6 optimization.";

        // Register upload
        let hash_future = server
            .register_upload(
                "transfer_test_1".to_string(),
                "file.bin".to_string(),
                upload_temp.clone(),
                token.clone(),
                payload.len() as u64,
                "".to_string(),
            )
            .await;

        // Connect and send HTTP POST with raw binary stream
        let mut client = TcpStream::connect(("127.0.0.1", port)).await.expect("connect");
        let req = format!(
            "POST /coudrop/v2/upload/transfer_test_1 HTTP/1.1\r\nHost: 127.0.0.1:{}\r\nX-Coudrop-Token: {}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            port, token, payload.len()
        );
        client.write_all(req.as_bytes()).await.unwrap();
        client.write_all(payload).await.unwrap();
        client.flush().await.unwrap();

        let mut resp = Vec::new();
        client.read_to_end(&mut resp).await.unwrap();
        let resp_str = String::from_utf8_lossy(&resp);
        assert!(resp_str.contains("200 OK"));

        // Verify written file matches payload
        let written = std::fs::read(&upload_temp).unwrap();
        assert_eq!(written, payload);

        // Verify incremental sha256
        let computed = hash_future.lock().await.clone().unwrap();
        assert!(!computed.is_empty());

        let _ = std::fs::remove_dir_all(&temp_dir);
    }
}
