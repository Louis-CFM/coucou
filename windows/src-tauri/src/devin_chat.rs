// Chat through the Devin CLI (`devin -p`), on the user's own Devin plan.
//
// The conversation lives in the CLI: `-c` picks the folder's latest session,
// so the chat runs in a private folder of its own and a reset just skips `-c`
// once. `--permission-mode auto` approves read-only tools only — the agent
// can look things up but not change the machine.
//
// Two walls keep a chat turn out of the island's own session feed, like
// claude-cli's `--setting-sources`: the user's hooks (including Coucou's)
// live in ~/.config/devin/config.json, so `--config` points at a private
// config that has none. The prompt goes through `--prompt-file` — argv on
// Windows caps at ~32k and a file context can be longer than that.

use std::path::Path;

use crate::chat::ChatContext;
use crate::cli_chat::{self, CliStatus};

fn cli_path() -> Option<std::path::PathBuf> {
    cli_chat::find_cli(&["devin"])
}

/// The config the chat runs under: version 1 and nothing else. Sign-in lives
/// in credentials.toml and still applies; the user's hooks and permission
/// rules do not.
fn private_config(dir: &Path) -> Result<std::path::PathBuf, String> {
    let cfg = dir.join("devin.json");
    if !cfg.is_file() {
        std::fs::write(&cfg, "{\"version\":1}\n").map_err(|e| e.to_string())?;
    }
    Ok(cfg)
}

/// One chat turn. `started` is whether this chat already owns the private
/// folder's latest session — it decides whether `-c` goes out. Answers with
/// the reply text and "-" once the folder's session is ours (the "session"
/// the shared Chat stores is only this marker).
pub async fn send(
    model: String,
    first: bool,
    session: Option<String>,
    query: String,
    context: Option<ChatContext>,
) -> Result<(String, Option<String>), String> {
    let cli =
        cli_path().ok_or("Devin CLI not found. Install it, then run `devin auth login`.")?;
    let prompt = cli_chat::build_prompt(first, context.as_ref(), &query, "Devin", true)?;

    let dir = cli_chat::workdir("devin-chat")?;
    let prompt_file = dir.join("prompt.txt");
    std::fs::write(&prompt_file, &prompt).map_err(|e| e.to_string())?;

    let mut cmd = cli_chat::command(&cli);
    cmd.current_dir(&dir).args([
        "-p",
        "--prompt-file",
        &prompt_file.to_string_lossy(),
        "--config",
        &private_config(&dir)?.to_string_lossy(),
        "--permission-mode",
        "auto",
        "--respect-workspace-trust",
        "false",
    ]);
    if !model.is_empty() {
        cmd.args(["--model", &model]);
    }
    if session.is_some() {
        cmd.arg("--continue");
    }

    let out = cli_chat::run(cmd, "the Devin CLI").await?;
    let _ = std::fs::remove_file(&prompt_file);
    let text = parse_answer(out.status.success(), &out.stdout, &out.stderr)?;
    Ok((text, Some("-".into())))
}

/// The answer from stdout — minus the first-run welcome banner a fresh
/// private config gets once — or the CLI's own error line.
fn parse_answer(ok: bool, stdout: &[u8], stderr: &[u8]) -> Result<String, String> {
    if ok {
        let text = strip_banner(&cli_chat::strip_ansi(&String::from_utf8_lossy(stdout)));
        return if text.is_empty() { Err("No response text.".into()) } else { Ok(text) };
    }
    let stderr = cli_chat::strip_ansi(&String::from_utf8_lossy(stderr));
    let stdout = strip_banner(&cli_chat::strip_ansi(&String::from_utf8_lossy(stdout)));
    let msg = stderr
        .lines()
        .map(str::trim)
        .find(|l| !l.is_empty())
        .or_else(|| stdout.lines().map(str::trim).rfind(|l| !l.is_empty()))
        .unwrap_or("Devin CLI failed.");
    Err(msg.chars().take(300).collect())
}

/// `devin -p` prints a one-time "Welcome to Devin CLI!" banner when the
/// config is new. A private config means that once lands on the first chat
/// answer; drop the block so the user never sees it.
fn strip_banner(out: &str) -> String {
    let out = out.trim_start();
    let Some(rest) = out.strip_prefix("Welcome to Devin CLI!") else {
        return out.trim_end().to_string();
    };
    rest.lines()
        .skip_while(|l| {
            let l = l.trim();
            l.is_empty() || l.starts_with('✓') || l.starts_with('✗')
        })
        .collect::<Vec<_>>()
        .join("\n")
        .trim()
        .to_string()
}

/// Whether the CLI is installed and signed in, for the settings window.
/// `devin auth status` says "Logged in" plus the account's details; the
/// version line makes the status read like the other CLIs'.
pub async fn status() -> CliStatus {
    let Some(cli) = cli_path() else { return CliStatus::missing() };
    let mut cmd = cli_chat::command(&cli);
    cmd.args(["auth", "status"]);
    let logged_in = match cli_chat::run(cmd, "the Devin CLI").await {
        Ok(out) => {
            let text = cli_chat::strip_ansi(&format!(
                "{}{}",
                String::from_utf8_lossy(&out.stdout),
                String::from_utf8_lossy(&out.stderr)
            ));
            text.contains("Logged in")
        }
        Err(_) => false,
    };
    let mut cmd = cli_chat::command(&cli);
    cmd.arg("--version");
    let version = match cli_chat::run(cmd, "the Devin CLI").await {
        Ok(out) => cli_chat::strip_ansi(&String::from_utf8_lossy(&out.stdout))
            .lines()
            .next()
            .unwrap_or("")
            .trim()
            .to_string(),
        Err(err) => err,
    };
    CliStatus::found(&cli, if logged_in { version } else { "not signed in".into() }, logged_in)
}

/// `devin models list` prints every family (50+ rows) — the picker gets the
/// useful handful instead: "" is the CLI's own configured model, the rest are
/// the aliases `devin --model` documents.
pub fn models() -> Vec<(String, String)> {
    vec![
        (String::new(), "Default".into()),
        ("adaptive".into(), "Adaptive".into()),
        ("swe-2-max".into(), "SWE-2 Max".into()),
        ("opus".into(), "Opus".into()),
        ("codex".into(), "Codex".into()),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_first_run_banner_drops_but_the_answer_stays() {
        let out = "\u{1b}[1mWelcome to Devin CLI!\u{1b}[0m\n\n ✓ Logged in as a@b.c.\n\n ✓ Organization: Org\n ✓ You're all set.\nrun2-ok\n";
        assert_eq!(strip_banner(&cli_chat::strip_ansi(out)), "run2-ok");
        assert_eq!(strip_banner("plain answer"), "plain answer");
    }

    #[test]
    fn reads_the_answer_or_the_cli_error() {
        assert_eq!(parse_answer(true, b"the answer\n", b""), Ok("the answer".into()));
        assert_eq!(parse_answer(true, b"", b""), Err("No response text.".into()));
        assert_eq!(
            parse_answer(false, b"", b"not logged in, run devin auth login\n"),
            Err("not logged in, run devin auth login".into())
        );
        assert_eq!(
            parse_answer(false, b"some failure detail\n", b""),
            Err("some failure detail".into())
        );
    }
}
