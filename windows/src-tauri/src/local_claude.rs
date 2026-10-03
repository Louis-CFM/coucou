// Mochi's chat through the user's own Claude Code instead of an API key.
//
// `claude -p` runs headless, on the user's subscription, either on Windows or
// inside a WSL distro — whichever the settings window marked "Use for Mochi".
// The question goes in on stdin, never on a command line; the conversation
// carries on with `--resume <session>`.
//
// Mochi gets read-only tools (Read, WebSearch, WebFetch) and runs in Coucou's
// inbox, where dropped files land, so it can read what was dropped and nothing
// it could break. Hooks are switched off for these runs, and the relay ignores
// anything marked COUCOU_INTERNAL besides: Mochi's own chat must never show up
// in the island as a Claude Code session.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::claude::{ChatContext, ChatReply, SYSTEM_PROMPT};
use crate::platform;

/// A long answer with a few web searches can take a while; a wedged CLI can't
/// hold the chat forever.
const TIMEOUT: Duration = Duration::from_secs(300);

const TOOLS: &str = "Read,WebSearch,WebFetch";
const SETTINGS: &str = r#"{"disableAllHooks":true}"#;
const EXTRA_PROMPT: &str = "You are answering from a small chat bubble, not a terminal. \
The user's dropped files are in the current directory; read them when the question is about them. \
You cannot change files or run commands here.";

/// Where Mochi's answers come from.
#[derive(Clone, PartialEq, Eq, Debug)]
pub enum Backend {
    Api,
    Windows,
    Wsl(String),
}

impl Backend {
    /// `settings.chat_backend`: "api", "windows" or "wsl:<distro>". Anything
    /// unrecognised is the API, which needs nothing installed.
    pub fn parse(value: &str) -> Self {
        match value {
            "windows" => Self::Windows,
            v => match v.strip_prefix("wsl:") {
                Some(d) if crate::wsl::is_distro_name(d) => Self::Wsl(d.to_string()),
                _ => Self::Api,
            },
        }
    }

    pub fn key(&self) -> String {
        match self {
            Self::Api => "api".into(),
            Self::Windows => "windows".into(),
            Self::Wsl(d) => format!("wsl:{d}"),
        }
    }
}

/// The session Mochi is in: the backend it belongs to (a session id from WSL
/// means nothing to the Windows CLI, and vice versa), its id once Claude Code
/// has given it one, and the folder it runs in — Coucou's inbox when unset.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ActiveSession {
    pub backend: String,
    pub id: Option<String>,
    pub cwd: Option<String>,
}

#[derive(Default)]
pub struct LocalSession(Mutex<Option<ActiveSession>>);

impl LocalSession {
    /// A new session in the inbox — what a dropped file starts.
    pub fn reset(&self) {
        *self.0.lock().unwrap() = None;
    }

    pub fn set(&self, active: Option<ActiveSession>) {
        *self.0.lock().unwrap() = active;
    }

    /// The active session, if it belongs to `backend`.
    pub fn get(&self, backend: &Backend) -> Option<ActiveSession> {
        self.0.lock().unwrap().clone().filter(|a| a.backend == backend.key())
    }
}

/// Claude Code on this machine: the native installer's `~/.local/bin/claude`
/// (`claude.exe` on Windows), else whatever `claude` PATH finds (an npm shim,
/// say), else the copy the Claude desktop app keeps for its Code tab.
pub fn windows_cli() -> Option<PathBuf> {
    let exe = if cfg!(windows) { "claude.exe" } else { "claude" };
    let native = Some(platform::home_dir().join(".local").join("bin").join(exe)).filter(|p| p.is_file());
    native
        .or_else(|| platform::find_on_path("claude"))
        .or_else(desktop_app_cli)
}

/// The Claude desktop app ships Claude Code in `…\Claude\claude-code\<version>\`,
/// under the Store package's LocalCache or, for the classic installer, under
/// %APPDATA%. The folder changes with every update, so the newest one wins.
/// That copy is signed in through the app, not on its own: see `logged_in`.
/// There is no such app, and none of these variables, outside Windows.
fn desktop_app_cli() -> Option<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(appdata) = std::env::var_os("APPDATA") {
        roots.push(PathBuf::from(appdata).join(r"Claude\claude-code"));
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        if let Ok(packages) = std::fs::read_dir(PathBuf::from(local).join("Packages")) {
            for pkg in packages.flatten() {
                if pkg.file_name().to_string_lossy().starts_with("Claude_") {
                    roots.push(pkg.path().join(r"LocalCache\Roaming\Claude\claude-code"));
                }
            }
        }
    }
    roots
        .iter()
        .filter_map(|root| std::fs::read_dir(root).ok())
        .flatten()
        .flatten()
        .map(|v| (version_key(&v.file_name().to_string_lossy()), v.path().join("claude.exe")))
        .filter(|(_, exe)| exe.is_file())
        .max_by(|a, b| a.0.cmp(&b.0))
        .map(|(_, exe)| exe)
}

