// OpenAI OAuth (PKCE) and Chat completions for Mochi.
//
// Implements Issue #17: 'Sign in with ChatGPT' OAuth flow for open-source / local apps,
// storing access and refresh tokens in Windows Credential Manager / Secret Service,
// with automatic token renewal and direct chat completion turns.
//
// Hard rule (CLAUDE.md): zero telemetry, secrets stay in the OS credential store,
// network requests go only to the configured services.

use std::sync::atomic::{AtomicBool, Ordering};
use std::time::Duration;

use serde::Serialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpListener;

use crate::claude::{Chat, ChatContext, ChatReply};
use crate::log;
use crate::secrets;

pub const DEFAULT_OPENAI_MODEL: &str = "gpt-4o";

// Standard OpenAI OAuth endpoints
const AUTH_URL: &str = "https://auth.openai.com/oauth/authorize";
const TOKEN_URL: &str = "https://auth.openai.com/oauth/token";
const CHAT_ENDPOINT: &str = "https://api.openai.com/v1/chat/completions";

// Default client id for local / open-source OAuth integration
const CLIENT_ID: &str = "coucou-mochi-desktop";
const CALLBACK_PORT: u16 = 14555;
const CALLBACK_URI: &str = "http://127.0.0.1:14555/auth/callback";

static AUTH_IN_PROGRESS: AtomicBool = AtomicBool::new(false);

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ChatGPTStatus {
    pub signed_in: bool,
    pub email: Option<String>,
    pub has_api_key: bool,
}

pub fn status() -> ChatGPTStatus {
    let signed_in = secrets::present("openai-oauth-token");
    let email = secrets::get("openai-account-email");
    let has_api_key = secrets::present("openai-api-key");
    ChatGPTStatus {
        signed_in,
        email,
        has_api_key,
    }
}

pub fn sign_out() -> Result<(), String> {
    let _ = secrets::clear("openai-oauth-token");
    let _ = secrets::clear("openai-refresh-token");
    let _ = secrets::clear("openai-account-email");
    Ok(())
}

/// Initiates the OAuth PKCE flow:
/// 1. Generates code_verifier & code_challenge (S256).
/// 2. Starts local HTTP server on 127.0.0.1:14555 to catch the redirect.
/// 3. Opens the browser to OpenAI authorization page.
/// 4. Exchanges authorization code for tokens and stores them in Credential Manager.
pub async fn start_oauth(app: AppHandle) -> Result<String, String> {
    if AUTH_IN_PROGRESS.swap(true, Ordering::SeqCst) {
        return Err("Authentication is already in progress.".into());
    }

    let result = run_oauth_flow(app.clone()).await;
    AUTH_IN_PROGRESS.store(false, Ordering::SeqCst);
    let _ = app.emit("chatgpt-auth-changed", ());
    result
}

