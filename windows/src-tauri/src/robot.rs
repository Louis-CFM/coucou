// Coucou Robot: a background agent does a task in the hidden browser
// (CloakBrowser on 127.0.0.1:9222). The user's own mouse, keyboard and
// windows are never touched.
//
// Flow of one run (`run_job`):
//   1. Make sure the hidden browser answers on :9222 (start it if not).
//   2. Run the first agent of `robotAgents` headless with the wrapped prompt
//      (`hermes -p amanda -z …`, then `codex exec …` as the fallback).
//   3. Read its output: `NEEDS_APPROVAL: …` → Allow/Deny card on the island;
//      `RESULT: …` → done. A quota/rate-limit/auth error, or a non-zero exit
//      with no result, moves on to the next agent with the same task.
//   4. Allow re-runs: Hermes resumes its session ("User approved: …"),
//      otherwise the whole task runs again with that action pre-approved.
//   5. Tabs are reset to one about:blank page before each fresh agent run
//      and when the task ends. An agent run over 15 minutes is killed.
//
// One run at a time. Stop kills the agent's process tree (taskkill /T /F).
// The log records phases and agents, never the task text.
//
// `RobotRunner` (spawn, read output, kill) and `JobHost` (status, approval,
// browser) are the seams; tests drive `run_job` with fakes.

use std::os::windows::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::time::{Duration, Instant};

use serde::Serialize;
use tauri::{AppHandle, Emitter, Manager};

use crate::log;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

pub const MAX_TASK_CHARS: usize = 4_000;
/// Agent runs per task, approvals and fallbacks included.
const MAX_RUNS: usize = 8;
const APPROVAL_TIMEOUT: Duration = Duration::from_secs(10 * 60);
/// One agent run longer than this is killed (whole tree) and counts as failed.
pub const RUN_TIMEOUT: Duration = Duration::from_secs(15 * 60);
const BROWSER_WAIT: Duration = Duration::from_secs(30);
const MAX_OUTPUT: usize = 1024 * 1024;
const MAX_LINE: usize = 400;

pub const CDP_URL: &str = "http://127.0.0.1:9222";
pub const DEFAULT_AGENTS: [&str; 2] = ["hermes:amanda", "codex"];
#[cfg(test)]
const DEFAULT_PREAPPROVED: &str =
    "Send the message 'this is coucou messaging' to the Telegram group 'Team - Dev'";

// ── Agents ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AgentSpec {
    Hermes { profile: Option<String> },
    Codex,
}

impl AgentSpec {
    /// "hermes:amanda", "hermes", "codex". Profile names are kept to
    /// letters, digits, `-` and `_` so they can never read as a flag.
    pub fn parse(raw: &str) -> Option<AgentSpec> {
        let raw = raw.trim();
        let (name, profile) = match raw.split_once(':') {
            Some((n, p)) => (n.trim(), Some(p.trim())),
            None => (raw, None),
        };
        match name.to_ascii_lowercase().as_str() {
            "hermes" => {
                let profile = match profile {
                    None => None,
                    Some(p) if valid_profile(p) => Some(p.to_string()),
                    Some(_) => return None,
                };
                Some(AgentSpec::Hermes { profile })
            }
            "codex" if profile.is_none() => Some(AgentSpec::Codex),
            _ => None,
        }
    }

    pub fn label(&self) -> String {
        match self {
            AgentSpec::Hermes { profile: Some(p) } => format!("Hermes ({p})"),
            AgentSpec::Hermes { profile: None } => "Hermes".into(),
            AgentSpec::Codex => "Codex".into(),
        }
    }

    pub fn id(&self) -> String {
        match self {
            AgentSpec::Hermes { profile: Some(p) } => format!("hermes:{p}"),
            AgentSpec::Hermes { profile: None } => "hermes".into(),
            AgentSpec::Codex => "codex".into(),
        }
    }
}

