// "+ New task": start an agent (Claude, Codex, Kimi Code, Hermes) in a folder,
// either as a CLI in a new terminal or in its desktop app, with a prompt.
//
// `execute` is the single entry point. The island's `launch_task` command and
// the chat's task tool both call it, so validation, logging and the typing
// safety rules are the same whoever asks.
//
// CLI prompts travel as one argv element, never through a shell string:
//   - Windows Terminal (`wt.exe -w new -d . -- <exe> <args>`) re-parses its
//     command line: `;` splits commands and `"`/`\` follow the MSVC rules, so
//     every argument goes through `wt_escape` first. wt also expands `%NAME%`
//     with no way to escape it, so a prompt containing `%` skips wt and opens
//     in a new console directly (Windows Terminal still hosts it when it is
//     the default terminal).
//   - An npm `.cmd` shim is resolved to the `.exe` it calls. A shim that cannot
//     be resolved is only ever started directly, where Rust's own batch-file
//     quoting applies.
//
// Desktop apps (and Kimi's CLI, which takes no prompt argument) get the prompt
// by clipboard paste + Enter, but only into a window whose process image is
// the expected app, and only while that window is in the foreground. Every
// keystroke batch is preceded by that check. If it fails, nothing is typed:
// the prompt stays on the clipboard and the caller is told to paste it.
//
// The log records agent, target, folder and outcome. Never the prompt.

use std::collections::HashSet;
use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::Mutex;
use std::time::{Duration, Instant};

use serde::Serialize;

pub const MAX_PROMPT_CHARS: usize = 8_000;

const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;
const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// One launch at a time: the clipboard and the keyboard are shared.
static BUSY: Mutex<()> = Mutex::new(());

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Agent {
    Claude,
    Codex,
    KimiCode,
    Hermes,
}

impl Agent {
    pub fn parse(id: &str) -> Option<Agent> {
        match id {
            "claude" => Some(Agent::Claude),
            "codex" => Some(Agent::Codex),
            "kimi-code" => Some(Agent::KimiCode),
            "hermes" => Some(Agent::Hermes),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
            Agent::KimiCode => "kimi-code",
            Agent::Hermes => "hermes",
        }
    }

    fn stem(self) -> &'static str {
        match self {
            Agent::Claude => "claude",
            Agent::Codex => "codex",
            Agent::KimiCode => "kimi",
            Agent::Hermes => "hermes",
        }
    }

    fn desktop_name(self) -> &'static str {
        match self {
            Agent::Claude => "Claude",
            Agent::Codex => "ChatGPT (Codex)",
            Agent::KimiCode => "Kimi Code",
            Agent::Hermes => "Hermes",
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Target {
    Cli,
    Desktop,
}

impl Target {
    pub fn parse(id: &str) -> Option<Target> {
        match id {
            "cli" => Some(Target::Cli),
            "desktop" => Some(Target::Desktop),
            _ => None,
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            Target::Cli => "cli",
            Target::Desktop => "desktop",
        }
    }
}

#[derive(Debug, Clone)]
pub struct LaunchRequest {
    pub agent: String,
    pub target: String,
    pub folder: String,
    pub prompt: String,
}

#[derive(Debug)]
pub struct Validated {
    pub agent: Agent,
    pub target: Target,
    /// Canonical folder without the `\\?\` prefix.
    pub folder: PathBuf,
    pub prompt: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
pub struct LaunchOutcome {
    /// "started" or "clipboard" (the prompt is on the clipboard: paste it).
    pub status: &'static str,
    pub message: String,
}

impl LaunchOutcome {
    fn started(message: impl Into<String>) -> Self {
        Self { status: "started", message: message.into() }
    }
    fn clipboard(message: impl Into<String>) -> Self {
        Self { status: "clipboard", message: message.into() }
    }
}

// ── Validation ───────────────────────────────────────────────────────────────

pub fn validate_prompt(prompt: &str) -> Result<String, String> {
    if prompt.contains('\0') {
        return Err("The prompt contains a NUL character.".into());
    }
    let trimmed = prompt.trim();
    if trimmed.is_empty() {
        return Err("Write a prompt first.".into());
    }
    if trimmed.chars().count() > MAX_PROMPT_CHARS {
        return Err(format!("The prompt is longer than {MAX_PROMPT_CHARS} characters."));
    }
    Ok(trimmed.to_string())
}

/// `\\?\C:\x` → `C:\x`, `\\?\UNC\srv\share` → `\\srv\share`. Terminals and
/// shells handle the verbatim form badly as a working directory.
pub fn strip_verbatim(path: &str) -> String {
    if let Some(rest) = path.strip_prefix(r"\\?\UNC\") {
        format!(r"\\{rest}")
    } else if let Some(rest) = path.strip_prefix(r"\\?\") {
        rest.to_string()
    } else {
        path.to_string()
    }
}

pub fn validate_folder(folder: &str) -> Result<PathBuf, String> {
    let folder = folder.trim();
    if folder.is_empty() {
        return Err("Choose a folder.".into());
    }
    if folder.contains('\0') {
        return Err("The folder path contains a NUL character.".into());
    }
    let canonical = std::fs::canonicalize(folder).map_err(|_| format!("Folder not found: {folder}"))?;
    if !canonical.is_dir() {
        return Err(format!("Not a folder: {folder}"));
    }
    Ok(PathBuf::from(strip_verbatim(&canonical.to_string_lossy())))
}

pub fn validate(req: &LaunchRequest) -> Result<Validated, String> {
    let agent = Agent::parse(&req.agent).ok_or_else(|| format!("Unknown agent: {}", req.agent))?;
    let target = Target::parse(&req.target).ok_or_else(|| format!("Unknown target: {}", req.target))?;
    let prompt = validate_prompt(&req.prompt)?;
    let folder = validate_folder(&req.folder)?;
    Ok(Validated { agent, target, folder, prompt })
}

// ── Prompt shaping ───────────────────────────────────────────────────────────

/// One line for a command line: control characters (newlines, tabs) become
/// spaces, and a leading `-` is shielded so no CLI reads the prompt as a flag.
pub fn cli_prompt(prompt: &str) -> String {
    let flat: String = prompt.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    let trimmed = flat.trim();
    if trimmed.starts_with('-') {
        format!(" {trimmed}")
    } else {
        trimmed.to_string()
    }
}

/// Text for a paste into a desktop composer: CRLF → LF, other control
/// characters except LF and TAB dropped.
pub fn paste_text(prompt: &str) -> String {
    prompt
        .replace("\r\n", "\n")
        .chars()
        .filter(|&c| c == '\n' || c == '\t' || !c.is_control())
        .collect()
}

/// The argv after the executable for each CLI.
pub fn cli_args(agent: Agent, prompt: &str) -> Vec<String> {
    let p = cli_prompt(prompt);
    match agent {
        Agent::Claude | Agent::Codex => vec![p],
        // On a TTY `-q` seeds an interactive session (see `hermes chat --help`).
        // `--cli`: the Ink TUI (display.interface: tui) gives up on the startup
        // query when its session takes over 4 s to appear, which happened here;
        // the classic CLI always submits it.
        Agent::Hermes => vec!["chat".into(), "--cli".into(), "-q".into(), p],
        // Kimi has no prompt argument; the prompt is pasted in.
        Agent::KimiCode => Vec::new(),
    }
}

/// Escapes one argument for Windows Terminal, which rebuilds the child's
/// command line from its own argv. The caller passes the result through
/// `Command::arg`, which adds the outer MSVC quoting. Verified against
/// wt 1.24 with spaces, quotes, backslashes, `;`, `&|<>^!`, `%` (without a
/// matching `%NAME%`) and non-ASCII text.
pub fn wt_escape(arg: &str) -> String {
    let wrapped = arg.is_empty() || arg.contains(' ') || arg.contains('\t');
    let mut out = String::with_capacity(arg.len() + 8);
    let mut backslashes = 0usize;
    for ch in arg.chars() {
        match ch {
            '\\' => backslashes += 1,
            '"' => {
                out.push_str(&"\\".repeat(backslashes * 2 + 1));
                out.push('"');
                backslashes = 0;
            }
            _ => {
                out.push_str(&"\\".repeat(backslashes));
                if ch == ';' {
                    out.push('\\');
                }
                out.push(ch);
                backslashes = 0;
            }
        }
    }
    out.push_str(&"\\".repeat(if wrapped { backslashes * 2 } else { backslashes }));
    out
}

/// wt cannot escape `%NAME%`, so any `%` sends the launch around it.
pub fn wt_safe(args: &[String]) -> bool {
    !args.iter().any(|a| a.contains('%'))
}

/// `wt.exe` arguments: a new window in the current directory (the caller sets
/// it to the task folder) running `exe args…`. A title is pinned (the app
/// cannot rename the tab) so the window can be found again.
pub fn wt_args(exe: &Path, args: &[String], title: Option<&str>) -> Vec<String> {
    let mut out: Vec<String> = ["-w", "new"].iter().map(|s| s.to_string()).collect();
    if let Some(t) = title {
        out.extend(["--title".to_string(), wt_escape(t), "--suppressApplicationTitle".to_string()]);
    }
    out.extend(["-d", ".", "--"].iter().map(|s| s.to_string()));
    out.push(wt_escape(&exe.to_string_lossy()));
    out.extend(args.iter().map(|a| wt_escape(a)));
    out
}

// ── Finding the CLIs ─────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Exe {
    /// A real executable; safe to hand to wt.
    Native(PathBuf),
    /// A `.cmd` shim we could not see through; only ever spawned directly.
    Shim(PathBuf),
}

/// The `.exe` an npm-style `.cmd` shim runs (`"%dp0%\node_modules\…\x.exe" %*`).
pub fn npm_shim_target(shim_text: &str) -> Option<String> {
    for line in shim_text.lines() {
        let Some(start) = line.find("\"%dp0%\\") else { continue };
        let rest = &line[start + 7..];
        let Some(end) = rest.find('"') else { continue };
        let rel = &rest[..end];
        if rel.to_ascii_lowercase().ends_with(".exe") && !rel.contains("..") {
            return Some(rel.to_string());
        }
    }
    None
}

fn home() -> PathBuf {
    std::env::var_os("USERPROFILE").map(PathBuf::from).unwrap_or_default()
}

fn local_app_data() -> PathBuf {
    std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default()
}

fn known_cli_paths(agent: Agent) -> Vec<PathBuf> {
    match agent {
        Agent::Claude => vec![home().join(r".local\bin\claude.exe")],
        Agent::Codex => vec![local_app_data().join(r"Programs\OpenAI\Codex\bin\codex.exe")],
        Agent::KimiCode => vec![home().join(r".kimi-code\bin\kimi.exe")],
        Agent::Hermes => vec![local_app_data().join(r"hermes\bin\hermes.exe")],
    }
}

pub fn find_cli(agent: Agent) -> Option<Exe> {
    let stem = agent.stem();
    let mut shim: Option<PathBuf> = None;
    if let Some(dirs) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&dirs) {
            let exe = dir.join(format!("{stem}.exe"));
            if exe.is_file() {
                return Some(Exe::Native(exe));
            }
            let cmd = dir.join(format!("{stem}.cmd"));
            if cmd.is_file() {
                if let Some(rel) = std::fs::read_to_string(&cmd).ok().as_deref().and_then(npm_shim_target) {
                    let target = dir.join(rel);
                    if target.is_file() {
                        return Some(Exe::Native(target));
                    }
                }
                shim.get_or_insert(cmd);
            }
        }
    }
    if let Some(p) = known_cli_paths(agent).into_iter().find(|p| p.is_file()) {
        return Some(Exe::Native(p));
    }
    shim.map(Exe::Shim)
}

