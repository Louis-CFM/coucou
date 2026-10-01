// Chat with the local Cursor agent.
//
// Coucou does not talk to Cursor's cloud itself. It runs the `agent` CLI the
// user already logged into. Agent mode edits the remembered project, even
// when the Cursor window is closed.
// Ask mode only answers. Follow-ups resume the same CLI chat until the island
// starts a new one.

use std::path::PathBuf;
use std::sync::Mutex;
use std::time::Duration;

use serde_json::Value;
use tokio::process::Command;
use tokio::time::timeout;

use crate::claude::ChatReply;

/// A conversation can sit on a tool for a while. Past this, the CLI is killed.
const TURN_LIMIT: Duration = Duration::from_secs(300);
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

#[derive(Default)]
pub struct CursorChat {
    session_id: Mutex<Option<String>>,
}

impl CursorChat {
    pub fn reset(&self) {
        *self.session_id.lock().unwrap() = None;
    }
}

/// One turn. `mode` is `agent` or `ask`. Agent edits go to `cwd`, so a turn
/// without a real folder is refused rather than aimed at whatever directory
/// the process inherited.
pub async fn send(
    chat: &CursorChat,
    query: String,
    cwd: Option<String>,
    mode: String,
) -> Result<ChatReply, String> {
    let query = query.trim().to_string();
    if query.is_empty() {
        return Err("Nothing to send.".into());
    }
    let bin = find_agent().ok_or_else(|| {
        "Cursor's agent CLI is not installed. In PowerShell: irm 'https://cursor.com/install?win32=true' | iex — then run `agent login`.".to_string()
    })?;

    let edit = match mode.as_str() {
        "agent" => true,
        "ask" => false,
        _ => return Err("Unknown Cursor mode.".into()),
    };
    let session = chat.session_id.lock().unwrap().clone();
    let workspace = cwd.filter(|dir| std::path::Path::new(dir).is_dir());
    if edit && workspace.is_none() {
        return Err(
            "Choose a project first. The folder button in the chat picks it, and Coucou keeps it after Cursor closes.".into(),
        );
    }

    let mut cmd = Command::new(&bin);
    cmd.arg("-p").arg("--output-format").arg("json").arg("--trust");
    if edit {
        // `--force` answers command prompts so a headless turn is not stuck
        // waiting for a click. `--sandbox disabled` writes the real project.
        cmd.arg("--force").arg("--sandbox").arg("disabled");
    } else {
        cmd.arg("--mode").arg("ask");
    }
    if let Some(dir) = &workspace {
        cmd.arg("--workspace").arg(dir);
    }
    if let Some(id) = &session {
        // One argument: a bare `--resume` would swallow the prompt that follows.
        cmd.arg(format!("--resume={id}"));
    }
    cmd.arg(&query);
    cmd.stdin(std::process::Stdio::null());
    cmd.stdout(std::process::Stdio::piped());
    cmd.stderr(std::process::Stdio::piped());
    cmd.kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(CREATE_NO_WINDOW);

    crate::log::line("cursor chat turn".to_string());
    let child = cmd.spawn().map_err(|err| format!("Could not start Cursor: {err}"))?;
    let output = match timeout(TURN_LIMIT, child.wait_with_output()).await {
        Ok(Ok(output)) => output,
        Ok(Err(err)) => return Err(format!("Cursor stopped: {err}")),
        Err(_) => return Err("Cursor took too long to answer.".into()),
    };

    let stdout = String::from_utf8_lossy(&output.stdout);
    let stderr = String::from_utf8_lossy(&output.stderr);
    if !output.status.success() && stdout.trim().is_empty() {
        let detail = stderr.trim();
        if detail.is_empty() {
            return Err("Cursor did not answer.".into());
        }
        return Err(clip(detail));
    }

    let (text, next_session) = parse_reply(&stdout)?;
    if let Some(id) = next_session {
        *chat.session_id.lock().unwrap() = Some(id);
    }
    Ok(ChatReply { text })
}

fn find_agent() -> Option<PathBuf> {
    if let Some(on_path) = super::find_on_path("agent") {
        return Some(on_path);
    }
    let home = std::env::var_os("USERPROFILE").map(PathBuf::from)?;
    let local = std::env::var_os("LOCALAPPDATA").map(PathBuf::from);
    let mut candidates = vec![
        home.join(".local").join("bin").join("agent.exe"),
        home.join(".cursor").join("bin").join("agent.exe"),
    ];
    if let Some(local) = local {
        candidates.push(local.join("cursor-agent").join("agent.exe"));
        candidates.push(local.join("cursor-agent").join("agent.cmd"));
    }
    candidates.into_iter().find(|path| path.is_file())
}

