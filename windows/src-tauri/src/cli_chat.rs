// What the CLI chat providers share: finding the binary, the private working
// folder, spawning with no console window, the answer deadline, the first-turn
// prompt, and the ANSI noise the status lines carry.
//
// The CLIs (Cursor's `agent`, `kiro-cli`, `claude`) keep the conversation
// themselves through `--resume`, so they get the system prompt and the context
// only on the first turn. They run in a private, empty folder — the same one
// every time because `--resume` is scoped to it — so nothing of the user's is
// in reach, and no shell is ever in the launch path.

use std::path::{Path, PathBuf};
use std::process::Stdio;
use std::time::Duration;

use serde::Serialize;
use tokio::process::Command;

use crate::chat::{self, ChatContext};
use crate::platform;

/// Coucou waits this long for a CLI answer, then hands the error to the user.
/// The child process is killed on drop, so a timed-out one does not linger.
pub const TIMEOUT: Duration = Duration::from_secs(120);
const MAX_INLINE_TEXT: u64 = 200_000;

/// The installer drops the CLI into folders a desktop session often lacks on
/// its PATH (~/.local/bin on Linux, ~/.local/bin-style shims on Windows).
pub fn find_cli(names: &[&str]) -> Option<PathBuf> {
    names.iter().find_map(|n| platform::find_on_path(n)).or_else(|| {
        let bin = platform::home_dir().join(".local").join("bin");
        names.iter().map(|n| bin.join(n)).find(|p| p.is_file())
    })
}

/// The private folder a CLI's chat runs in — empty, 0700, ours.
pub fn workdir(name: &str) -> Result<PathBuf, String> {
    let dir = crate::settings::local_dir().join(name);
    platform::ensure_private_dir(&dir).map_err(|e| e.to_string())?;
    Ok(dir)
}

/// A spawned CLI that dies with its caller and never shows a console.
pub fn command(cli: &Path) -> Command {
    let mut cmd = Command::new(cli);
    cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).kill_on_drop(true);
    #[cfg(windows)]
    cmd.creation_flags(0x0800_0000); // CREATE_NO_WINDOW
    cmd
}

/// Runs `cmd` to completion inside the deadline. The error names the CLI, so a
/// stack of providers can each say their own.
pub async fn run(mut cmd: Command, who: &str) -> Result<std::process::Output, String> {
    let child = cmd.spawn().map_err(|e| format!("Could not start {who}: {e}"))?;
    match tokio::time::timeout(TIMEOUT, child.wait_with_output()).await {
        Ok(out) => out.map_err(|e| e.to_string()),
        Err(_) => Err(format!("{who} took too long to answer.")),
    }
}

/// The message for a CLI that keeps the conversation itself: the system prompt
/// and the context go in the first turn only; after that `--resume` carries it.
/// `who` is the provider name the error mentions.
pub fn build_prompt(
    system_prompt: &str,
    first: bool,
    context: Option<&ChatContext>,
    query: &str,
    who: &str,
) -> Result<String, String> {
    let mut prompt = String::new();
    if first {
        prompt.push_str(system_prompt);
        prompt.push_str("\n\n");
        match context {
            Some(ChatContext::File { name, path }) => {
                let text = inline_text(path)
                    .ok_or(format!("Only text files can be sent to {who} for now."))?;
                prompt.push_str(&format!("File: {name}\nFile contents:\n{text}\n\n"));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                prompt.push_str(&chat::window_line(app_name, title, url.as_deref()));
                prompt.push_str("\n\n");
            }
            None => {}
        }
    }
    prompt.push_str(query);
    Ok(prompt)
}

fn inline_text(path: &str) -> Option<String> {
    if std::fs::metadata(path).ok()?.len() > MAX_INLINE_TEXT {
        return None;
    }
    std::fs::read_to_string(path).ok()
}

/// Whether a CLI is installed and signed in, for the settings window.
#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CliStatus {
    /// Path of the CLI, or None when it is not installed.
    pub cli: Option<String>,
    /// What its status command says, e.g. "Logged in as …".
    pub status: String,
    pub logged_in: bool,
}

impl CliStatus {
    pub fn missing() -> Self {
        Self { cli: None, status: String::new(), logged_in: false }
    }

    pub fn found(cli: &Path, status: String, logged_in: bool) -> Self {
        Self { cli: Some(cli.to_string_lossy().to_string()), status, logged_in }
    }
}

/// Terminal control codes out of a status line, so "✓ Logged in" matches.
pub fn strip_ansi(s: &str) -> String {
    let mut out = String::with_capacity(s.len());
    let mut chars = s.chars();
    while let Some(c) = chars.next() {
        if c == '\u{1b}' {
            for c in chars.by_ref() {
                if c.is_ascii_alphabetic() {
                    break;
                }
            }
        } else {
            out.push(c);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ansi_codes_come_out_of_status_text() {
        assert_eq!(strip_ansi("\u{1b}[32m✓\u{1b}[0m Logged in"), "✓ Logged in");
        assert_eq!(strip_ansi("plain"), "plain");
    }

    #[test]
    fn the_first_turn_carries_the_system_prompt_and_the_context() {
        let first = build_prompt("SYS", true, None, "hi", "Test").unwrap();
        assert!(first.starts_with("SYS"), "system prompt first: {first}");
        assert!(first.ends_with("hi"));

        // A resumed turn is only the question: --resume carries the rest.
        assert_eq!(build_prompt("SYS", false, None, "hi again", "Test").unwrap(), "hi again");

        let window = ChatContext::Window {
            app_name: "Code".into(),
            title: "main.rs".into(),
            url: None,
        };
        let with_ctx = build_prompt("SYS", true, Some(&window), "what is this?", "Test").unwrap();
        assert!(with_ctx.contains("Context — App: Code, Window: main.rs"));
        assert!(with_ctx.ends_with("what is this?"));
        // Context never rides a resumed turn.
        assert_eq!(
            build_prompt("SYS", false, Some(&window), "and now?", "Test").unwrap(),
            "and now?"
        );
    }

    #[test]
    fn a_file_context_inlines_text_but_not_binary_or_big() {
        let dir = std::env::temp_dir().join(format!("coucou-cli-prompt-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let text_file = dir.join("notes.txt");
        std::fs::write(&text_file, "some notes").unwrap();
        let file = ChatContext::File {
            name: "notes.txt".into(),
            path: text_file.to_string_lossy().to_string(),
        };
        let prompt = build_prompt("SYS", true, Some(&file), "summarize", "Test").unwrap();
        assert!(prompt.contains("File: notes.txt\nFile contents:\nsome notes"));

        let big = dir.join("big.txt");
        std::fs::write(&big, vec![b'x'; (MAX_INLINE_TEXT + 1) as usize]).unwrap();
        let file = ChatContext::File {
            name: "big.txt".into(),
            path: big.to_string_lossy().to_string(),
        };
        assert!(build_prompt("SYS", true, Some(&file), "summarize", "Test").is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
