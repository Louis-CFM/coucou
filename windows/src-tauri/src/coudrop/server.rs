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
use tokio_rustls::TlsAcceptor;

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

#[allow(dead_code)]
pub const STREAMING_BUFFER_SIZE: usize = 512 * 1024; // 512 KiB default buffer
pub const DEFAULT_DATA_PORT: u16 = 47822;

/// Tunes low-level TCP socket buffers on Windows to 2 MiB and enables SO_KEEPALIVE for maximum reliability over Wi-Fi.
#[cfg(windows)]
fn tune_tcp_socket(stream: &tokio::net::TcpStream) {
    use std::os::windows::io::AsRawSocket;
    let raw = stream.as_raw_socket();
    #[link(name = "ws2_32")]
    extern "system" {
        fn setsockopt(
            s: usize,
            level: i32,
            optname: i32,
            optval: *const i8,
            optlen: i32,
        ) -> i32;
    }
    const SOL_SOCKET: i32 = 0xffff;
    const SO_SNDBUF: i32 = 0x1001;
    const SO_RCVBUF: i32 = 0x1002;
    const SO_KEEPALIVE: i32 = 0x0008;
    let buf_size: i32 = 2 * 1024 * 1024; // 2 MiB socket buffer
    let keepalive_on: i32 = 1;
    unsafe {
        let _ = setsockopt(raw as usize, SOL_SOCKET, SO_RCVBUF, &buf_size as *const i32 as *const i8, std::mem::size_of::<i32>() as i32);
        let _ = setsockopt(raw as usize, SOL_SOCKET, SO_SNDBUF, &buf_size as *const i32 as *const i8, std::mem::size_of::<i32>() as i32);
        let _ = setsockopt(raw as usize, SOL_SOCKET, SO_KEEPALIVE, &keepalive_on as *const i32 as *const i8, std::mem::size_of::<i32>() as i32);
    }
}

#[cfg(not(windows))]
fn tune_tcp_socket(_stream: &tokio::net::TcpStream) {}

/// A 1.5-second sliding window throughput estimator that eliminates instantaneous Wi-Fi ACK jitter
/// while retaining fast adaptation to actual bandwidth changes.
#[derive(Debug, Clone)]
pub struct RollingSpeedEstimator {
    samples: std::collections::VecDeque<(std::time::Instant, u64)>,
    window_duration: std::time::Duration,
}

impl RollingSpeedEstimator {
    pub fn new(window_secs: f64) -> Self {
        Self {
            samples: std::collections::VecDeque::with_capacity(16),
            window_duration: std::time::Duration::from_secs_f64(window_secs),
        }
    }

    pub fn update(&mut self, total_bytes: u64, now: std::time::Instant) -> u64 {
        self.samples.push_back((now, total_bytes));
        while let Some(&(time, _)) = self.samples.front() {
            if now.duration_since(time) > self.window_duration && self.samples.len() > 2 {
                self.samples.pop_front();
            } else {
                break;
            }
        }
        if self.samples.len() < 2 {
            return 0;
        }
        let (oldest_time, oldest_bytes) = self.samples.front().unwrap();
        let elapsed = now.duration_since(*oldest_time).as_secs_f64();
        if elapsed <= 0.05 {
            return 0;
        }
        let bytes_delta = total_bytes.saturating_sub(*oldest_bytes);
        (bytes_delta as f64 / elapsed) as u64
    }
}

/// Computes an optimal streaming chunk size based on total transfer payload size.
pub fn adaptive_chunk_size(total_bytes: u64) -> usize {
    if total_bytes > 128 * 1024 * 1024 {
        1024 * 1024 // 1 MiB for large files (> 128 MB)
    } else if total_bytes > 16 * 1024 * 1024 {
        512 * 1024 // 512 KiB for medium files (16 MB - 128 MB)
    } else {
        256 * 1024 // 256 KiB for small files (< 16 MB)
    }
}

/// Purges abandoned `.coudrop_*.tmp` files from interrupted or crashed transfers older than `max_age`.
pub fn purge_stale_temp_files(dir: &Path, max_age: std::time::Duration) {
    let Ok(entries) = std::fs::read_dir(dir) else { return };
    let now = std::time::SystemTime::now();
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_file() {
            if let Some(file_name) = path.file_name().and_then(|f| f.to_str()) {
                if file_name.starts_with(".coudrop_") && file_name.ends_with(".tmp") {
                    if let Ok(meta) = entry.metadata() {
                        if let Ok(modified) = meta.modified() {
                            if let Ok(age) = now.duration_since(modified) {
                                if age > max_age {
                                    let _ = std::fs::remove_file(&path);
                                }
                            }
                        }
                    }
                }
            }
        }
    }
}

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
    tls_acceptor: Option<TlsAcceptor>,
    active_downloads: Arc<Mutex<HashMap<String, ActiveDownload>>>,
    active_uploads: Arc<Mutex<HashMap<String, ActiveUpload>>>,
    #[allow(dead_code)]
    shutdown_tx: tokio::sync::broadcast::Sender<()>,
}

