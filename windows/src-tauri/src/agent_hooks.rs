use std::fs::{self, OpenOptions};
use std::io::{self, Read, Seek, SeekFrom, Write};
use std::os::windows::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};

use std::sync::atomic::{AtomicU64, Ordering};
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Serialize;
use serde_yaml::Value as Yaml;
use toml_edit::DocumentMut;

const KIMI_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "StopFailure",
    "SessionEnd",
    "Notification",
];
const HERMES_EVENTS: &[&str] = &[
    "on_session_start",
    "pre_llm_call",
    "post_llm_call",
    "pre_tool_call",
    "post_tool_call",
    "pre_approval_request",
    "on_session_end",
    "on_session_finalize",
];
/// Codex events Coucou installs (names from https://developers.openai.com/codex/hooks).
const CODEX_EVENTS: &[&str] = &[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PermissionRequest",
    "PostToolUse",
    "Stop",
];
/// Codex `PermissionRequest` waits for a click on the island: longer than the
/// relay's own 110 s budget, so the relay always decides (or stays silent) first.
const CODEX_PERMISSION_TIMEOUT: u32 = 120;
/// Event sets of earlier Coucou releases. A managed block written by one of
/// them is still recognised, so it can be removed or upgraded in place.
const LEGACY_KIMI_EVENTS: &[&[&str]] = &[&[
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "PostToolUseFailure",
    "Stop",
    "StopFailure",
    "SessionEnd",
    "Notification",
]];
const LEGACY_HERMES_EVENTS: &[&[&str]] = &[&[
    "on_session_start",
    "pre_llm_call",
    "post_llm_call",
    "pre_tool_call",
    "post_tool_call",
    "on_session_end",
    "on_session_finalize",
]];
const LEGACY_CODEX_EVENTS: &[&[&str]] = &[&["Stop"]];

/// The current event set first, then every legacy set.
fn event_sets(agent: &str) -> Vec<&'static [&'static str]> {
    let (current, legacy): (&[&str], &[&[&str]]) = match agent {
        "kimi-code" => (KIMI_EVENTS, LEGACY_KIMI_EVENTS),
        "codex" => (CODEX_EVENTS, LEGACY_CODEX_EVENTS),
        "hermes" => (HERMES_EVENTS, LEGACY_HERMES_EVENTS),
        _ => return Vec::new(),
    };
    std::iter::once(current).chain(legacy.iter().copied()).collect()
}
const START: &str = "# coucou-agent-hooks begin";
const END: &str = "# coucou-agent-hooks end";
const NO_FINAL_NEWLINE: &str = "# coucou-agent-hooks original-no-final-newline\n";
const BLANK_ADDED: &str = "# coucou-agent-hooks blank-line-added-before\n";
const MERGED: &str = "    # coucou-agent-hooks merged ";
static SEQUENCE: AtomicU64 = AtomicU64::new(0);
static LIVE: AtomicU64 = AtomicU64::new(0);
const MAX_VERSION_READERS: usize = 2;
const VERSION_CACHE_TTL: std::time::Duration = std::time::Duration::from_secs(300);
const EOF_GRACE: std::time::Duration = std::time::Duration::from_secs(2);
static VERSION_READERS: [std::sync::atomic::AtomicUsize; 3] =
    [const { std::sync::atomic::AtomicUsize::new(0) }; 3];
static VERSION_LOCKS: [std::sync::Mutex<()>; 3] = [const { std::sync::Mutex::new(()) }; 3];
static VERSION_CACHE: std::sync::Mutex<Vec<CachedCheck>> = std::sync::Mutex::new(Vec::new());

struct CachedCheck {
    agent: usize,
    path: PathBuf,
    modified: SystemTime,
    len: u64,
    at: std::time::Instant,
    check: CliCheck,
}

#[derive(Clone, Debug, PartialEq)]
enum CliCheck {
    Missing,
    Tested(String),
    Untested(String),
    Unknown(String),
}

impl CliCheck {
    fn state(&self) -> &'static str {
        match self {
            Self::Missing => "missing",
            Self::Tested(_) => "tested",
            Self::Untested(_) => "untested",
            Self::Unknown(_) => "unknown",
        }
    }

    fn version(&self) -> String {
        match self {
            Self::Tested(version) | Self::Untested(version) => version.clone(),
            Self::Missing | Self::Unknown(_) => String::new(),
        }
    }

    fn reason(&self) -> String {
        match self {
            Self::Missing => "not found on PATH".into(),
            Self::Unknown(reason) => reason.clone(),
            Self::Tested(_) | Self::Untested(_) => String::new(),
        }
    }

    fn warning(&self, agent: &str) -> String {
        let tested = tested_version(agent);
        match self {
            Self::Tested(_) => String::new(),
            Self::Untested(version) => format!(
                "Untested CLI version {version} (tested: {tested}). Hooks may not fire or may behave differently; installing is at your own risk."
            ),
            Self::Unknown(reason) => format!(
                "Could not verify the CLI version ({reason}; tested: {tested}). Install only if you know this CLI supports these hooks."
            ),
            Self::Missing => "CLI not found on PATH; hook installation is unavailable.".into(),
        }
    }
}

struct VersionReaderPermit(&'static std::sync::atomic::AtomicUsize);

impl VersionReaderPermit {
    fn acquire(active: &'static std::sync::atomic::AtomicUsize) -> Option<Self> {
        active.try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
            (count < MAX_VERSION_READERS).then_some(count + 1)
        }).ok()?;
        Some(Self(active))
    }
}

impl Drop for VersionReaderPermit {
    fn drop(&mut self) {
        self.0.fetch_sub(1, Ordering::AcqRel);
    }
}

pub fn mark_live(agent: &str) {
    let bit = match agent {
        "kimi-code" => 1,
        "codex" => 2,
        "hermes" => 4,
        _ => 0,
    };
    LIVE.fetch_or(bit, Ordering::Relaxed);
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentHookStatus {
    /// Hooks can be installed: the CLI is on PATH, or the desktop app or the
    /// agent's config folder was found.
    pub available: bool,
    pub cli_found: bool,
    pub compatible: bool,
    pub version: String,
    pub version_state: String,
    pub version_reason: String,
    pub tested_version: String,
    pub version_warning: String,
    pub configured: bool,
    pub trust_verified: bool,
    pub live_event_seen: bool,
    pub settings_path: String,
    pub hook_path: String,
    pub hook_ready: bool,
    pub detail: String,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentHookPreview {
    pub version_warning: String,
    pub diff: String,
    pub fingerprint: String,
    pub backup: String,
    pub settings_path: String,
    pub hook_path: String,
    pub hook_ready: bool,
}

fn provider(agent: &str) -> Result<(&'static str, &'static str), String> {
    match agent {
        "kimi-code" => Ok(("kimi", ".kimi-code/config.toml")),
        "codex" => Ok(("codex", ".codex/config.toml")),
        "hermes" => Ok(("hermes", "config.yaml")),
        _ => Err("Unsupported agent".into()),
    }
}

fn agent_index(agent: &str) -> Option<usize> {
    match agent {
        "kimi-code" => Some(0),
        "codex" => Some(1),
        "hermes" => Some(2),
        _ => None,
    }
}

fn tested_version(agent: &str) -> &'static str {
    match agent {
        "kimi-code" => "2.1.1",
        "codex" => "codex-cli 0.157.0",
        "hermes" => "Hermes Agent v0.21.5",
        _ => "",
    }
}

fn probe_timeout(agent: &str) -> std::time::Duration {
    std::time::Duration::from_secs(if agent == "hermes" { 10 } else { 5 })
}

fn compatible_version(agent: &str, output: &str) -> bool {
    let first = output.lines().next().unwrap_or_default().trim();
    if first.is_empty() { return false; }
    if agent != "hermes" && output.lines().skip(1).any(|line| !line.trim().is_empty()) {
        return false;
    }
    match agent {
        "kimi-code" => first == "2.1.1",
        "codex" => first == "codex-cli 0.157.0",
        "hermes" => first.starts_with("Hermes Agent v0.21.5")
            && first["Hermes Agent v0.21.5".len()..]
                .chars()
                .next()
                .is_some_and(|c| c == '+' || c.is_whitespace()),
        _ => false,
    }
}

fn classify_version(agent: &str, output: &str) -> CliCheck {
    let version: String = output
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty())
        .unwrap_or_default()
        .chars()
        .filter(|c| !c.is_control())
        .take(200)
        .collect();
    if version.is_empty() {
        return CliCheck::Unknown("--version printed nothing".into());
    }
    if compatible_version(agent, output) {
        CliCheck::Tested(version)
    } else {
        CliCheck::Untested(version)
    }
}

#[cfg(test)]
fn checked_cli(agent: &str) -> CliCheck {
    checked_cli_in(agent, &Profile::from_env())
}

fn checked_cli_in(agent: &str, profile: &Profile) -> CliCheck {
    let Ok((exe, _)) = provider(agent) else { return CliCheck::Unknown("unsupported agent".into()) };
    let Some(path) = profile.find_cli(exe) else { return CliCheck::Missing };
    checked_cli_cached(agent, &path, || checked_cli_at(agent, &path))
}

fn checked_cli_cached(agent: &str, path: &Path, probe: impl FnOnce() -> CliCheck) -> CliCheck {
    let Some(index) = agent_index(agent) else { return CliCheck::Unknown("unsupported agent".into()) };
    let _serial = VERSION_LOCKS[index].lock().unwrap_or_else(|poison| poison.into_inner());
    let stamp = fs::metadata(path).ok().and_then(|meta| Some((meta.modified().ok()?, meta.len())));
    if let Some((modified, len)) = stamp {
        let cache = VERSION_CACHE.lock().unwrap_or_else(|poison| poison.into_inner());
        if let Some(hit) = cache.iter().find(|entry| {
            entry.agent == index
                && entry.path == path
                && entry.modified == modified
                && entry.len == len
                && entry.at.elapsed() < VERSION_CACHE_TTL
        }) {
            return hit.check.clone();
        }
    }
    let check = probe();
    if let (Some((modified, len)), CliCheck::Tested(_) | CliCheck::Untested(_)) = (stamp, &check) {
        let mut cache = VERSION_CACHE.lock().unwrap_or_else(|poison| poison.into_inner());
        cache.retain(|entry| entry.agent != index);
        cache.push(CachedCheck {
            agent: index,
            path: path.to_path_buf(),
            modified,
            len,
            at: std::time::Instant::now(),
            check: check.clone(),
        });
    }
    check
}

fn checked_cli_at(agent: &str, path: &Path) -> CliCheck {
    let mut command = std::process::Command::new(path);
    command.arg("--version");
    checked_cli_command(agent, command)
}

fn checked_cli_command(agent: &str, command: std::process::Command) -> CliCheck {
    let Some(index) = agent_index(agent) else { return CliCheck::Unknown("unsupported agent".into()) };
    checked_cli_command_limited(agent, command, &VERSION_READERS[index], probe_timeout(agent))
}

struct ProbeJob(windows::Win32::Foundation::HANDLE);