fn parse_reply(stdout: &str) -> Result<(String, Option<String>), String> {
    let value = serde_json::from_str::<Value>(stdout.trim()).or_else(|_| {
        stdout
            .lines()
            .rev()
            .find_map(|line| serde_json::from_str::<Value>(line.trim()).ok())
            .ok_or_else(|| "Cursor replied without a result.".to_string())
    })?;

    if value.get("is_error").and_then(Value::as_bool) == Some(true) {
        return Err(clip(&text_of(&value).unwrap_or_else(|| "Cursor could not answer.".into())));
    }
    let text = text_of(&value).ok_or_else(|| "Cursor replied without a result.".to_string())?;
    let session = value
        .get("session_id")
        .or_else(|| value.get("sessionId"))
        .or_else(|| value.get("chatId"))
        .and_then(Value::as_str)
        .filter(|id| !id.is_empty())
        .map(str::to_string);
    Ok((text, session))
}

fn text_of(value: &Value) -> Option<String> {
    for key in ["result", "text", "message"] {
        if let Some(text) = value.get(key).and_then(Value::as_str) {
            let trimmed = text.trim();
            if !trimmed.is_empty() {
                return Some(trimmed.to_string());
            }
        }
    }
    None
}

/// Native folder picker. The Cursor window does not have to be open.
pub fn pick_folder() -> Result<Option<String>, String> {
    let script = r#"
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName System.Windows.Forms
$owner = New-Object System.Windows.Forms.Form
$owner.TopMost = $true
$owner.ShowInTaskbar = $false
$dialog = New-Object System.Windows.Forms.FolderBrowserDialog
$dialog.Description = 'Choose the project Coucou will edit'
if ($dialog.ShowDialog($owner) -eq [System.Windows.Forms.DialogResult]::OK) {
  [Console]::Out.Write($dialog.SelectedPath)
}
$owner.Dispose()
"#;
    let output = std::process::Command::new("powershell.exe")
        .args(["-NoProfile", "-STA", "-WindowStyle", "Hidden", "-Command", script])
        .output()
        .map_err(|e| format!("Could not open the folder picker: {e}"))?;
    if !output.status.success() {
        let err = String::from_utf8_lossy(&output.stderr);
        return Err(format!("Could not open the folder picker: {}", err.trim()));
    }
    let path = decode_output(&output.stdout).trim().to_string();
    if path.is_empty() {
        return Ok(None);
    }
    if !std::path::Path::new(&path).is_dir() {
        return Err("That folder is not available.".into());
    }
    Ok(Some(path))
}

fn decode_output(bytes: &[u8]) -> String {
    let bytes = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if bytes.starts_with(&[0xFF, 0xFE]) {
        let units: Vec<u16> = bytes[2..]
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        return String::from_utf16_lossy(&units);
    }
    String::from_utf8_lossy(bytes).into_owned()
}

fn clip(text: &str) -> String {
    let mut end = text.len().min(500);
    while end > 0 && !text.is_char_boundary(end) {
        end -= 1;
    }
    text[..end].trim().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_json_result_keeps_the_session() {
        let raw = r#"{"type":"result","is_error":false,"result":"Hello from Cursor","session_id":"chat-1"}"#;
        let (text, session) = parse_reply(raw).unwrap();
        assert_eq!(text, "Hello from Cursor");
        assert_eq!(session.as_deref(), Some("chat-1"));
    }

    #[test]
    fn noise_before_the_json_line_is_ignored() {
        let raw = "booting\n{\"result\":\"ok\",\"sessionId\":\"abc\"}\n";
        let (text, session) = parse_reply(raw).unwrap();
        assert_eq!(text, "ok");
        assert_eq!(session.as_deref(), Some("abc"));
    }

    #[test]
    fn utf16_picker_output_is_decoded() {
        let bytes: Vec<u8> = "C:\\proj"
            .encode_utf16()
            .flat_map(|u| u.to_le_bytes())
            .collect();
        let mut with_bom = vec![0xFF, 0xFE];
        with_bom.extend(bytes);
        assert_eq!(decode_output(&with_bom), "C:\\proj");
    }

    #[test]
    fn an_error_payload_is_refused() {
        let err = parse_reply(r#"{"is_error":true,"result":"not logged in"}"#).unwrap_err();
        assert!(err.contains("not logged in"));
    }
}
