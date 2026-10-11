use crate::tools::mcp::{McpClient, McpToolCall};
use crate::tools::smtp::{send_email, EmailPayload};
use crate::tools::webhook::{dispatch_webhook, WebhookPayload};
use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Serialize, Deserialize)]
pub struct ToolExecutionRequest {
    pub tool_id: String,
    pub tool_type: String, // 'webhook', 'smtp', 'mcp'
    pub name: String,
    pub parameters: Value,
    pub confirmed_by_user: bool,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct ToolExecutionResponse {
    pub success: bool,
    pub output: Value,
    pub error: Option<String>,
}

pub struct ToolRunner;

impl ToolRunner {
    pub async fn run(request: ToolExecutionRequest) -> Result<ToolExecutionResponse, String> {
        match request.tool_type.as_str() {
            "webhook" => {
                let payload: WebhookPayload = serde_json::from_value(request.parameters)
                    .map_err(|e| format!("Parâmetros de webhook inválidos: {}", e))?;
                match dispatch_webhook(payload).await {
                    Ok(resp) => Ok(ToolExecutionResponse {
                        success: resp.success,
                        output: serde_json::to_value(&resp).unwrap(),
                        error: None,
                    }),
                    Err(e) => Ok(ToolExecutionResponse {
                        success: false,
                        output: Value::Null,
                        error: Some(e),
                    }),
                }
            }
            "smtp" => {
                let payload: EmailPayload = serde_json::from_value(request.parameters)
                    .map_err(|e| format!("Parâmetros de e-mail inválidos: {}", e))?;
                match send_email(payload).await {
                    Ok(resp) => Ok(ToolExecutionResponse {
                        success: resp.success,
                        output: serde_json::to_value(&resp).unwrap(),
                        error: None,
                    }),
                    Err(e) => Ok(ToolExecutionResponse {
                        success: false,
                        output: Value::Null,
                        error: Some(e),
                    }),
                }
            }
            "mcp" => {
                let payload: McpToolCall = serde_json::from_value(request.parameters)
                    .map_err(|e| format!("Parâmetros de chamada MCP inválidos: {}", e))?;
                match McpClient::execute_tool(payload).await {
                    Ok(resp) => Ok(ToolExecutionResponse {
                        success: resp.success,
                        output: resp.content,
                        error: None,
                    }),
                    Err(e) => Ok(ToolExecutionResponse {
                        success: false,
                        output: Value::Null,
                        error: Some(e),
                    }),
                }
            }
            _ => Err(format!("Tipo de ferramenta desconhecido: {}", request.tool_type)),
        }
    }
}