fn valid_profile(p: &str) -> bool {
    !p.is_empty()
        && p.len() <= 40
        && !p.starts_with('-')
        && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

/// The fallback order from settings: valid entries, first occurrence only.
/// Nothing usable → the default order.
pub fn agent_order(raw: &[String]) -> Vec<AgentSpec> {
    let mut out: Vec<AgentSpec> = Vec::new();
    for spec in raw.iter().filter_map(|r| AgentSpec::parse(r)) {
        if !out.contains(&spec) {
            out.push(spec);
        }
    }
    if out.is_empty() {
        out = DEFAULT_AGENTS.iter().filter_map(|r| AgentSpec::parse(r)).collect();
    }
    out
}

// ── Prompt ───────────────────────────────────────────────────────────────────

fn one_line(s: &str) -> String {
    let flat: String = s.chars().map(|c| if c.is_control() { ' ' } else { c }).collect();
    flat.split_whitespace().collect::<Vec<_>>().join(" ")
}

/// The rules Coucou puts around the user's task. `approved` lists the actions
/// that may be done without asking (settings list plus anything the user
/// allowed during this run).
pub fn wrap_prompt(task: &str, approved: &[String], downloads: &Path, agent: &AgentSpec) -> String {
    let browser = match agent {
        AgentSpec::Codex => format!(
            "Use ONLY your browser tool, attached to the already-running Chrome at {CDP_URL} (Chrome DevTools Protocol). \
             Do not launch a new browser."
        ),
        AgentSpec::Hermes { .. } => {
            "Use ONLY the browser tool. It is already connected to a running, logged-in browser; do not launch another one."
                .to_string()
        }
    };
    let mut p = String::new();
    p.push_str("You are Coucou Robot, working in a hidden browser on the user's behalf.\n");
    p.push_str("Rules:\n");
    p.push_str(&format!("- {browser}\n"));
    p.push_str("- Never touch the desktop: no mouse, no keyboard, no screenshots of the screen, no other apps or windows, no shell commands that open programs.\n");
    p.push_str(&format!("- Save every download to {}.\n", downloads.display()));
    p.push_str("- Approval is needed ONLY for actions that reach other people or change money, data or accounts:\n");
    p.push_str("  * sending or posting a message, email or comment to other people;\n");
    p.push_str("  * payments or purchases;\n");
    p.push_str("  * deleting anything;\n");
    p.push_str("  * changing account or security settings.\n");
    p.push_str("  Before one of these: STOP. Output exactly one line\n");
    p.push_str("  NEEDS_APPROVAL: <what exactly would be done>\n");
    p.push_str("  and end your run without doing it, unless the action matches one of the pre-approved actions below word for word.\n");
    p.push_str("- These do NOT need approval; just do them: typing and submitting prompts to an AI assistant (Gemini, ChatGPT, Claude and similar), searching, navigating, opening and reading pages, generating images or files, and downloading files.\n");
    if approved.is_empty() {
        p.push_str("- Pre-approved actions: none.\n");
    } else {
        p.push_str("- Pre-approved actions (do these without asking):\n");
        for a in approved {
            p.push_str(&format!("  * {}\n", one_line(a)));
        }
    }
    p.push_str("- When finished, make the last line of your answer: RESULT: <one-line summary>\n");
    p.push_str("\nTask:\n");
    p.push_str(task.trim());
    p.push('\n');
    p
}

/// What a resumed Hermes session is told after the user clicked Allow.
pub fn approval_followup(action: &str) -> String {
    format!(
        "User approved: {}. Do it now. Keep following the same rules: ask with NEEDS_APPROVAL before any other message to other people, payment, deletion or account change (prompts to AI assistants, searching and downloading need no approval), and end with the RESULT: line.",
        one_line(action)
    )
}

// ── Output ───────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Default, PartialEq)]
pub struct RunOutput {
    /// None when the process was killed or never reported a code.
    pub exit_code: Option<i32>,
    pub stdout: String,
    pub stderr: String,
    /// Hermes session to resume, read from its `--usage-file` report.
    pub session_id: Option<String>,
    /// Killed after RUN_TIMEOUT: a failure whatever it printed.
    pub timed_out: bool,
}

#[derive(Debug, Clone, PartialEq)]
pub enum Parsed {
    NeedsApproval(String),
    Result(String),
    /// Exit 0 and some text, but no RESULT line: the last line stands in.
    Done(String),
    Quota(String),
    Failed(String),
}

fn clip(s: &str, max: usize) -> String {
    let s = one_line(s);
    if s.chars().count() <= max {
        s
    } else {
        format!("{}…", s.chars().take(max).collect::<String>())
    }
}

/// Value of the last `KEY: value` line, tolerating markdown decoration
/// (`**NEEDS_APPROVAL:** x`, `` `RESULT: x` ``, `> RESULT: x`).
pub fn tagged_line(text: &str, key: &str) -> Option<String> {
    let deco: &[char] = &['*', '_', '`', '>', '#', '-', ' ', '\t'];
    text.lines().rev().find_map(|line| {
        let l = line.trim().trim_start_matches(deco);
        let rest = l.strip_prefix(key)?;
        let rest = rest.trim_start_matches(['*', '_', '`']).strip_prefix(':')?;
        let v = rest.trim().trim_start_matches(['*', '_', '`']).trim_end_matches(['*', '_', '`']).trim();
        (!v.is_empty()).then(|| clip(v, MAX_LINE))
    })
}

const QUOTA_MARKERS: [&str; 22] = [
    "rate limit", "rate-limit", "rate_limit", "ratelimit", "too many requests", "429",
    "quota", "usage limit", "insufficient_quota", "credit balance", "out of credits", "billing",
    "401", "unauthorized", "unauthorised", "authentication", "invalid api key", "invalid_api_key",
    "not logged in", "login required", "token expired", "expired token",
];

pub fn is_quota_error(text: &str) -> bool {
    let lower = text.to_ascii_lowercase();
    QUOTA_MARKERS.iter().any(|m| lower.contains(m))
}

fn last_line(text: &str) -> Option<String> {
    text.lines().map(str::trim).rev().find(|l| !l.is_empty()).map(|l| clip(l, MAX_LINE))
}

pub fn classify(out: &RunOutput) -> Parsed {
    if out.timed_out {
        return Parsed::Failed(format!("No result after {} minutes; the run was stopped.", RUN_TIMEOUT.as_secs() / 60));
    }
    // An approval request wins over anything else in the same output.
    if let Some(a) = tagged_line(&out.stdout, "NEEDS_APPROVAL") {
        return Parsed::NeedsApproval(a);
    }
    if let Some(r) = tagged_line(&out.stdout, "RESULT") {
        return Parsed::Result(r);
    }
    let all = format!("{}\n{}", out.stdout, out.stderr);
    let ok = out.exit_code == Some(0);
    if !ok || out.stdout.trim().is_empty() {
        if is_quota_error(&all) {
            return Parsed::Quota(last_line(&out.stderr).or_else(|| last_line(&out.stdout)).unwrap_or_else(|| "Quota or sign-in error.".into()));
        }
        let why = last_line(&out.stderr)
            .or_else(|| last_line(&out.stdout))
            .unwrap_or_else(|| match out.exit_code {
                Some(c) => format!("The agent exited with code {c} and no result."),
                None => "The agent stopped without a result.".into(),
            });
        return Parsed::Failed(why);
    }
    Parsed::Done(last_line(&out.stdout).unwrap_or_default())
}

/// Lowercase, quotes and decoration dropped, whitespace collapsed.
pub fn normalize_action(s: &str) -> String {
    let cleaned: String = one_line(s)
        .to_lowercase()
        .chars()
        .filter(|c| !matches!(c, '\'' | '"' | '‘' | '’' | '“' | '”' | '`' | '*' | '«' | '»'))
        .collect();
    cleaned
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .trim_end_matches(['.', '!', ';', ','])
        .trim()
        .to_string()
}

/// Strict: the same action, give or take quotes, case, spacing and a final
/// full stop. Anything more or less needs the user.
pub fn matches_preapproved(action: &str, list: &[String]) -> bool {
    let a = normalize_action(action);
    !a.is_empty() && list.iter().any(|p| normalize_action(p) == a)
}

// ── Downloads ────────────────────────────────────────────────────────────────

pub type Snapshot = Vec<(String, u64, Option<std::time::SystemTime>)>;

pub fn downloads_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join("Downloads")
        .join("Coucou-Robot")
}

pub fn snapshot(dir: &Path) -> Snapshot {
    let Ok(rd) = std::fs::read_dir(dir) else { return Vec::new() };
    rd.filter_map(Result::ok)
        .filter_map(|e| {
            let m = e.metadata().ok()?;
            m.is_file().then(|| (e.file_name().to_string_lossy().into_owned(), m.len(), m.modified().ok()))
        })
        .collect()
}

/// Files that are new or changed since `before`; partial downloads skipped.
pub fn new_files(before: &Snapshot, after: &Snapshot) -> Vec<String> {
    let mut out: Vec<String> = after
        .iter()
        .filter(|(name, _, _)| {
            let l = name.to_ascii_lowercase();
            !(l.ends_with(".crdownload") || l.ends_with(".tmp") || l.ends_with(".part"))
        })
        .filter(|f| !before.contains(f))
        .map(|(name, _, _)| name.clone())
        .collect();
    out.sort();
    out
}

// ── Seams ────────────────────────────────────────────────────────────────────

/// Shared between a run and the Stop button.
#[derive(Default)]
pub struct Cancel {
    flag: AtomicBool,
    pid: Mutex<Option<u32>>,
}

impl Cancel {
    pub fn cancelled(&self) -> bool {
        self.flag.load(Ordering::SeqCst)
    }

    pub fn set_pid(&self, pid: Option<u32>) {
        *self.pid.lock().unwrap() = pid;
    }

    /// Flags the run and kills the agent's process tree right away.
    pub fn stop(&self) {
        self.flag.store(true, Ordering::SeqCst);
        if let Some(pid) = *self.pid.lock().unwrap() {
            kill_tree(pid);
        }
    }
}

pub fn kill_tree(pid: u32) {
    let taskkill = std::env::var_os("SystemRoot")
        .map(|r| PathBuf::from(r).join(r"System32\taskkill.exe"))
        .filter(|p| p.is_file())
        .unwrap_or_else(|| PathBuf::from("taskkill.exe"));
    let _ = Command::new(taskkill)
        .args(["/T", "/F", "/PID", &pid.to_string()])
        .creation_flags(CREATE_NO_WINDOW)
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status();
}

#[derive(Debug, Clone, PartialEq)]
pub struct AgentCommand {
    pub program: PathBuf,
    pub args: Vec<String>,
    pub env: Vec<(String, String)>,
    pub cwd: PathBuf,
    /// Codex `-o`: the final message lands here.
    pub last_message_file: Option<PathBuf>,
    /// Hermes `--usage-file`: carries the session id.
    pub usage_file: Option<PathBuf>,
}

