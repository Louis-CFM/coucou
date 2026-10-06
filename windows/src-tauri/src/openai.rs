// OpenAI-Chat-Completions-compatible client: OpenAI, OpenRouter, Ollama,
// LiteLLM, LM Studio, vLLM. One wire shape covers all five.

use serde_json::{json, Value};

use crate::claude::MAX_INLINE_TEXT;

pub const DEFAULT_BASE_URL: &str = "https://api.openai.com/v1";

/// Server-side extras (web_search tool, file parts, file-parser) only exist
/// on OpenRouter; any other backend would reject them.
pub(crate) fn is_openrouter(base_url: &str) -> bool {
    base_url.to_lowercase().contains("openrouter.ai")
}

/// OpenRouter file part for one PDF, or None when it must fall back to
/// text-inline (wrong ext) or be skipped (over MAX_PDF_BYTES).
fn pdf_file_part(name: &str, bytes: &[u8]) -> Option<Value> {
    const MAX_PDF_BYTES: usize = 10_000_000;
    if !name.to_lowercase().ends_with(".pdf") || bytes.len() > MAX_PDF_BYTES {
        return None;
    }
    Some(json!({
        "type": "file",
        "file": {
            "filename": name,
            "file_data": format!("data:application/pdf;base64,{}", crate::claude::base64(bytes)),
        },
    }))
}

/// Explicit pdf-text (free) so a scanned PDF never triggers paid OCR silently.
fn file_parser_plugin() -> Value {
    json!({ "id": "file-parser", "pdf": { "engine": "pdf-text" } })
}

pub fn endpoint(base: &str) -> String {
    format!("{}/chat/completions", base.trim_end_matches('/'))
}

fn body(model: &str, system: &str, messages: &[Value]) -> Value {
    body_full(model, system, messages, vec![], false)
}

fn body_full(
    model: &str,
    system: &str,
    messages: &[Value],
    plugins: Vec<Value>,
    web_search: bool,
) -> Value {
    let tools = if web_search {
        vec![json!({ "type": "openrouter:web_search", "parameters": { "max_results": 5 } })]
    } else {
        vec![]
    };
    json!({
        "model": model,
        "max_tokens": super::claude::MAX_TOKENS,
        "system": system,
        "messages": messages,
        "plugins": plugins,
        "tools": tools,
    })
}

/// Reads `choices[0].message.content` as a string or an array of text parts.
fn reply_text(response: &Value) -> Result<String, String> {
    let content = response
        .get("choices")
        .and_then(Value::as_array)
        .and_then(|c| c.first())
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"));
    let text = match content {
        Some(Value::String(s)) => s.clone(),
        Some(Value::Array(parts)) => parts
            .iter()
            .filter_map(|p| p.get("text").and_then(Value::as_str))
            .collect::<Vec<_>>()
            .join("\n"),
        _ => return Err("Unexpected API response.".into()),
    };
    let text = text.trim().to_string();
    if text.is_empty() {
        return Err("No response text.".into());
    }
    Ok(text)
}

fn api_error(status: reqwest::StatusCode, text: &str) -> String {
    let detail = serde_json::from_str::<Value>(text)
        .ok()
        .and_then(|v| {
            v.get("error")
                .and_then(|e| e.get("message"))
                .and_then(Value::as_str)
                .map(str::to_string)
        })
        .unwrap_or_else(|| text.chars().take(200).collect());
    format!("OpenAI API {status}: {detail}")
}

/// One chat turn, same contract as `claude::send`. History is provider-scoped
/// (see `Chat::ensure_provider`); file context is text-inline + image data
/// URLs — Chat Completions has no document block, so unreadable PDFs are
/// skipped. No tools: web search is Anthropic-only.
pub async fn send(
    chat: &crate::claude::Chat,
    base_url: &str,
    key: &str,
    model: &str,
    query: String,
    context: Option<crate::claude::ChatContext>,
    web_search: bool,
) -> Result<crate::claude::ChatReply, String> {
    use crate::claude::{ChatContext, SYSTEM_PROMPT};

    chat.ensure_provider("openai-compatible");
    let openrouter = is_openrouter(base_url);

    let mut parts: Vec<Value> = Vec::new();
    let mut used_file = false;
    if chat.is_empty() {
        match &context {
            Some(ChatContext::File { name, path }) => {
                let (fp, used) = file_parts(path, openrouter);
                parts.extend(fp);
                used_file = used;
                parts.push(json!({ "type": "text", "text": format!("File: {name}") }));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                let mut text = format!("Context — App: {app_name}, Window: {title}");
                if let Some(url) = url {
                    text.push_str(&format!(", URL: {url}"));
                }
                parts.push(json!({ "type": "text", "text": text }));
            }
            None => {}
        }
    }
    parts.push(json!({ "type": "text", "text": query }));
    chat.push(json!({ "role": "user", "content": parts }));

    let plugins = if used_file { vec![file_parser_plugin()] } else { vec![] };
    let body = body_full(
        model,
        SYSTEM_PROMPT,
        &chat.snapshot(),
        plugins,
        web_search,
    );
    let response = match call(base_url, key, &body).await {
        Ok(v) => v,
        Err(err) => {
            chat.pop();
            return Err(err);
        }
    };
    let text = match reply_text(&response) {
        Ok(t) => t,
        Err(err) => {
            chat.pop();
            return Err(err);
        }
    };
    chat.push(json!({ "role": "assistant", "content": text.clone() }));
    Ok(crate::claude::ChatReply { text })
}

async fn call(base_url: &str, key: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let mut request = client
        .post(endpoint(base_url))
        .header("content-type", "application/json")
        .json(body);
    if !key.is_empty() {
        // Local backends (Ollama) need no key; remote ones do.
        request = request.header("authorization", format!("Bearer {key}"));
    }
    let response = request
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;

    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        return Err(api_error(status, &text));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad API response: {e}"))
}

