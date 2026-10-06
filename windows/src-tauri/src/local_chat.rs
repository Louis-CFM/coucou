use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct LocalChatMessage {
    pub role: String,
    pub content: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalChatReply {
    pub text: String,
}

fn normalize_base_url(base_url: &str) -> String {
    let trimmed = base_url.trim().trim_end_matches('/');
    if trimmed.ends_with("/v1") {
        trimmed.to_string()
    } else {
        format!("{trimmed}/v1")
    }
}

pub fn strip_think_tags(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    while let Some(start_idx) = rest.find("<think>") {
        out.push_str(&rest[..start_idx]);
        let after_start = &rest[start_idx + 7..];
        if let Some(end_idx) = after_start.find("</think>") {
            rest = &after_start[end_idx + 8..];
        } else {
            // Unclosed trailing <think>...
            rest = "";
            break;
        }
    }
    out.push_str(rest);
    out.trim().to_string()
}

pub async fn models(base_url: &str) -> Result<Vec<String>, String> {
    let url = normalize_base_url(base_url);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(5))
        .build()
        .map_err(|e| e.to_string())?;

    let res = client
        .get(format!("{url}/models"))
        .send()
        .await
        .map_err(|e| format!("Could not connect to server: {e}"))?;

    if !res.status().is_success() {
        return Err(format!("Server returned HTTP {}", res.status()));
    }

    let json: Value = res
        .json()
        .await
        .map_err(|e| format!("Invalid JSON from /models: {e}"))?;

    let mut model_list = Vec::new();

    let items = if let Some(arr) = json.get("data").and_then(|d| d.as_array()) {
        arr
    } else if let Some(arr) = json.get("models").and_then(|m| m.as_array()) {
        arr
    } else if let Some(arr) = json.as_array() {
        arr
    } else {
        return Err("Unrecognized models list format".to_string());
    };

    for item in items {
        let name_opt = item
            .get("id")
            .and_then(|v| v.as_str())
            .or_else(|| item.get("name").and_then(|v| v.as_str()))
            .or_else(|| item.as_str());

        if let Some(name) = name_opt {
            let lower = name.to_lowercase();
            if lower.contains("embed") || lower.contains("bge-") || lower.contains("rerank") {
                continue;
            }
            if !model_list.contains(&name.to_string()) {
                model_list.push(name.to_string());
            }
        }
    }

    Ok(model_list)
}

pub async fn chat_send(
    base_url: &str,
    model: &str,
    messages: Vec<LocalChatMessage>,
) -> Result<LocalChatReply, String> {
    let url = normalize_base_url(base_url);
    let client = reqwest::Client::builder()
        .timeout(std::time::Duration::from_secs(120))
        .build()
        .map_err(|e| e.to_string())?;

    let payload = serde_json::json!({
        "model": model,
        "messages": messages,
        "stream": false,
    });

    let res = client
        .post(format!("{url}/chat/completions"))
        .header("Content-Type", "application/json")
        .json(&payload)
        .send()
        .await
        .map_err(|e| format!("Failed to connect to local LLM: {e}"))?;

    if !res.status().is_success() {
        let err_text = res.text().await.unwrap_or_default();
        return Err(format!("Local LLM error: {err_text}"));
    }

    let json: Value = res
        .json()
        .await
        .map_err(|e| format!("Invalid JSON response: {e}"))?;

    let raw_content = json
        .get("choices")
        .and_then(|c| c.get(0))
        .and_then(|c| c.get("message"))
        .and_then(|m| m.get("content"))
        .and_then(|v| v.as_str())
        .ok_or_else(|| "Missing choices[0].message.content in response".to_string())?;

    let text = strip_think_tags(raw_content);
    Ok(LocalChatReply { text })
}