/// Spawns an agent, reads its output, kills it on Stop.
pub trait RobotRunner {
    fn locate(&self, agent: &AgentSpec) -> Option<PathBuf>;
    fn run(&self, cmd: &AgentCommand, cancel: &Cancel) -> Result<RunOutput, String>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Decision {
    Allow,
    Deny,
    Stopped,
}

/// What a run reports to, and asks of, the app.
pub trait JobHost {
    fn cancel(&self) -> &Cancel;
    fn ensure_browser(&self) -> Result<(), String>;
    fn running(&self, agent: &AgentSpec, note: &str);
    /// Blocks until Allow, Deny (or the 10 min timeout, which is a deny) or Stop.
    fn ask_approval(&self, action: &str) -> Decision;
    /// Unique per attempt, for the usage/last-message temp files.
    fn scratch_file(&self, name: &str) -> PathBuf;
    /// Leaves the hidden browser with a single about:blank page. Errors are
    /// logged, never fatal.
    fn reset_tabs(&self);
}

#[derive(Debug, Clone, PartialEq)]
pub enum JobEnd {
    Done { result: String, agent: String },
    Denied { action: String },
    Stopped,
    Failed { message: String },
}

pub struct JobConfig {
    pub agents: Vec<AgentSpec>,
    pub preapproved: Vec<String>,
    pub downloads: PathBuf,
}

pub fn build_command(
    agent: &AgentSpec,
    program: PathBuf,
    prompt: &str,
    resume: Option<&str>,
    cwd: &Path,
    scratch: &dyn Fn(&str) -> PathBuf,
) -> AgentCommand {
    let mut env = vec![("BROWSER_CDP_URL".to_string(), CDP_URL.to_string())];
    match agent {
        AgentSpec::Hermes { profile } => {
            env.push(("PYTHONUTF8".into(), "1".into()));
            env.push(("PYTHONIOENCODING".into(), "utf-8".into()));
            let usage = scratch("usage.json");
            let mut args = Vec::new();
            if let Some(p) = profile {
                args.extend(["-p".to_string(), p.clone()]);
            }
            if let Some(sid) = resume {
                args.extend(["--resume".to_string(), sid.to_string()]);
            }
            args.extend(["--usage-file".to_string(), usage.to_string_lossy().into_owned()]);
            args.extend(["-z".to_string(), prompt.to_string()]);
            AgentCommand { program, args, env, cwd: cwd.to_path_buf(), last_message_file: None, usage_file: Some(usage) }
        }
        AgentSpec::Codex => {
            let last = scratch("last-message.txt");
            let args = vec![
                "exec".into(),
                "--skip-git-repo-check".into(),
                "--color".into(),
                "never".into(),
                "-C".into(),
                cwd.to_string_lossy().into_owned(),
                "-o".into(),
                last.to_string_lossy().into_owned(),
                prompt.to_string(),
            ];
            AgentCommand { program, args, env, cwd: cwd.to_path_buf(), last_message_file: Some(last), usage_file: None }
        }
    }
}

/// Valid session ids only: they go back on a command line.
fn usable_session(id: Option<&str>) -> Option<String> {
    let id = id?.trim();
    (!id.is_empty() && id.len() <= 128 && !id.starts_with('-') && id.chars().all(|c| c.is_ascii_alphanumeric() || "-_.:".contains(c)))
        .then(|| id.to_string())
}

/// One task, start to end. Each agent of `cfg.agents` is tried at most once
/// as a fallback; approvals continue with the same agent.
///
/// Tabs: leftover pages break the next run (two Telegram Web tabs freeze each
/// other), so every fresh agent run starts from a single about:blank page,
/// and the browser is reset again when the task ends, however it ends. A
/// Hermes resume after Allow keeps the tabs: it continues in the same page.
pub fn run_job<R: RobotRunner, H: JobHost>(runner: &R, host: &H, cfg: &JobConfig, task: &str) -> JobEnd {
    if host.cancel().cancelled() {
        return JobEnd::Stopped;
    }
    if let Err(e) = host.ensure_browser() {
        return if host.cancel().cancelled() { JobEnd::Stopped } else { JobEnd::Failed { message: e } };
    }
    let end = run_agents(runner, host, cfg, task);
    host.reset_tabs();
    end
}

fn run_agents<R: RobotRunner, H: JobHost>(runner: &R, host: &H, cfg: &JobConfig, task: &str) -> JobEnd {
    let mut approved: Vec<String> = cfg.preapproved.clone();
    let mut idx = 0usize;
    // (session id, approved action) for a Hermes resume.
    let mut resume: Option<(String, String)> = None;
    let mut last_error = String::from("No agent could run the task.");

    for _ in 0..MAX_RUNS {
        if host.cancel().cancelled() {
            return JobEnd::Stopped;
        }
        let Some(agent) = cfg.agents.get(idx) else {
            return JobEnd::Failed { message: last_error };
        };
        let Some(program) = runner.locate(agent) else {
            last_error = format!("{} is not installed.", agent.label());
            log::line(format!("robot {} not found", agent.id()));
            idx += 1;
            resume = None;
            continue;
        };
        let (prompt, sid) = match resume.take() {
            Some((sid, action)) if matches!(agent, AgentSpec::Hermes { .. }) => (approval_followup(&action), Some(sid)),
            _ => (wrap_prompt(task, &approved, &cfg.downloads, agent), None),
        };
        if sid.is_none() {
            host.reset_tabs();
        }
        host.running(agent, if sid.is_some() { "continuing after approval" } else { "working" });
        let cmd = build_command(agent, program, &prompt, sid.as_deref(), &cfg.downloads, &|n| host.scratch_file(n));
        let out = runner.run(&cmd, host.cancel());
        if host.cancel().cancelled() {
            return JobEnd::Stopped;
        }
        let parsed = match out {
            Ok(out) => {
                let p = classify(&out);
                log::line(format!("robot {} exit={:?} → {}", agent.id(), out.exit_code, parsed_kind(&p)));
                (p, out.session_id)
            }
            Err(e) => {
                log::line(format!("robot {} did not start: {e}", agent.id()));
                (Parsed::Failed(e), None)
            }
        };
        match parsed {
            (Parsed::NeedsApproval(action), session) => {
                let pre = matches_preapproved(&action, &approved);
                if !pre {
                    match host.ask_approval(&action) {
                        Decision::Allow => log::line("robot approval: allowed"),
                        Decision::Deny => return JobEnd::Denied { action },
                        Decision::Stopped => return JobEnd::Stopped,
                    }
                    approved.push(action.clone());
                }
                resume = usable_session(session.as_deref()).map(|s| (s, action));
            }
            (Parsed::Result(r) | Parsed::Done(r), _) => return JobEnd::Done { result: r, agent: agent.label() },
            (Parsed::Quota(m) | Parsed::Failed(m), _) => {
                last_error = format!("{}: {m}", agent.label());
                idx += 1;
                resume = None;
            }
        }
    }
    JobEnd::Failed { message: format!("Stopped after {MAX_RUNS} agent runs. {last_error}") }
}

fn parsed_kind(p: &Parsed) -> &'static str {
    match p {
        Parsed::NeedsApproval(_) => "needs-approval",
        Parsed::Result(_) => "result",
        Parsed::Done(_) => "done",
        Parsed::Quota(_) => "quota",
        Parsed::Failed(_) => "failed",
    }
}

// ── Real process runner ──────────────────────────────────────────────────────

pub struct ProcessRunner {
    /// Hard limit per agent run; RUN_TIMEOUT in the app.
    pub timeout: Duration,
}

impl Default for ProcessRunner {
    fn default() -> Self {
        ProcessRunner { timeout: RUN_TIMEOUT }
    }
}

fn collect<R: std::io::Read + Send + 'static>(mut r: R) -> (Arc<Mutex<Vec<u8>>>, std::thread::JoinHandle<()>) {
    let buf = Arc::new(Mutex::new(Vec::new()));
    let sink = buf.clone();
    let handle = std::thread::spawn(move || {
        let mut chunk = [0u8; 8192];
        while let Ok(n) = r.read(&mut chunk) {
            if n == 0 {
                break;
            }
            let mut b = sink.lock().unwrap();
            let room = MAX_OUTPUT.saturating_sub(b.len());
            b.extend_from_slice(&chunk[..n.min(room)]);
        }
    });
    (buf, handle)
}

fn take(buf: &Arc<Mutex<Vec<u8>>>) -> String {
    String::from_utf8_lossy(&buf.lock().unwrap()).into_owned()
}

