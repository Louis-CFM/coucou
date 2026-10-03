use std::sync::Mutex;

use futures_util::StreamExt;
use serde::Deserialize;
use serde_json::{json, Value};
use tauri::{AppHandle, Emitter};

use crate::claude::{ChatContext, ChatReply};

const ENDPOINT: &str = "http://127.0.0.1:11434/api/chat";

const MAX_TOKENS: u32 = 4096;
const MAX_INLINE_TEXT: u64 = 200_000;

pub const DEFAULT_MODEL: &str = "gpt-oss:120b-cloud";

const SYSTEM_PROMPT: &str = r#"You are Mochi, a personal AI assistant living at the top of the user's screen.
You can help with research, coding, questions, and tasks.
Respond in the user's language. Be thorough and complete — use as much detail as the task requires.
No markdown formatting (no **, no ##, no bullet dashes). Use plain text with line breaks."#;

#[derive(Default)]
pub struct OllamaChat {
    messages: Mutex<Vec<Value>>,
}

impl OllamaChat {
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

#[derive(Debug, Deserialize)]
struct OllamaResponse {
    message: Option<OllamaMessage>,
    error: Option<String>,
}

#[derive(Debug, Deserialize)]
struct OllamaMessage {
    role: String,
    content: String,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct StreamChunk {
    pub request_id: String,
    pub delta: String,
    pub done: bool,
    pub error: Option<String>,
}

/// One Ollama chat turn.
///
/// The endpoint is intentionally local: Ollama owns the connection
/// to local or cloud-backed models.
pub async fn send(
    chat: &OllamaChat,
    model: &str,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let mut content = String::new();

    if chat.is_empty() {
        if let Some(context) = context {
            match context {
                ChatContext::File { name, path } => {
                    let Some(file_text) = file_text(&path)? else {
                        return Err(
                            "Ollama currently supports text/code file context only."
                                .into(),
                        );
                    };

                    content.push_str(&format!(
                        "File: {name}\n\nFile contents:\n{file_text}\n\n"
                    ));
                }

                ChatContext::Window {
                    app_name,
                    title,
                    url,
                } => {
                    content.push_str(&format!(
                        "Context — App: {app_name}, Window: {title}"
                    ));

                    if let Some(url) = url {
                        content.push_str(&format!(", URL: {url}"));
                    }

                    content.push_str("\n\n");
                }
            }
        }
    }

    content.push_str(&query);

    chat.push(json!({
        "role": "user",
        "content": content,
    }));

    let mut messages = vec![
        json!({
            "role": "system",
            "content": SYSTEM_PROMPT,
        }),
    ];

    messages.extend(chat.snapshot());

    let body = json!({
        "model": model,
        "messages": messages,
        "stream": false,
        "options": {
            "num_predict": MAX_TOKENS,
        },
    });

    let response = match call(&body).await {
        Ok(value) => value,

        Err(err) => {
            chat.pop();
            return Err(err);
        }
    };

    let parsed: OllamaResponse = match serde_json::from_value(response) {
        Ok(value) => value,

        Err(err) => {
            chat.pop();
            return Err(format!("Bad Ollama response: {err}"));
        }
    };

    if let Some(error) = parsed.error {
        chat.pop();
        return Err(format!("Ollama: {error}"));
    }

    let Some(message) = parsed.message else {
        chat.pop();
        return Err("Ollama returned no assistant message.".into());
    };

    let text = message.content.trim().to_string();

    if text.is_empty() {
        chat.pop();
        return Err("Ollama returned no response text.".into());
    }

    chat.push(json!({
        "role": message.role,
        "content": message.content,
    }));

    Ok(ChatReply { text })
}

/// Streams one Ollama chat turn to the frontend.
///
/// Ollama returns newline-delimited JSON objects while `stream` is enabled.
/// Rust remains the network boundary and forwards only text deltas to the UI.
pub async fn send_stream(
    app: &AppHandle,
    chat: &OllamaChat,
    model: &str,
    request_id: String,
    query: String,
    context: Option<ChatContext>,
) -> Result<(), String> {
    let mut content = String::new();

    /*
     * File/window context is only attached to the first conversation turn.
     */
    if chat.is_empty() {
        if let Some(context) = context {
            match context {
                ChatContext::File { name, path } => {
                    let Some(file_text) = file_text(&path)? else {
                        return Err(
                            "Ollama currently supports text/code file context only."
                                .into(),
                        );
                    };

                    content.push_str(&format!(
                        "File: {name}\n\nFile contents:\n{file_text}\n\n"
                    ));
                }

                ChatContext::Window {
                    app_name,
                    title,
                    url,
                } => {
                    content.push_str(&format!(
                        "Context — App: {app_name}, Window: {title}"
                    ));

                    if let Some(url) = url {
                        content.push_str(&format!(", URL: {url}"));
                    }

                    content.push_str("\n\n");
                }
            }
        }
    }

    content.push_str(&query);

    /*
     * Add the user message before making the request.
     *
     * If anything fails later, send_stream removes this message again.
     */
    chat.push(json!({
        "role": "user",
        "content": content,
    }));

    let mut messages = vec![
        json!({
            "role": "system",
            "content": SYSTEM_PROMPT,
        }),
    ];

    messages.extend(chat.snapshot());

    let body = json!({
        "model": model,
        "messages": messages,
        "stream": true,
        "options": {
            "num_predict": MAX_TOKENS,
        },
    });

    /*
     * Establish the HTTP connection.
     */
    let response = match stream_call(&body).await {
        Ok(response) => response,

        Err(err) => {
            chat.pop();
            emit_stream_error(app, &request_id, &err);
            return Err(err);
        }
    };

    let mut assistant_text = String::new();
    let mut buffer = String::new();
    let mut saw_done = false;

    let mut stream = response.bytes_stream();

    /*
     * Read Ollama's NDJSON stream.
     */
    while let Some(chunk) = stream.next().await {
        let bytes = match chunk {
            Ok(bytes) => bytes,

            Err(err) => {
                let message = format!("Ollama stream interrupted: {err}");

                chat.pop();
                emit_stream_error(app, &request_id, &message);

                return Err(message);
            }
        };

        /*
         * Ollama sends UTF-8 JSON.
         *
         * String::from_utf8_lossy prevents a malformed byte sequence from
         * crashing the stream parser.
         */
        buffer.push_str(&String::from_utf8_lossy(&bytes));

        /*
         * Process every complete NDJSON line currently in the buffer.
         */
        while let Some(newline) = buffer.find('\n') {
            let line = buffer[..newline].trim().to_string();

            buffer.drain(..=newline);

            if line.is_empty() {
                continue;
            }

            match process_stream_line(
                app,
                &request_id,
                &line,
                &mut assistant_text,
            ) {
                Ok(done) => {
                    if done {
                        saw_done = true;
                        break;
                    }
                }

                Err(err) => {
                    chat.pop();
                    emit_stream_error(app, &request_id, &err);

                    return Err(err);
                }
            }
        }

        if saw_done {
            break;
        }
    }

    /*
     * The final NDJSON object may not end with '\n'.
     *
     * Process anything remaining in the buffer.
     */
    if !saw_done {
        let line = buffer.trim();

        if !line.is_empty() {
            match process_stream_line(
                app,
                &request_id,
                line,
                &mut assistant_text,
            ) {
                Ok(done) => {
                    saw_done = done;
                }

                Err(err) => {
                    chat.pop();
                    emit_stream_error(app, &request_id, &err);

                    return Err(err);
                }
            }
        }
    }

    /*
     * A valid Ollama stream should finish with done=true.
     *
     * If the connection closes without that marker, treat it as an
     * interrupted/incomplete stream rather than silently accepting it.
     */
    if !saw_done {
        chat.pop();

        let message =
            "Ollama stream ended before the response was complete.".to_string();

        emit_stream_error(app, &request_id, &message);

        return Err(message);
    }

    /*
     * Don't store an empty assistant message in the conversation.
     */
    if assistant_text.trim().is_empty() {
        chat.pop();

        let message = "Ollama returned no response text.".to_string();

        emit_stream_error(app, &request_id, &message);

        return Err(message);
    }

    /*
     * Only now is the assistant response considered complete and safe
     * to add to the conversation history.
     */
    chat.push(json!({
        "role": "assistant",
        "content": assistant_text,
    }));

    /*
     * Tell the frontend that streaming completed successfully.
     */
    app.emit(
        "chat-stream",
        StreamChunk {
            request_id,
            delta: String::new(),
            done: true,
            error: None,
        },
    )
    .map_err(|err| {
        format!(
            "Could not emit Ollama stream completion: {err}"
        )
    })?;

    Ok(())
}

/// Process one complete Ollama NDJSON object.
///
/// Returns:
///     Ok(true)  -> Ollama marked the stream as complete.
///     Ok(false) -> more data is expected.
///     Err(...)  -> malformed/error response.
fn process_stream_line(
    app: &AppHandle,
    request_id: &str,
    line: &str,
    assistant_text: &mut String,
) -> Result<bool, String> {
    let value: Value = serde_json::from_str(line)
        .map_err(|err| format!("Bad Ollama stream response: {err}"))?;

    /*
     * Ollama can report an API-level error inside an otherwise valid
     * JSON stream.
     */
    if let Some(error) = value.get("error").and_then(Value::as_str) {
        return Err(format!("Ollama: {error}"));
    }

    /*
     * Extract the assistant text delta.
     */
    let delta = value
        .get("message")
        .and_then(|message| message.get("content"))
        .and_then(Value::as_str)
        .unwrap_or("");

    if !delta.is_empty() {
        assistant_text.push_str(delta);

        app.emit(
            "chat-stream",
            StreamChunk {
                request_id: request_id.to_string(),
                delta: delta.to_string(),
                done: false,
                error: None,
            },
        )
        .map_err(|err| {
            format!(
                "Could not emit Ollama stream event: {err}"
            )
        })?;
    }

    /*
     * Ollama sends done=true on the final object.
     */
    Ok(value
        .get("done")
        .and_then(Value::as_bool)
        .unwrap_or(false))
}

fn emit_stream_error(
    app: &AppHandle,
    request_id: &str,
    error: &str,
) {
    let _ = app.emit(
        "chat-stream",
        StreamChunk {
            request_id: request_id.to_string(),
            delta: String::new(),
            done: true,
            error: Some(error.to_string()),
        },
    );
}

async fn call(body: &Value) -> Result<Value, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(90))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(ENDPOINT)
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| {
            format!(
                "Could not reach Ollama at {ENDPOINT}. \
                 Make sure Ollama is running. ({e})"
            )
        })?;

    let status = response.status();

    let text = response
        .text()
        .await
        .map_err(|e| {
            format!("Could not read Ollama response: {e}")
        })?;

    let value = serde_json::from_str::<Value>(&text)
        .map_err(|e| {
            format!("Bad Ollama API response: {e}")
        })?;

    if !status.is_success() {
        let detail = value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Unknown Ollama error");

        return Err(format!(
            "Ollama API {status}: {detail}"
        ));
    }

    Ok(value)
}