fn windows_terminal() -> Option<PathBuf> {
    let wt = local_app_data().join(r"Microsoft\WindowsApps\wt.exe");
    // An app-execution alias is a reparse point; `exists` follows it, so use
    // symlink_metadata to accept the alias itself.
    std::fs::symlink_metadata(&wt).ok().map(|_| wt)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CliRoute {
    WindowsTerminal,
    NewConsole,
}

pub fn cli_route(exe: &Exe, args: &[String], wt_available: bool) -> CliRoute {
    match exe {
        Exe::Native(_) if wt_available && wt_safe(args) => CliRoute::WindowsTerminal,
        _ => CliRoute::NewConsole,
    }
}

// ── Desktop apps ─────────────────────────────────────────────────────────────

/// How a top-level window's process image is recognised.
#[derive(Debug, Clone, Copy)]
pub struct ExpectedExe {
    /// File name, compared case-insensitively.
    pub file: &'static str,
    /// Required (case-insensitive) substring of the full path, if any.
    pub path_part: Option<&'static str>,
}

impl ExpectedExe {
    pub fn matches(&self, image_path: &str) -> bool {
        let lower = image_path.to_ascii_lowercase().replace('/', "\\");
        let file = lower.rsplit('\\').next().unwrap_or("");
        file == self.file.to_ascii_lowercase()
            && self.path_part.map_or(true, |p| lower.contains(&p.to_ascii_lowercase()))
    }
}

pub const TERMINAL_EXE: ExpectedExe = ExpectedExe { file: "WindowsTerminal.exe", path_part: None };

pub fn desktop_exe(agent: Agent) -> ExpectedExe {
    match agent {
        // The CLI is also `claude.exe`; only the Store package path is the app.
        Agent::Claude => ExpectedExe { file: "Claude.exe", path_part: Some(r"\WindowsApps\Claude_") },
        Agent::Codex => ExpectedExe { file: "ChatGPT.exe", path_part: Some(r"\WindowsApps\OpenAI.Codex_") },
        Agent::KimiCode => ExpectedExe { file: "Kimi Code.exe", path_part: None },
        Agent::Hermes => ExpectedExe { file: "Hermes.exe", path_part: None },
    }
}

/// Percent-encodes everything except RFC 3986 unreserved characters.
pub fn url_encode(text: &str) -> String {
    let mut out = String::with_capacity(text.len() * 3);
    for b in text.bytes() {
        if b.is_ascii_alphanumeric() || matches!(b, b'-' | b'.' | b'_' | b'~') {
            out.push(b as char);
        } else {
            out.push_str(&format!("%{b:02X}"));
        }
    }
    out
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DesktopLaunch {
    /// Registered protocol URL, opened with ShellExecute.
    Url(String),
    /// Start the app's own exe with these args and extra environment, then
    /// once more per `then` entry (each one reaches the running instance).
    Exe { path: PathBuf, args: Vec<String>, env: Vec<(String, String)>, then: Vec<Vec<String>> },
}

/// What happens once the app's window is verified in front.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Input {
    /// The deep link already put the prompt in the composer: press Enter.
    PrefilledEnter,
    /// Optional shortcut chords first, then paste + Enter.
    Paste { pre_keys: Vec<Chord> },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Chord {
    CtrlN,
    CtrlL,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DesktopPlan {
    pub launch: DesktopLaunch,
    pub input: Input,
}

fn kimi_desktop_path() -> PathBuf {
    local_app_data().join(r"Programs\Kimi Code\Kimi Code.exe")
}

fn hermes_desktop_path() -> PathBuf {
    local_app_data().join(r"hermes\hermes-agent\apps\desktop\release\win-unpacked\Hermes.exe")
}

/// `already_running`: a window of the app was up before the launch.
pub fn desktop_plan(agent: Agent, folder: &Path, prompt: &str, already_running: bool) -> DesktopPlan {
    let folder_s = folder.to_string_lossy().to_string();
    match agent {
        // claude://code/new?q=…&folder=… opens a new Claude Code session in
        // the folder with the prompt in the composer (Claude 2.19675).
        Agent::Claude => DesktopPlan {
            launch: DesktopLaunch::Url(format!(
                "claude://code/new?q={}&folder={}",
                url_encode(prompt),
                url_encode(&folder_s)
            )),
            input: Input::PrefilledEnter,
        },
        // codex://threads/new?prompt=…&path=… opens a new thread for that
        // workspace with the prompt prefilled and the composer focused.
        Agent::Codex => DesktopPlan {
            launch: DesktopLaunch::Url(format!(
                "codex://threads/new?prompt={}&path={}",
                url_encode(prompt),
                url_encode(&folder_s)
            )),
            input: Input::PrefilledEnter,
        },
        // Kimi Code (1.0.4) forwards --new-chat / --workspace= from a second
        // instance, but always as "new chat" first, then "open workspace" —
        // and opening a workspace that has sessions selects its newest one,
        // so one call lands in an old session. Two calls in the right order:
        // switch to the workspace, then open a new chat there (which also
        // focuses the composer). Its kimi-code:// links only cover sign-in,
        // so the prompt is pasted.
        Agent::KimiCode => DesktopPlan {
            launch: DesktopLaunch::Exe {
                path: kimi_desktop_path(),
                args: vec![format!("--workspace={folder_s}")],
                env: Vec::new(),
                then: vec![vec!["--new-chat".into()]],
            },
            input: Input::Paste { pre_keys: Vec::new() },
        },
        // Hermes takes its first project from HERMES_DESKTOP_CWD at cold start
        // only. Ctrl+N = new session, Ctrl+L = focus the composer (its own
        // documented bindings).
        Agent::Hermes => DesktopPlan {
            launch: DesktopLaunch::Exe {
                path: hermes_desktop_path(),
                args: Vec::new(),
                env: vec![("HERMES_DESKTOP_CWD".into(), folder_s)],
                then: Vec::new(),
            },
            input: Input::Paste {
                pre_keys: if already_running { vec![Chord::CtrlN, Chord::CtrlL] } else { vec![Chord::CtrlL] },
            },
        },
    }
}

// ── Window choice and the typing gate (pure) ─────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WinInfo {
    pub hwnd: isize,
    pub pid: u32,
    pub exe: String,
    pub title: String,
}

/// What identifies the window to type into.
#[derive(Debug, Clone)]
pub struct WindowSpec {
    pub expected: ExpectedExe,
    /// Windows that existed before the launch and must not be the target.
    pub exclude: Option<HashSet<isize>>,
    /// Exact window title we set ourselves. Windows Terminal runs every window
    /// in one process, so for it the image alone cannot tell windows apart.
    pub title: Option<String>,
}

impl WindowSpec {
    pub fn matches(&self, w: &WinInfo, own_pid: u32) -> bool {
        w.hwnd != 0
            && w.pid != 0
            && w.pid != own_pid
            && self.expected.matches(&w.exe)
            && self.exclude.as_ref().map_or(true, |seen| !seen.contains(&w.hwnd))
            && self.title.as_deref().map_or(true, |t| w.title == t)
    }
}

/// The window to type into: the first candidate that fits the spec.
pub fn pick_window<'a>(candidates: &'a [WinInfo], spec: &WindowSpec, own_pid: u32) -> Option<&'a WinInfo> {
    candidates.iter().find(|w| spec.matches(w, own_pid))
}