impl DataServer {
    /// Starts the DataServer on `preferred_port` (default 47822) with optional TLS support.
    /// If preferred port is in use, seamlessly binds to an OS-assigned free port (port 0).
    pub async fn start(
        app: Option<AppHandle>,
        preferred_port: u16,
        tls_acceptor: Option<TlsAcceptor>,
    ) -> Result<Arc<Self>, String> {
        // Clean up any stale incomplete temp files from interrupted prior sessions
        purge_stale_temp_files(&coudrop_dir(), std::time::Duration::from_secs(6 * 3600));

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
            tls_acceptor,
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
                                    srv_clone.handle_incoming_stream(stream).await;
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

    async fn handle_incoming_stream(&self, stream: TcpStream) {
        let _ = stream.set_nodelay(true);
        tune_tcp_socket(&stream);

        // Connection sniffing: peek at first 3 bytes to detect TLS ClientHello (0x16, 0x03)
        let mut peek_buf = [0u8; 3];
        let is_tls = if let Ok(n) = stream.peek(&mut peek_buf).await {
            n >= 2 && peek_buf[0] == 0x16 && peek_buf[1] == 0x03
        } else {
            false
        };

        if is_tls {
            if let Some(ref acceptor) = self.tls_acceptor {
                match acceptor.accept(stream).await {
                    Ok(tls_stream) => {
                        self.handle_connection(tls_stream).await;
                    }
                    Err(e) => {
                        eprintln!("[coudrop-server] TLS handshake error: {e}");
                    }
                }
            } else {
                eprintln!("[coudrop-server] TLS ClientHello received but no TLS acceptor configured; falling back to direct stream");
                self.handle_connection(stream).await;
            }
        } else {
            self.handle_connection(stream).await;
        }
    }

    async fn handle_connection<S>(&self, mut stream: S)
    where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send,
    {
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

    async fn handle_upload<S>(
        &self,
        mut stream: S,
        transfer_id: &str,
        token: &str,
        offset: u64,
        content_length: Option<u64>,
        leftover: &[u8],
    ) where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send,
    {
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
        let chunk_size = adaptive_chunk_size(total_bytes);

        let file = match tokio::fs::OpenOptions::new()
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

        let mut buffered_file = tokio::io::BufWriter::with_capacity(chunk_size, file);
        let mut digest_ctx = ring::digest::Context::new(&SHA256);
        let mut body_bytes_read = offset;

        // Process leftover bytes from initial buffer
        if !leftover.is_empty() {
            if buffered_file.write_all(leftover).await.is_err() {
                return;
            }
            digest_ctx.update(leftover);
            body_bytes_read += leftover.len() as u64;
        }

        // Bounded producer-consumer channel: decouples high-speed socket reads from disk writes + hashing.
        // A depth of 4 provides smooth pipelined execution while bounding in-flight memory to ~4 MB.
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(4);

        let writer_handle = tokio::spawn(async move {
            let mut file = buffered_file;
            let mut digest = digest_ctx;
            while let Some(chunk) = rx.recv().await {
                if let Err(e) = file.write_all(&chunk).await {
                    return Err(format!("Disk write error: {e}"));
                }
                digest.update(&chunk);
            }
            if let Err(e) = file.flush().await {
                return Err(format!("Disk flush error: {e}"));
            }
            Ok(hex_encode(digest.finish().as_ref()))
        });

        let mut speed_estimator = RollingSpeedEstimator::new(1.5);
        let mut last_progress_emit = std::time::Instant::now();

        while total_bytes == 0 || body_bytes_read < total_bytes {
            let to_read = if total_bytes > 0 {
                std::cmp::min(chunk_size as u64, total_bytes - body_bytes_read) as usize
            } else {
                chunk_size
            };
            let mut buf = vec![0u8; to_read];
            let n = match stream.read(&mut buf).await {
                Ok(0) => break,
                Ok(n) => n,
                Err(_) => break,
            };
            buf.truncate(n);
            body_bytes_read += n as u64;

            if tx.send(buf).await.is_err() {
                break;
            }

            let now = std::time::Instant::now();
            if now.duration_since(last_progress_emit).as_secs_f64() >= 0.25 {
                let speed = speed_estimator.update(body_bytes_read, now);
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
                last_progress_emit = now;
            }
        }

        drop(tx); // EOF to writer

        match writer_handle.await {
            Ok(Ok(hash_str)) => {
                if total_bytes > 0 && body_bytes_read < total_bytes {
                    eprintln!("[coudrop-server] Upload stream interrupted: received {}/{} bytes", body_bytes_read, total_bytes);
                    let _ = stream.write_all(b"HTTP/1.1 400 Bad Request\r\nX-Coudrop-Error: incomplete_stream\r\nConnection: close\r\n\r\n").await;
                    let _ = stream.flush().await;
                    return;
                }
                *upload.completed_sha256.lock().await = Some(hash_str.clone());
                let resp = format!(
                    "HTTP/1.1 200 OK\r\nX-Coudrop-Sha256: {}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                    hash_str
                );
                let _ = stream.write_all(resp.as_bytes()).await;
                let _ = stream.flush().await;
            }
            Ok(Err(err)) => {
                eprintln!("[coudrop-server] Writer error for upload {}: {}", transfer_id, err);
                let _ = stream.write_all(b"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n").await;
            }
            Err(e) => {
                eprintln!("[coudrop-server] Writer task failed for upload {}: {}", transfer_id, e);
                let _ = stream.write_all(b"HTTP/1.1 500 Internal Server Error\r\nConnection: close\r\n\r\n").await;
            }
        }
    }

    async fn handle_download<S>(
        &self,
        mut stream: S,
        transfer_id: &str,
        token: &str,
        offset: u64,
    ) where
        S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin + Send,
    {
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
        let chunk_size = adaptive_chunk_size(remaining);

        let resp_header = if offset > 0 {
            let last_byte = download.size.saturating_sub(1);
            format!(
                "HTTP/1.1 206 Partial Content\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nContent-Range: bytes {}-{}/{}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                remaining, offset, last_byte, download.size
            )
        } else {
            format!(
                "HTTP/1.1 200 OK\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nAccept-Ranges: bytes\r\nConnection: close\r\n\r\n",
                remaining
            )
        };

        if stream.write_all(resp_header.as_bytes()).await.is_err() {
            return;
        }

        let mut buffered_file = tokio::io::BufReader::with_capacity(chunk_size, file);
        let (tx, mut rx) = tokio::sync::mpsc::channel::<Vec<u8>>(4);

        // Pipelined Reader & Hasher task: reads disk blocks and updates SHA-256 in parallel with network sends
        let reader_handle = tokio::spawn(async move {
            let mut digest_ctx = ring::digest::Context::new(&SHA256);
            let mut read_total = 0u64;
            while read_total < remaining {
                let to_read = std::cmp::min(chunk_size as u64, remaining - read_total) as usize;
                let mut buf = vec![0u8; to_read];
                let n = match buffered_file.read(&mut buf).await {
                    Ok(0) => break,
                    Ok(n) => n,
                    Err(_) => break,
                };
                buf.truncate(n);
                digest_ctx.update(&buf);
                read_total += n as u64;
                if tx.send(buf).await.is_err() {
                    break;
                }
            }
            hex_encode(digest_ctx.finish().as_ref())
        });

        let mut bytes_sent = 0u64;
        let mut speed_estimator = RollingSpeedEstimator::new(1.5);
        let mut last_progress_emit = std::time::Instant::now();

        while let Some(chunk) = rx.recv().await {
            let n = chunk.len() as u64;
            if stream.write_all(&chunk).await.is_err() {
                break;
            }
            bytes_sent += n;

            let now = std::time::Instant::now();
            if now.duration_since(last_progress_emit).as_secs_f64() >= 0.25 {
                let speed = speed_estimator.update(bytes_sent, now);
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
                last_progress_emit = now;
            }
        }

        let _ = stream.flush().await;

        let hash_str = reader_handle.await.unwrap_or_default();
        if bytes_sent >= remaining && !hash_str.is_empty() {
            *download.completed_sha256.lock().await = Some(hash_str);
        }
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

    #[test]
    fn test_adaptive_chunk_size_scaling() {
        assert_eq!(adaptive_chunk_size(10 * 1024 * 1024), 256 * 1024); // < 16 MB -> 256 KiB
        assert_eq!(adaptive_chunk_size(64 * 1024 * 1024), 512 * 1024); // 16 MB - 128 MB -> 512 KiB
        assert_eq!(adaptive_chunk_size(500 * 1024 * 1024), 1024 * 1024); // > 128 MB -> 1 MiB
        assert_eq!(adaptive_chunk_size(5 * 1024 * 1024 * 1024), 1024 * 1024); // 5 GB -> 1 MiB
    }

    #[test]
    fn test_rolling_speed_estimator_smoothing() {
        let mut est = RollingSpeedEstimator::new(1.5);
        let start = std::time::Instant::now();

        // Single sample: speed is 0
        assert_eq!(est.update(1000, start), 0);

        // Advance 0.5s with 50 MB
        let t1 = start + std::time::Duration::from_millis(500);
        let speed1 = est.update(50 * 1024 * 1024, t1);
        assert!(speed1 > 90_000_000, "speed should be around 100 MB/s");

        // Advance another 0.5s with another 50 MB (total 100 MB in 1.0s)
        let t2 = start + std::time::Duration::from_millis(1000);
        let speed2 = est.update(100 * 1024 * 1024, t2);
        assert!(speed2 > 90_000_000 && speed2 < 110_000_000);
    }

    #[tokio::test]
    async fn test_dataserver_upload_download() {
        let server = DataServer::start(None, 0, None).await.expect("start server");
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