async fn run_oauth_flow(app: AppHandle) -> Result<String, String> {
    let verifier = generate_random_string(48);
    let challenge = base64url(&sha256(verifier.as_bytes()));
    let state = generate_random_string(24);

    let listener = TcpListener::bind(format!("127.0.0.1:{CALLBACK_PORT}"))
        .await
        .map_err(|e| format!("Cannot start local OAuth callback listener on port {CALLBACK_PORT}: {e}"))?;

    let auth_url = format!(
        "{AUTH_URL}?client_id={CLIENT_ID}&response_type=code&redirect_uri={}&scope=openid%20profile%20email%20model.request%20offline_access&code_challenge={challenge}&code_challenge_method=S256&state={state}",
        urlencoding(CALLBACK_URI)
    );

    log::line("opening browser for ChatGPT OAuth sign-in");
    crate::platform::open_url(&auth_url);

    // Wait for the browser redirect callback with a 2-minute timeout
    let (mut stream, _) = match tokio::time::timeout(Duration::from_secs(120), listener.accept()).await {
        Ok(Ok(pair)) => pair,
        Ok(Err(e)) => return Err(format!("Connection error: {e}")),
        Err(_) => return Err("Sign-in timed out. Please try again.".into()),
    };

    let mut buf = [0u8; 4096];
    let n = stream.read(&mut buf).await.map_err(|e| e.to_string())?;
    let request_str = String::from_utf8_lossy(&buf[..n]);

    let first_line = request_str.lines().next().unwrap_or_default();
    let query_path = first_line
        .split_whitespace()
        .nth(1)
        .unwrap_or_default();

    let query_params = parse_query(query_path);
    let code = query_params.get("code").cloned();
    let returned_state = query_params.get("state").cloned();
    let error_param = query_params.get("error").cloned();

    // Serve a friendly HTML response to the browser tab
    let html_body = if code.is_some() {
        r#"<!DOCTYPE html><html><head><meta charset="utf-8"><title>Coucou — Signed In</title><style>body{font-family:system-ui,-apple-system,sans-serif;background:#0d0f12;color:#ffffff;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}.card{text-align:center;padding:40px;background:#181b20;border-radius:18px;border:1px solid #2d333b;box-shadow:0 12px 36px rgba(0,0,0,0.5);max-width:360px;}h2{margin:0 0 8px;font-size:22px;}p{color:#8b949e;margin:0 0 16px;font-size:14px;}.badge{display:inline-block;padding:6px 14px;background:#22c55e22;color:#22c55e;border-radius:20px;font-weight:600;font-size:13px;margin-bottom:12px;}</style></head><body><div class="card"><div class="badge">✓ Connected</div><h2>Welcome to Coucou</h2><p>Your ChatGPT account is now connected. You can close this window and return to Mochi.</p></div></body></html>"#
    } else {
        r#"<!DOCTYPE html><html><head><meta charset="utf-8"><title>Coucou — Sign-in Failed</title><style>body{font-family:system-ui,-apple-system,sans-serif;background:#0d0f12;color:#ffffff;display:flex;align-items:center;justify-content:center;height:100vh;margin:0;}.card{text-align:center;padding:40px;background:#181b20;border-radius:18px;border:1px solid #2d333b;max-width:360px;}h2{margin:0 0 8px;font-size:22px;color:#f4505e;}p{color:#8b949e;margin:0;font-size:14px;}</style></head><body><div class="card"><h2>Sign-in Incomplete</h2><p>Could not complete ChatGPT sign-in. Please return to Coucou and try again.</p></div></body></html>"#
    };

    let response = format!(
        "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{}",
        html_body.len(),
        html_body
    );
    let _ = stream.write_all(response.as_bytes()).await;
    let _ = stream.flush().await;

    if let Some(err) = error_param {
        return Err(format!("OpenAI OAuth error: {err}"));
    }

    if returned_state.as_deref() != Some(&state) {
        return Err("State mismatch in OAuth response.".into());
    }

    let Some(code) = code else {
        return Err("No authorization code received from browser.".into());
    };

    // Exchange authorization code for tokens
    exchange_code_for_tokens(&code, &verifier).await
}

async fn exchange_code_for_tokens(code: &str, verifier: &str) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;

    let params = [
        ("grant_type", "authorization_code"),
        ("client_id", CLIENT_ID),
        ("code", code),
        ("redirect_uri", CALLBACK_URI),
        ("code_verifier", verifier),
    ];

    let res = client
        .post(TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Failed to reach OpenAI token endpoint: {e}"))?;

    let status = res.status();
    let text = res.text().await.map_err(|e| e.to_string())?;

    if !status.is_success() {
        return Err(format!("Token exchange failed ({status}): {text}"));
    }

    let json: Value = serde_json::from_str(&text).map_err(|e| format!("Invalid token response JSON: {e}"))?;

    let access_token = json
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "No access_token in OAuth response.".to_string())?;

    let refresh_token = json.get("refresh_token").and_then(Value::as_str);

    // Save tokens in Credential Manager
    secrets::set("openai-oauth-token", access_token)?;
    if let Some(rf) = refresh_token {
        let _ = secrets::set("openai-refresh-token", rf);
    }

    // Try extracting email from id_token claims if available
    if let Some(id_token) = json.get("id_token").and_then(Value::as_str) {
        if let Some(email) = extract_jwt_email(id_token) {
            let _ = secrets::set("openai-account-email", &email);
            return Ok(email);
        }
    }

    let email = "ChatGPT Account".to_string();
    let _ = secrets::set("openai-account-email", &email);
    Ok(email)
}

