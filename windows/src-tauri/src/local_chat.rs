// Local-model chat over an OpenAI-chat-completions-compatible server — Ollama
// or LM Studio, both reachable the same way once pointed at a base URL. No
// API key: the user's own server, on their own machine.

use std::sync::Mutex;

use futures_util::StreamExt;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::claude::ChatReply;

/// Multi-turn history for the local provider, kept separate from the
/// Anthropic `Chat` — plain `{role, content}` text turns, not Anthropic's
/// content-block shape, so switching to a local provider starts its own
/// conversation rather than replaying blocks a local model never produced.
#[derive(Default)]
pub struct LocalChat {
    messages: Mutex<Vec<Value>>,
}

impl LocalChat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }

    fn push(&self, role: &str, content: &str) {
        self.messages.lock().unwrap().push(json!({ "role": role, "content": content }));
    }

    fn pop(&self) {
        self.messages.lock().unwrap().pop();
    }

    fn snapshot(&self) -> Vec<Value> {
        self.messages.lock().unwrap().clone()
    }
}

fn client(timeout_secs: u64) -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(timeout_secs))
        .build()
        .map_err(|e| e.to_string())
}

/// The models a local server has pulled/loaded, for the Settings "Connect"
/// button — both Ollama and LM Studio serve an OpenAI-shaped `/v1/models`.
pub async fn list_models(base_url: &str) -> Result<Vec<String>, String> {
    let url = format!("{}/v1/models", base_url.trim_end_matches('/'));
    let response = client(10)?
        .get(&url)
        .send()
        .await
        .map_err(|e| format!("Couldn't reach {url}: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(format!("{url} returned {status}"));
    }
    let body: Value =
        serde_json::from_str(&text).map_err(|e| format!("Bad response from {url}: {e}"))?;
    Ok(body
        .get("data")
        .and_then(Value::as_array)
        .map(|list| {
            list.iter()
                .filter_map(|m| m.get("id").and_then(Value::as_str))
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default())
}

/// One streamed chat turn. Partial text is pushed to the front end as
/// `chat-token` events on `window_label` as it arrives; the full text is also
/// returned once the stream ends, so the command's own caller — and history —
/// stay in sync even if a frontend listener misses an event.
pub async fn send(
    local: &LocalChat,
    app: &AppHandle,
    window_label: &str,
    base_url: &str,
    model: &str,
    query: String,
) -> Result<ChatReply, String> {
    local.push("user", &query);

    let url = format!("{}/v1/chat/completions", base_url.trim_end_matches('/'));
    let body = json!({ "model": model, "messages": local.snapshot(), "stream": true });

    let response = match client(300)?.post(&url).json(&body).send().await {
        Ok(r) => r,
        Err(err) => {
            local.pop();
            return Err(format!("Couldn't reach {url}: {err}"));
        }
    };

    let status = response.status();
    if !status.is_success() {
        local.pop();
        let text = response.text().await.unwrap_or_default();
        let detail: String = text.chars().take(200).collect();
        return Err(format!("{url} returned {status}: {detail}"));
    }

    let mut stream = response.bytes_stream();
    let mut full = String::new();
    // Buffered as raw bytes, not a String: a chunk boundary can land in the
    // middle of a multi-byte UTF-8 character, and '\n' (0x0A) never appears
    // inside one, so splitting on it at the byte level is always safe.
    let mut carry: Vec<u8> = Vec::new();
    while let Some(chunk) = stream.next().await {
        let chunk = match chunk {
            Ok(c) => c,
            Err(err) => {
                local.pop();
                return Err(format!("Stream error: {err}"));
            }
        };
        carry.extend_from_slice(&chunk);
        while let Some(pos) = carry.iter().position(|&b| b == b'\n') {
            let line_bytes: Vec<u8> = carry.drain(..=pos).collect();
            let line = String::from_utf8_lossy(&line_bytes[..line_bytes.len() - 1]);
            let line = line.trim();
            let Some(data) = line.strip_prefix("data: ") else { continue };
            if data == "[DONE]" {
                continue;
            }
            let Ok(event) = serde_json::from_str::<Value>(data) else { continue };
            if let Some(delta) = event
                .get("choices")
                .and_then(|c| c.get(0))
                .and_then(|c| c.get("delta"))
                .and_then(|d| d.get("content"))
                .and_then(Value::as_str)
            {
                full.push_str(delta);
                let _ = app.emit_to(window_label, "chat-token", delta);
            }
        }
    }

    if full.trim().is_empty() {
        local.pop();
        return Err("No response text.".into());
    }
    local.push("assistant", &full);
    Ok(ChatReply { text: full })
}
