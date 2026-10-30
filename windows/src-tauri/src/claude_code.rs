// The Claude Code relay: with no Anthropic API key saved, the chat, Flow's
// clean-up and the notes of a call are answered by the user's own Claude Code
// (`claude -p`), signed in with their own account. Coucou reads no credential
// and makes no network call of its own: Claude Code answers exactly as it does
// in a terminal.
//
// Each run is kept apart from the user's sessions: no settings file is loaded
// (so no hooks: Coucou's own would show the relay's runs as sessions), no MCP
// server, no skill, nothing saved to resume, and it runs in an empty folder of
// Coucou's, so no CLAUDE.md is picked up. It may only use the tools it is
// given: web search for the chat, and reading the one dropped file.

use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde_json::Value;
use tokio::io::AsyncWriteExt;

use crate::chat::{self, ChatContext, ModelInfo};
use crate::i18n::{t, tf};
use crate::{platform, settings};

/// The models offered in the picker without a key. Claude Code takes these ids
/// as they are, and so does the API once a key is added.
const MODELS: [(&str, &str); 3] = [
    ("claude-opus-5", "Claude Opus 5"),
    ("claude-sonnet-5", "Claude Sonnet 5"),
    ("claude-haiku-4-5", "Claude Haiku 4.5"),
];

/// What one run of `claude -p` is asked.
pub struct Request<'a> {
    pub model: &'a str,
    pub system: &'a str,
    pub prompt: &'a str,
    /// Built-in tools the run may use; none at all when empty.
    pub tools: &'a [&'a str],
    /// A folder the run may read from, besides its own.
    pub read_dir: Option<&'a Path>,
    pub timeout: Duration,
}

/// The Claude Code CLI, when it is installed.
pub fn exe() -> Option<PathBuf> {
    platform::cli_candidates("claude").into_iter().next()
}

pub fn available() -> bool {
    exe().is_some()
}

/// The models offered in the picker when Claude Code answers.
pub fn models() -> Vec<ModelInfo> {
    MODELS.iter().map(|(id, label)| ModelInfo { id: (*id).into(), label: (*label).into() }).collect()
}

/// Runs `claude -p` once and returns the text of its answer, or why there is none.
pub async fn ask(request: &Request<'_>) -> Result<String, String> {
    let exe = exe().ok_or_else(|| t("Claude Code is not installed."))?;
    let workdir = settings::local_dir().join("relay");
    std::fs::create_dir_all(&workdir).map_err(|e| e.to_string())?;

    let mut cmd = tokio::process::Command::new(&exe);
    cmd.args(args(request))
        .current_dir(&workdir)
        .env_remove("CLAUDECODE")
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    // An npm install is a `#!/usr/bin/env node` script: its own folder first on
    // PATH so it finds its Node, as codex_plan.rs does for Codex.
    if let Some(dir) = exe.parent() {
        let mut dirs = vec![dir.to_path_buf()];
        if let Some(path) = std::env::var_os("PATH") {
            dirs.extend(std::env::split_paths(&path));
        }
        if let Ok(joined) = std::env::join_paths(dirs) {
            cmd.env("PATH", joined);
        }
    }
    platform::no_console(cmd.as_std_mut());

    let mut child = cmd.spawn().map_err(|e| tf("Could not start Claude Code: {error}", &[("error", &e.to_string())]))?;
    if let Some(mut stdin) = child.stdin.take() {
        stdin.write_all(request.prompt.as_bytes()).await.map_err(|e| e.to_string())?;
    }
    let output = tokio::time::timeout(request.timeout, child.wait_with_output())
        .await
        .map_err(|_| t("Claude Code took too long to answer."))?
        .map_err(|e| e.to_string())?;
    parse(&output.stdout).map_err(|err| {
        let stderr = String::from_utf8_lossy(&output.stderr);
        match stderr.trim() {
            "" => err,
            detail => format!("{err} ({})", detail.lines().last().unwrap_or(detail)),
        }
    })
}

fn args(request: &Request<'_>) -> Vec<OsString> {
    let mut out: Vec<OsString> = [
        "-p",
        "--output-format",
        "json",
        "--model",
        request.model,
        "--system-prompt",
        request.system,
        "--tools",
    ]
    .iter()
    .map(OsString::from)
    .collect();
    out.push(request.tools.join(",").into());
    if !request.tools.is_empty() {
        out.push("--allowedTools".into());
        out.push(request.tools.join(",").into());
    }
    if let Some(dir) = request.read_dir {
        out.push("--add-dir".into());
        out.push(dir.as_os_str().to_owned());
    }
    for flag in ["--setting-sources", "", "--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] {
        out.push(flag.into());
    }
    out
}

/// The answer's text from `claude -p --output-format json`.
fn parse(stdout: &[u8]) -> Result<String, String> {
    let json: Value = serde_json::from_slice(stdout).map_err(|_| t("Claude Code gave no answer."))?;
    let result = json.get("result").and_then(Value::as_str).unwrap_or("").trim();
    if json.get("is_error").and_then(Value::as_bool).unwrap_or(false) {
        let why = if result.is_empty() { t("Claude Code could not answer.") } else { result.to_string() };
        return Err(why);
    }
    if result.is_empty() {
        return Err(t("No response text."));
    }
    Ok(result.to_string())
}