/// Refreshes the OAuth access token using the stored refresh token.
pub async fn refresh_access_token() -> Result<String, String> {
    let Some(refresh_token) = secrets::get("openai-refresh-token") else {
        return Err("No refresh token stored.".into());
    };

    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(30))
        .build()
        .map_err(|e| e.to_string())?;

    let params = [
        ("grant_type", "refresh_token"),
        ("client_id", CLIENT_ID),
        ("refresh_token", &refresh_token),
    ];

    let res = client
        .post(TOKEN_URL)
        .form(&params)
        .send()
        .await
        .map_err(|e| format!("Failed to refresh token: {e}"))?;

    let status = res.status();
    let text = res.text().await.map_err(|e| e.to_string())?;

    if !status.is_success() {
        let _ = sign_out();
        return Err(format!("Token refresh expired ({status}). Please sign in again."));
    }

    let json: Value = serde_json::from_str(&text).map_err(|e| format!("Invalid token response JSON: {e}"))?;
    let new_access = json
        .get("access_token")
        .and_then(Value::as_str)
        .ok_or_else(|| "No access_token in refresh response.".to_string())?;

    secrets::set("openai-oauth-token", new_access)?;
    if let Some(new_rf) = json.get("refresh_token").and_then(Value::as_str) {
        let _ = secrets::set("openai-refresh-token", new_rf);
    }

    Ok(new_access.to_string())
}

/// Executes one chat turn using OpenAI / ChatGPT.
pub async fn send_chat(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let mut token = secrets::get("openai-oauth-token")
        .or_else(|| secrets::get("openai-api-key"))
        .ok_or_else(|| "OpenAI / ChatGPT is not signed in. Open settings to sign in or add an API key.".to_string())?;

    let mut user_text = String::new();
    if chat_is_empty(chat) {
        if let Some(ctx) = context {
            match ctx {
                ChatContext::File { name, path } => {
                    if let Ok(content) = std::fs::read_to_string(&path) {
                        let truncated: String = content.chars().take(8000).collect();
                        user_text.push_str(&format!("[Context File: {name}]\n{truncated}\n\n"));
                    } else {
                        user_text.push_str(&format!("[Context File: {name}]\n\n"));
                    }
                }
                ChatContext::Window { app_name, title, url } => {
                    user_text.push_str(&format!("[Context Window — App: {app_name}, Title: {title}"));
                    if let Some(u) = url {
                        user_text.push_str(&format!(", URL: {u}"));
                    }
                    user_text.push_str("]\n\n");
                }
            }
        }
    }
    user_text.push_str(&query);

    chat.push(json!({ "role": "user", "content": user_text }));

    let system_msg = json!({
        "role": "system",
        "content": "You are Mochi, a friendly, helpful AI living at the top of the user's screen. Keep answers concise, clear, and direct. Use plain text formatting."
    });

    let mut messages = vec![system_msg];
    messages.extend(chat.snapshot());

    let payload = json!({
        "model": model,
        "messages": messages,
        "max_tokens": 4096
    });

    // Make request (with 1 automatic retry on 401 using refresh token)
    let reply_text = match call_openai(&token, &payload).await {
        Ok(text) => text,
        Err(err) if err.contains("401") && secrets::present("openai-refresh-token") => {
            log::line("OAuth token expired, attempting token refresh...");
            match refresh_access_token().await {
                Ok(new_token) => {
                    token = new_token;
                    call_openai(&token, &payload).await?
                }
                Err(refresh_err) => {
                    chat.pop();
                    return Err(refresh_err);
                }
            }
        }
        Err(err) => {
            chat.pop();
            return Err(err);
        }
    };

    chat.push(json!({ "role": "assistant", "content": reply_text }));
    Ok(ChatReply { text: reply_text })
}

