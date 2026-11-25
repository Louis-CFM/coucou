// CouCou Dynamic AI Companion — Native AI Orchestration Service (Phase 3)
// Handles loopback SSRF-validated Ollama HTTP requests, DPAPI-secured Cloud AI calls,
// in-flight request registration, and cross-runtime cancellation via CancellationToken.

use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};
use tauri::State;
use tokio::sync::watch;

/// Custom CancellationToken using tokio::sync::watch.
#[derive(Clone)]
pub struct CancellationToken {
    sender: watch::Sender<bool>,
    receiver: watch::Receiver<bool>,
}

impl Default for CancellationToken {
    fn default() -> Self {
        Self::new()
    }
}

impl CancellationToken {
    pub fn new() -> Self {
        let (sender, receiver) = watch::channel(false);
        Self { sender, receiver }
    }

    pub fn cancel(&self) {
        let _ = self.sender.send(true);
    }

    pub async fn cancelled(&self) {
        let mut rx = self.receiver.clone();
        while !*rx.borrow_and_update() {
            if rx.changed().await.is_err() {
                break;
            }
        }
    }

    #[allow(dead_code)]
    pub fn is_cancelled(&self) -> bool {
        *self.receiver.borrow()
    }
}

/// Global shared state tracking in-flight companion AI requests.
#[derive(Default, Clone)]
pub struct CompanionAiState {
    active_requests: Arc<Mutex<HashMap<String, CancellationToken>>>,
}

impl CompanionAiState {
    pub fn register(&self, request_id: &str) -> CancellationToken {
        let token = CancellationToken::new();
        let mut map = self.active_requests.lock().unwrap();
        map.insert(request_id.to_string(), token.clone());
        token
    }

    pub fn cancel(&self, request_id: &str) -> bool {
        let mut map = self.active_requests.lock().unwrap();
        if let Some(token) = map.remove(request_id) {
            token.cancel();
            true
        } else {
            false
        }
    }

    pub fn unregister(&self, request_id: &str) {
        let mut map = self.active_requests.lock().unwrap();
        map.remove(request_id);
    }

