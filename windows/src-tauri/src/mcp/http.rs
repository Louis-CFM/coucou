use std::collections::HashMap;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use reqwest::header::{HeaderMap, HeaderName, HeaderValue};
use serde_json::Value;

use super::jsonrpc;
use super::models::{MCPServerConfig, MCPTool, MCPToolResult, MCPTransport};

pub struct HttpClient {
    pub config: MCPServerConfig,
    client: reqwest::Client,
    next_id: AtomicU64,
}

impl HttpClient {
    pub fn new(config: MCPServerConfig) -> Arc<Self> {
        let mut headers = HeaderMap::new();
        headers.insert(reqwest::header::CONTENT_TYPE, HeaderValue::from_static("application/json"));

        if let MCPTransport::Http { headers: ref h_map, .. } = config.transport {
            for (k, v) in h_map {
                if let (Ok(hname), Ok(hval)) = (HeaderName::from_bytes(k.as_bytes()), HeaderValue::from_str(v)) {
                    headers.insert(hname, hval);
                }
            }
        }

        let client = reqwest::Client::builder()
            .default_headers(headers)
            .timeout(Duration::from_secs(60))
            .build()
            .unwrap_or_default();

        Arc::new(Self {
            config,
            client,
            next_id: AtomicU64::new(1),
        })
    }

    async fn post_jsonrpc(&self, body_text: &str, dur: Duration) -> Result<String, String> {
        let MCPTransport::Http { ref url, .. } = self.config.transport else {
            return Err("Not an HTTP transport".into());
        };

        let resp = self
            .client
            .post(url)
            .body(body_text.to_string())
            .timeout(dur)
            .send()
            .await
            .map_err(|e| format!("HTTP request to {} failed: {e}", self.config.name))?;

        let status = resp.status();
        if !status.is_success() {
            return Err(format!("HTTP {} from {}", status.as_u16(), self.config.name));
        }

        let text = resp
            .text()
            .await
            .map_err(|e| format!("Failed to read response body: {e}"))?;

        Ok(text)
    }

    pub async fn list_tools(&self) -> Result<Vec<MCPTool>, String> {
        // Initialize request
        let id1 = self.next_id.fetch_add(1, Ordering::SeqCst);
        let init_req = jsonrpc::initialize_request(id1, "Coucou", "0.3.0");
        let init_resp = self.post_jsonrpc(&init_req, Duration::from_secs(10)).await?;

        let (_, result, error) = jsonrpc::parse_response(&init_resp)
            .ok_or_else(|| "Invalid response during initialize".to_string())?;

        if let Some(err) = error {
            let msg = err.get("message").and_then(Value::as_str).unwrap_or("Initialize error");
            return Err(format!("{}: {msg}", self.config.name));
        }
        if result.is_none() {
            return Err("Missing initialize result".into());
        }

        // Tools/list request
        let id2 = self.next_id.fetch_add(1, Ordering::SeqCst);
        let list_req = jsonrpc::tools_list_request(id2);
        let list_resp = self.post_jsonrpc(&list_req, Duration::from_secs(10)).await?;

        let (_, result, error) = jsonrpc::parse_response(&list_resp)
            .ok_or_else(|| "Invalid response for tools/list".to_string())?;

        if let Some(err) = error {
            let msg = err.get("message").and_then(Value::as_str).unwrap_or("tools/list error");
            return Err(msg.to_string());
        }

        let Some(res) = result else {
            return Ok(Vec::new());
        };

        Ok(jsonrpc::parse_tools_list(&res, &self.config.id, &self.config.name))
    }

    pub async fn call_tool(&self, name: &str, arguments: &HashMap<String, Value>) -> Result<MCPToolResult, String> {
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = jsonrpc::tool_call_request(id, name, arguments);
        let resp = self.post_jsonrpc(&req, Duration::from_secs(60)).await?;

        let (_, result, error) = jsonrpc::parse_response(&resp)
            .ok_or_else(|| "Invalid response for tools/call".to_string())?;

        Ok(jsonrpc::parse_tool_call_result(result.as_ref(), error.as_ref()))
    }
}
