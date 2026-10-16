use serde_json::{json, Value};
use std::collections::HashMap;

use super::models::{MCPTool, MCPToolResult};

const SAFE_READ_PREFIXES: &[&str] = &[
    "get_", "list_", "read_", "search_", "fetch_", "check_", "describe_", "view_", "show_", "find_",
];
const MUTATING_KEYWORDS: &[&str] = &[
    "write", "delete", "remove", "drop", "send", "post", "update", "create", "insert", "execute", "run", "edit", "patch", "modify",
];

/// Formats a raw JSON-RPC 2.0 request line (newline-terminated).
pub fn make_request(id: u64, method: &str, params: Option<Value>) -> String {
    let mut obj = json!({
        "jsonrpc": "2.0",
        "id": id,
        "method": method,
    });
    if let Some(p) = params {
        obj["params"] = p;
    }
    format!("{}\n", obj)
}

/// Builds a formatted JSON-RPC 2.0 notification line (newline-terminated).
pub fn make_notification(method: &str, params: Option<Value>) -> String {
    let mut obj = json!({
        "jsonrpc": "2.0",
        "method": method,
    });
    if let Some(p) = params {
        obj["params"] = p;
    }
    format!("{}\n", obj)
}

/// Initial MCP handshake request.
pub fn initialize_request(id: u64, client_name: &str, version: &str) -> String {
    let params = json!({
        "protocolVersion": "2024-11-05",
        "capabilities": {
            "tools": {}
        },
        "clientInfo": {
            "name": client_name,
            "version": version,
        }
    });
    make_request(id, "initialize", Some(params))
}

/// Confirms MCP initialization completion.
pub fn initialized_notification() -> String {
    make_notification("notifications/initialized", None)
}

/// Requests available tools from the server.
pub fn tools_list_request(id: u64) -> String {
    make_request(id, "tools/list", None)
}

/// Invokes a specific tool on the server with arguments.
pub fn tool_call_request(id: u64, name: &str, arguments: &HashMap<String, Value>) -> String {
    let params = json!({
        "name": name,
        "arguments": arguments,
    });
    make_request(id, "tools/call", Some(params))
}

/// Decodes a line of JSON-RPC response.
pub fn parse_response(line: &str) -> Option<(Option<u64>, Option<Value>, Option<Value>)> {
    let json: Value = serde_json::from_str(line).ok()?;
    let id = json.get("id").and_then(Value::as_u64);
    let result = json.get("result").cloned();
    let error = json.get("error").cloned();
    Some((id, result, error))
}

/// Determines if a tool operation is purely read-only vs mutating based on name and schema hints.
pub fn is_read_only(name: &str, description: &str) -> bool {
    let lower_name = name.to_ascii_lowercase();
    let lower_desc = description.to_ascii_lowercase();

    for keyword in MUTATING_KEYWORDS {
        if lower_name.contains(keyword) || lower_desc.contains(keyword) {
            return false;
        }
    }
    for prefix in SAFE_READ_PREFIXES {
        if lower_name.starts_with(prefix) {
            return true;
        }
    }
    lower_desc.contains("read only") || lower_desc.contains("does not modify")
}

/// Parses the payload from tools/list into a list of MCPTool structs.
pub fn parse_tools_list(result: &Value, server_id: &str, server_name: &str) -> Vec<MCPTool> {
    let mut out = Vec::new();
    let Some(tools_arr) = result.get("tools").and_then(Value::as_array) else {
        return out;
    };

    for item in tools_arr {
        let Some(name) = item.get("name").and_then(Value::as_str) else {
            continue;
        };
        let desc = item.get("description").and_then(Value::as_str).unwrap_or("");
        let schema = item.get("inputSchema").cloned().unwrap_or_else(|| json!({ "type": "object" }));
        let read_only = is_read_only(name, desc);

        out.push(MCPTool {
            id: format!("mcp__{server_id}__{name}"),
            name: name.to_string(),
            server_id: server_id.to_string(),
            server_name: server_name.to_string(),
            description: desc.to_string(),
            input_schema: schema,
            is_read_only: read_only,
        });
    }
    out
}

/// Parses the output of a tools/call execution into an MCPToolResult.
pub fn parse_tool_call_result(result: Option<&Value>, error: Option<&Value>) -> MCPToolResult {
    if let Some(err) = error {
        let msg = err.get("message").and_then(Value::as_str).unwrap_or("MCP error");
        return MCPToolResult {
            content: msg.to_string(),
            is_error: true,
        };
    }

    let Some(res) = result else {
        return MCPToolResult {
            content: "Empty result from tool execution.".to_string(),
            is_error: false,
        };
    };

    let is_err = res.get("isError").and_then(Value::as_bool).unwrap_or(false);
    if let Some(content_arr) = res.get("content").and_then(Value::as_array) {
        let texts: Vec<&str> = content_arr
            .iter()
            .filter_map(|c| {
                if c.get("type").and_then(Value::as_str) == Some("text") {
                    c.get("text").and_then(Value::as_str)
                } else {
                    None
                }
            })
            .collect();

        if !texts.is_empty() {
            return MCPToolResult {
                content: texts.join("\n"),
                is_error: is_err,
            };
        }
    }

    MCPToolResult {
        content: res.to_string(),
        is_error: is_err,
    }
}

/// Encodes an MCP tool into OpenAI-compatible function calling definition.
pub fn to_openai_tool(tool: &MCPTool) -> Value {
    json!({
        "type": "function",
        "function": {
            "name": tool.id,
            "description": format!("[MCP: {}] {}", tool.server_name, tool.description),
            "parameters": tool.input_schema
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn request_building_format() {
        let req = initialize_request(1, "Coucou", "0.3.0");
        assert!(req.ends_with('\n'));
        assert!(req.contains(r#""jsonrpc":"2.0""#));
        assert!(req.contains(r#""method":"initialize""#));

        let list_req = tools_list_request(2);
        assert!(list_req.contains(r#""method":"tools/list""#));
    }

    #[test]
    fn read_only_heuristic_detection() {
        assert!(is_read_only("get_user", "Returns user details"));
        assert!(is_read_only("list_files", ""));
        assert!(!is_read_only("delete_file", "Removes a file from disk"));
        assert!(!is_read_only("execute_query", "Runs arbitrary SQL"));
    }
}