impl ProbeJob {
    fn new() -> Option<Self> {
        use windows::Win32::System::JobObjects::*;
        let job = Self(unsafe { CreateJobObjectW(None, windows::core::PCWSTR::null()) }.ok()?);
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        unsafe {
            SetInformationJobObject(
                job.0,
                JobObjectExtendedLimitInformation,
                (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
                std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
            )
        }
        .ok()?;
        Some(job)
    }

    fn assign(&self, child: &std::process::Child) -> bool {
        use std::os::windows::io::AsRawHandle;
        let process = windows::Win32::Foundation::HANDLE(child.as_raw_handle());
        unsafe { windows::Win32::System::JobObjects::AssignProcessToJobObject(self.0, process) }.is_ok()
    }
}

impl Drop for ProbeJob {
    fn drop(&mut self) {
        unsafe {
            let _ = windows::Win32::System::JobObjects::TerminateJobObject(self.0, 1);
            let _ = windows::Win32::Foundation::CloseHandle(self.0);
        }
    }
}

fn checked_cli_command_limited(
    agent: &str,
    mut command: std::process::Command,
    readers: &'static std::sync::atomic::AtomicUsize,
    timeout: std::time::Duration,
) -> CliCheck {
    use std::os::windows::process::CommandExt;
    let Some(permit) = VersionReaderPermit::acquire(readers) else {
        return CliCheck::Unknown("earlier version checks are still holding output open".into());
    };
    let job = ProbeJob::new();
    let mut child = match command
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .creation_flags(windows::Win32::System::Threading::CREATE_NO_WINDOW.0)
        .spawn()
    {
        Ok(child) => child,
        Err(err) => return CliCheck::Unknown(format!("could not start: {err}")),
    };
    let job = job.filter(|job| job.assign(&child));
    let deadline = std::time::Instant::now() + timeout;
    let stdout = child.stdout.take().unwrap();
    let (sender, receiver) = std::sync::mpsc::sync_channel(1);
    if std::thread::Builder::new().spawn(move || {
        let _permit = permit;
        let mut output = Vec::new();
        let result = stdout.take(4097).read_to_end(&mut output).map(|_| output);
        let _ = sender.send(result);
    }).is_err() {
        let _ = child.kill();
        let _ = child.wait();
        return CliCheck::Unknown("could not start the output reader".into());
    }
    let mut status = None;
    let mut exited_at = None;
    let mut output: Option<Vec<u8>> = None;
    let failure = loop {
        let now = std::time::Instant::now();
        if exited_at.is_some_and(|at: std::time::Instant| now >= at + EOF_GRACE) {
            break "the CLI exited but a child process kept its output open".to_string();
        }
        if now >= deadline {
            break format!("timed out after {}s", timeout.as_secs());
        }
        if status.is_none() {
            match child.try_wait() {
                Ok(result) => {
                    status = result;
                    if status.is_some() {
                        exited_at = Some(now);
                    }
                }
                Err(err) => break format!("could not wait for the process: {err}"),
            }
        }
        if let Some(code) = status.filter(|status: &std::process::ExitStatus| !status.success()) {
            break match code.code() {
                Some(code) => format!("exited with code {code}"),
                None => "exited abnormally".into(),
            };
        }
        if let (Some(_), Some(output)) = (status, output.as_ref()) {
            return classify_version(agent, &String::from_utf8_lossy(output));
        }
        let wait = deadline.saturating_duration_since(std::time::Instant::now())
            .min(std::time::Duration::from_millis(15));
        if output.is_none() {
            match receiver.recv_timeout(wait) {
                Ok(Ok(bytes)) if bytes.len() <= 4096 => output = Some(bytes),
                Ok(Ok(_)) => break "printed more than 4 KiB".into(),
                Ok(Err(err)) => break format!("could not read output: {err}"),
                Err(std::sync::mpsc::RecvTimeoutError::Disconnected) => break "output reader stopped".into(),
                Err(std::sync::mpsc::RecvTimeoutError::Timeout) => {}
            }
        } else {
            std::thread::sleep(wait);
        }
    };
    if status.is_none() {
        let _ = child.kill();
    }
    let _ = child.wait();
    drop(job);
    CliCheck::Unknown(failure)
}

/// The CLI check, plus the warning to show before installing. A missing CLI
/// only blocks installation when the agent is not there in any other form: a
/// desktop app or its config folder is enough to install hooks for it.
fn require_installable_in(agent: &str, profile: &Profile) -> Result<String, String> {
    installable(agent, profile, &checked_cli_in(agent, profile))
}

fn installable(agent: &str, profile: &Profile, check: &CliCheck) -> Result<String, String> {
    if *check != CliCheck::Missing {
        return Ok(check.warning(agent));
    }
    match missing_cli_warning(&crate::setup::detect_agent(agent, profile)) {
        Some(warning) => Ok(warning),
        None => Err("CLI not found on PATH and no desktop app or config folder detected; hook installation is unavailable".into()),
    }
}

fn missing_cli_warning(found: &crate::setup::Detection) -> Option<String> {
    if found.desktop.is_some() {
        Some("CLI not found; desktop app detected. Coucou can't check the hook version, so install only if your app supports these hooks.".into())
    } else if found.config_dir.is_some() {
        Some("CLI not found; config folder detected. Coucou can't check the hook version, so install only if your app supports these hooks.".into())
    } else {
        None
    }
}

fn settings_path_in(agent: &str, profile: &Profile) -> Result<PathBuf, String> {
    let (_, suffix) = provider(agent)?;
    if profile.home.as_os_str().is_empty() {
        return Err("USERPROFILE is unavailable".into());
    }
    if agent != "hermes" {
        return Ok(suffix.split('/').fold(profile.home.clone(), |path, part| path.join(part)));
    }
    hermes_config_path(&profile.hermes_root())
}

fn hermes_config_path(root: &Path) -> Result<PathBuf, String> {
    let active = root.join("active_profile");
    let name = match fs::read_to_string(&active) {
        Ok(value) => value.trim().to_string(),
        Err(err) if err.kind() == io::ErrorKind::NotFound => "default".into(),
        Err(err) => return Err(format!("Can't read {}: {err}", active.display())),
    };
    if name == "default" || name.is_empty() {
        return Ok(root.join("config.yaml"));
    }
    if !name
        .bytes()
        .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err("Hermes active profile is invalid".into());
    }
    Ok(root.join("profiles").join(name).join("config.yaml"))
}

fn read(path: &Path) -> Result<Option<Vec<u8>>, String> {
    match fs::read(path) {
        Ok(bytes) => Ok(Some(bytes)),
        Err(err) if err.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

fn fingerprint(
    agent: &str,
    install: bool,
    path: &Path,
    relay: &Path,
    bytes: Option<&[u8]>,
) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    let mut add = |part: &[u8]| {
        for byte in (part.len() as u64).to_le_bytes().iter().chain(part) {
            hash ^= *byte as u64;
            hash = hash.wrapping_mul(0x1000_0000_01b3);
        }
    };
    add(agent.as_bytes());
    add(if install { b"install" } else { b"remove" });
    add(path.as_os_str().as_encoded_bytes());
    add(relay.as_os_str().as_encoded_bytes());
    add(if bytes.is_some() { b"file" } else { b"absent" });
    add(bytes.unwrap_or_default());
    format!("{hash:016x}")
}

fn parse<'a>(agent: &str, bytes: &'a [u8]) -> Result<&'a str, String> {
    let text = std::str::from_utf8(bytes).map_err(|_| "Config is not UTF-8".to_string())?;
    if text.contains('\0') {
        return Err("Config contains NUL bytes".into());
    }
    match agent {
        "kimi-code" | "codex" => {
            if !text.trim().is_empty() {
                text.parse::<DocumentMut>()
                    .map_err(|_| "Invalid TOML config".to_string())?;
            }
        }
        "hermes" => {
            let value: Yaml =
                serde_yaml::from_str(text).map_err(|_| "Invalid YAML config".to_string())?;
            if !value.is_null() && !value.is_mapping() {
                return Err("Hermes config must be a mapping".into());
            }
            if let Some(hooks) = value.get("hooks") {
                if !hooks.is_null() && !hooks.is_mapping() {
                    return Err("Hermes hooks must be a mapping".into());
                }
                if let Some(mapping) = hooks.as_mapping() {
                    for event in HERMES_EVENTS {
                        if let Some(entries) = mapping.get(Yaml::String((*event).into())) {
                            if !entries.is_sequence() {
                                return Err(format!("Hermes {event} hooks must be a list"));
                            }
                        }
                    }
                }
            }
        }
        _ => return Err("Unsupported agent".into()),
    }
    Ok(text)
}

/// `text` with CRLF line endings turned into LF, and whether it used CRLF.
/// Editing works on the LF form; `styled` converts the result back, so a
/// consistently CRLF file keeps every unrelated byte. Mixed endings are refused.
fn normalized(text: &str) -> Result<(std::borrow::Cow<'_, str>, bool), String> {
    let crlf = text.matches("\r\n").count();
    if crlf == 0 {
        return Ok((text.into(), false));
    }
    if crlf != text.matches('\n').count() || crlf != text.matches('\r').count() {
        return Err(
            "Config mixes CRLF and LF line endings; make them consistent before changing hooks"
                .into(),
        );
    }
    Ok((text.replace("\r\n", "\n").into(), true))
}

fn styled(text: String, crlf: bool) -> String {
    if crlf { text.replace('\n', "\r\n") } else { text }
}

fn command(relay: &Path, agent: &str, event: &str) -> Result<String, String> {
    let path = relay.to_str().ok_or("Relay path is not UTF-8")?;
    if path.contains([
        '"', '\n', '\r', '\0', '%', '!', '^', '&', '|', '<', '>', '\'',
    ]) {
        return Err("Relay path cannot be safely quoted for Windows".into());
    }
    let command = format!("\"{path}\" --agent {agent} {event}");
    if command.len() > 8191 {
        return Err("Windows command exceeds 8191 characters".into());
    }
    Ok(command)
}

/// Codex runs `command_windows` through PowerShell, where a quoted path
/// followed by arguments is a parse error unless invoked with `&`.
fn powershell_command(relay: &Path, agent: &str, event: &str) -> Result<String, String> {
    Ok(format!("& {}", command(relay, agent, event)?))
}

fn escaped(value: &str) -> String {
    format!("'{}'", value.replace('\'', "''"))
}

fn block(agent: &str, relay: &Path) -> Result<String, String> {
    block_with(agent, relay, event_sets(agent).first().copied().unwrap_or_default())
}

fn block_with(agent: &str, relay: &Path, events: &[&str]) -> Result<String, String> {
    let mut out = String::new();
    match agent {
        "kimi-code" => {
            for event in events {
                out.push_str("[[hooks]]\n");
                out.push_str(&format!("event = {}\n", escaped(event)));
                if *event == "Notification" {
                    out.push_str("matcher = 'task\\.completed'\n");
                }
                out.push_str(&format!(
                    "command = {}\ntimeout = 3\n\n",
                    escaped(&command(relay, agent, event)?)
                ));
            }
        }
        "codex" => {
            for (i, event) in events.iter().enumerate() {
                if i > 0 {
                    out.push('\n');
                }
                let timeout = if *event == "PermissionRequest" { CODEX_PERMISSION_TIMEOUT } else { 3 };
                out.push_str(&format!(
                    "[[hooks.{event}]]\n[[hooks.{event}.hooks]]\ntype = 'command'\n"
                ));
                out.push_str(&format!(
                    "command = {}\ncommand_windows = {}\ntimeout = {timeout}\n",
                    escaped(&command(relay, agent, event)?),
                    escaped(&powershell_command(relay, agent, event)?)
                ));
            }
        }
        "hermes" => {
            for event in events {
                out.push_str(&format!(
                    "  {event}:\n    - command: {}\n      timeout: 3\n",
                    escaped(&command(relay, agent, event)?)
                ));
            }
        }
        _ => return Err("Unsupported agent".into()),
    }
    Ok(out)
}

fn markers(text: &str) -> Result<Option<(usize, usize)>, String> {
    let start = text.find(START);
    let end = text.find(END);
    match (start, end) {
        (None, None) => Ok(None),
        (Some(a), Some(b))
            if a <= b && text.matches(START).count() == 1 && text.matches(END).count() == 1 =>
        {
            let before = text[..a].rfind('\n').map_or(0, |i| i + 1);
            if before != a {
                return Err("Coucou marker is not on its own line".into());
            }
            let finish = b + END.len();
            if !matches!(text.as_bytes().get(finish), None | Some(b'\n')) {
                return Err("Coucou marker line is malformed".into());
            }
            let finish = if text.as_bytes().get(finish) == Some(&b'\n') {
                finish + 1
            } else {
                finish
            };
            if text.as_bytes().get(finish.saturating_sub(1)) == Some(&b'\r') {
                return Err("Coucou marker line is malformed".into());
            }
            Ok(Some((a, finish)))
        }
        _ => Err("Coucou markers are incomplete or duplicated".into()),
    }
}

/// Where a Codex block's lost begin marker belonged, when another tool dropped
/// it: the first of the contiguous `[[hooks.<Event>]]` / `[[hooks.<Event>.hooks]]`
/// tables that end at the lone end marker and run only coucou-hook.exe. Any
/// other shape is left as an error; the caller still checks the exact block.
fn recovered_start(text: &str) -> Option<usize> {
    if text.contains(START) || text.matches(END).count() != 1 {
        return None;
    }
    let mut offsets = Vec::new();
    let mut offset = 0;
    for line in text.split_inclusive('\n') {
        offsets.push((offset, line.trim_end_matches('\n')));
        offset += line.len();
    }
    let end = offsets.iter().position(|(_, line)| *line == END)?;
    let is_header = |line: &str| {
        line.strip_prefix("[[hooks.")
            .and_then(|rest| rest.strip_suffix("]]"))
            .and_then(|name| match name.split_once('.') {
                None => Some(name),
                Some((event, "hooks")) => Some(event),
                Some(_) => None,
            })
            .is_some_and(|event| !event.is_empty() && event.bytes().all(|b| b.is_ascii_alphanumeric()))
    };
    let is_body = |line: &str| match line.split_once(" = ") {
        Some(("type" | "timeout", _)) => true,
        Some(("command" | "command_windows", value)) => value.contains("coucou-hook.exe"),
        _ => false,
    };
    let owned_line = |line: &str| line.contains("coucou-hook.exe") || line.contains("coucou-agent-hooks");
    let mut start = None;
    let mut orphan_body = false;
    for &(at, line) in offsets[..end].iter().rev() {
        if is_header(line) {
            start = Some(at);
            orphan_body = false;
        } else if line.is_empty() {
            continue;
        } else if is_body(line) {
            orphan_body = true;
        } else {
            if orphan_body || owned_line(line) {
                return None;
            }
            break;
        }
    }
    if orphan_body {
        return None;
    }
    start.filter(|at| !text[..*at].lines().any(owned_line))
}

