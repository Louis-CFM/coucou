// OpenAI API client. Authentication is read only from Windows Credential
// Manager; the key and request body never cross the frontend IPC boundary.

use std::sync::Mutex;

use serde_json::{json, Value};

use crate::claude::{ChatContext, ChatReply};
use crate::secrets;

const ENDPOINT: &str = "https://api.openai.com/v1/chat/completions";
const MAX_INLINE_TEXT: u64 = 200_000;
const SYSTEM_PROMPT: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. Respond in the user's language. Be thorough and complete. Use plain text with line breaks and no markdown formatting.";

#[derive(Default)]
pub struct Chat {
    messages: Mutex<Vec<Value>>,
}

impl Chat {
    pub fn reset(&self) {
        self.messages.lock().unwrap().clear();
    }

    fn is_empty(&self) -> bool {
        self.messages.lock().unwrap().is_empty()
    }

    fn push(&self, message: Value) {
        self.messages.lock().unwrap().push(message);
    }

    fn pop(&self) {
        self.messages.lock().unwrap().pop();
    }

    fn snapshot(&self) -> Vec<Value> {
        self.messages.lock().unwrap().clone()
    }
}

pub async fn send(
    chat: &Chat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let key = secrets::get("openai-api-key")
        .ok_or_else(|| "OpenAI API key missing. Open settings.".to_string())?;

    let mut prompt = String::new();
    if chat.is_empty() {
        if let Some(context) = context {
            match context {
                ChatContext::File { name, path } => {
                    prompt.push_str(&format!("File: {name}\n"));
                    if let Some(contents) = file_text(&path) {
                        prompt.push_str(&contents);
                        prompt.push('\n');
                    }
                }
                ChatContext::Window {
                    app_name,
                    title,
                    url,
                } => {
                    prompt.push_str(&format!("Context - App: {app_name}, Window: {title}"));
                    if let Some(url) = url {
                        prompt.push_str(&format!(", URL: {url}"));
                    }
                    prompt.push('\n');
                }
            }
        }
    }
    prompt.push_str(&query);
    chat.push(json!({ "role": "user", "content": prompt }));

    let mut messages = vec![json!({ "role": "system", "content": SYSTEM_PROMPT })];
    messages.extend(chat.snapshot());
    let body = json!({
        "model": model,
        "messages": messages,
    });
    let response = match call(&key, &body).await {
        Ok(value) => value,
        Err(error) => {
            chat.pop();
            return Err(error);
        }
    };
    let Some(text) = response_text(&response) else {
        chat.pop();
        return Err("Unexpected OpenAI API response.".into());
    };
    chat.push(json!({ "role": "assistant", "content": text }));
    Ok(ChatReply { text })
}

async fn call(key: &str, body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;
    let response = client
        .post(ENDPOINT)
        .bearer_auth(key)
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| format!("Network error: {e}"))?;
    let status = response.status();
    let text = response.text().await.map_err(|e| e.to_string())?;
    if !status.is_success() {
        let detail = serde_json::from_str::<Value>(&text)
            .ok()
            .and_then(|v| v.get("error")?.get("message")?.as_str().map(str::to_string))
            .unwrap_or_else(|| text.chars().take(200).collect());
        return Err(format!("OpenAI API {status}: {detail}"));
    }
    serde_json::from_str(&text).map_err(|e| format!("Bad OpenAI API response: {e}"))
}

fn response_text(response: &Value) -> Option<String> {
    response
        .get("choices")?
        .as_array()?
        .first()?
        .get("message")?
        .get("content")?
        .as_str()
        .map(str::trim)
        .filter(|text| !text.is_empty())
        .map(str::to_string)
}

fn file_text(path: &str) -> Option<String> {
    let metadata = std::fs::metadata(path).ok()?;
    if metadata.len() > MAX_INLINE_TEXT {
        return None;
    }
    std::fs::read_to_string(path)
        .ok()
        .map(|text| format!("File contents:\n{text}"))
}

#[cfg(test)]
mod tests {
    use super::response_text;
    use serde_json::json;

    #[test]
    fn extracts_chat_completion_text() {
        let response = json!({"choices":[{"message":{"role":"assistant","content":" hello "}}]});
        assert_eq!(response_text(&response).as_deref(), Some("hello"));
    }

    #[test]
    fn rejects_empty_or_missing_completion() {
        assert!(response_text(&json!({"choices":[]})).is_none());
        assert!(response_text(&json!({"choices":[{"message":{"content":" "}}]})).is_none());
    }
}
