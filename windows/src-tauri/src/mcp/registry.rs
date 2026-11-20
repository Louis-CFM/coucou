use std::collections::HashMap;
use std::sync::Arc;
use tokio::sync::RwLock;

use serde_json::Value;

use super::http::HttpClient;
use super::models::{MCPServerConfig, MCPTool, MCPToolResult, MCPTransport};
use super::stdio::StdioClient;

enum ClientHandle {
    Stdio(Arc<StdioClient>),
    Http(Arc<HttpClient>),
}

#[derive(Default)]
pub struct Registry {
    inner: RwLock<RegistryState>,
}

#[derive(Default)]
struct RegistryState {
    configs: Vec<MCPServerConfig>,
    clients: HashMap<String, ClientHandle>,
    tools: Vec<MCPTool>,
}

impl Registry {
    pub async fn refresh(&self, configs: Vec<MCPServerConfig>) {
        let mut state = self.inner.write().await;
        let mut new_clients = HashMap::new();
        let mut all_tools = Vec::new();

        for cfg in configs.iter().filter(|c| c.is_enabled) {
            match cfg.transport {
                MCPTransport::Stdio { .. } => {
                    let client = StdioClient::new(cfg.clone());
                    if let Ok(tools) = client.list_tools().await {
                        all_tools.extend(tools);
                    }
                    new_clients.insert(cfg.id.clone(), ClientHandle::Stdio(client));
                }
                MCPTransport::Http { .. } => {
                    let client = HttpClient::new(cfg.clone());
                    if let Ok(tools) = client.list_tools().await {
                        all_tools.extend(tools);
                    }
                    new_clients.insert(cfg.id.clone(), ClientHandle::Http(client));
                }
            }
        }

        state.configs = configs;
        state.clients = new_clients;
        state.tools = all_tools;
    }

    pub async fn get_openai_tools(&self) -> Vec<Value> {
        let state = self.inner.read().await;
        state.tools.iter().map(super::jsonrpc::to_openai_tool).collect()
    }

    pub async fn get_tool(&self, id: &str) -> Option<MCPTool> {
        let state = self.inner.read().await;
        state.tools.iter().find(|t| t.id == id).cloned()
    }

    pub async fn get_configs(&self) -> Vec<MCPServerConfig> {
        let state = self.inner.read().await;
        state.configs.clone()
    }

    pub async fn execute_tool(&self, qualified_id: &str, arguments: &HashMap<String, Value>) -> MCPToolResult {
        let state = self.inner.read().await;
        let Some(tool) = state.tools.iter().find(|t| t.id == qualified_id) else {
            return MCPToolResult {
                content: format!("Unknown MCP tool: {qualified_id}"),
                is_error: true,
            };
        };

        let Some(client) = state.clients.get(&tool.server_id) else {
            return MCPToolResult {
                content: format!("MCP server {} is not connected", tool.server_name),
                is_error: true,
            };
        };

        match client {
            ClientHandle::Stdio(c) => match c.call_tool(&tool.name, arguments).await {
                Ok(res) => res,
                Err(e) => MCPToolResult { content: e, is_error: true },
            },
            ClientHandle::Http(c) => match c.call_tool(&tool.name, arguments).await {
                Ok(res) => res,
                Err(e) => MCPToolResult { content: e, is_error: true },
            },
        }
    }
}