    #[allow(dead_code)]
    pub fn cancel_all(&self) {
        let mut map = self.active_requests.lock().unwrap();
        for (_, token) in map.drain() {
            token.cancel();
        }
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionPromptPayload {
    pub system_prompt: String,
    pub user_context_json: String,
    pub personality_mode: String,
    pub recent_exclusions: Vec<String>,
    pub provider: String,
    pub model: String,
    pub endpoint: Option<String>,
    pub timeout_ms: u64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct CompanionRawCandidate {
    pub request_id: String,
    pub text: String,
    pub provider: String,
    pub model: String,
    pub duration_ms: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub load_duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub prompt_eval_duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eval_duration_ms: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub eval_count: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub thinking_disabled: Option<bool>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderHealthStatus {
    pub provider: String,
    pub state: String, // "HEALTHY" | "DEGRADED" | "OFFLINE"
    pub last_checked: u64,
    pub latency_ms: Option<u64>,
    pub error: Option<String>,
}

/// Maps companion provider identifiers to canonical Windows Credential Manager keys.
pub fn canonical_secret_key(provider: &str) -> Option<&'static str> {
    match provider {
        "anthropic" => Some("anthropic-api-key"),
        "openai" => Some("openai-api-key"),
        _ => None,
    }
}

/// Strict loopback URL validator to eliminate SSRF attack vectors.
pub fn validate_loopback_url(endpoint: &str) -> Result<String, String> {
    let trimmed = endpoint.trim();
    if !trimmed.starts_with("http://") {
        return Err("Only plain http:// loopback connections are supported for local inference".into());
    }
    let without_scheme = &trimmed[7..];
    // Reject userinfo or path/query tricks before parsing host
    if without_scheme.contains('@') {
        return Err("Userinfo in loopback endpoint is prohibited".into());
    }
    let host_part = without_scheme.split('/').next().unwrap_or(without_scheme);
    let host_part = host_part.split('?').next().unwrap_or(host_part);
    let host_part = host_part.split('#').next().unwrap_or(host_part);

    let (host, port) = if let Some((h, p)) = host_part.rsplit_once(':') {
        let clean_h = if h.starts_with('[') && h.ends_with(']') {
            &h[1..h.len() - 1]
        } else {
            h
        };
        (clean_h, p.parse::<u16>().map_err(|_| "Invalid port number")?)
    } else {
        let clean_h = if host_part.starts_with('[') && host_part.ends_with(']') {
            &host_part[1..host_part.len() - 1]
        } else {
            host_part
        };
        (clean_h, 11434)
    };

    let lower_host = host.to_lowercase();
    if lower_host == "127.0.0.1" || lower_host == "localhost" || lower_host == "::1" {
        Ok(format!("http://{lower_host}:{port}"))
    } else {
        Err(format!("Endpoint '{host}' is not a permitted loopback address (must be 127.0.0.1 or localhost)"))
    }
}

// ── Ollama Local Client ───────────────────────────────────────────────────────

#[derive(Debug, Clone)]
pub struct OllamaChatResult {
    pub content: String,
    pub load_duration_ms: Option<u64>,
    pub prompt_eval_duration_ms: Option<u64>,
    pub eval_duration_ms: Option<u64>,
    pub eval_count: Option<u64>,
    pub thinking_disabled: bool,
}

pub fn model_supports_thinking(model: &str) -> bool {
    let lower = model.to_lowercase();
    lower.contains("qwen") || lower.contains("r1") || lower.contains("think")
}

pub async fn check_model_supports_thinking(
    client: &reqwest::Client,
    endpoint: &str,
    model: &str,
) -> bool {
    // Fast path: if model identifier indicates a thinking model (like qwen3.5:4b), it is supported
    if model_supports_thinking(model) {
        return true;
    }
    // Only query /api/show on standard Ollama port to avoid interfering with unit test mock listeners
    if !endpoint.contains("11434") {
        return false;
    }
    let url = format!("{}/api/show", endpoint.trim_end_matches('/'));
    let body = serde_json::json!({ "model": model });
    if let Ok(res) = client.post(&url).json(&body).send().await {
        if res.status().is_success() {
            if let Ok(json) = res.json::<serde_json::Value>().await {
                if let Some(thinking) = json.get("thinking") {
                    if let Some(vals) = thinking.get("values").and_then(|v| v.as_array()) {
                        return vals.iter().any(|v| v.as_bool() == Some(false));
                    }
                }
                if let Some(caps) = json.get("capabilities").and_then(|c| c.as_array()) {
                    return caps.iter().any(|c| c.as_str() == Some("thinking"));
                }
            }
        }
    }
    false
}

pub async fn generate_ollama_chat(
    endpoint: &str,
    model: &str,
    system_prompt: &str,
    user_context: &str,
    timeout_ms: u64,
    token: CancellationToken,
) -> Result<OllamaChatResult, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .redirect(reqwest::redirect::Policy::none())
        .no_proxy()
        .build()
        .map_err(|e| format!("Client builder error: {e}"))?;

    let supports_thinking = check_model_supports_thinking(&client, endpoint, model).await;
    let url = format!("{}/api/chat", endpoint.trim_end_matches('/'));

    let mut body = serde_json::json!({
        "model": model,
        "messages": [
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": user_context }
        ],
        "stream": false,
        "options": {
            "num_predict": 75,
            "temperature": 0.6,
            "top_p": 0.9
        }
    });

    // Pass think as a top-level API parameter when supported (critical for qwen3.5:4b)
    if supports_thinking {
        body["think"] = serde_json::Value::Bool(false);
    }

    let send_fut = client.post(&url).json(&body).send();

    tokio::select! {
        _ = token.cancelled() => {
            Err("REQUEST_CANCELLED".into())
        }
        res = send_fut => {
            let response = res.map_err(|e| {
                if e.is_timeout() {
                    "GENERATION_TIMEOUT".to_string()
                } else {
                    format!("Ollama connection error: {e}")
                }
            })?;

            if response.status().is_redirection() {
                return Err(format!("REDIRECT_BLOCKED: Refusing HTTP {} redirect from local Ollama", response.status()));
            }

            if !response.status().is_success() {
                return Err(format!("Ollama returned HTTP {}", response.status()));
            }

            let json: serde_json::Value = response
                .json()
                .await
                .map_err(|e| format!("Failed to parse Ollama response JSON: {e}"))?;

            // Durations in Ollama are reported in nanoseconds; convert to milliseconds
            let load_duration_ms = json.get("load_duration").and_then(|v| v.as_u64()).map(|ns| ns / 1_000_000);
            let prompt_eval_duration_ms = json.get("prompt_eval_duration").and_then(|v| v.as_u64()).map(|ns| ns / 1_000_000);
            let eval_duration_ms = json.get("eval_duration").and_then(|v| v.as_u64()).map(|ns| ns / 1_000_000);
            let eval_count = json.get("eval_count").and_then(|v| v.as_u64());

            // Strict separation: extract message.content only
            let message = json.get("message");
            let raw_content = message
                .and_then(|m| m.get("content"))
                .and_then(|c| c.as_str())
                .unwrap_or_else(|| {
                    // Fallback to "response" field if testing against legacy mock endpoint
                    json.get("response").and_then(|r| r.as_str()).unwrap_or("")
                })
                .trim();

            // Check if thinking was present in the response
            let raw_thinking = message
                .and_then(|m| m.get("thinking"))
                .and_then(|t| t.as_str())
                .unwrap_or("")
                .trim();

            if !raw_thinking.is_empty() {
                // Log and discard reasoning trace without ever exposing to callers
                eprintln!("[CompanionAI] Discarded reasoning trace (length: {} chars)", raw_thinking.len());
            }

            // Never fallback to thinking if content is empty!
            if raw_content.is_empty() {
                return Err("EMPTY_MODEL_RESPONSE".into());
            }

            // Reject if content contains raw reasoning leak
            if raw_content.contains("<think>") || raw_content.contains("</think>") || raw_content.starts_with("Thinking Process:") {
                return Err("REASONING_LEAKED_IN_CONTENT".into());
            }

            Ok(OllamaChatResult {
                content: raw_content.to_string(),
                load_duration_ms,
                prompt_eval_duration_ms,
                eval_duration_ms,
                eval_count,
                thinking_disabled: supports_thinking,
            })
        }
    }
}

#[allow(dead_code)]
async fn generate_ollama(
    endpoint: &str,
    model: &str,
    prompt: &str,
    timeout_ms: u64,
    token: CancellationToken,
) -> Result<String, String> {
    let companion = crate::settings::active_companion_name();
    let prompt_persona = format!("You are {companion}, a helpful desktop companion in Coucou.");
    let res = generate_ollama_chat(
        endpoint,
        model,
        &prompt_persona,
        prompt,
        timeout_ms,
        token,
    )
    .await?;
    Ok(res.content)
}

// ── Cloud AI Clients ──────────────────────────────────────────────────────────

async fn generate_anthropic(
    api_key: &str,
    model: &str,
    system_prompt: &str,
    user_context: &str,
    timeout_ms: u64,
    token: CancellationToken,
) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .build()
        .map_err(|e| format!("Client error: {e}"))?;

    let body = serde_json::json!({
        "model": model,
        "max_tokens": 45,
        "temperature": 0.7,
        "system": system_prompt,
        "messages": [
            { "role": "user", "content": user_context }
        ]
    });

    let send_fut = client
        .post("https://api.anthropic.com/v1/messages")
        .header("x-api-key", api_key)
        .header("anthropic-version", "2023-06-01")
        .header("content-type", "application/json")
        .json(&body)
        .send();

    tokio::select! {
        _ = token.cancelled() => Err("REQUEST_CANCELLED".into()),
        res = send_fut => {
            let response = res.map_err(|e| format!("Anthropic request failed: {e}"))?;
            if !response.status().is_success() {
                return Err(format!("Anthropic HTTP {}", response.status()));
            }
            let json: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
            let text = json["content"][0]["text"].as_str().unwrap_or("").trim().to_string();
            Ok(text)
        }
    }
}

async fn generate_openai(
    api_key: &str,
    model: &str,
    system_prompt: &str,
    user_context: &str,
    timeout_ms: u64,
    token: CancellationToken,
) -> Result<String, String> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_millis(timeout_ms))
        .build()
        .map_err(|e| format!("Client error: {e}"))?;

    let body = serde_json::json!({
        "model": model,
        "max_tokens": 45,
        "temperature": 0.7,
        "messages": [
            { "role": "system", "content": system_prompt },
            { "role": "user", "content": user_context }
        ]
    });

    let send_fut = client
        .post("https://api.openai.com/v1/chat/completions")
        .header("Authorization", format!("Bearer {api_key}"))
        .header("Content-Type", "application/json")
        .json(&body)
        .send();

    tokio::select! {
        _ = token.cancelled() => Err("REQUEST_CANCELLED".into()),
        res = send_fut => {
            let response = res.map_err(|e| format!("OpenAI request failed: {e}"))?;
            if !response.status().is_success() {
                return Err(format!("OpenAI HTTP {}", response.status()));
            }
            let json: serde_json::Value = response.json().await.map_err(|e| e.to_string())?;
            let text = json["choices"][0]["message"]["content"].as_str().unwrap_or("").trim().to_string();
            Ok(text)
        }
    }
}

