//! OpenAI Responses client. Credentials and file bytes stay in Rust. History is
//! held locally, with store:false and no implicit fallback to another provider.
use std::{io::Read, path::Path, time::Duration};
use serde_json::{json, Value};
use crate::{chat::{Chat, Provider}, claude::{base64_for, ChatContext, ChatReply}, secrets};

const ENDPOINT: &str = "https://api.openai.com/v1/responses";
pub const DEFAULT_MODEL: &str = "gpt-4.1-mini";
const MAX_ATTACHMENT: u64 = 20 * 1024 * 1024;
const MAX_TEXT: u64 = 200_000;
const INSTRUCTIONS: &str = "You are Mochi, a personal AI assistant living at the top of the user's screen. \
Respond in the user's language. Help with questions and the files the user shares. \
You have no live web search or computer tools in this chat. \
Use plain text with line breaks, without markdown formatting.";

pub async fn send(chat: &Chat, model: &str, query: String, context: Option<ChatContext>) -> Result<ChatReply, String> {
    let key = secrets::get("openai-api-key")
        .ok_or("OpenAI API key missing. Open Settings → OpenAI.")?;
    send_to(chat, model, query, context, &key, ENDPOINT).await
}

async fn send_to(chat: &Chat, model: &str, query: String, context: Option<ChatContext>, key: &str, endpoint: &str) -> Result<ChatReply, String> {
    if model.trim().is_empty() {
        return Err("Choose an OpenAI model in settings.".into());
    }
    let (generation, mut messages) = chat.begin(Provider::Openai, model);
    let content = user_content(query, if messages.is_empty() { context } else { None })?;
    messages.push(json!({"role": "user", "content": content}));
    let body = json!({
        "model": model,
        "instructions": INSTRUCTIONS,
        "input": messages,
        "max_output_tokens": 4096,
        "store": false,
        "include": ["reasoning.encrypted_content"],
    });
    let response = call(key, endpoint, &body).await?;
    let (text, output) = reply(&response)?;
    messages.extend(output);
    chat.commit(generation, messages)?;
    Ok(ChatReply { text })
}

fn user_content(query: String, context: Option<ChatContext>) -> Result<Vec<Value>, String> {
    let mut content = Vec::new();
    match context {
        Some(ChatContext::File { name, path }) => {
            content.push(file_block(&path)?);
            content.push(json!({"type": "input_text", "text": format!("File: {name}")}));
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            let mut text = format!("Context — App: {app_name}, Window: {title}");
            if let Some(url) = url { text.push_str(&format!(", URL: {url}")); }
            content.push(json!({"type": "input_text", "text": text}));
        }
        None => {}
    }
    content.push(json!({"type": "input_text", "text": query}));
    Ok(content)
}

fn file_block(path: &str) -> Result<Value, String> {
    let path = Path::new(path);
    let ext = path.extension().and_then(|v| v.to_str()).unwrap_or("").to_lowercase();
    let mime = match ext.as_str() {
        "pdf" => Some("application/pdf"),
        "png" => Some("image/png"),
        "jpg" | "jpeg" => Some("image/jpeg"),
        "gif" => Some("image/gif"),
        "webp" => Some("image/webp"),
        _ => None,
    };
    let file = std::fs::File::open(path).map_err(|_| "Could not read the attached file.")?;
    if !file.metadata().map_err(|_| "Could not inspect the attached file.")?.is_file() {
        return Err("Attach a regular file.".into());
    }
    let limit = if mime.is_some() { MAX_ATTACHMENT } else { MAX_TEXT };
    let mut bytes = Vec::new();
    file.take(limit + 1).read_to_end(&mut bytes).map_err(|_| "Could not read the attached file.")?;
    if bytes.len() as u64 > limit {
        return Err(if mime.is_some() { "Attachments must be at most 20 MiB." } else { "Text attachments must be at most 200 KB." }.into());
    }
    match mime {
        Some("application/pdf") => Ok(json!({
            "type": "input_file",
            "filename": path.file_name().and_then(|v| v.to_str()).unwrap_or("document.pdf"),
            "file_data": format!("data:application/pdf;base64,{}", base64_for(&bytes)),
        })),
        Some(mime) => Ok(json!({"type": "input_image", "image_url": format!("data:{mime};base64,{}", base64_for(&bytes))})),
        None => {
            let text = String::from_utf8(bytes).map_err(|_| "Unsupported attachment. Use PDF, PNG, JPEG, GIF, WebP or UTF-8 text.")?;
            Ok(json!({"type": "input_text", "text": format!("File contents:\n{text}")}))
        }
    }
}

async fn call(key: &str, endpoint: &str, body: &Value) -> Result<Value, String> {
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(90))
        .redirect(reqwest::redirect::Policy::none())
        .build().map_err(|e| e.to_string())?
        .post(endpoint).bearer_auth(key).json(body)
        .send().await.map_err(|e| format!("OpenAI network error: {e}"))?;
    let status = response.status();
    let value: Value = response.json().await
        .map_err(|_| format!("OpenAI API {status}: invalid JSON response."))?;
    if !status.is_success() {
        let detail = value["error"]["message"].as_str().unwrap_or("Request failed.");
        // Invalid-key errors can echo part of the credential; never show them.
        let detail = if status == reqwest::StatusCode::UNAUTHORIZED {
            "Authentication failed. Check your OpenAI API key in settings.".to_string()
        } else {
            detail.replace(key, "[redacted]").chars().take(500).collect()
        };
        return Err(format!("OpenAI API {status}: {detail}"));
    }
    Ok(value)
}