/// One chat turn as a single prompt: the earlier plain turns, the context the
/// first question carries, then the question.
pub fn chat_prompt(history: &[Value], first: bool, context: Option<&ChatContext>, query: &str) -> String {
    let mut out = String::new();
    if !history.is_empty() {
        out.push_str("The conversation so far:\n<conversation>\n");
        for turn in history {
            let role = turn.get("role").and_then(Value::as_str).unwrap_or("user");
            let text = turn.get("content").and_then(Value::as_str).unwrap_or("");
            out.push_str(&format!("<{role}>\n{text}\n</{role}>\n"));
        }
        out.push_str("</conversation>\n\nThe user's new message:\n");
    }
    match context.filter(|_| first) {
        Some(ChatContext::File { name, path }) => {
            out.push_str(&format!("File: {name} (read it at {path})\n\n"));
        }
        Some(ChatContext::Window { app_name, title, url }) => {
            out.push_str(&chat::window_line(app_name, title, url.as_deref()));
            out.push_str("\n\n");
        }
        None => {}
    }
    out.push_str(query);
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn strings(args: &[OsString]) -> Vec<String> {
        args.iter().map(|a| a.to_string_lossy().into_owned()).collect()
    }

    #[test]
    fn a_run_loads_no_settings_and_only_the_tools_it_is_given() {
        let request = Request {
            model: "claude-x",
            system: "sys",
            prompt: "hi",
            tools: &[],
            read_dir: None,
            timeout: Duration::from_secs(1),
        };
        let a = strings(&args(&request));
        assert_eq!(&a[..8], ["-p", "--output-format", "json", "--model", "claude-x", "--system-prompt", "sys", "--tools"]);
        assert_eq!(a[8], "");
        assert!(!a.contains(&"--allowedTools".to_string()));
        assert!(!a.contains(&"--add-dir".to_string()));
        let sources = a.iter().position(|x| x == "--setting-sources").unwrap();
        assert_eq!(a[sources + 1], "");
        for flag in ["--strict-mcp-config", "--no-session-persistence", "--disable-slash-commands"] {
            assert!(a.contains(&flag.to_string()), "{flag}");
        }

        let inbox = PathBuf::from("/tmp/inbox");
        let request = Request { tools: &["WebSearch", "Read"], read_dir: Some(&inbox), ..request };
        let a = strings(&args(&request));
        assert_eq!(a[8], "WebSearch,Read");
        let allowed = a.iter().position(|x| x == "--allowedTools").unwrap();
        assert_eq!(a[allowed + 1], "WebSearch,Read");
        let dir = a.iter().position(|x| x == "--add-dir").unwrap();
        assert_eq!(a[dir + 1], "/tmp/inbox");
    }

    #[test]
    fn the_answer_or_the_error_comes_from_the_result_field() {
        assert_eq!(parse(br#"{"type":"result","is_error":false,"result":" Hi "}"#).unwrap(), "Hi");
        assert_eq!(parse(br#"{"is_error":true,"result":"Not logged in"}"#).unwrap_err(), "Not logged in");
        assert_eq!(parse(br#"{"is_error":true}"#).unwrap_err(), "Claude Code could not answer.");
        assert_eq!(parse(br#"{"is_error":false,"result":"  "}"#).unwrap_err(), "No response text.");
        assert_eq!(parse(b"[claude-code:unrecognized_model]").unwrap_err(), "Claude Code gave no answer.");
    }

    #[test]
    fn the_prompt_carries_the_history_then_the_context_then_the_question() {
        assert_eq!(chat_prompt(&[], true, None, "q"), "q");
        let history = vec![json!({"role":"user","content":"a"}), json!({"role":"assistant","content":"b"})];
        let p = chat_prompt(&history, false, None, "c");
        assert_eq!(
            p,
            "The conversation so far:\n<conversation>\n<user>\na\n</user>\n<assistant>\nb\n</assistant>\n</conversation>\n\nThe user's new message:\nc"
        );
        let file = ChatContext::File { name: "a.pdf".into(), path: "/inbox/a.pdf".into() };
        assert_eq!(chat_prompt(&[], true, Some(&file), "why?"), "File: a.pdf (read it at /inbox/a.pdf)\n\nwhy?");
        assert!(chat_prompt(&history, false, Some(&file), "why?").ends_with("message:\nwhy?"));
        let win = ChatContext::Window { app_name: "Code".into(), title: "main.rs".into(), url: None };
        assert_eq!(chat_prompt(&[], true, Some(&win), "q"), "Context — App: Code, Window: main.rs\n\nq");
    }

    #[test]
    fn the_picker_offers_the_same_models_as_the_settings() {
        let ids: Vec<String> = models().into_iter().map(|m| m.id).collect();
        assert_eq!(ids, ["claude-opus-5", "claude-sonnet-5", "claude-haiku-4-5"]);
    }
}