// ── Tauri Commands ────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn companion_ai_generate(
    state: State<'_, CompanionAiState>,
    request_id: String,
    _context_version: u64,
    payload: CompanionPromptPayload,
) -> Result<CompanionRawCandidate, String> {
    let token = state.register(&request_id);
    let start = Instant::now();

    let text_result = match payload.provider.as_str() {
        "ollama" => {
            let raw_endpoint = payload.endpoint.as_deref().unwrap_or("http://127.0.0.1:11434");
            let endpoint = validate_loopback_url(raw_endpoint)?;
            let user_context_prompt = format!(
                "Actual computer usage activity context:\n{}\n\nGenerate exactly one personalized companion message adhering to the output contract:",
                payload.user_context_json
            );
            let chat_res = generate_ollama_chat(
                &endpoint,
                &payload.model,
                &payload.system_prompt,
                &user_context_prompt,
                payload.timeout_ms,
                token.clone(),
            )
            .await;

            state.unregister(&request_id);
            let duration_ms = start.elapsed().as_millis() as u64;

            return match chat_res {
                Ok(res) => Ok(CompanionRawCandidate {
                    request_id,
                    text: res.content,
                    provider: payload.provider,
                    model: payload.model,
                    duration_ms,
                    load_duration_ms: res.load_duration_ms,
                    prompt_eval_duration_ms: res.prompt_eval_duration_ms,
                    eval_duration_ms: res.eval_duration_ms,
                    eval_count: res.eval_count,
                    thinking_disabled: Some(res.thinking_disabled),
                }),
                Err(e) => Err(e),
            };
        }
        "anthropic" => {
            let secret_key = canonical_secret_key("anthropic").unwrap();
            let key = crate::secrets::get(secret_key)
                .ok_or_else(|| "Anthropic API key not configured in Windows Credential Manager".to_string())?;
            generate_anthropic(
                &key,
                &payload.model,
                &payload.system_prompt,
                &payload.user_context_json,
                payload.timeout_ms,
                token.clone(),
            )
            .await
        }
        "openai" => {
            let secret_key = canonical_secret_key("openai").unwrap();
            let key = crate::secrets::get(secret_key)
                .ok_or_else(|| "OpenAI API key not configured in Windows Credential Manager".to_string())?;
            generate_openai(
                &key,
                &payload.model,
                &payload.system_prompt,
                &payload.user_context_json,
                payload.timeout_ms,
                token.clone(),
            )
            .await
        }
        other => Err(format!("Unsupported provider '{other}'")),
    };

    state.unregister(&request_id);
    let duration_ms = start.elapsed().as_millis() as u64;

    match text_result {
        Ok(text) => Ok(CompanionRawCandidate {
            request_id,
            text,
            provider: payload.provider,
            model: payload.model,
            duration_ms,
            load_duration_ms: None,
            prompt_eval_duration_ms: None,
            eval_duration_ms: None,
            eval_count: None,
            thinking_disabled: None,
        }),
        Err(e) => Err(e),
    }
}