/// "2.1.284" → [2, 1, 284], so 2.1.300 sorts after 2.1.29.
fn version_key(name: &str) -> Vec<u64> {
    name.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// Whether that Claude Code is signed in, from its own `claude auth status` —
/// which costs nothing. `None` when it can't be asked. A copy that comes with
/// the Claude desktop app answers "no" until it is signed in on its own.
pub fn logged_in(backend: &Backend) -> Option<bool> {
    let cmd = match backend {
        Backend::Api => return None,
        Backend::Windows => {
            let mut c = Command::new(windows_cli()?);
            c.args(["auth", "status"]);
            c
        }
        Backend::Wsl(distro) => {
            let mut c = Command::new("wsl.exe");
            c.args(["-d", distro, "--exec", "sh", "-lc", "exec claude auth status"]);
            c
        }
    };
    let (out, _) = run(cmd, "", Duration::from_secs(20)).ok()?;
    // Pretty-printed JSON; a login shell may print its own lines first.
    let json = &out[out.find('{')?..];
    serde_json::from_str::<Value>(json).ok()?.get("loggedIn")?.as_bool()
}

/// One chat turn through Claude Code. Blocking: run it off the main thread.
pub fn send(
    backend: &Backend,
    session: &LocalSession,
    query: String,
    context: Option<ChatContext>,
) -> Result<ChatReply, String> {
    let active = session.get(backend);
    let resume = active.as_ref().and_then(|a| a.id.clone());
    let folder = active.as_ref().and_then(|a| a.cwd.clone());

    // Context rides along with the first message only, as with the API.
    let mut prompt = String::new();
    if resume.is_none() {
        match &context {
            Some(ChatContext::File { name, path }) => {
                let file = Path::new(path).file_name().map(|f| f.to_string_lossy().into_owned());
                prompt.push_str(&format!(
                    "The user dropped a file named \"{name}\". It is in the current directory as \"{}\".\n\n",
                    file.unwrap_or_else(|| name.clone())
                ));
            }
            Some(ChatContext::Window { app_name, title, url }) => {
                prompt.push_str(&format!("Context — App: {app_name}, Window: {title}"));
                if let Some(url) = url {
                    prompt.push_str(&format!(", URL: {url}"));
                }
                prompt.push_str("\n\n");
            }
            None => {}
        }
    }
    prompt.push_str(&query);

    let mut args: Vec<String> = vec![
        "-p".into(),
        "--output-format".into(),
        "json".into(),
        "--settings".into(),
        SETTINGS.into(),
        "--allowedTools".into(),
        TOOLS.into(),
        "--append-system-prompt".into(),
        format!("{SYSTEM_PROMPT}\n{EXTRA_PROMPT}"),
    ];
    if let Some(id) = &resume {
        args.push("--resume".into());
        args.push(id.clone());
    }

    let inbox = crate::files::inbox_dir();
    let _ = std::fs::create_dir_all(&inbox);
    // A session's own folder, or the inbox for a new one (dropped files land there).
    let cwd = folder.clone().unwrap_or_else(|| inbox.to_string_lossy().into_owned());

    let mut cmd = match backend {
        Backend::Api => return Err("Mochi is set to use the Claude API.".into()),
        Backend::Windows => {
            let cli = windows_cli()
                .ok_or("Claude Code isn't installed on Windows. Pick another engine in Settings.")?;
            let mut c = Command::new(cli);
            c.args(&args).current_dir(&cwd);
            c
        }
        Backend::Wsl(distro) => {
            // A login shell finds `claude` where the user installed it
            // (~/.local/bin, npm…); the arguments travel as "$@", unparsed.
            let mut c = Command::new("wsl.exe");
            // --cd takes a Linux path (from the transcript) as well as a Windows one.
            c.args(["-d", distro, "--cd"])
                .arg(&cwd)
                .args(["--exec", "sh", "-lc", r#"exec claude "$@""#, "claude"])
                .args(&args);
            let wslenv = std::env::var("WSLENV").unwrap_or_default();
            let wslenv = if wslenv.is_empty() { "COUCOU_INTERNAL".into() } else { format!("{wslenv}:COUCOU_INTERNAL") };
            c.env("WSLENV", wslenv);
            c
        }
    };
    cmd.env("COUCOU_INTERNAL", "1");

    let (stdout, stderr) = run(cmd, &prompt, TIMEOUT)?;
    let reply = parse_reply(&stdout).ok_or_else(|| {
        let why = stderr.lines().rev().find(|l| !l.trim().is_empty()).unwrap_or("no answer");
        format!("Claude Code: {}", why.chars().take(200).collect::<String>())
    })?;

    let id = reply.session_id.clone().or(resume);
    if id.is_some() {
        session.set(Some(ActiveSession { backend: backend.key(), id: id.clone(), cwd: folder }));
    }
    if reply.is_error {
        return Err(format!("Claude Code: {}", reply.text.chars().take(300).collect::<String>()));
    }
    if reply.text.trim().is_empty() {
        return Err("No response text.".into());
    }
    Ok(ChatReply { text: reply.text.trim().to_string(), session: id })
}

/// Spawns the CLI, feeds it the prompt and collects its output under a deadline.
fn run(mut cmd: Command, prompt: &str, timeout: Duration) -> Result<(String, String), String> {
    let mut child = platform::no_console(cmd.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped()))
        .spawn()
        .map_err(|e| format!("Can't start Claude Code: {e}"))?;

    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(prompt.as_bytes());
        // Dropped here: end of input is what tells `claude -p` to start.
    }
    // Drain both pipes on their own threads so a big answer can't fill one and
    // stall the process.
    let drain = |pipe: Option<Box<dyn Read + Send>>| {
        std::thread::spawn(move || {
            let mut buf = Vec::new();
            if let Some(mut p) = pipe {
                let _ = p.read_to_end(&mut buf);
            }
            String::from_utf8_lossy(&buf).into_owned()
        })
    };
    let out = drain(child.stdout.take().map(|p| Box::new(p) as Box<dyn Read + Send>));
    let err = drain(child.stderr.take().map(|p| Box::new(p) as Box<dyn Read + Send>));

    let deadline = Instant::now() + timeout;
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                return Err("Claude Code took too long to answer.".into());
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok((out.join().unwrap_or_default(), err.join().unwrap_or_default()))
}

struct Reply {
    text: String,
    session_id: Option<String>,
    is_error: bool,
}

/// The `--output-format json` result object. A login shell may print its own
/// lines first, so the last line that parses as one is taken.
fn parse_reply(stdout: &str) -> Option<Reply> {
    stdout.lines().rev().find_map(|line| {
        let v: Value = serde_json::from_str(line.trim()).ok()?;
        let is_result = v.get("type").and_then(Value::as_str) == Some("result")
            || (v.get("result").is_some() && v.get("session_id").is_some());
        if !is_result {
            return None;
        }
        Some(Reply {
            text: v.get("result").and_then(Value::as_str).unwrap_or("").to_string(),
            session_id: v
                .get("session_id")
                .and_then(Value::as_str)
                .filter(|s| s.chars().all(|c| c.is_ascii_hexdigit() || c == '-'))
                .map(str::to_string),
            is_error: v.get("is_error").and_then(Value::as_bool).unwrap_or(false),
        })
    })
}

/// Claude Code inside a distro, as its login shell finds it.
pub fn wsl_cli(distro: &str) -> Option<String> {
    crate::wsl::run_wsl(&["-d", distro, "--exec", "sh", "-lc", "command -v claude"])
        .map(|s| s.trim().to_string())
        .filter(|p| p.starts_with('/'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_newest_bundled_version_wins() {
        let mut v = vec!["2.1.29", "2.1.284", "2.1.300", "2.0.999"];
        v.sort_by_key(|s| version_key(s));
        assert_eq!(v.last(), Some(&"2.1.300"));
    }

    #[test]
    fn backends_parse_and_refuse_odd_distros() {
        assert_eq!(Backend::parse("api"), Backend::Api);
        assert_eq!(Backend::parse("windows"), Backend::Windows);
        assert_eq!(Backend::parse("wsl:Ubuntu-22.04"), Backend::Wsl("Ubuntu-22.04".into()));
        assert_eq!(Backend::parse("wsl:x&y"), Backend::Api);
        assert_eq!(Backend::parse(""), Backend::Api);
    }

    #[test]
    fn the_result_line_is_found_after_shell_noise() {
        let out = "Welcome to Ubuntu\n{\"type\":\"result\",\"subtype\":\"success\",\"is_error\":false,\"result\":\"OK\",\"session_id\":\"b015262a-3d5d-46cc-b71d-8f56527dee84\"}\n";
        let r = parse_reply(out).unwrap();
        assert_eq!(r.text, "OK");
        assert_eq!(r.session_id.as_deref(), Some("b015262a-3d5d-46cc-b71d-8f56527dee84"));
        assert!(!r.is_error);
        assert!(parse_reply("not json\n").is_none());
    }

    #[test]
    fn a_session_id_that_is_not_a_uuid_is_never_resumed() {
        let out = r#"{"type":"result","result":"x","session_id":"--dangerously-skip-permissions"}"#;
        assert!(parse_reply(out).unwrap().session_id.is_none());
    }
}