fn read_session_id(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let v: serde_json::Value = serde_json::from_str(&text).ok()?;
    v.get("session_id").and_then(|s| s.as_str()).map(str::to_string)
}

impl RobotRunner for ProcessRunner {
    fn locate(&self, agent: &AgentSpec) -> Option<PathBuf> {
        let kind = match agent {
            AgentSpec::Hermes { .. } => crate::launch::Agent::Hermes,
            AgentSpec::Codex => crate::launch::Agent::Codex,
        };
        // Only a real exe: the prompt has newlines, which a .cmd shim mangles.
        match crate::launch::find_cli(kind)? {
            crate::launch::Exe::Native(p) => Some(p),
            crate::launch::Exe::Shim(_) => None,
        }
    }

    fn run(&self, cmd: &AgentCommand, cancel: &Cancel) -> Result<RunOutput, String> {
        for f in [&cmd.last_message_file, &cmd.usage_file].into_iter().flatten() {
            let _ = std::fs::remove_file(f);
        }
        let _ = std::fs::create_dir_all(&cmd.cwd);
        let mut c = Command::new(&cmd.program);
        c.args(&cmd.args)
            .current_dir(&cmd.cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .creation_flags(CREATE_NO_WINDOW);
        for (k, v) in &cmd.env {
            c.env(k, v);
        }
        let mut child = c.spawn().map_err(|e| format!("Could not start {}: {e}", cmd.program.display()))?;
        cancel.set_pid(Some(child.id()));
        let (out_buf, out_h) = collect(child.stdout.take().expect("piped stdout"));
        let (err_buf, err_h) = collect(child.stderr.take().expect("piped stderr"));

        let deadline = Instant::now() + self.timeout;
        let mut timed_out = false;
        let status = loop {
            if !cancel.cancelled() && Instant::now() >= deadline {
                timed_out = true;
                log::line(format!("robot run timed out after {} s", self.timeout.as_secs()));
            }
            if cancel.cancelled() || timed_out {
                kill_tree(child.id());
                let _ = child.kill();
                break child.wait().ok();
            }
            match child.try_wait() {
                Ok(Some(s)) => break Some(s),
                Ok(None) => std::thread::sleep(Duration::from_millis(100)),
                Err(e) => {
                    cancel.set_pid(None);
                    return Err(e.to_string());
                }
            }
        };
        cancel.set_pid(None);
        // A grandchild may still hold the pipes: do not wait on it for ever.
        let deadline = Instant::now() + Duration::from_secs(2);
        while (!out_h.is_finished() || !err_h.is_finished()) && Instant::now() < deadline {
            std::thread::sleep(Duration::from_millis(20));
        }
        let mut stdout = take(&out_buf);
        if let Some(text) = cmd.last_message_file.as_ref().and_then(|f| std::fs::read_to_string(f).ok()) {
            if !text.trim().is_empty() {
                stdout = text;
            }
        }
        let session_id = cmd.usage_file.as_deref().and_then(read_session_id);
        for f in [&cmd.last_message_file, &cmd.usage_file].into_iter().flatten() {
            let _ = std::fs::remove_file(f);
        }
        Ok(RunOutput {
            exit_code: if cancel.cancelled() || timed_out { None } else { status.and_then(|s| s.code()) },
            stdout,
            stderr: take(&err_buf),
            session_id,
            timed_out,
        })
    }
}

// ── App state ────────────────────────────────────────────────────────────────

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RobotApproval {
    pub id: String,
    pub action: String,
}

#[derive(Debug, Clone, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct RobotStatus {
    /// idle, browser, running, approval, done, denied, stopped, failed.
    pub phase: &'static str,
    pub run_id: u64,
    pub task: String,
    pub agent: String,
    pub message: String,
    pub result: String,
    pub files: Vec<String>,
    pub downloads: String,
    pub approval: Option<RobotApproval>,
}

impl Default for RobotStatus {
    fn default() -> Self {
        RobotStatus {
            phase: "idle",
            run_id: 0,
            task: String::new(),
            agent: String::new(),
            message: String::new(),
            result: String::new(),
            files: Vec::new(),
            downloads: downloads_dir().to_string_lossy().into_owned(),
            approval: None,
        }
    }
}

impl RobotStatus {
    pub fn busy(&self) -> bool {
        matches!(self.phase, "browser" | "running" | "approval")
    }
}

#[derive(Default)]
struct Inner {
    status: RobotStatus,
    cancel: Option<Arc<Cancel>>,
    approval: Option<(String, mpsc::Sender<bool>)>,
}

#[derive(Default)]
pub struct Robot {
    inner: Mutex<Inner>,
}

static RUN_IDS: AtomicU64 = AtomicU64::new(1);

impl Robot {
    pub fn status(&self) -> RobotStatus {
        self.inner.lock().unwrap().status.clone()
    }
}

fn emit(app: &AppHandle, status: &RobotStatus) {
    let _ = app.emit("robot-status", status.clone());
}

fn update(app: &AppHandle, run_id: u64, change: impl FnOnce(&mut RobotStatus)) {
    let robot = app.state::<Robot>();
    let snapshot = {
        let mut inner = robot.inner.lock().unwrap();
        if inner.status.run_id != run_id {
            return;
        }
        change(&mut inner.status);
        inner.status.clone()
    };
    emit(app, &snapshot);
}

pub fn validate_task(task: &str) -> Result<String, String> {
    if task.contains('\0') {
        return Err("The task contains a NUL character.".into());
    }
    let t = task.trim();
    if t.is_empty() {
        return Err("Tell the robot what to do first.".into());
    }
    if t.chars().count() > MAX_TASK_CHARS {
        return Err(format!("The task is longer than {MAX_TASK_CHARS} characters."));
    }
    Ok(t.to_string())
}

/// Starts a run in the background. A second request while one runs is "busy".
pub fn start(app: &AppHandle, task: &str) -> Result<RobotStatus, String> {
    let task = validate_task(task)?;
    let (agents, preapproved, browser_start) = {
        let shared = app.state::<crate::Shared>();
        let s = shared.settings.lock().unwrap();
        (agent_order(&s.robot_agents), s.robot_preapproved.clone(), s.robot_browser_start.clone())
    };
    let robot = app.state::<Robot>();
    let cancel = Arc::new(Cancel::default());
    let status = {
        let mut inner = robot.inner.lock().unwrap();
        if inner.status.busy() {
            return Err("The robot is busy with another task. Wait for it or press Stop.".into());
        }
        let run_id = RUN_IDS.fetch_add(1, Ordering::Relaxed);
        inner.status = RobotStatus {
            phase: "browser",
            run_id,
            task: task.clone(),
            message: "Checking the hidden browser…".into(),
            ..RobotStatus::default()
        };
        inner.cancel = Some(cancel.clone());
        inner.approval = None;
        inner.status.clone()
    };
    emit(app, &status);
    log::line(format!("robot start run={} agents={}", status.run_id, agents.iter().map(AgentSpec::id).collect::<Vec<_>>().join(",")));

    let app2 = app.clone();
    let run_id = status.run_id;
    std::thread::spawn(move || {
        let downloads = downloads_dir();
        let _ = std::fs::create_dir_all(&downloads);
        let before = snapshot(&downloads);
        let host = AppHost { app: app2.clone(), run_id, cancel, browser_start, downloads: downloads.clone(), attempt: AtomicU64::new(0), guard: Mutex::new(None) };
        let cfg = JobConfig { agents, preapproved, downloads: downloads.clone() };
        let end = run_job(&ProcessRunner::default(), &host, &cfg, &task);
        drop(host.guard.lock().unwrap().take());
        let files = new_files(&before, &snapshot(&downloads));
        finish(&app2, run_id, end, files);
    });
    Ok(status)
}