async fn call_openai(token: &str, body: &Value) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let res = client
        .post(CHAT_ENDPOINT)
        .header("Authorization", format!("Bearer {token}"))
        .header("Content-Type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = res.status();
    let text = res.text().await.map_err(|e| e.to_string())?;

    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| {
                v.get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .map(str::to_string)
            })
            .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(format!("OpenAI API ({status}): {detail}"));
    }

    let json: Value = serde_json::from_str(&text).map_err(|e| format!("Bad JSON response: {e}"))?;
    let content = json
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .ok_or_else(|| "No reply message in OpenAI response.".to_string())?;

    Ok(content.trim().to_string())
}

fn chat_is_empty(chat: &Chat) -> bool {
    chat.snapshot().is_empty()
}

// ── Helpers & Pure Rust Cryptography ──────────────────────────────────────────

fn parse_query(path_and_query: &str) -> std::collections::HashMap<String, String> {
    let mut map = std::collections::HashMap::new();
    if let Some(pos) = path_and_query.find('?') {
        let query = &path_and_query[pos + 1..];
        for pair in query.split('&') {
            let mut parts = pair.splitn(2, '=');
            if let (Some(k), Some(v)) = (parts.next(), parts.next()) {
                map.insert(urldecode(k), urldecode(v));
            }
        }
    }
    map
}

fn urldecode(s: &str) -> String {
    let mut res = Vec::new();
    let bytes = s.as_bytes();
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' && i + 2 < bytes.len() {
            if let Ok(byte) = u8::from_str_radix(std::str::from_utf8(&bytes[i + 1..i + 3]).unwrap_or(""), 16) {
                res.push(byte);
                i += 3;
                continue;
            }
        } else if bytes[i] == b'+' {
            res.push(b' ');
            i += 1;
            continue;
        }
        res.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&res).to_string()
}

fn urlencoding(s: &str) -> String {
    let mut out = String::new();
    for b in s.bytes() {
        match b {
            b'a'..=b'z' | b'A'..=b'Z' | b'0'..=b'9' | b'-' | b'_' | b'.' | b'~' => {
                out.push(b as char);
            }
            _ => {
                out.push_str(&format!("%{b:02X}"));
            }
        }
    }
    out
}

fn generate_random_string(length: usize) -> String {
    use std::time::SystemTime;
    let seed = SystemTime::now()
        .duration_since(SystemTime::UNIX_EPOCH)
        .map(|d| d.as_nanos())
        .unwrap_or(123456789);

    const CHARS: &[u8] = b"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~";
    let mut res = String::with_capacity(length);
    let mut val = seed;
    for i in 0..length {
        val = val.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407 + i as u128);
        let idx = (val % (CHARS.len() as u128)) as usize;
        res.push(CHARS[idx] as char);
    }
    res
}

fn extract_jwt_email(jwt: &str) -> Option<String> {
    let parts: Vec<&str> = jwt.split('.').collect();
    if parts.len() < 2 {
        return None;
    }
    let payload = base64_url_decode(parts[1])?;
    let json: Value = serde_json::from_slice(&payload).ok()?;
    json.get("email")
        .and_then(Value::as_str)
        .map(str::to_string)
        .or_else(|| json.get("name").and_then(Value::as_str).map(str::to_string))
}

