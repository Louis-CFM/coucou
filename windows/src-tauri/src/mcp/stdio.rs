use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::Arc;
use std::time::Duration;

use serde_json::Value;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::sync::Mutex;
use tokio::time::timeout;

use super::jsonrpc;
use super::models::{MCPServerConfig, MCPTool, MCPToolResult, MCPTransport};

pub struct StdioClient {
    pub config: MCPServerConfig,
    child: Mutex<Option<Child>>,
    stdin: Mutex<Option<ChildStdin>>,
    stdout_lines: Mutex<Option<tokio::io::Lines<BufReader<ChildStdout>>>>,
    next_id: AtomicU64,
}

impl StdioClient {
    pub fn new(config: MCPServerConfig) -> Arc<Self> {
        Arc::new(Self {
            config,
            child: Mutex::new(None),
            stdin: Mutex::new(None),
            stdout_lines: Mutex::new(None),
            next_id: AtomicU64::new(1),
        })
    }

    pub async fn ensure_started(&self) -> Result<(), String> {
        let mut child_guard = self.child.lock().await;
        if child_guard.is_some() {
            return Ok(());
        }

        let MCPTransport::Stdio { command, args, env } = &self.config.transport else {
            return Err("Not a stdio transport configuration".into());
        };

        let mut cmd = Command::new(command);
        cmd.args(args);
        // Inherit base PATH and essential system variables, but isolate Coucou's internal secrets
        let path_var = std::env::var("PATH").unwrap_or_default();
        cmd.env("PATH", path_var);

        #[cfg(windows)]
        {
            if let Ok(systemroot) = std::env::var("SystemRoot") {
                cmd.env("SystemRoot", systemroot);
            }
            if let Ok(temp) = std::env::var("TEMP") {
                cmd.env("TEMP", temp);
            }
            if let Ok(tmp) = std::env::var("TMP") {
                cmd.env("TMP", tmp);
            }
        }

        // Apply explicitly configured environment variables from config
        cmd.envs(env);
        cmd.stdin(Stdio::piped());
        cmd.stdout(Stdio::piped());
        cmd.stderr(Stdio::piped());

        #[cfg(windows)]
        {
            // CREATE_NO_WINDOW
            const CREATE_NO_WINDOW: u32 = 0x08000000;
            cmd.creation_flags(CREATE_NO_WINDOW);
        }

        let mut spawned = cmd
            .spawn()
            .map_err(|e| format!("Failed to start MCP server {}: {e}", self.config.name))?;

        let stdin = spawned.stdin.take().ok_or("Failed to open stdin pipe")?;
        let stdout = spawned.stdout.take().ok_or("Failed to open stdout pipe")?;
        let stderr = spawned.stderr.take();

        // Drain stderr continuously to prevent pipe buffer deadlocks
        if let Some(mut err_pipe) = stderr {
            tokio::spawn(async move {
                let mut buf = [0u8; 1024];
                while let Ok(n) = tokio::io::AsyncReadExt::read(&mut err_pipe, &mut buf).await {
                    if n == 0 {
                        break;
                    }
                }
            });
        }

        let reader = BufReader::new(stdout).lines();

        *child_guard = Some(spawned);
        *self.stdin.lock().await = Some(stdin);
        *self.stdout_lines.lock().await = Some(reader);

        // Perform MCP initialize handshake
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let init_req = jsonrpc::initialize_request(id, "Coucou", "0.3.0");
        let init_resp = self.send_and_receive(&init_req, id, Duration::from_secs(10)).await?;

        let (_, result, error) = jsonrpc::parse_response(&init_resp)
            .ok_or_else(|| "Invalid response during initialize".to_string())?;

        if let Some(err) = error {
            let msg = err.get("message").and_then(Value::as_str).unwrap_or("Initialize error");
            return Err(format!("Initialize error from {}: {msg}", self.config.name));
        }
        if result.is_none() {
            return Err("Missing result during MCP handshake".into());
        }

        // Send initialized notification
        let notif = jsonrpc::initialized_notification();
        self.write_line(&notif).await?;

        Ok(())
    }

    async fn write_line(&self, line: &str) -> Result<(), String> {
        let mut stdin_guard = self.stdin.lock().await;
        let stdin = stdin_guard.as_mut().ok_or("Server stdin not available")?;
        stdin
            .write_all(line.as_bytes())
            .await
            .map_err(|e| format!("Write failed: {e}"))?;
        stdin.flush().await.map_err(|e| format!("Flush failed: {e}"))?;
        Ok(())
    }

    async fn send_and_receive(&self, req_text: &str, target_id: u64, dur: Duration) -> Result<String, String> {
        self.write_line(req_text).await?;

        let mut lines_guard = self.stdout_lines.lock().await;
        let lines = lines_guard.as_mut().ok_or("Server stdout not available")?;

        let read_future = async {
            while let Ok(Some(line)) = lines.next_line().await {
                let trimmed = line.trim();
                if trimmed.is_empty() {
                    continue;
                }
                if let Some((Some(id), _, _)) = jsonrpc::parse_response(trimmed) {
                    if id == target_id {
                        return Ok(trimmed.to_string());
                    }
                }
            }
            Err("EOF received from server before response".to_string())
        };

        timeout(dur, read_future)
            .await
            .map_err(|_| format!("MCP request timed out after {}s", dur.as_secs()))?
    }

    pub async fn list_tools(&self) -> Result<Vec<MCPTool>, String> {
        self.ensure_started().await?;
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = jsonrpc::tools_list_request(id);
        let resp = self.send_and_receive(&req, id, Duration::from_secs(10)).await?;

        let (_, result, error) = jsonrpc::parse_response(&resp)
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
        self.ensure_started().await?;
        let id = self.next_id.fetch_add(1, Ordering::SeqCst);
        let req = jsonrpc::tool_call_request(id, name, arguments);
        let resp = self.send_and_receive(&req, id, Duration::from_secs(60)).await?;

        let (_, result, error) = jsonrpc::parse_response(&resp)
            .ok_or_else(|| "Invalid response for tools/call".to_string())?;

        Ok(jsonrpc::parse_tool_call_result(result.as_ref(), error.as_ref()))
    }
}