/// `text` with a recoverable lost begin marker put back.
fn healed(text: &str) -> Option<String> {
    let at = recovered_start(text)?;
    let mut out = text.to_string();
    out.insert_str(at, &format!("{START}\n"));
    Some(out)
}

/// Coucou's managed block in `text`: `(start, end, no_final_newline, current)`.
/// `current` is false when the block was written by an earlier Coucou with a
/// smaller event set; such a block is still owned and can be upgraded or removed.
fn managed_block(
    agent: &str,
    text: &str,
    relay: &Path,
) -> Result<Option<(usize, usize, bool, bool)>, String> {
    let sets = event_sets(agent);
    let mut first_err = None;
    for (i, events) in sets.iter().enumerate() {
        match managed_block_with(agent, text, relay, events) {
            Ok(found) => return Ok(found.map(|(s, e, n)| (s, e, n, i == 0))),
            Err(err) => {
                first_err.get_or_insert(err);
            }
        }
    }
    Err(first_err.unwrap_or_else(|| "Unsupported agent".into()))
}

fn managed_block_with(
    agent: &str,
    text: &str,
    relay: &Path,
    events: &[&str],
) -> Result<Option<(usize, usize, bool)>, String> {
    let Some((start, end)) = markers(text)? else {
        return Ok(None);
    };
    let chunk = &text[start..end];
    let mut merged_events = Vec::new();
    if agent == "hermes" {
        let (header_end, _, _) = hermes_hooks(text)?.ok_or("Hermes hooks header is missing")?;
        if header_end > start {
            return Err("Hermes hooks changed outside Coucou's managed block".into());
        }
        let merged = hermes_merged(text, relay)?;
        let existing_keys: Vec<_> = text[header_end..start]
            .lines()
            .filter_map(|line| {
                line.strip_prefix("  ")
                    .filter(|rest| !rest.starts_with(' '))
                    .and_then(|rest| rest.strip_suffix(':'))
                    .filter(|key| events.contains(key))
            })
            .collect();
        merged_events = merged.into_iter().map(|(_, _, event)| event).collect();
        if existing_keys.len() != merged_events.len()
            || existing_keys
                .iter()
                .any(|key| !merged_events.iter().any(|event| event == key))
        {
            return Err("Hermes hooks changed outside Coucou's managed block".into());
        }
    }
    let no_final_newline = chunk.starts_with(&format!("{START}\n{NO_FINAL_NEWLINE}"));
    let blank_added = agent == "codex"
        && chunk.starts_with(&format!(
            "{START}\n{}{BLANK_ADDED}",
            if no_final_newline { NO_FINAL_NEWLINE } else { "" }
        ));
    let fragment = if agent == "hermes" {
        if merged_events.iter().any(|event| !events.contains(&event.as_str())) {
            return Err("Unrecognized or misplaced Coucou Hermes entry".into());
        }
        let mut fragment = String::new();
        for event in events {
            if !merged_events.iter().any(|found| found == event) {
                fragment.push_str(&format!(
                    "  {event}:\n    - command: {}\n      timeout: 3\n",
                    escaped(&command(relay, agent, event)?)
                ));
            }
        }
        fragment
    } else {
        block_with(agent, relay, events)?
    };
    let expected = format!(
        "{START}\n{}{}{fragment}{END}\n",
        if no_final_newline {
            NO_FINAL_NEWLINE
        } else {
            ""
        },
        if blank_added { BLANK_ADDED } else { "" }
    );
    if chunk != expected
        || (no_final_newline && (end != text.len() || start == 0))
        || (blank_added && !text[..start].ends_with("\n\n"))
    {
        return Err(
            "Coucou's managed hook block has changed; remove it manually after reviewing".into(),
        );
    }
    let start = if blank_added { start - 1 } else { start };
    Ok(Some((start, end, no_final_newline)))
}

fn hermes_hooks(text: &str) -> Result<Option<(usize, usize, Vec<String>)>, String> {
    let mut offset = 0;
    let mut found = None;
    for line in text.split_inclusive('\n') {
        if line == "hooks:\n" || line == "hooks:" {
            if found.is_some() {
                return Err("Multiple Hermes hooks blocks; cannot safely edit".into());
            }
            found = Some(offset + line.len());
        }
        offset += line.len();
    }
    let Some(start) = found else {
        return Ok(None);
    };
    let mut end = start;
    let mut keys = Vec::new();
    for line in text[start..].split_inclusive('\n') {
        if !line.starts_with(' ') && !line.starts_with('#') && !line.trim().is_empty() {
            break;
        }
        if line.starts_with("  ") && !line.starts_with("    ") {
            let key = line
                .trim()
                .split_once(':')
                .ok_or("Hermes hook key uses unsupported formatting")?;
            if !key.1.trim().is_empty() {
                return Err("Hermes hook event must use a block list".into());
            }
            keys.push(key.0.to_string());
        }
        end += line.len();
    }
    Ok(Some((start, end, keys)))
}

fn hermes_merged(text: &str, relay: &Path) -> Result<Vec<(usize, usize, String)>, String> {
    let Some((hooks_start, hooks_end, _)) = hermes_hooks(text)? else {
        return Ok(Vec::new());
    };
    let mut offset = hooks_start;
    let mut merged = Vec::new();
    let mut active_event = None;
    for line in text[hooks_start..hooks_end].split_inclusive('\n') {
        if let Some(event) = line
            .strip_prefix("  ")
            .filter(|rest| !rest.starts_with(' '))
            .and_then(|rest| rest.strip_suffix(":\n"))
        {
            active_event = Some(event);
        }
        if let Some(event) = line
            .strip_prefix(MERGED)
            .and_then(|name| name.strip_suffix('\n'))
        {
            if !HERMES_EVENTS.contains(&event)
                || active_event != Some(event)
                || merged.iter().any(|(_, _, found)| found == event)
            {
                return Err("Unrecognized or misplaced Coucou Hermes entry".into());
            }
            let expected = format!(
                "{MERGED}{event}\n    - command: {}\n      timeout: 3\n",
                escaped(&command(relay, "hermes", event)?)
            );
            if !text[offset..].starts_with(&expected) {
                return Err("Coucou's managed Hermes entry has changed".into());
            }
            merged.push((offset, offset + expected.len(), event.to_string()));
        }
        offset += line.len();
    }
    Ok(merged)
}

fn patch(agent: &str, current: &str, install: bool, relay: &Path) -> Result<String, String> {
    if agent == "codex" {
        if let Some(repaired) = healed(current) {
            if managed_block(agent, &repaired, relay).is_ok() {
                return patch(agent, &repaired, install, relay);
            }
        }
    }
    let owned = managed_block(agent, current, relay)?;
    if install && owned.is_some_and(|(_, _, _, up_to_date)| !up_to_date) {
        // An earlier Coucou's smaller block: remove it, then install the current one.
        let removed = patch(agent, current, false, relay)?;
        return patch(agent, &removed, true, relay);
    }
    let owned = owned.map(|(start, end, no_final_newline, _)| (start, end, no_final_newline));
    if agent != "hermes" {
        let mut clean = current.to_string();
        if owned.is_some() && install {
            return Ok(clean);
        }
        if let Some((start, end, no_final_newline)) = owned {
            clean.replace_range(start..end, "");
            if no_final_newline {
                clean.pop();
            }
        }
        if !install {
            return Ok(clean);
        }
        let no_final_newline = !clean.is_empty() && !clean.ends_with('\n');
        if no_final_newline {
            clean.push('\n');
        }
        let blank_added = agent == "codex" && !clean.is_empty() && !clean.ends_with("\n\n");
        if blank_added {
            clean.push('\n');
        }
        clean.push_str(&format!(
            "{START}\n{}{}{}{END}\n",
            if no_final_newline {
                NO_FINAL_NEWLINE
            } else {
                ""
            },
            if blank_added { BLANK_ADDED } else { "" },
            block(agent, relay)?
        ));
        parse(agent, clean.as_bytes())?;
        return Ok(clean);
    }
    if owned.is_some() && install {
        return Ok(current.to_string());
    }
    if let Some((start, end, no_final_newline)) = owned {
        let mut clean = current.to_string();
        let preceded_by_hooks = clean[..start]
            .lines()
            .last()
            .is_some_and(|line| line.trim() == "hooks:");
        clean.replace_range(start..end, "");
        if preceded_by_hooks
            && clean[start..]
                .lines()
                .next()
                .is_none_or(|line| !line.starts_with("  "))
        {
            let header_start = clean[..start]
                .rfind("hooks:")
                .ok_or("Missing Hermes hooks header")?;
            clean.replace_range(header_start..start, "");
        }
        for (entry_start, entry_end, _) in hermes_merged(current, relay)?.into_iter().rev() {
            clean.replace_range(entry_start..entry_end, "");
        }
        if no_final_newline {
            clean.pop();
        }
        parse(agent, clean.as_bytes())?;
        return Ok(clean);
    }
    let parsed: Yaml =
        serde_yaml::from_str(current).map_err(|_| "Invalid YAML config".to_string())?;
    let mut clean = current.to_string();
    let fragment = block(agent, relay)?;
    if parsed.get("hooks").is_some_and(|v| !v.is_null()) {
        let Some((_, end, existing)) = hermes_hooks(current)? else {
            return Err("Hermes hooks use a complex YAML key; cannot safely edit".into());
        };
        let parsed_keys = parsed["hooks"]
            .as_mapping()
            .ok_or("Hermes hooks must be a mapping")?;
        if current.contains("# coucou-agent-hooks merged ")
            || existing.len() != parsed_keys.len()
            || parsed_keys.keys().any(|key| {
                key.as_str()
                    .is_none_or(|name| !existing.iter().any(|found| found == name))
            })
        {
            return Err("Hermes hooks use unsupported formatting; cannot safely edit".into());
        }
        if end > 0 && clean.as_bytes()[end - 1] != b'\n' {
            return Err("Hermes hooks block lacks a final newline; cannot safely edit".into());
        }
        let mut fragment = String::new();
        let mut merged = Vec::new();
        for event in HERMES_EVENTS {
            if existing.iter().any(|key| key == event) {
                let header = format!("  {event}:\n");
                let occurrences: Vec<_> = current
                    .match_indices(&header)
                    .filter(|(at, _)| *at < end)
                    .collect();
                if occurrences.len() != 1 {
                    return Err("Hermes event uses ambiguous formatting".into());
                }
                let start = occurrences[0].0 + header.len();
                let boundary = current[start..end]
                    .find("\n  ")
                    .map_or(end, |at| start + at + 1);
                let entries = &current[start..boundary];
                if entries.contains('\t')
                    || entries.contains('&')
                    || entries.contains('*')
                    || entries.contains("# coucou-agent-hooks merged ")
                    || entries.lines().any(|line| {
                        !line.trim().is_empty()
                            && !line.starts_with("    ")
                            && !line.starts_with('#')
                    })
                    || parsed["hooks"][*event]
                        .as_sequence()
                        .is_none_or(|items| items.is_empty())
                {
                    return Err("Hermes event list uses unsupported formatting".into());
                }
                merged.push((
                    boundary,
                    format!(
                        "{MERGED}{event}\n    - command: {}\n      timeout: 3\n",
                        escaped(&command(relay, agent, event)?)
                    ),
                ));
            } else {
                fragment.push_str(&format!(
                    "  {event}:\n    - command: {}\n      timeout: 3\n",
                    escaped(&command(relay, agent, event)?)
                ));
            }
        }
        clean.insert_str(end, &format!("{START}\n{fragment}{END}\n"));
        merged.sort_by_key(|(at, _)| *at);
        for (at, item) in merged.into_iter().rev() {
            clean.insert_str(at, &item);
        }
    } else {
        let no_final_newline = !clean.is_empty() && !clean.ends_with('\n');
        if no_final_newline {
            clean.push('\n');
        }
        clean.push_str(&format!(
            "hooks:\n{START}\n{}{fragment}{END}\n",
            if no_final_newline {
                NO_FINAL_NEWLINE
            } else {
                ""
            }
        ));
    }
    parse(agent, clean.as_bytes())?;
    Ok(clean)
}