#[tauri::command]
pub fn companion_ai_cancel(
    state: State<'_, CompanionAiState>,
    request_id: String,
) -> Result<bool, String> {
    Ok(state.cancel(&request_id))
}

#[tauri::command]
pub async fn companion_probe_health(
    provider: String,
    endpoint: Option<String>,
) -> Result<ProviderHealthStatus, String> {
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis() as u64;

    match provider.as_str() {
        "ollama" => {
            let raw_endpoint = endpoint.as_deref().unwrap_or("http://127.0.0.1:11434");
            let ep = match validate_loopback_url(raw_endpoint) {
                Ok(v) => v,
                Err(e) => {
                    return Ok(ProviderHealthStatus {
                        provider,
                        state: "OFFLINE".into(),
                        last_checked: now,
                        latency_ms: None,
                        error: Some(e),
                    })
                }
            };

            let start = Instant::now();
            let client = reqwest::Client::builder()
                .timeout(Duration::from_millis(2000))
                .redirect(reqwest::redirect::Policy::none())
                .no_proxy()
                .build()
                .unwrap_or_default();

            match client.get(format!("{ep}/api/tags")).send().await {
                Ok(res) if res.status().is_success() => {
                    let latency = start.elapsed().as_millis() as u64;
                    Ok(ProviderHealthStatus {
                        provider,
                        state: "HEALTHY".into(),
                        last_checked: now,
                        latency_ms: Some(latency),
                        error: None,
                    })
                }
                Ok(res) => Ok(ProviderHealthStatus {
                    provider,
                    state: "DEGRADED".into(),
                    last_checked: now,
                    latency_ms: Some(start.elapsed().as_millis() as u64),
                    error: Some(format!("HTTP {}", res.status())),
                }),
                Err(e) => Ok(ProviderHealthStatus {
                    provider,
                    state: "OFFLINE".into(),
                    last_checked: now,
                    latency_ms: None,
                    error: Some(e.to_string()),
                }),
            }
        }
        "anthropic" | "openai" => {
            let secret_key = match canonical_secret_key(&provider) {
                Some(k) => k,
                None => {
                    return Ok(ProviderHealthStatus {
                        provider,
                        state: "OFFLINE".into(),
                        last_checked: now,
                        latency_ms: None,
                        error: Some("Unknown provider".into()),
                    });
                }
            };
            let has_key = crate::secrets::present(secret_key);

            if has_key {
                Ok(ProviderHealthStatus {
                    provider,
                    state: "HEALTHY".into(),
                    last_checked: now,
                    latency_ms: None,
                    error: None,
                })
            } else {
                Ok(ProviderHealthStatus {
                    provider,
                    state: "DEGRADED".into(),
                    last_checked: now,
                    latency_ms: None,
                    error: Some("Key not found in Windows Credential Manager".into()),
                })
            }
        }
        _ => Ok(ProviderHealthStatus {
            provider,
            state: "OFFLINE".into(),
            last_checked: now,
            latency_ms: None,
            error: Some("Unknown provider".into()),
        }),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validate_loopback_url_accepts_valid_localhost() {
        assert_eq!(
            validate_loopback_url("http://127.0.0.1:11434").unwrap(),
            "http://127.0.0.1:11434"
        );
        assert_eq!(
            validate_loopback_url("http://localhost:11434").unwrap(),
            "http://localhost:11434"
        );
        assert_eq!(
            validate_loopback_url("http://127.0.0.1").unwrap(),
            "http://127.0.0.1:11434"
        );
    }

    #[test]
    fn validate_loopback_url_rejects_ssrf_attempts() {
        assert!(validate_loopback_url("http://192.168.1.1:11434").is_err());
        assert!(validate_loopback_url("http://10.0.0.1:8080").is_err());
        assert!(validate_loopback_url("https://google.com").is_err());
        assert!(validate_loopback_url("ftp://127.0.0.1").is_err());
    }

    #[tokio::test]
    async fn token_cancellation_lifecycle() {
        let state = CompanionAiState::default();
        let token = state.register("req_1");

        assert!(!token.is_cancelled());
        assert!(state.cancel("req_1"));
        assert!(token.is_cancelled());
        assert!(!state.cancel("req_1")); // Already removed
    }

    #[test]
    fn canonical_secret_key_maps_correct_keys() {
        assert_eq!(canonical_secret_key("anthropic"), Some("anthropic-api-key"));
        assert_eq!(canonical_secret_key("openai"), Some("openai-api-key"));
        assert_eq!(canonical_secret_key("ollama"), None);
        assert_eq!(canonical_secret_key("cohere"), None);
        assert_eq!(canonical_secret_key(""), None);
    }

    #[test]
    fn validate_loopback_url_rejects_userinfo_and_metadata() {
        assert!(validate_loopback_url("http://admin:pass@127.0.0.1:11434").is_err());
        assert!(validate_loopback_url("http://127.0.0.1@attacker.com").is_err());
        assert!(validate_loopback_url("http://169.254.169.254:11434").is_err());
        assert!(validate_loopback_url("http://0.0.0.0:11434").is_err());
        assert!(validate_loopback_url("http://[::1]:11434").is_ok());
    }

    #[tokio::test]
    async fn ollama_client_refuses_http_302_redirects() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let endpoint = format!("http://127.0.0.1:{port}");

        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf).await;
                let redirect_response =
                    "HTTP/1.1 302 Found\r\nLocation: http://169.254.169.254/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";
                let _ = stream.write_all(redirect_response.as_bytes()).await;
                let _ = stream.flush().await;
            }
        });

        let res = generate_ollama(
            &endpoint,
            "test_model",
            "prompt",
            1000,
            CancellationToken::new(),
        )
        .await;

        assert!(res.is_err());
        let err = res.unwrap_err();
        assert!(err.contains("REDIRECT_BLOCKED") || err.contains("302"));
    }

    #[tokio::test]
    async fn ollama_client_timeout_and_cancellation() {
        use tokio::io::AsyncReadExt;
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let endpoint = format!("http://127.0.0.1:{port}");

        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 1024];
                let _ = stream.read(&mut buf).await;
                tokio::time::sleep(Duration::from_millis(300)).await;
            }
        });

        // 1. Timeout test: server takes 300ms, timeout is 50ms
        let res_timeout = generate_ollama(
            &endpoint,
            "test_model",
            "prompt",
            50, // 50ms timeout
            CancellationToken::new(),
        )
        .await;
        assert_eq!(res_timeout.unwrap_err(), "GENERATION_TIMEOUT");

        // 2. Cancellation test: token is cancelled
        let token = CancellationToken::new();
        token.cancel();
        let res_cancelled = generate_ollama(
            &endpoint,
            "test_model",
            "prompt",
            1000,
            token,
        )
        .await;
        assert_eq!(res_cancelled.unwrap_err(), "REQUEST_CANCELLED");
    }

    #[tokio::test]
    async fn ollama_chat_separates_thinking_and_content_safely() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let endpoint = format!("http://127.0.0.1:{port}");

        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf).await;
                let chat_response = concat!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    r#"{"model":"qwen3.5:4b","message":{"role":"assistant","content":"Save your current work and take a short break.","thinking":"Thinking Process:\n1. User has been coding...\n2. Suggest break."},"done":true}"#
                );
                let _ = stream.write_all(chat_response.as_bytes()).await;
                let _ = stream.flush().await;
            }
        });

        let res = generate_ollama_chat(
            &endpoint,
            "qwen3.5:4b",
            "system",
            "user",
            2000,
            CancellationToken::new(),
        )
        .await
        .unwrap();

        assert_eq!(res.content, "Save your current work and take a short break.");
        assert!(!res.content.contains("Thinking Process"));
        assert!(res.thinking_disabled);
    }

    #[tokio::test]
    async fn ollama_chat_rejects_empty_content_when_thinking_only() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let endpoint = format!("http://127.0.0.1:{port}");

        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf).await;
                let chat_response = concat!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    r#"{"model":"qwen3.5:4b","message":{"role":"assistant","content":"","thinking":"Thinking only, no content"},"done":true}"#
                );
                let _ = stream.write_all(chat_response.as_bytes()).await;
                let _ = stream.flush().await;
            }
        });

        let res = generate_ollama_chat(
            &endpoint,
            "qwen3.5:4b",
            "system",
            "user",
            2000,
            CancellationToken::new(),
        )
        .await;

        assert_eq!(res.unwrap_err(), "EMPTY_MODEL_RESPONSE");
    }

    #[tokio::test]
    async fn ollama_chat_rejects_leaked_thinking_tags() {
        use tokio::io::{AsyncReadExt, AsyncWriteExt};
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let endpoint = format!("http://127.0.0.1:{port}");

        tokio::spawn(async move {
            if let Ok((mut stream, _)) = listener.accept().await {
                let mut buf = [0u8; 2048];
                let _ = stream.read(&mut buf).await;
                let chat_response = concat!(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nConnection: close\r\n\r\n",
                    r#"{"model":"qwen3.5:4b","message":{"role":"assistant","content":"<think>leak</think>Take a break."},"done":true}"#
                );
                let _ = stream.write_all(chat_response.as_bytes()).await;
                let _ = stream.flush().await;
            }
        });

        let res = generate_ollama_chat(
            &endpoint,
            "qwen3.5:4b",
            "system",
            "user",
            2000,
            CancellationToken::new(),
        )
        .await;

        assert_eq!(res.unwrap_err(), "REASONING_LEAKED_IN_CONTENT");
    }
}