/// Typing is allowed only while the foreground window is exactly the target
/// window, still owned by the same process, still the expected image (and,
/// when the spec has one, still carrying our title).
pub fn foreground_is_target(target: &WinInfo, foreground: Option<&WinInfo>, spec: &WindowSpec, own_pid: u32) -> bool {
    match foreground {
        Some(fg) => {
            fg.hwnd == target.hwnd
                && fg.pid == target.pid
                && fg.pid != own_pid
                && spec.expected.matches(&fg.exe)
                && spec.title.as_deref().map_or(true, |t| fg.title == t)
        }
        None => false,
    }
}

/// A title no other window will have, for the terminal Kimi is typed into.
pub fn unique_title(seed: u128) -> String {
    format!("Coucou task {:08x}", (seed % 0x1_0000_0000) as u32)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Gate {
    Type,
    /// The user is holding a modifier; a Ctrl/Shift/Alt/Win press would turn
    /// Enter into something else.
    Hold,
    Abort,
}

pub fn gate(verified: bool, modifiers_down: bool) -> Gate {
    if !verified {
        Gate::Abort
    } else if modifiers_down {
        Gate::Hold
    } else {
        Gate::Type
    }
}

pub fn paste_hint(app: &str) -> String {
    format!("Prompt copied. Press Ctrl+V then Enter in {app}.")
}

// ── Entry point ──────────────────────────────────────────────────────────────

/// Validates, launches and (where needed) types the prompt. Blocking: call it
/// off the main thread. Shared by the island and the chat's task tool.
pub fn execute(req: &LaunchRequest) -> Result<(Validated, LaunchOutcome), String> {
    let v = match validate(req) {
        Ok(v) => v,
        Err(err) => {
            crate::log::line(format!(
                "launch agent={} target={} outcome=invalid ({err})",
                req.agent, req.target
            ));
            return Err(err);
        }
    };
    let Ok(_guard) = BUSY.try_lock() else {
        return Err("Another task is still starting.".into());
    };
    let result = match v.target {
        Target::Cli => run_cli(&v),
        Target::Desktop => run_desktop(&v),
    };
    let outcome = match &result {
        Ok(o) => format!("{} ({})", o.status, o.message),
        Err(e) => format!("error ({e})"),
    };
    crate::log::line(format!(
        "launch agent={} target={} folder={} outcome={outcome}",
        v.agent.id(),
        v.target.id(),
        v.folder.display()
    ));
    result.map(|o| (v, o))
}

fn run_cli(v: &Validated) -> Result<LaunchOutcome, String> {
    let exe = find_cli(v.agent).ok_or_else(|| format!("`{}` was not found on PATH.", v.agent.stem()))?;
    let args = cli_args(v.agent, &v.prompt);
    let wt = windows_terminal();
    let route = cli_route(&exe, &args, wt.is_some());

    if v.agent == Agent::KimiCode {
        let (Some(wt), Exe::Native(exe_path)) = (wt.as_ref(), &exe) else {
            spawn_console(&exe, &args, &v.folder)?;
            sys::set_clipboard_text(&cli_prompt(&v.prompt))?;
            return Ok(LaunchOutcome::clipboard(paste_hint("the Kimi terminal")));
        };
        let before = sys::window_set(&TERMINAL_EXE);
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| d.as_nanos())
            .unwrap_or_default();
        let title = unique_title(nanos ^ u128::from(std::process::id()) << 32);
        spawn_wt_titled(wt, exe_path, &args, &v.folder, Some(&title))?;
        return sys::deliver(&Delivery {
            app: "the Kimi terminal",
            window: WindowSpec { expected: TERMINAL_EXE, exclude: Some(before), title: Some(title) },
            settle: Duration::from_millis(3_500),
            pre_keys: Vec::new(),
            text: Some(cli_prompt(&v.prompt)),
            started: "Kimi started in a new terminal with your prompt.",
        });
    }

    match (route, &exe, wt.as_ref()) {
        (CliRoute::WindowsTerminal, Exe::Native(exe_path), Some(wt)) => spawn_wt(wt, exe_path, &args, &v.folder)?,
        _ => spawn_console(&exe, &args, &v.folder)?,
    }
    Ok(LaunchOutcome::started(format!("Started {} in a new terminal.", v.agent.stem())))
}