/// Text/code → inline text part; images → data-URL part; PDFs on OpenRouter →
/// file part (bool reports it, so the caller attaches the parser plugin);
/// anything else → none.
fn file_parts(path: &str, openrouter: bool) -> (Vec<Value>, bool) {
    let ext = std::path::Path::new(path)
        .extension()
        .and_then(|e| e.to_str())
        .unwrap_or("")
        .to_lowercase();

    if openrouter && ext == "pdf" {
        let name = std::path::Path::new(path)
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("document.pdf");
        match std::fs::read(path) {
            Ok(bytes) => {
                let part: Vec<Value> = pdf_file_part(name, &bytes).into_iter().collect();
                let used = !part.is_empty();
                return (part, used);
            }
            Err(_) => return (vec![], false),
        }
    }

    let media = match ext.as_str() {
        "jpg" | "jpeg" => Some("image/jpeg"),
        "png" => Some("image/png"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    };
    if let Some(media) = media {
        let bytes = match std::fs::read(path) {
            Ok(b) => b,
            Err(_) => return (vec![], false),
        };
        return (
            vec![json!({
                "type": "image_url",
                "image_url": { "url": format!("data:{media};base64,{}", crate::claude::base64(&bytes)) },
            })],
            false,
        );
    }

    let len = match std::fs::metadata(path) {
        Ok(m) => m.len(),
        Err(_) => return (vec![], false),
    };
    if len > MAX_INLINE_TEXT {
        return (vec![], false);
    }
    match std::fs::read_to_string(path) {
        Ok(text) => (
            vec![json!({ "type": "text", "text": format!("File contents:\n{text}") })],
            false,
        ),
        Err(_) => (vec![], false),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn endpoint_joins_without_double_slash() {
        assert_eq!(
            endpoint("https://api.openai.com/v1/"),
            "https://api.openai.com/v1/chat/completions"
        );
        assert_eq!(
            endpoint("http://localhost:11434/v1"),
            "http://localhost:11434/v1/chat/completions"
        );
    }

    #[test]
    fn body_carries_model_system_and_messages() {
        let b = body("gpt-5.4-mini", "sys", &[json!({"role": "user"})]);
        assert_eq!(b["model"], "gpt-5.4-mini");
        assert_eq!(b["system"], "sys");
        assert_eq!(b["messages"], json!([{"role": "user"}]));
    }

    #[test]
    fn pdf_from_disk_becomes_file_part_on_openrouter() {
        // NOTE: live PDF turns need ≥$0.50 OpenRouter balance (code 402
        // otherwise), so the wire shape is pinned here and was verified
        // against the official file-parser docs/examples.
        let pdf = b"%PDF-1.4\n1 0 obj<</Type/Catalog/Pages 2 0 R>>endobj\ntrailer<</Root 1 0 R>>";
        let path = std::env::temp_dir().join("coucou-shape.pdf");
        std::fs::write(&path, pdf).unwrap();
        let (parts, used) = file_parts(&path.to_string_lossy(), true);
        let _ = std::fs::remove_file(&path);
        assert!(used);
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0]["type"], "file");
        assert_eq!(parts[0]["file"]["filename"], "coucou-shape.pdf");
        assert!(parts[0]["file"]["file_data"]
            .as_str()
            .unwrap()
            .starts_with("data:application/pdf;base64,"));
    }
    #[test]
    fn web_tool_injected_only_when_asked() {
        let on = body_full("m", "s", &[], vec![], true);
        assert_eq!(
            on["tools"],
            json!([{"type": "openrouter:web_search", "parameters": {"max_results": 5}}])
        );
        let off = body_full("m", "s", &[], vec![], false);
        assert_eq!(off["tools"], json!([]));
    }

    #[test]
    fn body_passes_through_plugins() {
        let b = body_full("m", "s", &[], vec![file_parser_plugin()], false);
        assert_eq!(
            b["plugins"],
            json!([{"id": "file-parser", "pdf": {"engine": "pdf-text"}}])
        );
        assert_eq!(b["tools"], json!([]));
    }

    #[test]
    fn reply_reads_string_content() {
        let v = json!({"choices": [{"message": {"content": "  hi  "}}]});
        assert_eq!(reply_text(&v).unwrap(), "hi");
    }

    #[test]
    fn reply_reads_part_array_and_rejects_empties() {
        let v = json!({"choices": [{"message": {"content": [
            {"type": "text", "text": "a"},
            {"type": "text", "text": "b"},
        ]}}]});
        assert_eq!(reply_text(&v).unwrap(), "a\nb");
        let empty = json!({"choices": [{"message": {"content": ""}}]});
        assert!(reply_text(&empty).is_err());
        assert!(reply_text(&json!({})).is_err());
    }

    #[test]
    fn error_surfaces_the_api_message() {
        let e = api_error(
            reqwest::StatusCode::UNAUTHORIZED,
            r#"{"error": {"message": "bad key"}}"#,
        );
        assert!(e.contains("bad key"), "got: {e}");
    }

    #[test]
    fn openrouter_detection_ignores_case_and_path() {
        assert!(is_openrouter("https://openrouter.ai/api/v1/"));
        assert!(!is_openrouter("http://localhost:11434/v1"));
        assert!(!is_openrouter("https://api.openai.com/v1"));
    }

    #[test]
    fn pdf_part_uses_file_shape_and_size_guard() {
        assert!(pdf_file_part("a.pdf", &vec![0u8; 100]).is_some());
        assert!(pdf_file_part("a.pdf", &vec![0u8; 11_000_000]).is_none());
        assert!(pdf_file_part("a.txt", &vec![0u8; 100]).is_none());
    }
}