fn base64_url_decode(s: &str) -> Option<Vec<u8>> {
    let mut standard = s.replace('-', "+").replace('_', "/");
    while standard.len() % 4 != 0 {
        standard.push('=');
    }
    const TABLE: &[u8; 256] = &{
        let mut t = [255u8; 256];
        let b = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
        let mut i = 0;
        while i < 64 {
            t[b[i] as usize] = i as u8;
            i += 1;
        }
        t
    };

    let mut out = Vec::new();
    let bytes = standard.as_bytes();
    for chunk in bytes.chunks(4) {
        if chunk.len() < 4 {
            break;
        }
        let (c0, c1, c2, c3) = (chunk[0], chunk[1], chunk[2], chunk[3]);
        let (v0, v1) = (TABLE[c0 as usize], TABLE[c1 as usize]);
        if v0 == 255 || v1 == 255 {
            break;
        }
        out.push((v0 << 2) | (v1 >> 4));
        if c2 != b'=' {
            let v2 = TABLE[c2 as usize];
            if v2 == 255 {
                break;
            }
            out.push((v1 << 4) | (v2 >> 2));
            if c3 != b'=' {
                let v3 = TABLE[c3 as usize];
                if v3 == 255 {
                    break;
                }
                out.push((v2 << 6) | v3);
            }
        }
    }
    Some(out)
}

fn base64url(bytes: &[u8]) -> String {
    crate::claude::base64_for(bytes)
        .replace('+', "-")
        .replace('/', "_")
        .trim_end_matches('=')
        .to_string()
}

/// Standalone pure-Rust SHA-256 (RFC 6234) with zero extra dependencies.
fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h: [u32; 8] = [
        0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
        0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
    ];
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
        0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
        0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
        0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
        0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];

    let bit_len = (data.len() as u64) * 8;
    let mut msg = data.to_vec();
    msg.push(0x80);
    while (msg.len() + 8) % 64 != 0 {
        msg.push(0x00);
    }
    msg.extend_from_slice(&bit_len.to_be_bytes());

    for chunk in msg.chunks(64) {
        let mut w = [0u32; 64];
        for (i, w_val) in w.iter_mut().take(16).enumerate() {
            *w_val = u32::from_be_bytes([chunk[4 * i], chunk[4 * i + 1], chunk[4 * i + 2], chunk[4 * i + 3]]);
        }
        for i in 16..64 {
            let s0 = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let s1 = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }

        let mut a = h[0];
        let mut b = h[1];
        let mut c = h[2];
        let mut d = h[3];
        let mut e = h[4];
        let mut f = h[5];
        let mut g = h[6];
        let mut h_var = h[7];

        for i in 0..64 {
            let s1 = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let ch = (e & f) ^ ((!e) & g);
            let temp1 = h_var.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let temp2 = s0.wrapping_add(maj);

            h_var = g;
            g = f;
            f = e;
            e = d.wrapping_add(temp1);
            d = c;
            c = b;
            b = a;
            a = temp1.wrapping_add(temp2);
        }

        h[0] = h[0].wrapping_add(a);
        h[1] = h[1].wrapping_add(b);
        h[2] = h[2].wrapping_add(c);
        h[3] = h[3].wrapping_add(d);
        h[4] = h[4].wrapping_add(e);
        h[5] = h[5].wrapping_add(f);
        h[6] = h[6].wrapping_add(g);
        h[7] = h[7].wrapping_add(h_var);
    }

    let mut out = [0u8; 32];
    for (i, val) in h.iter().enumerate() {
        out[4 * i..4 * i + 4].copy_from_slice(&val.to_be_bytes());
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sha256_matches_known_vector() {
        let digest = sha256(b"hello world");
        let hex: String = digest.iter().map(|b| format!("{b:02x}")).collect();
        assert_eq!(hex, "b94d27b9934d3e08a52e52d7da7dabfac484efe37a5380ee9088f7ace2efcde9");
    }

    #[test]
    fn base64url_strips_padding() {
        let b = b"hello";
        let enc = base64url(b);
        assert!(!enc.contains('='));
        assert!(!enc.contains('+'));
        assert!(!enc.contains('/'));
    }
}