fn spawn_wt(wt: &Path, exe: &Path, args: &[String], folder: &Path) -> Result<(), String> {
    spawn_wt_titled(wt, exe, args, folder, None)
}

fn spawn_wt_titled(wt: &Path, exe: &Path, args: &[String], folder: &Path, title: Option<&str>) -> Result<(), String> {
    let mut child = Command::new(wt)
        .args(wt_args(exe, args, title))
        .current_dir(folder)
        .creation_flags(CREATE_NO_WINDOW)
        .spawn()
        .map_err(|e| format!("Windows Terminal did not start: {e}"))?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => return Ok(()),
            Ok(Some(status)) => return Err(format!("Windows Terminal exited with {status}.")),
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(50)),
            // Still running after 5 s: it has opened its window.
            Ok(None) => return Ok(()),
            Err(e) => return Err(format!("Windows Terminal: {e}")),
        }
    }
}

fn spawn_console(exe: &Exe, args: &[String], folder: &Path) -> Result<(), String> {
    let path = match exe {
        Exe::Native(p) | Exe::Shim(p) => p,
    };
    Command::new(path)
        .args(args)
        .current_dir(folder)
        .creation_flags(CREATE_NEW_CONSOLE)
        .spawn()
        .map(|_| ())
        .map_err(|e| format!("Could not start {}: {e}", path.display()))
}

fn run_desktop(v: &Validated) -> Result<LaunchOutcome, String> {
    let expected = desktop_exe(v.agent);
    let running = !sys::window_set(&expected).is_empty();
    let plan = desktop_plan(v.agent, &v.folder, &v.prompt, running);
    let app = v.agent.desktop_name();

    match &plan.launch {
        DesktopLaunch::Url(url) => sys::open_url(url).map_err(|e| format!("Could not open {app}: {e}"))?,
        DesktopLaunch::Exe { path, args, env, then } => {
            if !path.is_file() {
                return Err(format!("{app} is not installed ({}).", path.display()));
            }
            let spawn = |args: &[String]| {
                let mut cmd = Command::new(path);
                cmd.args(args).current_dir(&v.folder);
                for (k, val) in env {
                    cmd.env(k, val);
                }
                cmd.spawn().map_err(|e| format!("Could not start {app}: {e}"))
            };
            let mut child = spawn(args)?;
            for next in then {
                handed_over(&mut child, &expected, running);
                std::thread::sleep(Duration::from_millis(400));
                child = spawn(next)?;
            }
        }
    }

    let (pre_keys, text) = match &plan.input {
        Input::PrefilledEnter => (Vec::new(), None),
        Input::Paste { pre_keys } => (pre_keys.clone(), Some(paste_text(&v.prompt))),
    };
    let outcome = sys::deliver(&Delivery {
        app,
        window: WindowSpec { expected, exclude: None, title: None },
        settle: if running { Duration::from_millis(1_500) } else { Duration::from_millis(6_000) },
        pre_keys,
        text,
        started: "Started with your prompt.",
    })?;
    if outcome.status == "clipboard" && plan.input == Input::PrefilledEnter {
        sys::set_clipboard_text(&paste_text(&v.prompt))?;
        return Ok(LaunchOutcome::clipboard(format!(
            "Check {app}: press Enter if the prompt is filled in, or Ctrl+V then Enter."
        )));
    }
    Ok(outcome)
}

/// Waits until a just-started app exe has done its part, so the next call
/// lands after it. Already running: the new process hands its argv to the
/// running one and exits. Cold start: it becomes the app; once its window is
/// up it holds the single-instance lock and queues later argv in order.
fn handed_over(child: &mut std::process::Child, expected: &ExpectedExe, already_running: bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while Instant::now() < deadline {
        match child.try_wait() {
            Ok(Some(_)) | Err(_) => return,
            Ok(None) if !already_running && !sys::window_set(expected).is_empty() => return,
            Ok(None) => std::thread::sleep(Duration::from_millis(100)),
        }
    }
}

pub struct Delivery {
    pub app: &'static str,
    pub window: WindowSpec,
    /// Wait after the window appears, before the first keystroke.
    pub settle: Duration,
    pub pre_keys: Vec<Chord>,
    /// Text to paste; None = only press Enter.
    pub text: Option<String>,
    pub started: &'static str,
}

pub fn open_protocol_url(url: &str) -> Result<(), String> {
    const SCHEMES: [&str; 3] = ["claude://", "codex://", "hermes://"];
    if !SCHEMES.iter().any(|scheme| url.starts_with(scheme)) { return Err("not an agent app link".into()); }
    sys::open_url(url)
}

// ── Win32 side ───────────────────────────────────────────────────────────────

