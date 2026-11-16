// Vayli Drop — shared utilities (windows/src-tauri/src/coudrop/server.rs)
// The QR-based HTTP server has been replaced by the Zero-QR device-aware
// architecture that reuses the existing authenticated Coucou TLS link.
// This file keeps only the utilities still referenced by coudrop/mod.rs.

use std::path::{Path, PathBuf};

use ring::rand::{SecureRandom, SystemRandom};
use serde::{Deserialize, Serialize};

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
}

// ── Destination directory ─────────────────────────────────────────────────────

/// Returns the user-configured Coudrop download folder, or the default
/// `%USERPROFILE%\Downloads\Coudrop` when none is configured.
/// Creates the directory if it does not yet exist.
pub fn coudrop_dir() -> PathBuf {
    // Read from persisted settings; fall back to default when empty.
    let configured = crate::settings::load().coudrop_download_dir;
    if !configured.is_empty() {
        let dir = PathBuf::from(&configured);
        let _ = std::fs::create_dir_all(&dir);
        return dir;
    }
    // Default: %USERPROFILE%\Downloads\Coudrop
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
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// Standard Base64 encoder used for chunk framing over the TLS link.
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

/// Standard Base64 decoder used for incoming chunk framing over the TLS link.
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

// ── File helpers ──────────────────────────────────────────────────────────────

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

// ── Tests ─────────────────────────────────────────────────────────────────────

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
        // "Man" → "TWFu" per RFC 4648
        assert_eq!(base64_encode(b"Man"), "TWFu");
        // empty slice
        assert_eq!(base64_encode(b""), "");
        // one byte: 0x00 → "AA=="
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
    fn base64_decode_rfc_vectors() {
        assert_eq!(base64_decode("TWFu").unwrap(), b"Man");
        assert_eq!(base64_decode("").unwrap(), b"");
        assert_eq!(base64_decode("AA==").unwrap(), &[0x00]);
    }
}