fn diff(before: &str, after: &str) -> Result<String, String> {
    if before == after {
        return Ok("No change.".into());
    }
    if !before.contains(START) && after.contains(START) {
        if let Some(repaired) = healed(before) {
            let rest = if repaired == after { String::new() } else { diff(&repaired, after)? };
            return Ok(format!("+ {START}  (repair: restores the missing begin marker)\n{rest}"));
        }
    }
    if before.contains(START) && after.contains(START) {
        // Upgrading an earlier Coucou block: show what goes and what comes.
        let stripped = |text: &str| -> Result<String, String> {
            let (start, end) = markers(text)?.ok_or("Managed block is missing from preview")?;
            Ok(format!("{}{}", &text[..start], &text[end..]))
        };
        let old = diff(before, &stripped(before)?)?;
        let new = diff(&stripped(after)?, after)?;
        return Ok(format!("{old}{new}"));
    }
    let (text, sign) = if after.contains(START) {
        (after, '+')
    } else {
        (before, '-')
    };
    let (start, end) = markers(text)?.ok_or("Managed block is missing from preview")?;
    let mut out = String::new();
    if sign == '+' && !before.is_empty() && !before.ends_with('\n') {
        out.push_str("+ <final newline added before Coucou hooks>\n");
    }
    if text[..start].ends_with("hooks:\n") && !before.contains("hooks:") {
        out.push_str("+ hooks:\n");
    }
    for line in text[start..end].lines() {
        out.push_str(&format!("{sign} {line}\n"));
    }
    let source = if sign == '+' { after } else { before };
    let mut lines = source.lines();
    while let Some(line) = lines.next() {
        if line.starts_with(MERGED) {
            out.push_str(&format!("{sign} {line}\n"));
            for owned_line in lines.by_ref().take(2) {
                out.push_str(&format!("{sign} {owned_line}\n"));
            }
        }
    }
    if sign == '-' && !after.contains("hooks:") && before[..start].ends_with("hooks:\n") {
        out.push_str("- hooks:\n");
    }
    Ok(out)
}

fn projected_backup(path: &Path) -> PathBuf {
    path.with_file_name(format!(
        "{}.bak-coucou-<timestamp>-<unique>",
        path.file_name().unwrap_or_default().to_string_lossy()
    ))
}

fn preview_at(
    agent: &str,
    install: bool,
    path: &Path,
    relay: &Path,
) -> Result<AgentHookPreview, String> {
    provider(agent)?;
    let bytes = read(path)?;
    let (before, _) = normalized(parse(agent, bytes.as_deref().unwrap_or_default())?)?;
    let after = patch(agent, &before, install, relay)?;
    Ok(AgentHookPreview {
        version_warning: String::new(),
        diff: diff(&before, &after)?,
        fingerprint: fingerprint(agent, install, path, relay, bytes.as_deref()),
        backup: projected_backup(path).to_string_lossy().to_string(),
        settings_path: path.to_string_lossy().to_string(),
        hook_path: relay.to_string_lossy().to_string(),
        hook_ready: relay.is_file(),
    })
}

fn unique_path(path: &Path, kind: &str) -> PathBuf {
    let stamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_millis();
    path.with_file_name(format!(
        "{}.{}-{stamp}-{}-{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        kind,
        std::process::id(),
        SEQUENCE.fetch_add(1, Ordering::Relaxed)
    ))
}

fn apply_at(
    agent: &str,
    install: bool,
    expected: &str,
    path: &Path,
    relay: &Path,
) -> Result<String, String> {
    provider(agent)?;
    let parent = path.parent().ok_or("Config has no parent directory")?;
    if fingerprint(agent, install, path, relay, read(path)?.as_deref()) != expected {
        return Err("Config changed since the preview. Review it again.".into());
    }
    if install && !relay.is_file() {
        return Err("Coucou relay is unavailable".into());
    }
    if !path.exists() {
        let before = parse(agent, &[])?;
        let after = patch(agent, before, install, relay)?;
        if before == after {
            return Ok(String::new());
        }
        fs::create_dir_all(parent)
            .map_err(|err| format!("Can't create config directory: {err}"))?;
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(path)
            .map_err(|err| {
                format!("Config appeared or could not be created; review it again: {err}")
            })?;
        if let Err(err) = file
            .write_all(after.as_bytes())
            .and_then(|_| file.sync_all())
        {
            return Err(format!(
                "New config write failed; inspect {} before retrying: {err}",
                path.display()
            ));
        }
        return Ok(String::new());
    }
    let mut target = OpenOptions::new()
        .read(true)
        .write(true)
        .share_mode(0)
        .open(path)
        .map_err(|err| format!("Config is busy or cannot be locked; no changes made: {err}"))?;
    let mut original = Vec::new();
    target
        .read_to_end(&mut original)
        .map_err(|err| format!("Can't read locked config: {err}"))?;
    if fingerprint(agent, install, path, relay, Some(&original)) != expected {
        return Err("Config changed since the preview. Review it again.".into());
    }
    let (before, crlf) = normalized(parse(agent, &original)?)?;
    let after = patch(agent, &before, install, relay)?;
    if before == after {
        return Ok(String::new());
    }
    let after = styled(after, crlf);
    let backup = unique_path(path, "bak-coucou");
    let mut backup_file = OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(&backup)
        .map_err(|err| format!("Backup failed: {err}"))?;
    backup_file
        .write_all(&original)
        .and_then(|_| backup_file.sync_all())
        .map_err(|err| format!("Backup failed: {err}"))?;
    target
        .seek(SeekFrom::Start(0))
        .map_err(|err| format!("Can't seek locked config: {err}"))?;
    let write_result = target
        .write_all(after.as_bytes())
        .and_then(|_| target.set_len(after.len() as u64))
        .and_then(|_| target.sync_all());
    if let Err(err) = write_result {
        let recovery = target
            .seek(SeekFrom::Start(0))
            .and_then(|_| target.write_all(&original))
            .and_then(|_| target.set_len(original.len() as u64))
            .and_then(|_| target.sync_all());
        return Err(format!(
            "Config write failed: {err}; restoration from backup {}: {}",
            backup.display(),
            if recovery.is_ok() {
                "succeeded"
            } else {
                "FAILED; restore manually"
            }
        ));
    }
    Ok(backup.to_string_lossy().to_string())
}

pub fn status(agent: &str) -> Result<AgentHookStatus, String> {
    status_in(agent, &Profile::from_env())
}

pub fn status_in(agent: &str, profile: &Profile) -> Result<AgentHookStatus, String> {
    provider(agent)?;
    let path = settings_path_in(agent, profile)?;
    let relay = profile.relay();
    let check = checked_cli_in(agent, profile);
    let installable = installable(agent, profile, &check);
    let bytes = read(&path)?;
    let configured = bytes
        .as_deref()
        .and_then(|raw| std::str::from_utf8(raw).ok())
        .is_some_and(|text| text.contains(START));
    let detail = preview_at(agent, true, &path, &relay)
        .err()
        .unwrap_or_default();
    let bit = match agent {
        "kimi-code" => 1,
        "codex" => 2,
        "hermes" => 4,
        _ => 0,
    };
    Ok(AgentHookStatus {
        available: installable.is_ok(),
        cli_found: check != CliCheck::Missing,
        compatible: matches!(check, CliCheck::Tested(_)),
        version: check.version(),
        version_state: check.state().into(),
        version_reason: check.reason(),
        tested_version: tested_version(agent).into(),
        version_warning: match &installable {
            Ok(warning) => warning.clone(),
            Err(_) => check.warning(agent),
        },
        configured,
        trust_verified: false,
        live_event_seen: LIVE.load(Ordering::Relaxed) & bit != 0,
        settings_path: path.to_string_lossy().to_string(),
        hook_path: relay.to_string_lossy().to_string(),
        hook_ready: relay.is_file(),
        detail,
    })
}

pub fn preview(agent: &str, install: bool) -> Result<AgentHookPreview, String> {
    preview_in(agent, install, &Profile::from_env())
}

pub fn preview_in(agent: &str, install: bool, profile: &Profile) -> Result<AgentHookPreview, String> {
    let warning = if install { require_installable_in(agent, profile)? } else { String::new() };
    let path = settings_path_in(agent, profile)?;
    let mut preview = preview_at(agent, install, &path, &profile.relay())?;
    preview.version_warning = warning;
    Ok(preview)
}

pub fn apply(agent: &str, install: bool, expected: &str) -> Result<String, String> {
    apply_in(agent, install, expected, &Profile::from_env())
}

pub fn apply_in(agent: &str, install: bool, expected: &str, profile: &Profile) -> Result<String, String> {
    if install { require_installable_in(agent, profile)?; }
    let path = settings_path_in(agent, profile)?;
    apply_at(agent, install, expected, &path, &profile.relay())
}

/// Whether the agent's config holds Coucou's managed block. Used by setup to
/// tell "already set up" apart from "installed now".
pub fn configured_in(agent: &str, profile: &Profile) -> Result<bool, String> {
    let path = settings_path_in(agent, profile)?;
    Ok(read(&path)?
        .as_deref()
        .and_then(|raw| std::str::from_utf8(raw).ok())
        .is_some_and(|text| text.contains(START)))
}

/// Everything that decides where agent configs, the relay and the CLIs are.
/// Built from the environment in the app; tests build one from temp folders so
/// nothing ever reaches the real profile.
#[derive(Clone, Debug, Default)]
pub struct Profile {
    pub home: PathBuf,
    pub local_app_data: PathBuf,
    pub hermes_home: Option<PathBuf>,
    pub path: Option<std::ffi::OsString>,
}

impl Profile {
    pub fn from_env() -> Self {
        Self {
            home: std::env::var_os("USERPROFILE").map(PathBuf::from).unwrap_or_default(),
            local_app_data: std::env::var_os("LOCALAPPDATA").map(PathBuf::from).unwrap_or_default(),
            hermes_home: std::env::var_os("HERMES_HOME").filter(|v| !v.is_empty()).map(PathBuf::from),
            path: std::env::var_os("PATH"),
        }
    }

    /// %LOCALAPPDATA%\Coucou\bin\coucou-hook.exe for this profile.
    pub fn relay(&self) -> PathBuf {
        self.local_app_data.join("Coucou").join("bin").join("coucou-hook.exe")
    }

    /// HERMES_HOME when set; otherwise ~/.hermes, unless only the Windows
    /// installer's %LOCALAPPDATA%\hermes exists.
    pub fn hermes_root(&self) -> PathBuf {
        if let Some(root) = &self.hermes_home {
            return root.clone();
        }
        let dotted = self.home.join(".hermes");
        let local = self.local_app_data.join("hermes");
        if !dotted.is_dir() && !self.local_app_data.as_os_str().is_empty() && local.is_dir() {
            return local;
        }
        dotted
    }

    pub fn find_cli(&self, stem: &str) -> Option<PathBuf> {
        crate::find_in(stem, self.path.as_deref()?)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    static NEXT: AtomicU64 = AtomicU64::new(0);

    struct Fixture(PathBuf);
    impl Fixture {
        fn new() -> Self {
            let path = std::env::temp_dir().join(format!(
                "coucou-agent-hooks-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            std::fs::create_dir_all(&path).unwrap();
            Self(path)
        }
        fn config(&self, name: &str) -> PathBuf {
            self.0.join(name)
        }
        fn relay(&self) -> PathBuf {
            let path = self.0.join("Coucou relay").join("coucou-hook.exe");
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, b"relay fixture").unwrap();
            path
        }
    }
    impl Drop for Fixture {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.0);
        }
    }

