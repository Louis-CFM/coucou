use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Serialize, Deserialize)]
pub struct McpToolCall {
    pub server_name: String,
    pub tool_name: String,
    pub arguments: Value,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct McpResponse {
    pub success: bool,
    pub content: Value,
}

pub struct McpClient;

impl McpClient {
    pub async fn execute_tool(call: McpToolCall) -> Result<McpResponse, String> {
        println!(
            "[MCP Client] Chamando ferramenta '{}' no servidor '{}'",
            call.tool_name, call.server_name
        );

        // Simulated local tool evaluation with structured response
        let result = match call.tool_name.as_str() {
            "list_files" => serde_json::json!({
                "files": ["documentos/proposta.pdf", "planilhas/metricas_q3.xlsx", "anotacoes.txt"]
            }),
            "read_file" => serde_json::json!({
                "content": "Contrato de Prestação de Serviços Coucou Realtime - Vigência: 12 meses."
            }),
            _ => serde_json::json!({
                "status": "executed",
                "tool": call.tool_name,
                "server": call.server_name,
                "input": call.arguments
            }),
        };

        Ok(McpResponse {
            success: true,
            content: result,
        })
    }
}