async fn stream_call(
    body: &Value,
) -> Result<reqwest::Response, String> {
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(180))
        .build()
        .map_err(|e| e.to_string())?;

    let response = client
        .post(ENDPOINT)
        .header("content-type", "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| {
            format!(
                "Could not reach Ollama at {ENDPOINT}. \
                 Make sure Ollama is running. ({e})"
            )
        })?;

    let status = response.status();

    if !status.is_success() {
        let text = response
            .text()
            .await
            .map_err(|e| {
                format!(
                    "Could not read Ollama error response: {e}"
                )
            })?;

        let value =
            serde_json::from_str::<Value>(&text)
                .unwrap_or_else(|_| json!({}));

        let detail = value
            .get("error")
            .and_then(Value::as_str)
            .unwrap_or("Unknown Ollama error");

        return Err(format!(
            "Ollama API {status}: {detail}"
        ));
    }

    Ok(response)
}

fn file_text(path: &str) -> Result<Option<String>, String> {
    let path = std::path::Path::new(path);

    let len = std::fs::metadata(path)
        .map_err(|e| {
            format!("Could not read file metadata: {e}")
        })?
        .len();

    if len > MAX_INLINE_TEXT {
        return Err(
            "File is too large for Ollama context \
             (maximum 200,000 bytes)."
                .into(),
        );
    }

    match std::fs::read_to_string(path) {
        Ok(text) => Ok(Some(text)),
        Err(_) => Ok(None),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn default_model_is_cloud_120b() {
        assert_eq!(
            DEFAULT_MODEL,
            "gpt-oss:120b-cloud"
        );
    }

    #[test]
    fn stream_chunk_uses_camel_case_fields() {
        let chunk = StreamChunk {
            request_id: "test-request".into(),
            delta: "hello".into(),
            done: false,
            error: None,
        };

        let value =
            serde_json::to_value(chunk).unwrap();

        assert_eq!(
            value["requestId"],
            "test-request"
        );

        assert_eq!(value["delta"], "hello");
        assert_eq!(value["done"], false);
        assert!(value["error"].is_null());
    }
}