fn finish(app: &AppHandle, run_id: u64, end: JobEnd, files: Vec<String>) {
    let label = match &end {
        JobEnd::Done { .. } => "done",
        JobEnd::Denied { .. } => "denied",
        JobEnd::Stopped => "stopped",
        JobEnd::Failed { .. } => "failed",
    };
    log::line(format!("robot end run={run_id} {label} files={}", files.len()));
    {
        let robot = app.state::<Robot>();
        let mut inner = robot.inner.lock().unwrap();
        if inner.status.run_id == run_id {
            inner.cancel = None;
            inner.approval = None;
        }
    }
    update(app, run_id, |s| {
        s.approval = None;
        s.files = files;
        match end {
            JobEnd::Done { result, agent } => {
                s.phase = "done";
                s.agent = agent;
                s.message = format!("Robot done: {result}");
                s.result = result;
            }
            JobEnd::Denied { action } => {
                s.phase = "denied";
                s.message = format!("Denied: {action}");
            }
            JobEnd::Stopped => {
                s.phase = "stopped";
                s.message = "Stopped.".into();
            }
            JobEnd::Failed { message } => {
                s.phase = "failed";
                s.message = message;
            }
        }
    });
}

/// Stop: kill the agent's process tree now; the run thread reports "stopped".
pub fn stop(app: &AppHandle) -> RobotStatus {
    let robot = app.state::<Robot>();
    let (cancel, approval, run_id) = {
        let mut inner = robot.inner.lock().unwrap();
        (inner.cancel.clone(), inner.approval.take(), inner.status.run_id)
    };
    if let Some(c) = cancel {
        log::line(format!("robot stop run={run_id}"));
        c.stop();
        if let Some((_, tx)) = approval {
            let _ = tx.send(false);
        }
        update(app, run_id, |s| {
            s.message = "Stopping…".into();
            s.approval = None;
        });
    }
    robot.status()
}

/// Allow / Deny from the island card.
pub fn approve(app: &AppHandle, id: &str, allow: bool) -> bool {
    let robot = app.state::<Robot>();
    let tx = {
        let mut inner = robot.inner.lock().unwrap();
        match &inner.approval {
            Some((pending, _)) if pending == id => inner.approval.take().map(|(_, tx)| tx),
            _ => None,
        }
    };
    match tx {
        Some(tx) => tx.send(allow).is_ok(),
        None => {
            log::line(format!("robot approval {id}: nothing pending"));
            false
        }
    }
}

struct AppHost {
    app: AppHandle,
    run_id: u64,
    cancel: Arc<Cancel>,
    browser_start: String,
    downloads: PathBuf,
    attempt: AtomicU64,
    guard: Mutex<Option<crate::cdp::DownloadGuard>>,
}

/// A start command for the hidden browser: an existing .cmd/.bat/.exe.
pub fn browser_start_command(path: &str) -> Result<PathBuf, String> {
    let p = PathBuf::from(path.trim());
    let ext = p.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    if path.trim().is_empty() || !["cmd", "bat", "exe"].contains(&ext.as_str()) {
        return Err("The hidden browser is not running, and no start command (.cmd/.bat/.exe) is set in Settings.".into());
    }
    if !p.is_file() {
        return Err(format!("The hidden browser is not running, and its start command was not found: {}", p.display()));
    }
    Ok(p)
}

impl JobHost for AppHost {
    fn cancel(&self) -> &Cancel {
        &self.cancel
    }

    fn ensure_browser(&self) -> Result<(), String> {
        if !crate::cdp::alive() {
            let cmd = browser_start_command(&self.browser_start)?;
            update(&self.app, self.run_id, |s| s.message = "Starting the hidden browser…".into());
            log::line("robot starting the hidden browser");
            Command::new(&cmd)
                .current_dir(cmd.parent().unwrap_or(Path::new(".")))
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .creation_flags(CREATE_NO_WINDOW)
                .spawn()
                .map_err(|e| format!("Could not start the hidden browser: {e}"))?;
            let deadline = Instant::now() + BROWSER_WAIT;
            loop {
                if self.cancel.cancelled() {
                    return Err("Stopped.".into());
                }
                if crate::cdp::alive() {
                    break;
                }
                if Instant::now() >= deadline {
                    return Err("The hidden browser did not answer on 127.0.0.1:9222 within 30 s.".into());
                }
                std::thread::sleep(Duration::from_millis(500));
            }
        }
        match crate::cdp::DownloadGuard::open(&self.downloads) {
            Ok(g) => *self.guard.lock().unwrap() = Some(g),
            Err(e) => log::line(format!("robot download folder not set: {e}")),
        }
        Ok(())
    }

    fn running(&self, agent: &AgentSpec, note: &str) {
        let label = agent.label();
        let note = note.to_string();
        update(&self.app, self.run_id, |s| {
            s.phase = "running";
            s.agent = label.clone();
            s.approval = None;
            s.message = format!("{label} is {note}…");
        });
    }

