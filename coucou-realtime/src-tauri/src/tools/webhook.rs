use reqwest::Client;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::time::Duration;

#[derive(Debug, Serialize, Deserialize)]
pub struct WebhookPayload {
    pub url: String,
    pub method: Option<String>,
    pub headers: Option<std::collections::HashMap<String, String>>,
    pub body: Option<Value>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct WebhookResponse {
    pub success: bool,
    pub status: u16,
    pub response_body: String,
}

pub async fn dispatch_webhook(payload: WebhookPayload) -> Result<WebhookResponse, String> {
    let client = Client::builder()
        .timeout(Duration::from_secs(10))
        .build()
        .map_err(|e| e.to_string())?;

    let method = payload.method.unwrap_or_else(|| "POST".to_string());
    let mut req = match method.to_uppercase().as_str() {
        "GET" => client.get(&payload.url),
        "PUT" => client.put(&payload.url),
        _ => client.post(&payload.url),
    };

    if let Some(headers) = payload.headers {
        for (k, v) in headers {
            req = req.header(k, v);
        }
    }

    if let Some(body) = payload.body {
        req = req.json(&body);
    }

    let resp = req.send().await.map_err(|e| e.to_string())?;
    let status = resp.status().as_u16();
    let text = resp.text().await.unwrap_or_default();

    Ok(WebhookResponse {
        success: status >= 200 && status < 300,
        status,
        response_body: text,
    })
}