mod sys {
    use super::*;
    use windows::core::{BOOL, PCWSTR, PWSTR};
    use windows::Win32::Foundation::{CloseHandle, GlobalFree, HANDLE, HGLOBAL, HWND, LPARAM};
    use windows::Win32::System::Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED, COINIT_DISABLE_OLE1DDE};
    use windows::Win32::System::DataExchange::{
        CloseClipboard, CountClipboardFormats, EmptyClipboard, GetClipboardData, GetClipboardSequenceNumber,
        IsClipboardFormatAvailable, OpenClipboard, SetClipboardData,
    };
    use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalSize, GlobalUnlock, GMEM_MOVEABLE};
    use windows::Win32::System::Ole::CF_UNICODETEXT;
    use windows::Win32::System::Threading::{
        GetCurrentProcessId, OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32,
        PROCESS_QUERY_LIMITED_INFORMATION,
    };
    use windows::Win32::UI::Input::KeyboardAndMouse::{
        GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS, KEYEVENTF_KEYUP,
        VIRTUAL_KEY, VK_CONTROL, VK_L, VK_LWIN, VK_MENU, VK_N, VK_RETURN, VK_RWIN, VK_SHIFT, VK_V,
    };
    use windows::Win32::UI::Shell::ShellExecuteW;
    use windows::Win32::UI::WindowsAndMessaging::{
        EnumWindows, GetForegroundWindow, GetWindow, GetWindowLongW, GetWindowTextLengthW, GetWindowTextW,
        GetWindowThreadProcessId, IsWindowVisible,
        GWL_EXSTYLE, GW_OWNER, SW_SHOWNORMAL, WS_EX_TOOLWINDOW,
    };

    const CF_TEXT: u32 = CF_UNICODETEXT.0 as u32;
    const WINDOW_WAIT: Duration = Duration::from_secs(20);

    fn wide(s: &str) -> Vec<u16> {
        s.encode_utf16().chain(std::iter::once(0)).collect()
    }

    pub fn own_pid() -> u32 {
        unsafe { GetCurrentProcessId() }
    }

    pub fn image_path(pid: u32) -> Option<String> {
        unsafe {
            let handle = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid).ok()?;
            let mut buf = vec![0u16; 1024];
            let mut len = buf.len() as u32;
            let ok = QueryFullProcessImageNameW(handle, PROCESS_NAME_WIN32, PWSTR(buf.as_mut_ptr()), &mut len).is_ok();
            let _ = CloseHandle(handle);
            ok.then(|| String::from_utf16_lossy(&buf[..len as usize]))
        }
    }

    fn info(hwnd: HWND) -> Option<WinInfo> {
        let mut pid = 0u32;
        unsafe { GetWindowThreadProcessId(hwnd, Some(&mut pid)) };
        if pid == 0 {
            return None;
        }
        let len = unsafe { GetWindowTextLengthW(hwnd) }.max(0) as usize;
        let mut buf = vec![0u16; len + 1];
        let n = unsafe { GetWindowTextW(hwnd, &mut buf) }.max(0) as usize;
        let title = String::from_utf16_lossy(&buf[..n.min(len)]);
        Some(WinInfo { hwnd: hwnd.0 as isize, pid, exe: image_path(pid)?, title })
    }

    unsafe extern "system" fn collect(hwnd: HWND, lparam: LPARAM) -> BOOL {
        let list = &mut *(lparam.0 as *mut Vec<HWND>);
        let visible = IsWindowVisible(hwnd).as_bool();
        let owned = GetWindow(hwnd, GW_OWNER).map(|h| !h.is_invalid()).unwrap_or(false);
        let tool = (GetWindowLongW(hwnd, GWL_EXSTYLE) as u32) & WS_EX_TOOLWINDOW.0 != 0;
        if visible && !owned && !tool {
            list.push(hwnd);
        }
        true.into()
    }

    /// Visible, unowned, non-tool top-level windows, in z-order.
    pub fn top_windows() -> Vec<WinInfo> {
        let mut handles: Vec<HWND> = Vec::new();
        unsafe {
            let _ = EnumWindows(Some(collect), LPARAM(&mut handles as *mut Vec<HWND> as isize));
        }
        handles.into_iter().filter_map(info).collect()
    }

    pub fn window_set(expected: &ExpectedExe) -> HashSet<isize> {
        top_windows().into_iter().filter(|w| expected.matches(&w.exe)).map(|w| w.hwnd).collect()
    }

    fn foreground() -> Option<WinInfo> {
        let hwnd = unsafe { GetForegroundWindow() };
        if hwnd.is_invalid() {
            return None;
        }
        info(hwnd)
    }

    fn modifiers_down() -> bool {
        [VK_CONTROL, VK_SHIFT, VK_MENU, VK_LWIN, VK_RWIN]
            .iter()
            .any(|vk| unsafe { GetAsyncKeyState(vk.0 as i32) } as u16 & 0x8000 != 0)
    }

    /// Re-checks the foreground right before a keystroke batch.
    fn check(target: &WinInfo, spec: &WindowSpec) -> Gate {
        let own = own_pid();
        for _ in 0..10 {
            let verified = foreground_is_target(target, foreground().as_ref(), spec, own);
            match gate(verified, modifiers_down()) {
                Gate::Hold => std::thread::sleep(Duration::from_millis(100)),
                other => return other,
            }
        }
        Gate::Abort
    }

    fn key(vk: VIRTUAL_KEY, up: bool) -> INPUT {
        INPUT {
            r#type: INPUT_KEYBOARD,
            Anonymous: INPUT_0 {
                ki: KEYBDINPUT { wVk: vk, dwFlags: if up { KEYEVENTF_KEYUP } else { KEYBD_EVENT_FLAGS(0) }, ..Default::default() },
            },
        }
    }

    fn send(inputs: &[INPUT]) -> bool {
        let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
        sent as usize == inputs.len()
    }

    fn ctrl(vk: VIRTUAL_KEY) -> bool {
        send(&[key(VK_CONTROL, false), key(vk, false), key(vk, true), key(VK_CONTROL, true)])
    }

    fn enter() -> bool {
        send(&[key(VK_RETURN, false), key(VK_RETURN, true)])
    }

    fn open_clipboard() -> bool {
        for _ in 0..20 {
            if unsafe { OpenClipboard(None) }.is_ok() {
                return true;
            }
            std::thread::sleep(Duration::from_millis(25));
        }
        false
    }

    /// Previous clipboard: Some(Some(text)) = text, Some(None) = empty,
    /// None = something we cannot put back (an image, files…).
    fn read_clipboard() -> Option<Option<String>> {
        if !open_clipboard() {
            return None;
        }
        let result = unsafe {
            if IsClipboardFormatAvailable(CF_TEXT).is_ok() {
                GetClipboardData(CF_TEXT).ok().and_then(|h| {
                    let g = HGLOBAL(h.0);
                    let ptr = GlobalLock(g) as *const u16;
                    if ptr.is_null() {
                        return None;
                    }
                    let max = GlobalSize(g) / 2;
                    let slice = std::slice::from_raw_parts(ptr, max);
                    let len = slice.iter().position(|&c| c == 0).unwrap_or(max);
                    let text = String::from_utf16_lossy(&slice[..len]);
                    let _ = GlobalUnlock(g);
                    Some(Some(text))
                })
            } else if CountClipboardFormats() == 0 {
                Some(None)
            } else {
                None
            }
        };
        unsafe {
            let _ = CloseClipboard();
        }
        result
    }

    pub fn set_clipboard_text(text: &str) -> Result<(), String> {
        if !open_clipboard() {
            return Err("The clipboard is busy.".into());
        }
        let data = wide(text);
        let result = unsafe {
            (|| -> Result<(), String> {
                EmptyClipboard().map_err(|e| e.to_string())?;
                let g = GlobalAlloc(GMEM_MOVEABLE, data.len() * 2).map_err(|e| e.to_string())?;
                let ptr = GlobalLock(g) as *mut u16;
                if ptr.is_null() {
                    let _ = GlobalFree(Some(g));
                    return Err("clipboard memory".into());
                }
                std::ptr::copy_nonoverlapping(data.as_ptr(), ptr, data.len());
                let _ = GlobalUnlock(g);
                if SetClipboardData(CF_TEXT, Some(HANDLE(g.0))).is_err() {
                    let _ = GlobalFree(Some(g));
                    return Err("SetClipboardData failed".into());
                }
                Ok(())
            })()
        };
        unsafe {
            let _ = CloseClipboard();
        }
        result.map_err(|e| format!("Could not use the clipboard: {e}"))
    }

    fn empty_clipboard() {
        if open_clipboard() {
            unsafe {
                let _ = EmptyClipboard();
                let _ = CloseClipboard();
            }
        }
    }

    pub fn open_url(url: &str) -> Result<(), String> {
        let w = wide(url);
        unsafe {
            let com = CoInitializeEx(None, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
            let r = ShellExecuteW(None, windows::core::w!("open"), PCWSTR(w.as_ptr()), PCWSTR::null(), PCWSTR::null(), SW_SHOWNORMAL);
            if com.is_ok() {
                CoUninitialize();
            }
            if r.0 as isize > 32 {
                Ok(())
            } else {
                Err(format!("ShellExecute error {}", r.0 as isize))
            }
        }
    }

    fn wait_for_window(d: &Delivery) -> Option<WinInfo> {
        let own = own_pid();
        let deadline = Instant::now() + WINDOW_WAIT;
        while Instant::now() < deadline {
            let all = top_windows();
            // Prefer the foreground window if it is the app's own.
            if let Some(fg) = foreground() {
                if pick_window(std::slice::from_ref(&fg), &d.window, own).is_some() {
                    return Some(fg);
                }
            }
            if let Some(w) = pick_window(&all, &d.window, own) {
                return Some(w.clone());
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        None
    }

    /// Waits for the app's window, brings it forward, and types — or leaves
    /// the prompt on the clipboard when anything cannot be verified.
    pub fn deliver(d: &Delivery) -> Result<LaunchOutcome, String> {
        let fallback = |why: &str| -> Result<LaunchOutcome, String> {
            crate::log::line(format!("launch typing skipped: {why}"));
            if let Some(text) = &d.text {
                set_clipboard_text(text)?;
            }
            Ok(LaunchOutcome::clipboard(paste_hint(d.app)))
        };

        let Some(target) = wait_for_window(d) else { return fallback("window never appeared") };
        std::thread::sleep(d.settle);
        // The window may have been replaced (splash → main) while settling.
        let target = if crate::focus::focus(target.hwnd as i64, target.pid) {
            target
        } else {
            match wait_for_window(d) {
                Some(t) if crate::focus::focus(t.hwnd as i64, t.pid) => t,
                _ => return fallback("could not bring the window forward"),
            }
        };
        std::thread::sleep(Duration::from_millis(350));

        for chord in &d.pre_keys {
            if check(&target, &d.window) != Gate::Type {
                return fallback("foreground changed before a shortcut");
            }
            let vk = match chord {
                Chord::CtrlN => VK_N,
                Chord::CtrlL => VK_L,
            };
            if !ctrl(vk) {
                return fallback("SendInput was blocked");
            }
            std::thread::sleep(Duration::from_millis(match chord {
                Chord::CtrlN => 900,
                Chord::CtrlL => 300,
            }));
        }

        if let Some(text) = &d.text {
            let previous = read_clipboard();
            set_clipboard_text(text)?;
            let ours = unsafe { GetClipboardSequenceNumber() };
            if check(&target, &d.window) != Gate::Type {
                return fallback("foreground changed before paste");
            }
            if !ctrl(VK_V) {
                return fallback("SendInput was blocked");
            }
            // The target reads the clipboard while handling the paste.
            std::thread::sleep(Duration::from_millis(700));
            if check(&target, &d.window) != Gate::Type {
                return fallback("foreground changed after paste");
            }
            if !enter() {
                return fallback("SendInput was blocked");
            }
            std::thread::sleep(Duration::from_millis(400));
            if unsafe { GetClipboardSequenceNumber() } == ours {
                match previous {
                    Some(Some(old)) => {
                        let _ = set_clipboard_text(&old);
                    }
                    Some(None) => empty_clipboard(),
                    None => {}
                }
            }
        } else {
            if check(&target, &d.window) != Gate::Type {
                return fallback("foreground changed before Enter");
            }
            if !enter() {
                return fallback("SendInput was blocked");
            }
        }
        Ok(LaunchOutcome::started(d.started))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &[&str]) -> Vec<String> {
        v.iter().map(|x| x.to_string()).collect()
    }

    #[test]
    fn prompt_validation() {
        assert_eq!(validate_prompt("  hi  ").unwrap(), "hi");
        assert!(validate_prompt("   \n ").is_err());
        assert!(validate_prompt("a\0b").is_err());
        assert!(validate_prompt(&"é".repeat(MAX_PROMPT_CHARS)).is_ok());
        assert!(validate_prompt(&"é".repeat(MAX_PROMPT_CHARS + 1)).is_err());
    }

    #[test]
    fn folder_validation() {
        let dir = std::env::temp_dir();
        let ok = validate_folder(&dir.to_string_lossy()).unwrap();
        assert!(ok.is_dir());
        assert!(!ok.to_string_lossy().starts_with(r"\\?\"));
        assert!(validate_folder("").is_err());
        assert!(validate_folder(r"C:\definitely\not\here\coucou").is_err());
        let file = std::env::current_exe().unwrap();
        assert!(validate_folder(&file.to_string_lossy()).is_err());
    }

    #[test]
    fn request_validation_rejects_unknown_values() {
        let dir = std::env::temp_dir().to_string_lossy().to_string();
        let req = |agent: &str, target: &str| LaunchRequest {
            agent: agent.into(),
            target: target.into(),
            folder: dir.clone(),
            prompt: "do it".into(),
        };
        assert!(validate(&req("claude", "cli")).is_ok());
        assert!(validate(&req("kimi-code", "desktop")).is_ok());
        assert!(validate(&req("gpt", "cli")).is_err());
        assert!(validate(&req("codex", "web")).is_err());
    }

    #[test]
    fn verbatim_prefix_is_stripped() {
        assert_eq!(strip_verbatim(r"\\?\C:\work"), r"C:\work");
        assert_eq!(strip_verbatim(r"\\?\UNC\srv\share\x"), r"\\srv\share\x");
        assert_eq!(strip_verbatim(r"C:\work"), r"C:\work");
    }

    #[test]
    fn cli_prompt_is_one_line_and_never_a_flag() {
        assert_eq!(cli_prompt("line one\r\nline two\tthree"), "line one  line two three");
        assert_eq!(cli_prompt("--help me"), " --help me");
        assert_eq!(cli_prompt("  -x  "), " -x");
    }

    #[test]
    fn paste_text_keeps_newlines_drops_other_controls() {
        assert_eq!(paste_text("a\r\nb\tc\u{7}d"), "a\nb\tcd");
    }

    #[test]
    fn cli_args_per_agent() {
        let p = r#"fix "it"; then & 100% ^ done"#;
        assert_eq!(cli_args(Agent::Claude, p), s(&[p]));
        assert_eq!(cli_args(Agent::Codex, p), s(&[p]));
        assert_eq!(cli_args(Agent::Hermes, p), s(&["chat", "--cli", "-q", p]));
        assert!(cli_args(Agent::KimiCode, p).is_empty());
        assert_eq!(cli_args(Agent::Claude, "a\nb"), s(&["a b"]));
    }

    #[test]
    fn wt_escape_cases() {
        // Expected values were checked end to end against wt 1.24 (argv echo).
        assert_eq!(wt_escape("Reply with just: ok"), "Reply with just: ok");
        assert_eq!(wt_escape("x;y"), r"x\;y");
        assert_eq!(wt_escape(";"), r"\;");
        assert_eq!(wt_escape(r#"a"b"#), r#"a\"b"#);
        assert_eq!(wt_escape(r#"say "hi there" now"#), r#"say \"hi there\" now"#);
        assert_eq!(wt_escape(r"ends with\"), r"ends with\\");
        assert_eq!(wt_escape(r"C:\dir\"), r"C:\dir\");
        assert_eq!(wt_escape(r#"q\"x"#), r#"q\\\"x"#);
        assert_eq!(wt_escape("a & b | c > d < e ^ f !g"), "a & b | c > d < e ^ f !g");
        assert_eq!(wt_escape("é 中文 🙂"), "é 中文 🙂");
    }

    #[test]
    fn wt_args_shape() {
        let args = wt_args(Path::new(r"C:\a b\claude.exe"), &s(&["x;y"]), None);
        assert_eq!(args, s(&["-w", "new", "-d", ".", "--", r"C:\a b\claude.exe", r"x\;y"]));
        let titled = wt_args(Path::new(r"C:\k\kimi.exe"), &[], Some("Coucou task 0000abcd"));
        assert_eq!(
            titled,
            s(&["-w", "new", "--title", "Coucou task 0000abcd", "--suppressApplicationTitle", "-d", ".", "--", r"C:\k\kimi.exe"])
        );
        assert_eq!(unique_title(0x1_2345_6789), "Coucou task 23456789");
    }

    #[test]
    fn percent_avoids_wt() {
        let native = Exe::Native(PathBuf::from(r"C:\x\codex.exe"));
        let shim = Exe::Shim(PathBuf::from(r"C:\x\codex.cmd"));
        assert_eq!(cli_route(&native, &s(&["fix it"]), true), CliRoute::WindowsTerminal);
        assert_eq!(cli_route(&native, &s(&["100%"]), true), CliRoute::NewConsole);
        assert_eq!(cli_route(&native, &s(&["%PATH%"]), true), CliRoute::NewConsole);
        assert_eq!(cli_route(&native, &s(&["fix it"]), false), CliRoute::NewConsole);
        assert_eq!(cli_route(&shim, &s(&["fix it"]), true), CliRoute::NewConsole);
    }

    #[test]
    fn npm_shim_is_seen_through() {
        let shim = "@ECHO off\r\nGOTO start\r\n:start\r\nSETLOCAL\r\nCALL :find_dp0\r\n\"%dp0%\\node_modules\\@anthropic-ai\\claude-code\\bin\\claude.exe\"   %*\r\n";
        assert_eq!(npm_shim_target(shim).as_deref(), Some(r"node_modules\@anthropic-ai\claude-code\bin\claude.exe"));
        assert_eq!(npm_shim_target("\"%dp0%\\node.exe\" \"%dp0%\\x.js\" %*").as_deref(), Some("node.exe"));
        assert_eq!(npm_shim_target("\"%dp0%\\..\\evil.exe\" %*"), None);
        assert_eq!(npm_shim_target("python.exe -c ..."), None);
    }

    #[test]
    fn exe_matching_uses_path_not_title() {
        let claude = desktop_exe(Agent::Claude);
        assert!(claude.matches(r"C:\Program Files\WindowsApps\Claude_2.19675.0.0_x64__pzs8sxrjxfjjc\app\Claude.exe"));
        assert!(!claude.matches(r"C:\Users\A\AppData\Roaming\Claude\claude-code\2.1.286\x\claude.exe"));
        assert!(!claude.matches(r"C:\Program Files\WindowsApps\Claude_2\app\ClaudeHelper.exe"));
        let codex = desktop_exe(Agent::Codex);
        assert!(codex.matches(r"C:\Program Files\WindowsApps\OpenAI.Codex_26.928.3736.0_x64__2p2nqsd0c76g0\app\ChatGPT.exe"));
        assert!(!codex.matches(r"C:\Program Files\ChatGPT\ChatGPT.exe"));
        assert!(desktop_exe(Agent::KimiCode).matches(r"C:\Users\A\AppData\Local\Programs\Kimi Code\Kimi Code.exe"));
        assert!(desktop_exe(Agent::Hermes).matches(r"c:\users\a\appdata\local\hermes\x\HERMES.EXE"));
        assert!(TERMINAL_EXE.matches(r"C:\Program Files\WindowsApps\Microsoft.WindowsTerminal_1\WindowsTerminal.exe"));
    }

    fn w(hwnd: isize, pid: u32, exe: &str) -> WinInfo {
        WinInfo { hwnd, pid, exe: exe.into(), title: String::new() }
    }

    fn spec(expected: ExpectedExe, exclude: Option<&[isize]>, title: Option<&str>) -> WindowSpec {
        WindowSpec {
            expected,
            exclude: exclude.map(|e| e.iter().copied().collect()),
            title: title.map(str::to_string),
        }
    }

    const WT: &str = r"C:\WindowsApps\Microsoft.WindowsTerminal_1\WindowsTerminal.exe";

    #[test]
    fn window_pick_skips_old_and_foreign_windows() {
        let wins = vec![w(1, 10, r"C:\x\Code.exe"), w(2, 20, WT), w(3, 30, WT)];
        assert_eq!(pick_window(&wins, &spec(TERMINAL_EXE, Some(&[2]), None), 99).map(|w| w.hwnd), Some(3));
        assert_eq!(pick_window(&wins, &spec(TERMINAL_EXE, None, None), 99).map(|w| w.hwnd), Some(2));
        assert!(pick_window(&wins, &spec(TERMINAL_EXE, Some(&[2, 3]), None), 99).is_none());
        // Our own process never qualifies.
        assert!(pick_window(&[w(4, 99, WT)], &spec(TERMINAL_EXE, None, None), 99).is_none());
    }

    #[test]
    fn terminal_window_is_found_by_our_title_not_by_being_new() {
        // All wt windows share one process; another tab may open meanwhile.
        let mut other = w(7, 20, WT);
        other.title = "codex".into();
        let mut ours = w(8, 20, WT);
        ours.title = "Coucou task 0000abcd".into();
        let s = spec(TERMINAL_EXE, Some(&[2]), Some("Coucou task 0000abcd"));
        assert_eq!(pick_window(&[other.clone(), ours.clone()], &s, 99).map(|w| w.hwnd), Some(8));
        assert!(pick_window(&[other.clone()], &s, 99).is_none());
        // The tab being renamed (pin lost) also stops typing.
        let mut renamed = ours.clone();
        renamed.title = "kimi-code".into();
        assert!(foreground_is_target(&ours, Some(&ours), &s, 99));
        assert!(!foreground_is_target(&ours, Some(&renamed), &s, 99));
    }

    #[test]
    fn foreground_check_requires_same_window_process_and_image() {
        const K: &str = r"C:\P\Kimi Code\Kimi Code.exe";
        let exp = spec(desktop_exe(Agent::KimiCode), None, None);
        let target = w(5, 50, K);
        assert!(foreground_is_target(&target, Some(&w(5, 50, K)), &exp, 1));
        assert!(!foreground_is_target(&target, Some(&w(6, 50, K)), &exp, 1));
        assert!(!foreground_is_target(&target, Some(&w(5, 51, K)), &exp, 1));
        assert!(!foreground_is_target(&target, Some(&w(5, 50, r"C:\x\notepad.exe")), &exp, 1));
        assert!(!foreground_is_target(&target, None, &exp, 1));
        assert!(!foreground_is_target(&w(5, 1, K), Some(&w(5, 1, K)), &exp, 1));
    }

    #[test]
    fn gate_decisions() {
        assert_eq!(gate(true, false), Gate::Type);
        assert_eq!(gate(true, true), Gate::Hold);
        assert_eq!(gate(false, false), Gate::Abort);
        assert_eq!(gate(false, true), Gate::Abort);
    }

    #[test]
    fn url_encoding_and_deep_links() {
        assert_eq!(url_encode("a b&c=d/é"), "a%20b%26c%3Dd%2F%C3%A9");
        let folder = Path::new(r"C:\my work");
        let plan = desktop_plan(Agent::Claude, folder, "fix #1 & go", false);
        assert_eq!(
            plan.launch,
            DesktopLaunch::Url("claude://code/new?q=fix%20%231%20%26%20go&folder=C%3A%5Cmy%20work".into())
        );
        assert_eq!(plan.input, Input::PrefilledEnter);
        let plan = desktop_plan(Agent::Codex, folder, "x?y", true);
        assert_eq!(plan.launch, DesktopLaunch::Url("codex://threads/new?prompt=x%3Fy&path=C%3A%5Cmy%20work".into()));
    }

    #[test]
    fn exe_based_desktop_plans() {
        let folder = Path::new(r"C:\w");
        for running in [false, true] {
            let plan = desktop_plan(Agent::KimiCode, Path::new(r"C:\my work"), "p", running);
            match plan.launch {
                DesktopLaunch::Exe { path, args, env, then } => {
                    assert!(path.ends_with(r"Programs\Kimi Code\Kimi Code.exe"));
                    // Workspace first, new chat second: the app always handles
                    // --new-chat before --workspace= within one argv.
                    assert_eq!(args, s(&[r"--workspace=C:\my work"]));
                    assert_eq!(then, vec![s(&["--new-chat"])]);
                    assert!(env.is_empty());
                }
                other => panic!("{other:?}"),
            }
            assert_eq!(plan.input, Input::Paste { pre_keys: Vec::new() });
        }
        let cold = desktop_plan(Agent::Hermes, folder, "p", false);
        let warm = desktop_plan(Agent::Hermes, folder, "p", true);
        assert_eq!(cold.input, Input::Paste { pre_keys: vec![Chord::CtrlL] });
        assert_eq!(warm.input, Input::Paste { pre_keys: vec![Chord::CtrlN, Chord::CtrlL] });
        match cold.launch {
            DesktopLaunch::Exe { env, .. } => assert_eq!(env, vec![("HERMES_DESKTOP_CWD".to_string(), r"C:\w".to_string())]),
            other => panic!("{other:?}"),
        }
    }

    /// Real wt round trip: `cargo test -p coucou launch::tests::real_wt_argv -- --ignored`.
    /// Needs python on PATH; echoes argv back through the exact wt_args path.
    #[test]
    #[ignore]
    fn real_wt_argv() {
        let Some(py) = std::env::var_os("PATH").and_then(|dirs| {
            std::env::split_paths(&dirs)
                .map(|d| d.join("python.exe"))
                .find(|p| p.is_file() && !p.to_string_lossy().contains("WindowsApps"))
        }) else {
            eprintln!("python not found; skipped");
            return;
        };
        let wt = windows_terminal().expect("wt.exe");
        let dir = std::env::current_dir().unwrap().join("../target/launchtest/wt-argv");
        std::fs::create_dir_all(&dir).unwrap();
        let dir = validate_folder(&dir.to_string_lossy()).unwrap();
        let out = dir.join("argv.json");
        let _ = std::fs::remove_file(&out);
        let script = dir.join("echo.py");
        std::fs::write(&script, "import sys, json\nopen(sys.argv[1], 'w', encoding='utf-8').write(json.dumps(sys.argv[2:]))\n").unwrap();
        let cases = s(&[
            "Reply with just: ok",
            r#"say "hi there"; then & go | x > y ^ z !w"#,
            r"ends with\",
            r#"q\"x ; \;"#,
            "é 中文 🙂",
            " --flag-looking",
        ]);
        let mut args = vec![script.to_string_lossy().to_string(), out.to_string_lossy().to_string()];
        args.extend(cases.iter().cloned());
        assert!(wt_safe(&args));
        spawn_wt(&wt, &py, &args, &dir).unwrap();
        let deadline = Instant::now() + Duration::from_secs(15);
        while !out.exists() && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(200));
        }
        let got: Vec<String> = serde_json::from_str(&std::fs::read_to_string(&out).expect("argv.json")).unwrap();
        assert_eq!(got, cases);
    }

    /// Launches each CLI for real with "Reply with just: ok" in
    /// windows/target/launchtest. Opens four terminal windows and, for Kimi,
    /// pastes into the new terminal. Run on purpose only:
    /// `cargo test -p coucou launch::tests::real_cli_launches -- --ignored --nocapture`.
    /// `COUCOU_LAUNCH_ONLY=kimi-code` limits it to one agent.
    #[test]
    #[ignore]
    fn real_cli_launches() {
        let dir = std::env::current_dir().unwrap().join("../target/launchtest");
        std::fs::create_dir_all(&dir).unwrap();
        let only = std::env::var("COUCOU_LAUNCH_ONLY").unwrap_or_default();
        for agent in ["claude", "codex", "hermes", "kimi-code"].into_iter().filter(|a| only.is_empty() || only == *a) {
            let req = LaunchRequest {
                agent: agent.into(),
                target: "cli".into(),
                folder: dir.to_string_lossy().to_string(),
                prompt: "Reply with just: ok".into(),
            };
            match execute(&req) {
                Ok((_, outcome)) => println!("{agent}: {} — {}", outcome.status, outcome.message),
                Err(err) => println!("{agent}: ERROR {err}"),
            }
        }
    }

    /// Kimi Code desktop for real, same folder and prompt. Run on purpose only:
    /// `cargo test -p coucou launch::tests::real_kimi_desktop -- --ignored --nocapture`.
    #[test]
    #[ignore]
    fn real_kimi_desktop() {
        let dir = std::env::current_dir().unwrap().join("../target/launchtest");
        std::fs::create_dir_all(&dir).unwrap();
        let req = LaunchRequest {
            agent: "kimi-code".into(),
            target: "desktop".into(),
            folder: dir.to_string_lossy().to_string(),
            prompt: "Reply with just: ok".into(),
        };
        match execute(&req) {
            Ok((_, outcome)) => println!("kimi-code desktop: {} — {}", outcome.status, outcome.message),
            Err(err) => println!("kimi-code desktop: ERROR {err}"),
        }
    }
}
