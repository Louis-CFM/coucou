// Ollama client: chat and model list over Ollama's native API (/api/chat, /api/tags).

use std::time::Duration;

use reqwest::Url;
use serde_json::{json, Value};

use crate::claude::{base64_for, Chat, ChatContext, ChatReply};

const DEFAULT_PORT: u16 = 11434;
const MAX_TOKENS: u32 = 4096;
const MAX_INLINE_TEXT: u64 = 200_000;

const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
You have no internet access. Respond in the user's language. Be clear and concise. \
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks.";

/// Accepts what people actually type or have in OLLAMA_HOST: "localhost", "0.0.0.0:11434",
/// "http://host/api", trailing slashes. On Windows "localhost" can resolve to ::1 first while
/// Ollama only listens on 127.0.0.1, so loopback names are pinned to 127.0.0.1.
pub fn normalise_url(raw: &str) -> Result<Url, String> {
    let mut s = raw.trim().to_string();
    if s.is_empty() {
        s = std::env::var("OLLAMA_HOST").unwrap_or_default().trim().to_string();
    }
    if s.is_empty() {
        s = format!("http://127.0.0.1:{DEFAULT_PORT}");
    }
    if !s.contains("://") {
        s = format!("http://{s}");
    }
    let mut url = Url::parse(&s).map_err(|_| format!("Invalid Ollama URL: {raw}"))?;

    let host = url.host_str().unwrap_or("").to_lowercase();
    let loopback = matches!(host.as_str(), "localhost" | "0.0.0.0" | "127.0.0.1" | "[::]" | "[::1]");
    if loopback {
        let _ = url.set_host(Some("127.0.0.1"));
        if url.port().is_none() && url.scheme() == "http" {
            let _ = url.set_port(Some(DEFAULT_PORT));
        }
    }

    let mut path = url.path().trim_end_matches('/').to_string();
    for suffix in ["/api", "/v1"] {
        if path.ends_with(suffix) {
            path.truncate(path.len() - suffix.len());
        }
    }
    url.set_path(&path);
    url.set_query(None);
    Ok(url)
}

fn endpoint(base: &Url, tail: &str) -> String {
    format!("{}{}", base.as_str().trim_end_matches('/'), tail)
}

fn client(base: &Url, timeout: Duration) -> Result<reqwest::Client, String> {
    let mut builder = reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .timeout(timeout);
    if base.host_str() == Some("127.0.0.1") {
        builder = builder.no_proxy();
    }
    builder.build().map_err(|e| e.to_string())
}

fn unreachable_msg(base: &Url) -> String {
    format!(
        "Cannot reach Ollama at {}. Start it (Ollama app or `ollama serve`) and check the URL in settings.",
        base.as_str().trim_end_matches('/')
    )
}

fn api_error(text: &str, status: reqwest::StatusCode, model: &str) -> String {
    let detail = serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| v.get("error").and_then(Value::as_str).map(str::to_string))
        .unwrap_or_else(|| text.chars().take(200).collect());
    if status == reqwest::StatusCode::NOT_FOUND && detail.to_lowercase().contains("not found") {
        return format!("Model '{model}' is not installed. Run: ollama pull {model}");
    }
    format!("Ollama {status}: {detail}")
}

const EXCLUDED: [&str; 5] = ["embed", "bge-", "all-minilm", "clip", "rerank"];

pub async fn models(url: &str) -> Result<Vec<String>, String> {
    let base = normalise_url(url)?;
    let response = client(&base, Duration::from_secs(8))?
        .get(endpoint(&base, "/api/tags"))
        .send()
        .await
        .map_err(|_| unreachable_msg(&base))?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(api_error(&text, status, ""));
    }
    let v: Value = serde_json::from_str(&text).map_err(|_| "Unexpected reply from Ollama.".to_string())?;
    let mut names: Vec<String> = v
        .get("models")
        .and_then(Value::as_array)
        .map(|items| {
            items
                .iter()
                .filter_map(|m| m.get("name").and_then(Value::as_str))
                .filter(|n| {
                    let lower = n.to_lowercase();
                    !EXCLUDED.iter().any(|x| lower.contains(x))
                })
                .map(str::to_string)
                .collect()
        })
        .unwrap_or_default();
    names.sort();
    Ok(names)
}

fn strip_thinking(text: &str) -> String {
    let mut out = String::new();
    let mut rest = text;
    while let Some(start) = rest.find("<think>") {
        out.push_str(&rest[..start]);
        match rest[start..].find("</think>") {
            Some(end) => rest = &rest[start + end + "</think>".len()..],
            None => {
                rest = "";
                break;
            }
        }
    }
    out.push_str(rest);
    out.trim().to_string()
}

struct Attachment {
    text: Option<String>,
    image: Option<String>,
}

