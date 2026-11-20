use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::collections::HashMap;

/// Origin of an imported MCP server configuration.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum MCPServerSource {
    ClaudeDesktop,
    ClaudeCode,
    Cursor,
    Vscode,
    Windsurf,
    Opencode,
    Manual,
}

impl MCPServerSource {
    pub fn display_name(&self) -> &'static str {
        match self {
            Self::ClaudeDesktop => "Claude Desktop",
            Self::ClaudeCode => "Claude Code",
            Self::Cursor => "Cursor",
            Self::Vscode => "VS Code",
            Self::Windsurf => "Windsurf",
            Self::Opencode => "OpenCode",
            Self::Manual => "Manual",
        }
    }
}

/// Transport protocol used to communicate with an MCP server.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "type", rename_all = "lowercase")]
pub enum MCPTransport {
    Stdio {
        command: String,
        #[serde(default)]
        args: Vec<String>,
        #[serde(default)]
        env: HashMap<String, String>,
    },
    Http {
        url: String,
        #[serde(default)]
        headers: HashMap<String, String>,
    },
}

/// Stored configuration for a single MCP server.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MCPServerConfig {
    pub id: String,
    pub name: String,
    #[serde(default)]
    pub sources: Vec<MCPServerSource>,
    pub transport: MCPTransport,
    #[serde(default = "default_true")]
    pub is_enabled: bool,
    #[serde(default)]
    pub notes: Vec<String>,
}

fn default_true() -> bool {
    true
}

/// A tool published by an MCP server.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MCPTool {
    pub id: String,
    pub name: String,
    pub server_id: String,
    pub server_name: String,
    pub description: String,
    pub input_schema: Value,
    pub is_read_only: bool,
}

/// The result returned from invoking an MCP tool.
#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MCPToolResult {
    pub content: String,
    pub is_error: bool,
}