    #[test]
    fn kimi_preserves_orca_and_foreign_hooks_and_uninstalls_only_ours() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let original = b"# retained comment\nmodel = 'x'\n\n[[hooks]]\n# Orca-managed; do not edit\nevent = 'Stop'\ncommand = 'orca hook'\n\n[[hooks]]\nevent = 'SessionStart'\ncommand = 'foreign hook'\n";
        std::fs::write(&path, original).unwrap();
        let p = preview_at("kimi-code", true, &path, &f.relay()).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert!(p.diff.contains("Notification"));
        assert!(p.diff.contains("task"));
        let backup = apply_at("kimi-code", true, &p.fingerprint, &path, &f.relay()).unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), original);
        let installed = std::fs::read_to_string(&path).unwrap();
        assert!(installed.starts_with(std::str::from_utf8(original).unwrap()));
        let again = preview_at("kimi-code", true, &path, &f.relay()).unwrap();
        assert_eq!(again.diff, "No change.");
        let before = std::fs::read(&path).unwrap();
        assert!(
            apply_at("kimi-code", true, &again.fingerprint, &path, &f.relay())
                .unwrap()
                .is_empty()
        );
        assert_eq!(std::fs::read(&path).unwrap(), before);
        let removal = preview_at("kimi-code", false, &path, &f.relay()).unwrap();
        let backup2 =
            apply_at("kimi-code", false, &removal.fingerprint, &path, &f.relay()).unwrap();
        assert_ne!(backup2, backup);
        assert_eq!(std::fs::read(&path).unwrap(), original);
        assert_eq!(std::fs::read(backup2).unwrap(), before);
    }

    #[test]
    fn codex_preserves_other_stop_handler_and_has_nested_windows_command() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let original = "# saved\n[features]\nhooks = true\n\n[[hooks.Stop]]\n[[hooks.Stop.hooks]]\ntype = 'command'\ncommand_windows = 'other.exe'\n";
        std::fs::write(&path, original).unwrap();
        let p = preview_at("codex", true, &path, &f.relay()).unwrap();
        apply_at("codex", true, &p.fingerprint, &path, &f.relay()).unwrap();
        let next = std::fs::read_to_string(&path).unwrap();
        assert!(next.starts_with(original));
        assert!(next.contains("[[hooks.Stop.hooks]]"));
        assert!(next.contains("command_windows = '& \""));
        assert!(next.contains("--agent codex Stop"));
        assert!(
            next.contains("command_windows = 'other.exe'"),
            "existing handler remains"
        );
        assert!(
            next.contains("command = '\""),
            "Codex command handler requires the base command"
        );
        let doc: DocumentMut = next.parse().unwrap();
        for event in CODEX_EVENTS {
            let groups = doc["hooks"][event].as_array_of_tables().unwrap();
            let ours = groups.iter().last().unwrap()["hooks"].as_array_of_tables().unwrap().get(0).unwrap();
            assert_eq!(ours["type"].as_str(), Some("command"));
            let windows = ours["command_windows"].as_str().unwrap();
            assert!(windows.starts_with("& \"") && windows.ends_with(&format!("--agent codex {event}")), "{windows}");
            let timeout = ours["timeout"].as_integer().unwrap();
            assert_eq!(timeout, if *event == "PermissionRequest" { 120 } else { 3 }, "{event}");
        }
        assert!(doc["hooks"].get("Interrupt").is_none() && doc["hooks"].get("SessionEnd").is_none());
        let p = preview_at("codex", false, &path, &f.relay()).unwrap();
        apply_at("codex", false, &p.fingerprint, &path, &f.relay()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    const WORKLOG_TABLE: &str = "model = 'x'\n\n[mcp_servers.worklog]\ncommand = \"python\"\nargs = [\"mcp_bridge.py\"]\n";

    /// Codex config after the worklog kit's nightly rewrite ate our begin line.
    fn codex_lost_begin(relay: &Path) -> String {
        format!(
            "{WORKLOG_TABLE}env_vars = [\"WORKLOG_TOKEN\"]\n\n{}{END}\n",
            block("codex", relay).unwrap()
        )
    }

    #[test]
    fn codex_recovers_begin_marker_eaten_by_another_tool() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let relay = f.relay();
        let before = format!("{WORKLOG_TABLE}{START}\n{}{END}\n", block("codex", &relay).unwrap());
        assert!(managed_block("codex", &before, &relay).unwrap().is_some());
        let broken = codex_lost_begin(&relay);
        assert_eq!(markers(&broken).unwrap_err(), "Coucou markers are incomplete or duplicated");
        std::fs::write(&path, &broken).unwrap();
        let p = preview_at("codex", true, &path, &relay).unwrap();
        assert!(p.diff.contains("repair"), "{}", p.diff);
        assert_ne!(p.diff, "No change.");
        let backup = apply_at("codex", true, &p.fingerprint, &path, &relay).unwrap();
        assert_eq!(std::fs::read_to_string(&backup).unwrap(), broken);
        let fixed = std::fs::read_to_string(&path).unwrap();
        assert_eq!(
            fixed,
            format!(
                "{WORKLOG_TABLE}env_vars = [\"WORKLOG_TOKEN\"]\n\n{START}\n{}{END}\n",
                block("codex", &relay).unwrap()
            )
        );
        assert_eq!(preview_at("codex", true, &path, &relay).unwrap().diff, "No change.");
        let removal = preview_at("codex", false, &path, &relay).unwrap();
        apply_at("codex", false, &removal.fingerprint, &path, &relay).unwrap();
        assert_eq!(
            std::fs::read_to_string(&path).unwrap(),
            format!("{WORKLOG_TABLE}env_vars = [\"WORKLOG_TOKEN\"]\n\n")
        );
    }

    #[test]
    fn codex_does_not_recover_begin_marker_when_a_foreign_command_is_in_the_run() {
        let relay = Fixture::new().relay();
        let foreign = codex_lost_begin(&relay).replacen(
            &format!("command_windows = {}", escaped(&powershell_command(&relay, "codex", CODEX_EVENTS[0]).unwrap())),
            "command_windows = 'other.exe'",
            1,
        );
        assert!(foreign.contains("other.exe"));
        assert_eq!(recovered_start(&foreign), None);
        assert!(patch("codex", &foreign, true, &relay).is_err());
        let last = CODEX_EVENTS[CODEX_EVENTS.len() - 1];
        let foreign_last = codex_lost_begin(&relay).replacen(
            &format!("command = {}", escaped(&command(&relay, "codex", last).unwrap())),
            "command = 'other.exe'",
            1,
        );
        assert!(foreign_last.contains("other.exe"));
        assert_eq!(recovered_start(&foreign_last), None);
        assert!(patch("codex", &foreign_last, true, &relay).is_err());
    }

    #[test]
    fn codex_does_not_recover_lone_end_marker_without_hook_tables() {
        let relay = Fixture::new().relay();
        for text in [
            format!("{WORKLOG_TABLE}{END}\n"),
            format!("{WORKLOG_TABLE}\n{END}\n"),
            format!("{END}\n"),
            format!("{}{WORKLOG_TABLE}{END}\n", block("codex", &relay).unwrap()),
        ] {
            assert_eq!(recovered_start(&text), None, "{text}");
            assert_eq!(
                patch("codex", &text, true, &relay).unwrap_err(),
                "Coucou markers are incomplete or duplicated"
            );
        }
    }

    #[test]
    fn codex_duplicated_markers_still_error() {
        let relay = Fixture::new().relay();
        let fragment = block("codex", &relay).unwrap();
        for text in [
            format!("{START}\n{fragment}{END}\n\n{START}\n{fragment}{END}\n"),
            format!("{fragment}{END}\n\n{fragment}{END}\n"),
            format!("{START}\n{START}\n{fragment}{END}\n"),
        ] {
            assert_eq!(recovered_start(&text), None);
            assert_eq!(
                patch("codex", &text, true, &relay).unwrap_err(),
                "Coucou markers are incomplete or duplicated"
            );
        }
    }

    #[test]
    fn codex_new_block_is_separated_from_previous_table_and_removal_is_exact() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let relay = f.relay();
        for original in [WORKLOG_TABLE.to_string(), WORKLOG_TABLE.trim_end().to_string(), format!("{WORKLOG_TABLE}\n")] {
            std::fs::write(&path, &original).unwrap();
            let p = preview_at("codex", true, &path, &relay).unwrap();
            apply_at("codex", true, &p.fingerprint, &path, &relay).unwrap();
            let next = std::fs::read_to_string(&path).unwrap();
            let at = next.find(START).unwrap();
            assert!(next[..at].ends_with("\n\n"), "{next}");
            assert!(!next[..at].ends_with("\n\n\n"), "{next}");
            assert_eq!(preview_at("codex", true, &path, &relay).unwrap().diff, "No change.");
            let removal = preview_at("codex", false, &path, &relay).unwrap();
            apply_at("codex", false, &removal.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        }
    }

    /// A config as an earlier Coucou wrote it, with the given event set.
    fn legacy_install(agent: &str, original: &str, relay: &Path, events: &[&str]) -> String {
        let fragment = if agent == "hermes" {
            events
                .iter()
                .map(|e| format!("  {e}:\n    - command: {}\n      timeout: 3\n", escaped(&command(relay, agent, e).unwrap())))
                .collect::<String>()
        } else {
            block_with(agent, relay, events).unwrap()
        };
        let header = if agent == "hermes" { "hooks:\n" } else { "" };
        format!("{original}{header}{START}\n{fragment}{END}\n")
    }

    #[test]
    fn earlier_coucou_blocks_are_upgraded_in_place_and_still_removable() {
        let f = Fixture::new();
        let relay = f.relay();
        for (agent, name, original, legacy) in [
            ("codex", "codex.toml", "# saved\nmodel = 'x'\n", LEGACY_CODEX_EVENTS[0]),
            ("kimi-code", "kimi.toml", "model = 'x'\n", LEGACY_KIMI_EVENTS[0]),
            ("hermes", "hermes.yaml", "model: x\n", LEGACY_HERMES_EVENTS[0]),
        ] {
            let path = f.config(name);
            let old = legacy_install(agent, original, &relay, legacy);
            std::fs::write(&path, &old).unwrap();
            // The old block can still be removed as-is.
            let removal = preview_at(agent, false, &path, &relay).unwrap();
            assert!(removal.diff.starts_with("- "), "{agent}: {}", removal.diff);
            // Reinstall upgrades it: old lines out, new events in, nothing else touched.
            let p = preview_at(agent, true, &path, &relay).unwrap();
            assert!(p.diff.contains("- ") && p.diff.contains("+ "), "{agent}: {}", p.diff);
            let backup = apply_at(agent, true, &p.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read_to_string(&backup).unwrap(), old);
            let upgraded = std::fs::read_to_string(&path).unwrap();
            assert!(upgraded.starts_with(original), "{agent}");
            let new_event = match agent {
                "codex" => "--agent codex PermissionRequest",
                "kimi-code" => "--agent kimi-code PermissionRequest",
                _ => "--agent hermes pre_approval_request",
            };
            assert!(upgraded.contains(new_event), "{agent}");
            assert_eq!(upgraded.matches(START).count(), 1);
            assert_eq!(preview_at(agent, true, &path, &relay).unwrap().diff, "No change.");
            let p = preview_at(agent, false, &path, &relay).unwrap();
            apply_at(agent, false, &p.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read_to_string(&path).unwrap(), original, "{agent}");
        }
    }

    fn crlf(text: &str) -> String {
        text.replace('\n', "\r\n")
    }

    fn assert_crlf_only(bytes: &[u8], label: &str) {
        let text = std::str::from_utf8(bytes).unwrap();
        assert_eq!(text.matches('\n').count(), text.matches("\r\n").count(), "{label}");
        assert_eq!(text.matches('\r').count(), text.matches("\r\n").count(), "{label}");
    }

    #[test]
    fn crlf_configs_install_upgrade_and_uninstall_byte_for_byte() {
        let f = Fixture::new();
        let relay = f.relay();
        for (agent, name, original, legacy) in [
            ("kimi-code", "kimi.toml", "# c\nmodel = 'x'\n", LEGACY_KIMI_EVENTS[0]),
            ("codex", "codex.toml", "# saved\nmodel = 'x'\n", LEGACY_CODEX_EVENTS[0]),
            ("hermes", "hermes.yaml", "model: x\n", LEGACY_HERMES_EVENTS[0]),
        ] {
            let path = f.config(name);
            let original = crlf(original);
            std::fs::write(&path, &original).unwrap();
            let p = preview_at(agent, true, &path, &relay).unwrap();
            assert!(!p.diff.contains('\r'), "{agent}: {}", p.diff);
            let backup = apply_at(agent, true, &p.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read(&backup).unwrap(), original.as_bytes());
            let installed = std::fs::read(&path).unwrap();
            assert_crlf_only(&installed, agent);
            assert!(installed.starts_with(original.as_bytes()), "{agent}");
            assert_eq!(preview_at(agent, true, &path, &relay).unwrap().diff, "No change.");
            let p = preview_at(agent, false, &path, &relay).unwrap();
            apply_at(agent, false, &p.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read(&path).unwrap(), original.as_bytes(), "{agent}");

            let old = crlf(&legacy_install(agent, &original.replace("\r\n", "\n"), &relay, legacy));
            std::fs::write(&path, &old).unwrap();
            let p = preview_at(agent, true, &path, &relay).unwrap();
            assert!(p.diff.contains("- ") && p.diff.contains("+ "), "{agent}: {}", p.diff);
            apply_at(agent, true, &p.fingerprint, &path, &relay).unwrap();
            let upgraded = std::fs::read(&path).unwrap();
            assert_crlf_only(&upgraded, agent);
            assert_eq!(String::from_utf8_lossy(&upgraded).matches(START).count(), 1);
            assert_eq!(preview_at(agent, true, &path, &relay).unwrap().diff, "No change.");
            let p = preview_at(agent, false, &path, &relay).unwrap();
            apply_at(agent, false, &p.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read(&path).unwrap(), original.as_bytes(), "{agent}");
        }
    }

    #[test]
    fn crlf_configs_without_final_newline_round_trip() {
        let f = Fixture::new();
        let relay = f.relay();
        for (agent, name, original) in [
            ("kimi-code", "kimi.toml", "# c\r\nmodel = 'private'"),
            ("codex", "codex.toml", "# c\r\nmodel = 'private'"),
            ("hermes", "hermes.yaml", "a: 1\r\nmodel: private"),
        ] {
            let path = f.config(name);
            std::fs::write(&path, original).unwrap();
            let p = preview_at(agent, true, &path, &relay).unwrap();
            apply_at(agent, true, &p.fingerprint, &path, &relay).unwrap();
            assert_crlf_only(&std::fs::read(&path).unwrap(), agent);
            let p = preview_at(agent, false, &path, &relay).unwrap();
            apply_at(agent, false, &p.fingerprint, &path, &relay).unwrap();
            assert_eq!(std::fs::read(&path).unwrap(), original.as_bytes(), "{agent}");
        }
    }

    #[test]
    fn crlf_hermes_merges_into_foreign_same_event_lists() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let relay = f.relay();
        let original = crlf("hooks:\n  on_session_end:\n    - command: 'foreign-end.exe'\n    # keep-end\n  pre_tool_call:\n    - command: 'foreign-tool.exe'\nother: value\n");
        std::fs::write(&path, &original).unwrap();
        let p = preview_at("hermes", true, &path, &relay).unwrap();
        assert!(p.diff.contains("merged on_session_end"), "{}", p.diff);
        apply_at("hermes", true, &p.fingerprint, &path, &relay).unwrap();
        let installed = std::fs::read(&path).unwrap();
        assert_crlf_only(&installed, "hermes");
        let value: Yaml = serde_yaml::from_slice(&installed).unwrap();
        for (event, foreign) in [("on_session_end", "foreign-end.exe"), ("pre_tool_call", "foreign-tool.exe")] {
            let entries = value["hooks"][event].as_sequence().unwrap();
            assert_eq!(entries.len(), 2, "{event}");
            assert_eq!(entries[0]["command"].as_str(), Some(foreign));
            assert!(entries[1]["command"].as_str().unwrap().contains(&format!("--agent hermes {event}")));
        }
        assert_eq!(preview_at("hermes", true, &path, &relay).unwrap().diff, "No change.");
        let p = preview_at("hermes", false, &path, &relay).unwrap();
        apply_at("hermes", false, &p.fingerprint, &path, &relay).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), original.as_bytes());
    }

    #[test]
    fn mixed_line_endings_are_refused_without_writing() {
        let f = Fixture::new();
        let relay = f.relay();
        for (agent, name, original) in [
            ("kimi-code", "kimi.toml", "a = 1\r\nmodel = 'x'\n"),
            ("codex", "codex.toml", "a = 1\nmodel = 'x'\r\n"),
            ("hermes", "hermes.yaml", "a: 1\r\nmodel: x\n"),
        ] {
            let path = f.config(name);
            std::fs::write(&path, original).unwrap();
            let Err(err) = preview_at(agent, true, &path, &relay) else { panic!("{agent}: accepted") };
            assert!(err.contains("line endings"), "{agent}: {err}");
            assert!(preview_at(agent, false, &path, &relay).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), original.as_bytes());
        }
    }

    #[test]
    fn real_shaped_crlf_hermes_block_upgrades_to_approval_request() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let shaped = |relay: &str| {
            let mut text = String::from("model:\n  default: x\nhooks:\n# coucou-agent-hooks begin\n");
            for event in LEGACY_HERMES_EVENTS[0] {
                text.push_str(&format!(
                    "  {event}:\n    - command: '\"{relay}\" --agent hermes {event}'\n      timeout: 3\n"
                ));
            }
            text.push_str("# coucou-agent-hooks end\ntelemetry:\n  enabled: false\n");
            crlf(&text)
        };
        let real = r"C:\Users\Admin\AppData\Local\Coucou\bin\coucou-hook.exe";
        std::fs::write(&path, shaped(real)).unwrap();
        let p = preview_at("hermes", true, &path, Path::new(real)).unwrap();
        assert!(p.diff.contains("+   pre_approval_request:"), "{}", p.diff);
        assert!(preview_at("hermes", false, &path, Path::new(real)).is_ok());
        let relay = f.relay();
        let original = shaped(relay.to_str().unwrap());
        std::fs::write(&path, &original).unwrap();
        let p = preview_at("hermes", true, &path, &relay).unwrap();
        assert!(p.diff.contains("+   pre_approval_request:"), "{}", p.diff);
        apply_at("hermes", true, &p.fingerprint, &path, &relay).unwrap();
        let upgraded = std::fs::read(&path).unwrap();
        assert_crlf_only(&upgraded, "hermes");
        let upgraded = String::from_utf8(upgraded).unwrap();
        assert!(upgraded.contains("--agent hermes pre_approval_request'\r\n"));
        assert!(upgraded.starts_with("model:\r\n  default: x\r\n"));
        assert!(upgraded.contains("telemetry:\r\n  enabled: false\r\n"));
        let value: Yaml = serde_yaml::from_str(&upgraded).unwrap();
        assert_eq!(value["hooks"].as_mapping().unwrap().len(), HERMES_EVENTS.len());
        assert_eq!(value["telemetry"]["enabled"].as_bool(), Some(false));
        assert_eq!(preview_at("hermes", true, &path, &relay).unwrap().diff, "No change.");
    }

    #[test]
    fn hermes_and_kimi_blocks_subscribe_to_approval_observers() {
        let f = Fixture::new();
        let block = block("hermes", &f.relay()).unwrap();
        assert!(block.contains("  pre_approval_request:\n"));
        assert!(!block.contains("post_approval_response"));
        let block = super::block("kimi-code", &f.relay()).unwrap();
        assert!(block.contains("event = 'PermissionRequest'"));
        assert!(!block.contains("PermissionResult"));
    }

    #[test]
    fn cli_versions_are_verified_before_hook_installation() {
        assert!(compatible_version("kimi-code", "2.1.1"));
        assert!(!compatible_version("kimi-code", "2.1.2"));
        assert!(compatible_version("codex", "codex-cli 0.157.0"));
        assert!(!compatible_version("codex", "codex-cli 0.158.0"));
        assert!(compatible_version("hermes", "Hermes Agent v0.21.5+4343.g226eeeb.dirty (2026.9.24) · upstream 54724890"));
        assert!(!compatible_version("hermes", "Hermes Agent v0.22.0"));
        assert!(!compatible_version("codex", ""));
        assert!(!compatible_version("codex", "codex-cli 0.157.0\nextra"));
    }

    const HERMES_NEWER: &str = "Hermes Agent v0.22.1+12.gabcdef0 (2026.10.1) · upstream abcdef01\r\nInstall directory: C:\\Users\\x\\hermes\r\nInstall method: git\r\nPython: 3.14.7\r\nOpenAI SDK: 2.24.0\r\nUpdate available: 6 commits behind — run 'hermes update'\r\n";

    #[test]
    fn version_classification_reports_tested_untested_and_unknown() {
        let current = HERMES_NEWER.replace("v0.22.1+12.gabcdef0", "v0.21.5+5819.g50a6abc.dirty");
        assert_eq!(
            classify_version("hermes", &current),
            CliCheck::Tested("Hermes Agent v0.21.5+5819.g50a6abc.dirty (2026.10.1) · upstream abcdef01".into())
        );
        let newer = classify_version("hermes", HERMES_NEWER);
        assert_eq!(newer, CliCheck::Untested("Hermes Agent v0.22.1+12.gabcdef0 (2026.10.1) · upstream abcdef01".into()));
        let warning = newer.warning("hermes");
        assert!(warning.contains("Untested CLI version Hermes Agent v0.22.1"), "{warning}");
        assert!(warning.contains("(tested: Hermes Agent v0.21.5)"), "{warning}");
        assert_eq!(classify_version("codex", "codex-cli 0.158.0\n"), CliCheck::Untested("codex-cli 0.158.0".into()));
        assert_eq!(classify_version("kimi-code", "2.1.1\r\n"), CliCheck::Tested("2.1.1".into()));
        assert_eq!(classify_version("kimi-code", "\r\n  \n"), CliCheck::Unknown("--version printed nothing".into()));
        let unknown = CliCheck::Unknown("timed out after 10s".into());
        assert!(unknown.warning("hermes").contains("timed out after 10s"));
        assert!(!unknown.warning("hermes").contains("()"));
        assert_eq!(CliCheck::Tested("2.1.1".into()).warning("kimi-code"), "");
    }

    #[test]
    fn version_probe_reads_multiline_hermes_output_and_reports_exit_codes() {
        let f = Fixture::new();
        let script = f.config("hermes-newer.cmd");
        let mut body = String::from("@echo off\r\n");
        for line in HERMES_NEWER.lines() {
            body.push_str(&format!("echo {}\r\n", line.replace('\'', "")));
        }
        std::fs::write(&script, body).unwrap();
        let result = checked_cli_at("hermes", &script);
        let CliCheck::Untested(version) = result else { panic!("unexpected {result:?}") };
        assert!(version.starts_with("Hermes Agent v0.22.1+12.gabcdef0"), "{version}");
        let failing = f.config("failing.cmd");
        std::fs::write(&failing, "@echo off\r\necho broken\r\nexit /b 7\r\n").unwrap();
        assert_eq!(checked_cli_at("codex", &failing), CliCheck::Unknown("exited with code 7".into()));
    }

    #[test]
    fn version_probe_reports_timeout_and_kills_the_process_tree() {
        static READERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let f = Fixture::new();
        let script = f.config("slow.cmd");
        std::fs::write(&script, "@echo off\r\nping -n 30 127.0.0.1 >nul\r\necho 2.1.1\r\n").unwrap();
        let mut command = std::process::Command::new(&script);
        command.arg("--version");
        let started = std::time::Instant::now();
        let result = checked_cli_command_limited("kimi-code", command, &READERS, std::time::Duration::from_secs(1));
        assert_eq!(result, CliCheck::Unknown("timed out after 1s".into()));
        assert!(started.elapsed() < std::time::Duration::from_secs(5), "{:?}", started.elapsed());
        let until = std::time::Instant::now() + std::time::Duration::from_secs(3);
        while READERS.load(Ordering::Acquire) != 0 && std::time::Instant::now() < until {
            std::thread::sleep(std::time::Duration::from_millis(10));
        }
        assert_eq!(READERS.load(Ordering::Acquire), 0, "killing the job must release the reader");
    }

    #[test]
    fn successful_version_checks_are_cached_per_executable_until_it_changes() {
        let f = Fixture::new();
        let exe = f.config("cached-cli.cmd");
        std::fs::write(&exe, "@echo 2.1.1\r\n").unwrap();
        let calls = std::cell::Cell::new(0);
        let probe = |result: CliCheck| {
            calls.set(calls.get() + 1);
            result
        };
        let tested = CliCheck::Tested("2.1.1".into());
        assert_eq!(checked_cli_cached("kimi-code", &exe, || probe(tested.clone())), tested);
        assert_eq!(checked_cli_cached("kimi-code", &exe, || probe(CliCheck::Unknown("respawned".into()))), tested);
        assert_eq!(calls.get(), 1, "a cached success must not respawn the CLI");
        std::fs::write(&exe, "@echo 2.1.2 and more bytes\r\n").unwrap();
        let newer = CliCheck::Untested("2.1.2".into());
        assert_eq!(checked_cli_cached("kimi-code", &exe, || probe(newer.clone())), newer);
        assert_eq!(calls.get(), 2, "a changed executable must be probed again");
        let other = f.config("other-cli.cmd");
        std::fs::write(&other, "@echo 2.1.1\r\n").unwrap();
        let failed = CliCheck::Unknown("timed out after 5s".into());
        assert_eq!(checked_cli_cached("kimi-code", &other, || probe(failed.clone())), failed);
        assert_eq!(checked_cli_cached("kimi-code", &other, || probe(tested.clone())), tested);
        assert_eq!(calls.get(), 4, "failures are never cached");
    }

    const DELAYED_EXIT_ROLE: &str = "COUCOU_VERSION_PROBE_DELAYED_EXIT";

    // Runs before libtest's main so the role's stdout contains only the version line.
    #[used]
    #[link_section = ".CRT$XCU"]
    static DELAYED_EXIT_INIT: extern "C" fn() = delayed_exit_role;

    extern "C" fn delayed_exit_role() {
        let Some(marker) = std::env::var_os(DELAYED_EXIT_ROLE) else { return };
        extern "system" {
            fn GetStdHandle(kind: u32) -> *mut std::ffi::c_void;
            fn WriteFile(handle: *mut std::ffi::c_void, buffer: *const std::ffi::c_void, length: u32, written: *mut u32, overlapped: *mut std::ffi::c_void) -> i32;
            fn CloseHandle(handle: *mut std::ffi::c_void) -> i32;
        }
        let closed = unsafe {
            let handle = GetStdHandle(-11i32 as u32);
            let mut written = 0;
            let bytes = b"2.1.1\n";
            handle as isize != -1
                && !handle.is_null()
                && WriteFile(handle, bytes.as_ptr().cast(), bytes.len() as u32, &mut written, std::ptr::null_mut()) != 0
                && written as usize == bytes.len()
                && CloseHandle(handle) != 0
        };
        if !closed { std::process::exit(3) }
        if std::fs::write(marker, b"closed").is_err() { std::process::exit(4) }
        std::thread::sleep(std::time::Duration::from_millis(500));
        std::process::exit(0);
    }

    #[test]
    fn version_probe_accepts_eof_before_delayed_successful_exit() {
        let f = Fixture::new();
        let marker = f.config("stdout-closed");
        let mut command = std::process::Command::new(std::env::current_exe().unwrap());
        command.env(DELAYED_EXIT_ROLE, &marker);
        let started = std::time::Instant::now();
        let result = checked_cli_command("kimi-code", command);
        assert!(marker.exists(), "child never closed stdout before exiting");
        assert!(started.elapsed() >= std::time::Duration::from_millis(450));
        assert_eq!(result, CliCheck::Tested("2.1.1".into()));
    }

    #[test]
    fn version_probe_rejects_descendant_holding_stdout_without_waiting_for_eof() {
        let role = std::env::var_os("COUCOU_VERSION_PROBE_ROLE");
        if let Some(role) = role.as_deref() {
            let marker = PathBuf::from(std::env::var_os("COUCOU_VERSION_PROBE_MARKER").unwrap());
            let release = PathBuf::from(std::env::var_os("COUCOU_VERSION_PROBE_RELEASE").unwrap());
            if role == "descendant" {
                std::fs::write(&marker, b"ready").unwrap();
                let until = std::time::Instant::now() + std::time::Duration::from_secs(7);
                while !release.exists() && std::time::Instant::now() < until {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
            } else {
                println!("2.1.1");
                std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", "agent_hooks::tests::version_probe_rejects_descendant_holding_stdout_without_waiting_for_eof", "--nocapture"])
                    .env("COUCOU_VERSION_PROBE_ROLE", "descendant")
                    .stdout(std::process::Stdio::inherit())
                    .spawn()
                    .unwrap();
                let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
                while !marker.exists() && std::time::Instant::now() < until {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                assert!(marker.exists(), "descendant never inherited stdout");
            }
            return;
        }

        let f = Fixture::new();
        let marker = f.config("descendant-ready");
        let release = f.config("release-descendant");
        struct Release(PathBuf);
        impl Drop for Release {
            fn drop(&mut self) {
                let _ = std::fs::write(&self.0, b"release");
            }
        }
        let _release = Release(release.clone());
        let script = f.config("version-probe.cmd");
        std::fs::write(
            &script,
            format!(
                "@echo off\r\nset \"COUCOU_VERSION_PROBE_ROLE=direct\"\r\nset \"COUCOU_VERSION_PROBE_MARKER={}\"\r\nset \"COUCOU_VERSION_PROBE_RELEASE={}\"\r\n\"{}\" --exact agent_hooks::tests::version_probe_rejects_descendant_holding_stdout_without_waiting_for_eof --nocapture\r\n",
                marker.display(), release.display(), std::env::current_exe().unwrap().display()
            ),
        ).unwrap();
        let start = std::time::Instant::now();
        let result = checked_cli_at("kimi-code", &script);
        let elapsed = start.elapsed();
        assert!(marker.exists(), "descendant never opened the inherited stdout");
        let CliCheck::Unknown(reason) = &result else { panic!("unexpected {result:?}") };
        assert!(!reason.is_empty());
        assert!(
            elapsed < std::time::Duration::from_secs(4),
            "probe waited {elapsed:?} for a descendant's stdout"
        );
    }

    #[test]
    fn version_probe_caps_readers_until_descendants_release_stdout() {
        const ROLE: &str = "COUCOU_VERSION_PROBE_HOLD_ROLE";
        if let Some(role) = std::env::var_os(ROLE) {
            let root = PathBuf::from(std::env::var_os("COUCOU_VERSION_PROBE_ROOT").unwrap());
            let release = root.join("release");
            if role == "descendant" {
                std::fs::write(root.join(format!("ready-{}", std::process::id())), b"ready").unwrap();
                let until = std::time::Instant::now() + std::time::Duration::from_secs(30);
                while !release.exists() && std::time::Instant::now() < until {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
            } else {
                println!("2.1.1");
                let descendant = std::process::Command::new(std::env::current_exe().unwrap())
                    .args(["--exact", "agent_hooks::tests::version_probe_caps_readers_until_descendants_release_stdout", "--nocapture"])
                    .env(ROLE, "descendant")
                    .stdout(std::process::Stdio::inherit())
                    .spawn().unwrap();
                std::fs::write(root.join(format!("launched-{}", descendant.id())), b"launched").unwrap();
                let ready = root.join(format!("ready-{}", descendant.id()));
                let until = std::time::Instant::now() + std::time::Duration::from_secs(2);
                while !ready.exists() && std::time::Instant::now() < until {
                    std::thread::sleep(std::time::Duration::from_millis(10));
                }
                assert!(ready.exists(), "descendant never held stdout");
            }
            return;
        }
        let f = Fixture::new();
        let release = f.config("release");
        struct Release(PathBuf);
        impl Drop for Release {
            fn drop(&mut self) { let _ = std::fs::write(&self.0, b"release"); }
        }
        let _release = Release(release.clone());
        let script = f.config("held-probe.cmd");
        std::fs::write(&script, format!(
            "@echo off\r\nset \"{ROLE}=direct\"\r\nset \"COUCOU_VERSION_PROBE_ROOT={}\"\r\n\"{}\" --exact agent_hooks::tests::version_probe_caps_readers_until_descendants_release_stdout --nocapture\r\n",
            f.0.display(), std::env::current_exe().unwrap().display()
        )).unwrap();
        static READERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let probe = |script: &Path| {
            let mut command = std::process::Command::new(script);
            command.arg("--version");
            checked_cli_command_limited("kimi-code", command, &READERS, std::time::Duration::from_secs(5))
        };
        for _ in 0..3 {
            let result = probe(&script);
            assert!(matches!(result, CliCheck::Unknown(_)), "{result:?}");
            let until = std::time::Instant::now() + std::time::Duration::from_secs(3);
            while READERS.load(Ordering::Acquire) != 0 && std::time::Instant::now() < until {
                std::thread::sleep(std::time::Duration::from_millis(10));
            }
            assert_eq!(READERS.load(Ordering::Acquire), 0, "the job must kill descendants holding stdout");
        }
        let launched = || std::fs::read_dir(&f.0).unwrap().filter(|item| {
            item.as_ref().unwrap().file_name().to_string_lossy().starts_with("launched-")
        }).count();
        assert_eq!(launched(), 3, "every probe may launch after descendants are reaped");
        let recovered = f.config("recovered-probe.cmd");
        std::fs::write(&recovered, "@echo 2.1.1\r\n").unwrap();
        assert_eq!(probe(&recovered), CliCheck::Tested("2.1.1".into()));
    }

    #[test]
    #[ignore = "reads real status on this machine; never writes configs"]
    fn real_status_report() {
        for agent in ["kimi-code", "codex", "hermes"] {
            match status(agent) {
                Ok(s) => println!(
                    "{agent}: configured={} version={:?} state={} path={} detail={:?}",
                    s.configured, s.version, s.version_state, s.settings_path, s.detail
                ),
                Err(e) => println!("{agent}: ERR {e}"),
            }
        }
    }

    #[test]
    #[ignore = "runs the real kimi/codex/hermes --version on this machine; never writes configs"]
    fn real_cli_version_probe() {
        for round in 0..2 {
            for agent in ["kimi-code", "codex", "hermes"] {
                let exe = provider(agent).unwrap().0;
                let started = std::time::Instant::now();
                let check = checked_cli(agent);
                println!(
                    "round {round} {agent}: path={:?} state={} version={:?} reason={:?} warning={:?} in {:?}",
                    crate::find_on_path(exe), check.state(), check.version(), check.reason(), check.warning(agent), started.elapsed()
                );
                assert_ne!(check, CliCheck::Missing, "{agent} must be on PATH for this check");
                assert!(!matches!(check, CliCheck::Unknown(_)), "{agent}: {check:?}");
            }
        }
    }

    #[test]
    fn version_probe_caps_readers_when_descendants_escape_the_job() {
        static READERS: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);
        let held: Vec<_> = (0..MAX_VERSION_READERS)
            .map(|_| VersionReaderPermit::acquire(&READERS).unwrap())
            .collect();
        let f = Fixture::new();
        let script = f.config("never-run.cmd");
        std::fs::write(&script, format!("@echo off\r\necho ran> \"{}\"\r\necho 2.1.1\r\n", f.config("ran").display())).unwrap();
        let mut command = std::process::Command::new(&script);
        command.arg("--version");
        let result = checked_cli_command_limited("kimi-code", command, &READERS, std::time::Duration::from_secs(5));
        let CliCheck::Unknown(reason) = result else { panic!("unexpected {result:?}") };
        assert!(reason.contains("still holding output open"), "{reason}");
        assert!(!f.config("ran").exists(), "a saturated agent must not spawn more readers");
        drop(held);
        let mut command = std::process::Command::new(&script);
        command.arg("--version");
        assert_eq!(
            checked_cli_command_limited("kimi-code", command, &READERS, std::time::Duration::from_secs(5)),
            CliCheck::Tested("2.1.1".into())
        );
    }

    #[test]
    fn hermes_custom_home_resolves_active_profile() {
        let f = Fixture::new();
        let root = f.config("custom-hermes-home");
        std::fs::create_dir_all(&root).unwrap();
        std::fs::write(root.join("active_profile"), "work\n").unwrap();
        assert_eq!(hermes_config_path(&root).unwrap(), root.join("profiles/work/config.yaml"));
        std::fs::write(root.join("active_profile"), "default\n").unwrap();
        assert_eq!(hermes_config_path(&root).unwrap(), root.join("config.yaml"));
    }

    #[test]
    fn hermes_preserves_foreign_hook_and_maps_turn_and_finalize() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let original = "model: example\nhooks:\n  foreign_event:\n    - command: 'other.exe'\n  outbound:\n    - url: https://example.org\nother: value\n";
        std::fs::write(&path, original).unwrap();
        let p = preview_at("hermes", true, &path, &f.relay()).unwrap();
        apply_at("hermes", true, &p.fingerprint, &path, &f.relay()).unwrap();
        let next = std::fs::read_to_string(&path).unwrap();
        assert!(next.contains("on_session_end:"));
        assert!(next.contains("on_session_finalize:"));
        assert!(next.contains("--agent hermes on_session_end"));
        assert!(next.contains("--agent hermes on_session_finalize"));
        assert!(next.contains("- command: 'other.exe'"));
        assert!(next.contains("other: value"));
        let p = preview_at("hermes", false, &path, &f.relay()).unwrap();
        apply_at("hermes", false, &p.fingerprint, &path, &f.relay()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn preview_never_exposes_unrelated_config_values() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let original = "secret_key = 'private-token-123'\nmodel = 'existing'\n";
        std::fs::write(&path, original).unwrap();
        let p = preview_at("kimi-code", true, &path, &f.relay()).unwrap();
        assert!(!p.diff.contains("private-token-123"));
        assert!(!p.diff.contains("existing"));
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn hermes_keeps_existing_same_event_and_refuses_to_remove_modified_managed_commands() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let original = "hooks:\n  on_session_end:\n    - command: 'foreign-end.exe'\n    # keep-end\n  pre_tool_call:\n    - command: 'foreign-tool.exe'\n    # keep-tool\n";
        std::fs::write(&path, original).unwrap();
        let preview = preview_at("hermes", true, &path, &f.relay()).unwrap();
        assert!(!preview.diff.contains("foreign-end.exe"));
        assert!(!preview.diff.contains("foreign-tool.exe"));
        assert!(preview.diff.contains("merged on_session_end"));
        assert!(preview.diff.contains("merged pre_tool_call"));
        apply_at("hermes", true, &preview.fingerprint, &path, &f.relay()).unwrap();
        let installed = std::fs::read_to_string(&path).unwrap();
        let value: Yaml = serde_yaml::from_str(&installed).unwrap();
        for (event, foreign) in [
            ("on_session_end", "foreign-end.exe"),
            ("pre_tool_call", "foreign-tool.exe"),
        ] {
            let entries = value["hooks"][event].as_sequence().unwrap();
            assert_eq!(entries.len(), 2);
            assert_eq!(entries[0]["command"].as_str(), Some(foreign));
            assert!(entries[1]["command"]
                .as_str()
                .unwrap()
                .contains(&format!("--agent hermes {event}")));
        }
        let removal = preview_at("hermes", false, &path, &f.relay()).unwrap();
        apply_at("hermes", false, &removal.fingerprint, &path, &f.relay()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        std::fs::write(&path, original).unwrap();
        let p = preview_at("hermes", true, &path, &f.relay()).unwrap();
        apply_at("hermes", true, &p.fingerprint, &path, &f.relay()).unwrap();
        let altered = std::fs::read_to_string(&path)
            .unwrap()
            .replace("--agent hermes on_session_end", "--agent hermes changed");
        std::fs::write(&path, &altered).unwrap();
        assert!(preview_at("hermes", false, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), altered);
        let nonoverlapping = "hooks:\n  foreign_event:\n    - command: 'foreign.exe'\n";
        std::fs::write(&path, nonoverlapping).unwrap();
        let p = preview_at("hermes", true, &path, &f.relay()).unwrap();
        apply_at("hermes", true, &p.fingerprint, &path, &f.relay()).unwrap();
        let modified = std::fs::read_to_string(&path)
            .unwrap()
            .replace("--agent hermes pre_llm_call", "--agent hermes changed");
        std::fs::write(&path, &modified).unwrap();
        assert!(preview_at("hermes", false, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), modified);
    }

    #[test]
    fn hermes_overlap_preview_shows_exact_owned_commands_on_install_and_remove() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let relay = f.relay();
        let original = "hooks:\n  on_session_end:\n    - command: 'foreign-end.exe'\n    # keep-end\n  pre_tool_call:\n    - command: 'foreign-tool.exe'\n    # keep-tool\n";
        std::fs::write(&path, original).unwrap();
        let install = preview_at("hermes", true, &path, &relay).unwrap();
        assert!(!install.diff.contains("foreign-end.exe"));
        assert!(!install.diff.contains("foreign-tool.exe"));
        assert!(!install.diff.contains("keep-end"));
        assert!(!install.diff.contains("keep-tool"));
        apply_at("hermes", true, &install.fingerprint, &path, &relay).unwrap();
        let installed = std::fs::read_to_string(&path).unwrap();
        for event in ["on_session_end", "pre_tool_call"] {
            let entry = format!(
                "{MERGED}{event}\n    - command: {}\n      timeout: 3\n",
                escaped(&command(&relay, "hermes", event).unwrap())
            );
            assert!(installed.contains(&entry));
            let displayed = entry
                .lines()
                .map(|line| format!("+ {line}\n"))
                .collect::<String>();
            assert!(
                install.diff.contains(&displayed),
                "install preview missed {event}: {}",
                install.diff
            );
        }
        let remove = preview_at("hermes", false, &path, &relay).unwrap();
        assert!(!remove.diff.contains("foreign-end.exe"));
        assert!(!remove.diff.contains("foreign-tool.exe"));
        for event in ["on_session_end", "pre_tool_call"] {
            let entry = format!(
                "{MERGED}{event}\n    - command: {}\n      timeout: 3\n",
                escaped(&command(&relay, "hermes", event).unwrap())
            );
            let displayed = entry
                .lines()
                .map(|line| format!("- {line}\n"))
                .collect::<String>();
            assert!(
                remove.diff.contains(&displayed),
                "removal preview missed {event}: {}",
                remove.diff
            );
        }
        apply_at("hermes", false, &remove.fingerprint, &path, &relay).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn hermes_allows_single_foreign_key_without_a_hooks_list() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let original = "model: example\nhooks:\n  foreign_event:\n    - command: 'foreign.exe'\n";
        std::fs::write(&path, original).unwrap();
        let preview = preview_at("hermes", true, &path, &f.relay()).unwrap();
        assert!(!preview.diff.contains("foreign.exe"));
        apply_at("hermes", true, &preview.fingerprint, &path, &f.relay()).unwrap();
        let installed = std::fs::read_to_string(&path).unwrap();
        assert!(installed.contains("foreign.exe"));
        let removal = preview_at("hermes", false, &path, &f.relay()).unwrap();
        apply_at("hermes", false, &removal.fingerprint, &path, &f.relay()).unwrap();
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn hermes_existing_hooks_without_final_newline_are_refused_without_writing() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let original = b"hooks:\n  pre_tool_call:\n    - command: 'foreign.exe'";
        std::fs::write(&path, original).unwrap();
        assert!(preview_at("hermes", true, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
    }

    #[test]
    fn hermes_rejects_foreign_collision_after_install() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        let p = preview_at("hermes", true, &path, &f.relay()).unwrap();
        apply_at("hermes", true, &p.fingerprint, &path, &f.relay()).unwrap();
        let altered = std::fs::read_to_string(&path).unwrap()
            + "hooks:\n  on_session_end:\n    - command: 'foreign-end.exe'\n";
        std::fs::write(&path, &altered).unwrap();
        assert!(preview_at("hermes", false, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), altered);
    }

    #[test]
    fn malformed_marker_and_yaml_block_are_rejected() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let original = format!("# {START} not a marker\n");
        std::fs::write(&path, &original).unwrap();
        assert!(preview_at("kimi-code", true, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        let path = f.config("config.yaml");
        let original = "hooks:\n  foreign_event:\n    - command: 'foreign.exe'";
        std::fs::write(&path, original).unwrap();
        assert!(preview_at("hermes", true, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
    }

    #[test]
    fn hermes_rejects_unowned_event_formatting_without_writing() {
        let f = Fixture::new();
        let path = f.config("config.yaml");
        for original in [
            "hooks:\n  'pre_tool_call':\n    - command: 'foreign.exe'\n",
            "hooks:\n  pre_tool_call: {}\n",
            "hooks: {pre_tool_call: [{command: 'foreign.exe'}]}\n",
            "hooks:\n  on_session_start: &a []\n  pre_tool_call: *a\n",
            "hooks:\n  pre_tool_call:\n    - command: 'foreign.exe'\n  pre_tool_call:\n    - command: 'duplicate.exe'\n",
            "hooks:\n  pre_tool_call: [{command: 'foreign.exe'}]\n",
            "hooks:\n  pre_tool_call:\n    - command: 'foreign.exe'\n    # coucou-agent-hooks merged pre_tool_call\n",
        ] {
            std::fs::write(&path, original).unwrap();
            assert!(preview_at("hermes", true, &path, &f.relay()).is_err(), "accepted: {original}");
            assert_eq!(std::fs::read_to_string(&path).unwrap(), original);
        }
    }

    #[test]
    fn installing_without_relay_fails_without_creating_config() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        let absent = f.config("absent relay.exe");
        let p = preview_at("codex", true, &path, &absent).unwrap();
        assert!(!p.hook_ready);
        assert!(apply_at("codex", true, &p.fingerprint, &path, &absent).is_err());
        assert!(!path.exists());
    }

    #[test]
    fn no_file_preview_is_read_only_and_uninstall_is_noop() {
        let f = Fixture::new();
        let path = f.config("missing.toml");
        let p = preview_at("kimi-code", false, &path, &f.relay()).unwrap();
        assert_eq!(p.diff, "No change.");
        assert!(
            apply_at("kimi-code", false, &p.fingerprint, &path, &f.relay())
                .unwrap()
                .is_empty()
        );
        assert!(!path.exists());
        let p = preview_at("kimi-code", true, &path, &f.relay()).unwrap();
        assert!(!path.exists());
        assert!(
            apply_at("kimi-code", true, &p.fingerprint, &path, &f.relay())
                .unwrap()
                .is_empty()
        );
        assert!(path.exists());
    }

    #[test]
    fn malformed_encoding_and_syntax_and_modified_managed_block_are_refused() {
        let f = Fixture::new();
        for (agent, name, bad) in [
            ("kimi-code", "kimi.toml", b"\xff\xfe".as_slice()),
            ("codex", "codex.toml", b"[hooks.Stop\n".as_slice()),
            (
                "hermes",
                "hermes.yaml",
                b"hooks: [unterminated\n".as_slice(),
            ),
        ] {
            let path = f.config(name);
            std::fs::write(&path, bad).unwrap();
            assert!(preview_at(agent, true, &path, &f.relay()).is_err());
            assert_eq!(std::fs::read(&path).unwrap(), bad);
        }
        let path = f.config("managed.toml");
        let p = preview_at("kimi-code", true, &path, &f.relay()).unwrap();
        apply_at("kimi-code", true, &p.fingerprint, &path, &f.relay()).unwrap();
        let changed = std::fs::read_to_string(&path)
            .unwrap()
            .replace("--agent kimi-code Stop", "--agent kimi-code Evil");
        std::fs::write(&path, &changed).unwrap();
        assert!(preview_at("kimi-code", false, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), changed);
    }

    #[test]
    fn preview_authorizes_only_its_agent_operation_destination_and_relay() {
        let f = Fixture::new();
        let first = f.config("profile-one.toml");
        let second = f.config("profile-two.toml");
        let relay = f.relay();
        let preview = preview_at("kimi-code", true, &first, &relay).unwrap();
        let other_relay = f.config("another relay.exe");
        std::fs::write(&other_relay, b"relay fixture").unwrap();
        for (agent, install, target, executable) in [
            ("kimi-code", true, second.as_path(), relay.as_path()),
            ("codex", true, first.as_path(), relay.as_path()),
            ("kimi-code", false, first.as_path(), relay.as_path()),
            ("kimi-code", true, first.as_path(), other_relay.as_path()),
        ] {
            assert!(apply_at(agent, install, &preview.fingerprint, target, executable).is_err());
            assert!(!target.exists());
        }
        assert!(!first.exists());
    }

    #[test]
    fn uninstall_restores_configs_without_final_newline_byte_for_byte() {
        let f = Fixture::new();
        let relay = f.relay();
        for (agent, name, original) in [
            ("kimi-code", "kimi.toml", "model = 'private'"),
            ("codex", "codex.toml", "model = 'private'"),
            ("hermes", "hermes.yaml", "model: private"),
        ] {
            let path = f.config(name);
            std::fs::write(&path, original).unwrap();
            let install = preview_at(agent, true, &path, &relay).unwrap();
            assert!(!install.diff.contains("private"));
            apply_at(agent, true, &install.fingerprint, &path, &relay).unwrap();
            let remove = preview_at(agent, false, &path, &relay).unwrap();
            apply_at(agent, false, &remove.fingerprint, &path, &relay).unwrap();
            assert_eq!(
                std::fs::read(&path).unwrap(),
                original.as_bytes(),
                "{agent}"
            );
        }
    }

    #[test]
    fn preview_shows_added_separator_when_original_lacks_final_newline() {
        let f = Fixture::new();
        let relay = f.relay();
        for (agent, name, original) in [
            ("kimi-code", "kimi.toml", "model = 'private'"),
            ("codex", "codex.toml", "model = 'private'"),
            ("hermes", "hermes.yaml", "model: private"),
        ] {
            let path = f.config(name);
            std::fs::write(&path, original).unwrap();
            let preview = preview_at(agent, true, &path, &relay).unwrap();
            assert!(
                preview
                    .diff
                    .contains("+ <final newline added before Coucou hooks>\n"),
                "{agent}: {}",
                preview.diff
            );
            assert!(!preview.diff.contains("private"));
            let installed = patch(agent, original, true, &relay).unwrap();
            assert!(
                installed.starts_with(&format!("{original}\n{START}\n"))
                    || installed.starts_with(&format!("{original}\nhooks:\n{START}\n"))
                    || (agent == "codex"
                        && installed.starts_with(&format!("{original}\n\n{START}\n{NO_FINAL_NEWLINE}{BLANK_ADDED}")))
            );
        }
    }

    #[test]
    fn exclusive_existing_file_denies_competing_writers_and_refuses_contention() {
        let f = Fixture::new();
        let path = f.config("locked.toml");
        let original = b"model = 'original'\n";
        std::fs::write(&path, original).unwrap();
        let relay = f.relay();
        let preview = preview_at("kimi-code", true, &path, &relay).unwrap();
        let busy = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(apply_at("kimi-code", true, &preview.fingerprint, &path, &relay).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), original);
        drop(busy);
        let backup = apply_at("kimi-code", true, &preview.fingerprint, &path, &relay).unwrap();
        assert_eq!(std::fs::read(&backup).unwrap(), original);
        let removal = preview_at("kimi-code", false, &path, &relay).unwrap();
        let busy = OpenOptions::new().read(true).open(&path).unwrap();
        assert!(apply_at("kimi-code", false, &removal.fingerprint, &path, &relay).is_err());
        drop(busy);
        apply_at("kimi-code", false, &removal.fingerprint, &path, &relay).unwrap();
        assert_eq!(std::fs::read(&path).unwrap(), original);
    }

    #[test]
    fn absent_target_never_replaces_competing_creation() {
        let f = Fixture::new();
        let path = f.config("new.toml");
        let relay = f.relay();
        let preview = preview_at("codex", true, &path, &relay).unwrap();
        let competing = b"model = 'someone-else'\n";
        std::fs::write(&path, competing).unwrap();
        assert!(apply_at("codex", true, &preview.fingerprint, &path, &relay).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), competing);
    }

    #[test]
    fn stale_preview_and_path_quoting_and_overlong_commands_are_safe() {
        let f = Fixture::new();
        let path = f.config("config.toml");
        std::fs::write(&path, "theme = 'dark'\n").unwrap();
        let p = preview_at("codex", true, &path, &f.relay()).unwrap();
        std::fs::write(&path, "theme = 'light'\n").unwrap();
        assert!(apply_at("codex", true, &p.fingerprint, &path, &f.relay()).is_err());
        assert_eq!(std::fs::read_to_string(&path).unwrap(), "theme = 'light'\n");
        let quoted = f.0.join("bad\"name.exe");
        assert!(preview_at("codex", true, &path, &quoted).is_err());
        let long = f.0.join("x".repeat(8300));
        assert!(preview_at("codex", true, &path, &long).is_err());
        assert!(preview_at("unknown", true, &path, &f.relay()).is_err());
    }
}