    fn ask_approval(&self, action: &str) -> Decision {
        let id = format!("robot-{}-{}", self.run_id, self.attempt.fetch_add(1, Ordering::Relaxed));
        let (tx, rx) = mpsc::channel::<bool>();
        {
            let robot = self.app.state::<Robot>();
            robot.inner.lock().unwrap().approval = Some((id.clone(), tx));
        }
        let action_owned = action.to_string();
        update(&self.app, self.run_id, |s| {
            s.phase = "approval";
            s.message = "Waiting for your OK.".into();
            s.approval = Some(RobotApproval { id: id.clone(), action: action_owned });
        });
        log::line(format!("robot approval asked {id}"));
        let deadline = Instant::now() + APPROVAL_TIMEOUT;
        let decision = loop {
            if self.cancel.cancelled() {
                break Decision::Stopped;
            }
            match rx.recv_timeout(Duration::from_millis(250)) {
                Ok(true) => break Decision::Allow,
                Ok(false) if self.cancel.cancelled() => break Decision::Stopped,
                Ok(false) => break Decision::Deny,
                Err(mpsc::RecvTimeoutError::Timeout) if Instant::now() < deadline => {}
                Err(mpsc::RecvTimeoutError::Timeout) => {
                    log::line(format!("robot approval {id} timed out (deny)"));
                    break Decision::Deny;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => break Decision::Deny,
            }
        };
        let robot = self.app.state::<Robot>();
        let mut inner = robot.inner.lock().unwrap();
        if inner.approval.as_ref().is_some_and(|(p, _)| p == &id) {
            inner.approval = None;
        }
        decision
    }

    fn reset_tabs(&self) {
        match crate::cdp::reset_tabs() {
            Ok(n) => log::line(format!("robot tabs reset ({n} closed)")),
            Err(e) => log::line(format!("robot tabs not reset: {e}")),
        }
    }

    fn scratch_file(&self, name: &str) -> PathBuf {
        let n = self.attempt.fetch_add(1, Ordering::Relaxed);
        let dir = crate::settings::local_dir().join("robot");
        let _ = std::fs::create_dir_all(&dir);
        dir.join(format!("{}-{n}-{name}", self.run_id))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::cell::RefCell;

    #[test]
    fn agent_specs_parse_and_order() {
        assert_eq!(AgentSpec::parse("hermes:amanda"), Some(AgentSpec::Hermes { profile: Some("amanda".into()) }));
        assert_eq!(AgentSpec::parse(" Hermes "), Some(AgentSpec::Hermes { profile: None }));
        assert_eq!(AgentSpec::parse("codex"), Some(AgentSpec::Codex));
        assert_eq!(AgentSpec::parse("hermes:--yolo"), None);
        assert_eq!(AgentSpec::parse("hermes:a b"), None);
        assert_eq!(AgentSpec::parse("codex:x"), None);
        assert_eq!(AgentSpec::parse("claude"), None);
        let order = agent_order(&["codex".into(), "bogus".into(), "hermes:amanda".into(), "codex".into()]);
        assert_eq!(order, vec![AgentSpec::Codex, AgentSpec::Hermes { profile: Some("amanda".into()) }]);
        assert_eq!(agent_order(&[]), vec![AgentSpec::Hermes { profile: Some("amanda".into()) }, AgentSpec::Codex]);
        assert_eq!(agent_order(&["nope".into()]).len(), 2);
    }

    #[test]
    fn output_parsing_finds_approval_result_and_errors() {
        let out = |stdout: &str, stderr: &str, code: Option<i32>| RunOutput {
            exit_code: code, stdout: stdout.into(), stderr: stderr.into(), ..Default::default()
        };
        assert_eq!(
            classify(&out("Opened Telegram.\nNEEDS_APPROVAL: Send 'hi' to Bob\n", "", Some(0))),
            Parsed::NeedsApproval("Send 'hi' to Bob".into())
        );
        assert_eq!(
            classify(&out("**NEEDS_APPROVAL:** Delete the draft\nRESULT: nothing", "", Some(0))),
            Parsed::NeedsApproval("Delete the draft".into())
        );
        assert_eq!(classify(&out("did it\n`RESULT: Sent the message.`\n", "", Some(0))), Parsed::Result("Sent the message.".into()));
        assert_eq!(classify(&out("> RESULT: ok", "", Some(1))), Parsed::Result("ok".into()));
        assert_eq!(classify(&out("All good, saved cat.png\n", "", Some(0))), Parsed::Done("All good, saved cat.png".into()));
        assert!(matches!(classify(&out("", "Error 429: Too Many Requests", Some(1))), Parsed::Quota(_)));
        assert!(matches!(classify(&out("", "hermes -z: agent failed: 401 Unauthorized", Some(1))), Parsed::Quota(_)));
        assert!(matches!(classify(&out("You've hit your usage limit.", "", Some(1))), Parsed::Quota(_)));
        assert_eq!(classify(&out("", "boom\n", Some(2))), Parsed::Failed("boom".into()));
        assert_eq!(classify(&out("", "", Some(3))), Parsed::Failed("The agent exited with code 3 and no result.".into()));
        assert!(matches!(classify(&out("", "", Some(0))), Parsed::Failed(_)));
        // Quota words in a successful answer are not an error.
        assert_eq!(classify(&out("The quota page says 429 left\n", "", Some(0))), Parsed::Done("The quota page says 429 left".into()));
        assert_eq!(tagged_line("RESULT:   ", "RESULT"), None);
        assert_eq!(tagged_line("MY_RESULT: x", "RESULT"), None);
    }

    #[test]
    fn preapproval_matching_is_strict() {
        let list = vec![DEFAULT_PREAPPROVED.to_string()];
        assert!(matches_preapproved(DEFAULT_PREAPPROVED, &list));
        assert!(matches_preapproved("send the message \"this is coucou messaging\" to the Telegram group “Team - Dev”.", &list));
        assert!(matches_preapproved("Send  the message this is coucou messaging to the Telegram group Team - Dev", &list));
        assert!(!matches_preapproved("Send the message 'this is coucou messaging!!' to the Telegram group 'Team - Dev'", &list));
        assert!(!matches_preapproved("Send the message 'hello' to the Telegram group 'Team - Dev'", &list));
        assert!(!matches_preapproved(
            "Send the message 'this is coucou messaging' to the Telegram group 'Team - Dev' and delete the group",
            &list
        ));
        assert!(!matches_preapproved("", &list));
        assert!(!matches_preapproved(DEFAULT_PREAPPROVED, &[]));
    }

    #[test]
    fn prompt_carries_the_rules_and_the_preapproved_list() {
        let dir = PathBuf::from(r"C:\Users\x\Downloads\Coucou-Robot");
        let p = wrap_prompt("  open gemini  ", &[DEFAULT_PREAPPROVED.into(), "a\nb".into()], &dir, &AgentSpec::Hermes { profile: None });
        assert!(p.contains("ONLY the browser tool"));
        assert!(p.contains("Never touch the desktop"));
        assert!(p.contains(r"C:\Users\x\Downloads\Coucou-Robot"));
        assert!(p.contains("NEEDS_APPROVAL: <what exactly would be done>"));
        assert!(p.contains("ONLY for actions that reach other people or change money, data or accounts"));
        for needs in ["message, email or comment to other people", "payments or purchases", "deleting anything", "account or security settings"] {
            assert!(p.contains(needs), "{needs}");
        }
        assert!(p.contains("do NOT need approval"));
        for free in ["submitting prompts to an AI assistant (Gemini, ChatGPT", "searching", "navigating", "generating images or files", "downloading files"] {
            assert!(p.contains(free), "{free}");
        }
        assert!(!p.contains("SEND, POST, PAY"));
        assert!(approval_followup("x").contains("prompts to AI assistants"));
        assert!(p.contains(&format!("  * {DEFAULT_PREAPPROVED}\n")));
        assert!(p.contains("  * a b\n"));
        assert!(p.contains("RESULT: <one-line summary>"));
        assert!(p.ends_with("Task:\nopen gemini\n"));
        let c = wrap_prompt("t", &[], &dir, &AgentSpec::Codex);
        assert!(c.contains("browser tool, attached to the already-running Chrome at http://127.0.0.1:9222"));
        assert!(c.contains("Pre-approved actions: none."));
    }

    #[test]
    fn commands_are_built_per_agent() {
        let scratch = |n: &str| PathBuf::from(format!(r"C:\tmp\{n}"));
        let dir = PathBuf::from(r"C:\dl");
        let h = build_command(&AgentSpec::Hermes { profile: Some("amanda".into()) }, "hermes.exe".into(), "P", None, &dir, &scratch);
        assert_eq!(h.args, vec!["-p", "amanda", "--usage-file", r"C:\tmp\usage.json", "-z", "P"]);
        assert!(h.env.contains(&("BROWSER_CDP_URL".into(), "http://127.0.0.1:9222".into())));
        let r = build_command(&AgentSpec::Hermes { profile: Some("amanda".into()) }, "hermes.exe".into(), "Q", Some("20261003_1"), &dir, &scratch);
        assert_eq!(&r.args[..4], &["-p", "amanda", "--resume", "20261003_1"]);
        let c = build_command(&AgentSpec::Codex, "codex.exe".into(), "P", None, &dir, &scratch);
        assert_eq!(c.args[0], "exec");
        assert_eq!(c.args.last().unwrap(), "P");
        assert_eq!(c.last_message_file, Some(PathBuf::from(r"C:\tmp\last-message.txt")));
        assert_eq!(usable_session(Some("--evil")), None);
        assert_eq!(usable_session(Some("a b")), None);
        assert_eq!(usable_session(Some("20261003_120000_ab12")), Some("20261003_120000_ab12".into()));
    }

    #[test]
    fn new_downloads_are_listed() {
        let t = Some(std::time::SystemTime::UNIX_EPOCH);
        let before: Snapshot = vec![("old.png".into(), 10, t)];
        let after: Snapshot = vec![
            ("old.png".into(), 10, t),
            ("cat.png".into(), 5, t),
            ("b.pdf.crdownload".into(), 1, t),
            ("a.txt".into(), 1, t),
        ];
        assert_eq!(new_files(&before, &after), vec!["a.txt".to_string(), "cat.png".to_string()]);
    }

    #[test]
    fn tasks_and_browser_paths_are_validated() {
        assert!(validate_task("  ").is_err());
        assert!(validate_task("a\0b").is_err());
        assert!(validate_task(&"x".repeat(MAX_TASK_CHARS + 1)).is_err());
        assert_eq!(validate_task("  go  ").unwrap(), "go");
        assert!(browser_start_command("").is_err());
        assert!(browser_start_command(r"C:\nope\start.ps1").unwrap_err().contains(".cmd"));
        assert!(browser_start_command(r"C:\nope\start.cmd").unwrap_err().contains("not found"));
        assert!(RobotStatus { phase: "approval", ..Default::default() }.busy());
        assert!(!RobotStatus { phase: "done", ..Default::default() }.busy());
    }

    // ── run_job with fakes ───────────────────────────────────────────────────

    struct FakeRunner {
        outputs: RefCell<Vec<Result<RunOutput, String>>>,
        seen: RefCell<Vec<AgentCommand>>,
        missing: Vec<AgentSpec>,
    }

    impl FakeRunner {
        fn new(outputs: Vec<Result<RunOutput, String>>) -> Self {
            FakeRunner { outputs: RefCell::new(outputs), seen: RefCell::new(Vec::new()), missing: Vec::new() }
        }
        fn programs(&self) -> Vec<String> {
            self.seen.borrow().iter().map(|c| c.program.to_string_lossy().into_owned()).collect()
        }
        fn prompt(&self, i: usize) -> String {
            self.seen.borrow()[i].args.last().unwrap().clone()
        }
    }

    impl RobotRunner for FakeRunner {
        fn locate(&self, agent: &AgentSpec) -> Option<PathBuf> {
            (!self.missing.contains(agent)).then(|| PathBuf::from(agent.id()))
        }
        fn run(&self, cmd: &AgentCommand, _cancel: &Cancel) -> Result<RunOutput, String> {
            self.seen.borrow_mut().push(cmd.clone());
            self.outputs.borrow_mut().remove(0)
        }
    }

    struct FakeHost {
        cancel: Cancel,
        decisions: RefCell<Vec<Decision>>,
        asked: RefCell<Vec<String>>,
        browser: Result<(), String>,
        stop_on_ask: bool,
        /// One entry per reset: how many agent runs had happened by then.
        resets: RefCell<Vec<usize>>,
        runs_seen: std::cell::Cell<usize>,
    }

    impl FakeHost {
        fn new(decisions: Vec<Decision>) -> Self {
            FakeHost { cancel: Cancel::default(), decisions: RefCell::new(decisions), asked: RefCell::new(Vec::new()), browser: Ok(()), stop_on_ask: false, resets: RefCell::new(Vec::new()), runs_seen: std::cell::Cell::new(0) }
        }
    }

    impl JobHost for FakeHost {
        fn cancel(&self) -> &Cancel {
            &self.cancel
        }
        fn ensure_browser(&self) -> Result<(), String> {
            self.browser.clone()
        }
        fn running(&self, _agent: &AgentSpec, _note: &str) {
            self.runs_seen.set(self.runs_seen.get() + 1);
        }
        fn reset_tabs(&self) {
            self.resets.borrow_mut().push(self.runs_seen.get());
        }
        fn ask_approval(&self, action: &str) -> Decision {
            self.asked.borrow_mut().push(action.to_string());
            if self.stop_on_ask {
                self.cancel.stop();
                return Decision::Stopped;
            }
            self.decisions.borrow_mut().remove(0)
        }
        fn scratch_file(&self, name: &str) -> PathBuf {
            PathBuf::from(name)
        }
    }

    fn cfg() -> JobConfig {
        JobConfig { agents: agent_order(&[]), preapproved: vec![DEFAULT_PREAPPROVED.into()], downloads: PathBuf::from(r"C:\dl") }
    }

    fn ok(stdout: &str) -> Result<RunOutput, String> {
        Ok(RunOutput { exit_code: Some(0), stdout: stdout.into(), ..Default::default() })
    }

    fn with_session(stdout: &str, sid: &str) -> Result<RunOutput, String> {
        Ok(RunOutput { exit_code: Some(0), stdout: stdout.into(), session_id: Some(sid.into()), ..Default::default() })
    }

    fn fail(stderr: &str, code: i32) -> Result<RunOutput, String> {
        Ok(RunOutput { exit_code: Some(code), stderr: stderr.into(), ..Default::default() })
    }

    #[test]
    fn a_plain_result_ends_the_job_on_the_first_agent() {
        let runner = FakeRunner::new(vec![ok("RESULT: Downloaded cat.png")]);
        let end = run_job(&runner, &FakeHost::new(vec![]), &cfg(), "get a cat");
        assert_eq!(end, JobEnd::Done { result: "Downloaded cat.png".into(), agent: "Hermes (amanda)".into() });
        assert_eq!(runner.programs(), vec!["hermes:amanda"]);
        assert!(runner.prompt(0).contains("get a cat") && runner.prompt(0).contains(DEFAULT_PREAPPROVED));
    }

    #[test]
    fn quota_errors_and_silent_failures_fall_back_to_codex_once() {
        let runner = FakeRunner::new(vec![fail("rate limit exceeded", 1), ok("RESULT: done by codex")]);
        let end = run_job(&runner, &FakeHost::new(vec![]), &cfg(), "t");
        assert_eq!(end, JobEnd::Done { result: "done by codex".into(), agent: "Codex".into() });
        assert_eq!(runner.programs(), vec!["hermes:amanda", "codex"]);
        assert!(runner.prompt(1).contains("Task:\nt\n"));

        let runner = FakeRunner::new(vec![fail("", 1), fail("codex broke", 1)]);
        let end = run_job(&runner, &FakeHost::new(vec![]), &cfg(), "t");
        assert_eq!(end, JobEnd::Failed { message: "Codex: codex broke".into() });
        assert_eq!(runner.seen.borrow().len(), 2);

        let mut runner = FakeRunner::new(vec![ok("RESULT: codex")]);
        runner.missing = vec![AgentSpec::Hermes { profile: Some("amanda".into()) }];
        assert!(matches!(run_job(&runner, &FakeHost::new(vec![]), &cfg(), "t"), JobEnd::Done { .. }));
        assert_eq!(runner.programs(), vec!["codex"]);

        let runner = FakeRunner::new(vec![Err("spawn failed".into()), ok("RESULT: codex")]);
        assert!(matches!(run_job(&runner, &FakeHost::new(vec![]), &cfg(), "t"), JobEnd::Done { .. }));
    }

    #[test]
    fn allow_resumes_the_hermes_session() {
        let runner = FakeRunner::new(vec![
            with_session("NEEDS_APPROVAL: Send 'hello' to Bob", "sess_1"),
            ok("RESULT: Sent hello to Bob"),
        ]);
        let host = FakeHost::new(vec![Decision::Allow]);
        let end = run_job(&runner, &host, &cfg(), "say hello to Bob");
        assert_eq!(end, JobEnd::Done { result: "Sent hello to Bob".into(), agent: "Hermes (amanda)".into() });
        assert_eq!(*host.asked.borrow(), vec!["Send 'hello' to Bob".to_string()]);
        let second = &runner.seen.borrow()[1];
        assert!(second.args.windows(2).any(|w| w == ["--resume", "sess_1"]));
        assert_eq!(second.args.last().unwrap(), &approval_followup("Send 'hello' to Bob"));
    }

    #[test]
    fn allow_without_a_session_reruns_the_task_with_the_action_approved() {
        let runner = FakeRunner::new(vec![ok("NEEDS_APPROVAL: Post the photo"), ok("RESULT: posted")]);
        let host = FakeHost::new(vec![Decision::Allow]);
        assert!(matches!(run_job(&runner, &host, &cfg(), "post it"), JobEnd::Done { .. }));
        let p = runner.prompt(1);
        assert!(p.contains("  * Post the photo\n") && p.contains("Task:\npost it"));
        assert!(!runner.seen.borrow()[1].args.contains(&"--resume".to_string()));
    }

    #[test]
    fn deny_and_stop_end_the_job_without_running_again() {
        let runner = FakeRunner::new(vec![ok("NEEDS_APPROVAL: Pay 10 EUR")]);
        let host = FakeHost::new(vec![Decision::Deny]);
        assert_eq!(run_job(&runner, &host, &cfg(), "t"), JobEnd::Denied { action: "Pay 10 EUR".into() });
        assert_eq!(runner.seen.borrow().len(), 1);

        let runner = FakeRunner::new(vec![ok("NEEDS_APPROVAL: Pay 10 EUR")]);
        let mut host = FakeHost::new(vec![]);
        host.stop_on_ask = true;
        assert_eq!(run_job(&runner, &host, &cfg(), "t"), JobEnd::Stopped);

        let host = FakeHost::new(vec![]);
        host.cancel.stop();
        assert_eq!(run_job(&FakeRunner::new(vec![]), &host, &cfg(), "t"), JobEnd::Stopped);
    }

    #[test]
    fn a_preapproved_request_continues_without_a_card() {
        let runner = FakeRunner::new(vec![
            with_session(&format!("NEEDS_APPROVAL: {DEFAULT_PREAPPROVED}"), "s9"),
            ok("RESULT: sent"),
        ]);
        let host = FakeHost::new(vec![]);
        assert!(matches!(run_job(&runner, &host, &cfg(), "send it"), JobEnd::Done { .. }));
        assert!(host.asked.borrow().is_empty());
        assert!(runner.seen.borrow()[1].args.contains(&"s9".to_string()));
    }

    #[test]
    fn tabs_are_reset_before_each_fresh_run_and_after_the_job() {
        // Plain result: before the run, after the job.
        let runner = FakeRunner::new(vec![ok("RESULT: x")]);
        let host = FakeHost::new(vec![]);
        run_job(&runner, &host, &cfg(), "t");
        assert_eq!(*host.resets.borrow(), vec![0, 1]);

        // Fallback: a fresh page for Codex too.
        let runner = FakeRunner::new(vec![fail("429", 1), ok("RESULT: x")]);
        let host = FakeHost::new(vec![]);
        run_job(&runner, &host, &cfg(), "t");
        assert_eq!(*host.resets.borrow(), vec![0, 1, 2]);

        // A Hermes resume after Allow continues in the same page: no reset between.
        let runner = FakeRunner::new(vec![with_session("NEEDS_APPROVAL: Post it", "s1"), ok("RESULT: x")]);
        let host = FakeHost::new(vec![Decision::Allow]);
        run_job(&runner, &host, &cfg(), "t");
        assert_eq!(*host.resets.borrow(), vec![0, 2]);

        // Deny and Stop still clean up.
        let runner = FakeRunner::new(vec![ok("NEEDS_APPROVAL: Pay")]);
        let host = FakeHost::new(vec![Decision::Deny]);
        run_job(&runner, &host, &cfg(), "t");
        assert_eq!(host.resets.borrow().last(), Some(&1));
        let mut host = FakeHost::new(vec![]);
        host.stop_on_ask = true;
        run_job(&FakeRunner::new(vec![ok("NEEDS_APPROVAL: Pay")]), &host, &cfg(), "t");
        assert_eq!(host.resets.borrow().len(), 2);

        // Browser never came up: nothing to reset.
        let mut host = FakeHost::new(vec![]);
        host.browser = Err("down".into());
        run_job(&FakeRunner::new(vec![]), &host, &cfg(), "t");
        assert!(host.resets.borrow().is_empty());
    }

    #[test]
    fn a_timed_out_run_is_a_failure_and_falls_back() {
        let timed = RunOutput { stdout: "RESULT: half".into(), timed_out: true, ..Default::default() };
        assert!(matches!(classify(&timed), Parsed::Failed(m) if m.contains("15 minutes")));
        let runner = FakeRunner::new(vec![Ok(timed), ok("RESULT: codex did it")]);
        let end = run_job(&runner, &FakeHost::new(vec![]), &cfg(), "t");
        assert_eq!(end, JobEnd::Done { result: "codex did it".into(), agent: "Codex".into() });
    }

    #[test]
    fn browser_failure_and_endless_approvals_are_reported() {
        let mut host = FakeHost::new(vec![]);
        host.browser = Err("browser down".into());
        assert_eq!(run_job(&FakeRunner::new(vec![]), &host, &cfg(), "t"), JobEnd::Failed { message: "browser down".into() });

        let outputs = (0..MAX_RUNS).map(|_| ok(&format!("NEEDS_APPROVAL: {DEFAULT_PREAPPROVED}"))).collect();
        let runner = FakeRunner::new(outputs);
        assert!(matches!(run_job(&runner, &FakeHost::new(vec![]), &cfg(), "t"), JobEnd::Failed { .. }));
        assert_eq!(runner.seen.borrow().len(), MAX_RUNS);
    }

    // ── The real runner against real (fake-agent) processes ──────────────────

    fn cmd_exe() -> PathBuf {
        PathBuf::from(std::env::var("ComSpec").unwrap_or_else(|_| r"C:\Windows\System32\cmd.exe".into()))
    }

    #[test]
    fn process_runner_reads_output_and_exit_code() {
        let cmd = AgentCommand {
            program: cmd_exe(),
            args: vec!["/C".into(), "echo working& echo RESULT: fake agent done& echo oops 1>&2& exit 0".into()],
            env: vec![("BROWSER_CDP_URL".into(), CDP_URL.into())],
            cwd: std::env::temp_dir(),
            last_message_file: None,
            usage_file: None,
        };
        let out = ProcessRunner::default().run(&cmd, &Cancel::default()).unwrap();
        assert_eq!(out.exit_code, Some(0));
        assert_eq!(classify(&out), Parsed::Result("fake agent done".into()));
        assert!(out.stderr.contains("oops"));

        let failing = AgentCommand { args: vec!["/C".into(), "exit 7".into()], ..cmd };
        assert_eq!(ProcessRunner::default().run(&failing, &Cancel::default()).unwrap().exit_code, Some(7));
    }

    #[test]
    fn process_runner_stop_kills_the_tree_within_two_seconds() {
        let cancel = Arc::new(Cancel::default());
        let cmd = AgentCommand {
            program: cmd_exe(),
            // A child process (ping) that would run for ~60 s.
            args: vec!["/C".into(), "ping -n 60 127.0.0.1 >NUL".into()],
            env: Vec::new(),
            cwd: std::env::temp_dir(),
            last_message_file: None,
            usage_file: None,
        };
        let c2 = cancel.clone();
        let stopper = std::thread::spawn(move || {
            std::thread::sleep(Duration::from_millis(700));
            let t = Instant::now();
            c2.stop();
            t
        });
        let out = ProcessRunner::default().run(&cmd, &cancel).unwrap();
        let stopped_at = stopper.join().unwrap();
        assert!(stopped_at.elapsed() < Duration::from_secs(2), "took {:?}", stopped_at.elapsed());
        assert_eq!(out.exit_code, None);
        assert!(!out.timed_out);
        assert_eq!(*cancel.pid.lock().unwrap(), None);
    }

    #[test]
    fn process_runner_timeout_kills_the_tree() {
        let cmd = AgentCommand {
            program: cmd_exe(),
            args: vec!["/C".into(), "echo RESULT: too late& ping -n 60 127.0.0.1 >NUL".into()],
            env: Vec::new(),
            cwd: std::env::temp_dir(),
            last_message_file: None,
            usage_file: None,
        };
        let started = Instant::now();
        let cancel = Cancel::default();
        let out = ProcessRunner { timeout: Duration::from_millis(800) }.run(&cmd, &cancel).unwrap();
        assert!(started.elapsed() < Duration::from_secs(5), "took {:?}", started.elapsed());
        assert!(out.timed_out);
        assert_eq!(out.exit_code, None);
        assert!(!cancel.cancelled());
        assert!(matches!(classify(&out), Parsed::Failed(_)));
    }
}