fn read_attachment(path: &str) -> Result<Attachment, String> {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();
    match ext.as_str() {
        "png" | "jpg" | "jpeg" | "gif" | "webp" => {
            let bytes = std::fs::read(path).map_err(|e| format!("Could not read the file: {e}"))?;
            Ok(Attachment { text: None, image: Some(base64_for(&bytes)) })
        }
        "pdf" => Err("Ollama can't read PDF files. Drop a text file or an image.".into()),
        _ => {
            let len = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
            if len > MAX_INLINE_TEXT {
                return Err("That file is too large for the local model.".into());
            }
            let text = std::fs::read_to_string(path)
                .map_err(|_| "Ollama can only read text files and images.".to_string())?;
            Ok(Attachment { text: Some(format!("File contents:\n{text}")), image: None })
        }
    }
}

pub async fn send(
    chat: &Chat,
    url: &str,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    if model.trim().is_empty() {
        return Err("No Ollama model selected. Open settings.".into());
    }
    let base = normalise_url(url)?;

    let first = chat.local.lock().unwrap().is_empty();
    let mut text = String::new();
    let mut images: Vec<String> = Vec::new();
    if first {
        match &context {
            Some(ChatContext::File { name, path }) => {
                let att = read_attachment(path)?;
                text.push_str(&format!("File: {name}\n"));
                if let Some(t) = att.text {
                    text.push_str(&t);
                    text.push_str("\n\n");
                }
                if let Some(i) = att.image {
                    images.push(i);
                }
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                text.push_str(&format!("Context — App: {app_name}, Window: {title}"));
                if let Some(url) = url {
                    text.push_str(&format!(", URL: {url}"));
                }
                text.push_str("\n\n");
            }
            None => {}
        }
    }
    text.push_str(&query);

    let mut user = json!({ "role": "user", "content": text });
    if !images.is_empty() {
        user["images"] = json!(images);
    }
    chat.local.lock().unwrap().push(user);

    let mut messages = vec![json!({ "role": "system", "content": SYSTEM_PROMPT })];
    messages.extend(chat.local.lock().unwrap().iter().cloned());
    let body = json!({
        "model": model,
        "messages": messages,
        "stream": false,
        "options": { "num_predict": MAX_TOKENS },
    });

    match request(&base, model, &body).await {
        Ok(reply) => {
            chat.local
                .lock()
                .unwrap()
                .push(json!({ "role": "assistant", "content": reply }));
            Ok(ChatReply { text: reply })
        }
        Err(err) => {
            chat.local.lock().unwrap().pop();
            Err(err)
        }
    }
}

async fn request(base: &Url, model: &str, body: &Value) -> Result<String, String> {
    let response = client(base, Duration::from_secs(300))?
        .post(endpoint(base, "/api/chat"))
        .json(body)
        .send()
        .await
        .map_err(|e| {
            if e.is_timeout() {
                "Ollama took too long to answer. The model may still be loading; try again.".to_string()
            } else {
                unreachable_msg(base)
            }
        })?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(api_error(&text, status, model));
    }
    let v: Value = serde_json::from_str(&text).map_err(|_| "Unexpected reply from Ollama.".to_string())?;
    let content = v
        .get("message")
        .and_then(|m| m.get("content"))
        .and_then(Value::as_str)
        .unwrap_or("");
    let cleaned = strip_thinking(content);
    if cleaned.is_empty() {
        return Err("No response text.".into());
    }
    Ok(cleaned)
}

#[cfg(test)]
mod tests {
    use super::{normalise_url, strip_thinking};

    fn norm(s: &str) -> String {
        normalise_url(s).unwrap().as_str().trim_end_matches('/').to_string()
    }

    #[test]
    fn pins_loopback_to_ipv4() {
        assert_eq!(norm("http://localhost:11434"), "http://127.0.0.1:11434");
        assert_eq!(norm("localhost"), "http://127.0.0.1:11434");
        assert_eq!(norm("0.0.0.0:11434"), "http://127.0.0.1:11434");
        assert_eq!(norm("http://[::1]:11434"), "http://127.0.0.1:11434");
    }

    #[test]
    fn strips_api_suffixes_and_slashes() {
        assert_eq!(norm("http://127.0.0.1:11434/"), "http://127.0.0.1:11434");
        assert_eq!(norm("http://127.0.0.1:11434/v1"), "http://127.0.0.1:11434");
        assert_eq!(norm("http://box.lan:8080/api/"), "http://box.lan:8080");
    }

    #[test]
    fn keeps_remote_hosts() {
        assert_eq!(norm("https://ollama.example.com"), "https://ollama.example.com");
        assert_eq!(norm("192.168.1.20:11434"), "http://192.168.1.20:11434");
    }

    #[test]
    fn removes_think_blocks() {
        assert_eq!(strip_thinking("<think>x</think>hola"), "hola");
        assert_eq!(strip_thinking("hola <think>sin cerrar"), "hola");
        assert_eq!(strip_thinking("a<think>x</think>b<think>y</think>c"), "abc");
    }
}