fn reply(response: &Value) -> Result<(String, Vec<Value>), String> {
    if response["status"].as_str() != Some("completed") {
        let reason = response["incomplete_details"]["reason"].as_str()
            .or(response["error"]["code"].as_str()).unwrap_or("unexpected response status");
        return Err(format!("OpenAI response incomplete ({reason}). Try a shorter request."));
    }
    let output = response["output"].as_array().ok_or("Unexpected OpenAI response: no output.")?;
    let mut texts = Vec::new();
    for item in output {
        if item["type"] != "message" { continue; }
        for block in item["content"].as_array().into_iter().flatten() {
            match block["type"].as_str() {
                Some("output_text") => if let Some(text) = block["text"].as_str() { texts.push(text); },
                Some("refusal") => return Err(block["refusal"].as_str().unwrap_or("OpenAI declined this request.").into()),
                _ => {}
            }
        }
    }
    let text = texts.join("\n").trim().to_string();
    if text.is_empty() { return Err("OpenAI returned no response text.".into()); }
    // Replay output items, including encrypted reasoning, for stateless turns.
    Ok((text, output.clone()))
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn response() -> Value {
        json!({"status": "completed", "output": [
            {"type": "reasoning", "id": "r1", "encrypted_content": "opaque"},
            {"type": "message", "role": "assistant", "content": [{"type": "output_text", "text": "Hola"}]}
        ]})
    }

    #[test]
    fn rejects_incomplete_refused_and_empty_output() {
        assert_eq!(reply(&response()).unwrap().0, "Hola");
        for bad in [json!({"status":"incomplete","incomplete_details":{"reason":"max_output_tokens"}}),
            json!({"status":"completed","output":[]}),
            json!({"status":"completed","output":[{"type":"message","content":[{"type":"refusal","refusal":"Declined"}]}]})] {
            assert!(reply(&bad).is_err());
        }
    }

    #[test]
    fn attachments_are_encoded_and_bounded() {
        let dir = std::env::temp_dir().join(format!("coucou-openai-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        for (name, kind, bytes) in [("test.pdf", "input_file", b"fixture".as_slice()), ("test.png", "input_image", b"fixture".as_slice()), ("test.txt", "input_text", "Español".as_bytes())] {
            let path = dir.join(name);
            std::fs::write(&path, bytes).unwrap();
            let block = file_block(path.to_str().unwrap()).unwrap();
            assert_eq!(block["type"], kind);
            if kind == "input_file" { assert_eq!(block["file_data"], "data:application/pdf;base64,Zml4dHVyZQ=="); }
        }
        let path = dir.join("large.txt");
        std::fs::File::create(&path).unwrap().set_len(MAX_TEXT + 1).unwrap();
        assert!(file_block(path.to_str().unwrap()).is_err());
        std::fs::write(&path, [0xff, 0xfe]).unwrap();
        assert!(file_block(path.to_str().unwrap()).is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }

    #[test]
    fn http_auth_multiturn_and_failure_rollback() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let endpoint = format!("http://{}/v1/responses", listener.local_addr().unwrap());
        let worker = std::thread::spawn(move || {
            let mut bodies = Vec::new();
            for index in 0..3 {
                let (mut stream, _) = listener.accept().unwrap();
                stream.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
                let mut request = Vec::new();
                let header_end = loop {
                    let mut byte = [0];
                    stream.read_exact(&mut byte).unwrap();
                    request.push(byte[0]);
                    if request.ends_with(b"\r\n\r\n") { break request.len(); }
                };
                let headers = String::from_utf8_lossy(&request).to_lowercase();
                assert!(headers.contains("authorization: bearer test-key"));
                let len: usize = headers.lines().find_map(|l| l.strip_prefix("content-length: ")).unwrap().parse().unwrap();
                request.resize(header_end + len, 0);
                stream.read_exact(&mut request[header_end..]).unwrap();
                bodies.push(serde_json::from_slice::<Value>(&request[header_end..]).unwrap());
                let (status, body) = if index == 1 { ("401 Unauthorized", json!({"error":{"message":"Invalid test-key"}})) } else { ("200 OK", response()) };
                let body = body.to_string();
                write!(stream, "HTTP/1.1 {status}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
            }
            bodies
        });
        let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
        runtime.block_on(async {
            let chat = Chat::default();
            assert_eq!(send_to(&chat, DEFAULT_MODEL, "Hola".into(), None, "test-key", &endpoint).await.unwrap().text, "Hola");
            let error = send_to(&chat, DEFAULT_MODEL, "failed turn".into(), None, "test-key", &endpoint).await.err().unwrap();
            assert!(!error.contains("test-key"));
            send_to(&chat, DEFAULT_MODEL, "Continue".into(), None, "test-key", &endpoint).await.unwrap();
        });
        let bodies = worker.join().unwrap();
        assert_eq!(bodies[0]["store"], false);
        assert!(bodies[0].get("previous_response_id").is_none());
        assert_eq!(bodies[2]["input"].as_array().unwrap().len(), 4);
        assert_eq!(bodies[2]["input"][1]["encrypted_content"], "opaque");
        assert!(!bodies[2].to_string().contains("failed turn"));
    }
}
