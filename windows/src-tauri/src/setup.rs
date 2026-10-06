// One-step agent setup: find which agents this user has, then install (or
// remove) Coucou's hooks for each of them with the same preview → backup →
// write path the Settings buttons use. Shared by the Settings button and by
// `coucou.exe --setup-agents` / `--remove-agents`.
//
// An agent that is not detected is skipped: Coucou never creates a config for
// an agent the user does not have.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::agent_hooks::{self, Profile};
use crate::hooks;

pub const AGENTS: &[&str] = &["claude", "codex", "kimi-code", "hermes"];

pub fn label(agent: &str) -> &'static str {
    match agent {
        "claude" => "Claude Code",
        "codex" => "Codex",
        "kimi-code" => "Kimi Code",
        "hermes" => "Hermes",
        _ => "Unknown agent",
    }
}

fn cli_name(agent: &str) -> &'static str {
    match agent {
        "claude" => "claude",
        "codex" => "codex",
        "kimi-code" => "kimi",
        "hermes" => "hermes",
        _ => "",
    }
}

#[derive(Clone, Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Detection {
    pub agent: String,
    pub label: String,
    pub cli: Option<PathBuf>,
    pub desktop: Option<PathBuf>,
    pub config_dir: Option<PathBuf>,
    pub found: bool,
}

impl Detection {
    /// "CLI, desktop app" — how the agent was found, for the report.
    pub fn signals(&self) -> String {
        let mut out = Vec::new();
        if self.cli.is_some() {
            out.push("CLI");
        }
        if self.desktop.is_some() {
            out.push("desktop app");
        }
        if self.config_dir.is_some() {
            out.push("config folder");
        }
        out.join(", ")
    }
}

fn dir(path: PathBuf) -> Option<PathBuf> {
    path.is_dir().then_some(path)
}

fn under(base: &Path, rest: &str) -> Option<PathBuf> {
    if base.as_os_str().is_empty() {
        return None;
    }
    Some(base.join(rest))
}

/// A Microsoft Store package folder whose name starts with `prefix`
/// (e.g. `Claude_pzs8sxrjxfjjc`) in %LOCALAPPDATA%\Packages.
fn store_package(profile: &Profile, prefix: &str) -> Option<PathBuf> {
    let packages = under(&profile.local_app_data, "Packages")?;
    let mut found: Vec<PathBuf> = std::fs::read_dir(packages)
        .ok()?
        .filter_map(Result::ok)
        .filter(|e| e.file_name().to_string_lossy().starts_with(prefix))
        .map(|e| e.path())
        .filter(|p| p.is_dir())
        .collect();
    found.sort();
    found.into_iter().next()
}

/// Whether `agent` is on this machine: its CLI on PATH, its desktop app, or
/// its config folder. Read-only: nothing is created or spawned.
pub fn detect_agent(agent: &str, profile: &Profile) -> Detection {
    let cli = profile.find_cli(cli_name(agent));
    let home = |rest: &str| under(&profile.home, rest).and_then(dir);
    let (desktop, config_dir) = match agent {
        "claude" => (
            store_package(profile, "Claude_")
                .or_else(|| under(&profile.local_app_data, "AnthropicClaude").and_then(dir)),
            home(".claude"),
        ),
        "codex" => (store_package(profile, "OpenAI.Codex_"), home(".codex")),
        "kimi-code" => (
            under(&profile.local_app_data, r"Programs\Kimi Code\Kimi Code.exe").filter(|p| p.is_file()),
            home(".kimi-code"),
        ),
        "hermes" => (
            None,
            profile
                .hermes_home
                .clone()
                .and_then(dir)
                .or_else(|| home(".hermes"))
                .or_else(|| under(&profile.local_app_data, "hermes").and_then(dir)),
        ),
        _ => (None, None),
    };
    let found = cli.is_some() || desktop.is_some() || config_dir.is_some();
    Detection {
        agent: agent.to_string(),
        label: label(agent).to_string(),
        cli,
        desktop,
        config_dir,
        found,
    }
}

pub fn detect_all(profile: &Profile) -> Vec<Detection> {
    AGENTS.iter().map(|a| detect_agent(a, profile)).collect()
}

fn claude_settings(profile: &Profile) -> PathBuf {
    profile.home.join(".claude").join("settings.json")
}

/// Whether Coucou's hooks are already in this agent's config.
pub fn configured(agent: &str, profile: &Profile) -> Result<bool, String> {
    if agent == "claude" {
        hooks::installed_at(&claude_settings(profile))
    } else {
        agent_hooks::configured_in(agent, profile)
    }
}

/// Detected agents that are not configured yet — what the first-launch offer
/// lists. Errors count as "not configured" so the user gets to see them.
pub fn unconfigured_detected(profile: &Profile) -> Vec<String> {
    detect_all(profile)
        .into_iter()
        .filter(|d| d.found && !configured(&d.agent, profile).unwrap_or(false))
        .map(|d| d.label)
        .collect()
}

// ── Results ───────────────────────────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Outcome {
    Installed,
    AlreadySetUp,
    WouldInstall,
    Removed,
    WouldRemove,
    NotInstalled,
    Skipped,
    Error,
}

impl Outcome {
    pub fn text(self) -> &'static str {
        match self {
            Self::Installed => "installed",
            Self::AlreadySetUp => "already set up",
            Self::WouldInstall => "would install (dry run)",
            Self::Removed => "removed",
            Self::WouldRemove => "would remove (dry run)",
            Self::NotInstalled => "nothing to remove",
            Self::Skipped => "skipped: not found",
            Self::Error => "error",
        }
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentResult {
    pub agent: String,
    pub label: String,
    pub outcome: Outcome,
    pub message: String,
    pub detected_by: String,
    pub warning: String,
    pub settings_path: String,
    pub backup: String,
    pub follow_up: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SetupReport {
    pub action: String,
    pub dry_run: bool,
    pub relay: String,
    pub relay_ready: bool,
    pub relay_message: String,
    pub agents: Vec<AgentResult>,
    pub ok: bool,
}

impl SetupReport {
    /// 0 when nothing failed (skipped agents are fine), 1 otherwise.
    pub fn exit_code(&self) -> i32 {
        if self.ok { 0 } else { 1 }
    }
}

pub fn follow_up(agent: &str) -> &'static str {
    match agent {
        "claude" => "Restart Claude Code (open a new session; restart the Claude desktop app if you use it).",
        "codex" => "Restart Codex, then trust each Coucou hook: type /hooks in the Codex CLI, or approve them in the Codex / ChatGPT desktop app's hook review. Coucou never trusts hooks for you.",
        "kimi-code" => "Restart Kimi Code (the CLI and the desktop app).",
        "hermes" => "Restart Hermes and approve each Coucou hook when it asks, or run `hermes --accept-hooks` once if you agree to all of them.",
        _ => "",
    }
}

fn result(d: &Detection, outcome: Outcome) -> AgentResult {
    AgentResult {
        agent: d.agent.clone(),
        label: d.label.clone(),
        outcome,
        message: String::new(),
        detected_by: d.signals(),
        warning: String::new(),
        settings_path: String::new(),
        backup: String::new(),
        follow_up: String::new(),
    }
}

/// Stages the relay (unless `dry_run`) and reports where it stands.
fn relay_state(profile: &Profile, sources: &[PathBuf], dry_run: bool) -> (bool, String) {
    let dest = profile.relay();
    if dry_run {
        if dest.is_file() {
            return (true, "present".into());
        }
        return match sources.iter().find(|p| p.is_file()) {
            Some(src) => (true, format!("would be copied from {}", src.display())),
            None => (false, "missing, and no coucou-hook.exe next to coucou.exe".into()),
        };
    }
    match hooks::stage_relay(sources, &dest) {
        Ok(()) => (true, "ready".into()),
        Err(err) => (false, err),
    }
}

/// For every detected agent: preview the hook install, apply it with a backup
/// when something changes, and say what the user still has to do by hand.
/// Idempotent — a second run reports "already set up" and writes nothing.
pub fn setup_all_detected(profile: &Profile, relay_sources: &[PathBuf], dry_run: bool) -> SetupReport {
    let (relay_ready, relay_message) = relay_state(profile, relay_sources, dry_run);
    let relay = profile.relay();
    let mut agents = Vec::new();
    for d in detect_all(profile) {
        if !d.found {
            agents.push(result(&d, Outcome::Skipped));
            continue;
        }
        let mut r = result(&d, Outcome::Error);
        match install_one(&d.agent, profile, &relay, relay_ready, dry_run) {
            Ok(done) => {
                r.outcome = done.outcome;
                r.warning = done.warning;
                r.settings_path = done.settings_path;
                r.backup = done.backup;
                r.follow_up = follow_up(&d.agent).into();
            }
            Err(err) => r.message = err,
        }
        agents.push(r);
    }
    let ok = agents.iter().all(|a| a.outcome != Outcome::Error);
    SetupReport {
        action: "setup".into(),
        dry_run,
        relay: relay.to_string_lossy().into(),
        relay_ready,
        relay_message,
        agents,
        ok,
    }
}

struct Done {
    outcome: Outcome,
    warning: String,
    settings_path: String,
    backup: String,
}

fn install_one(agent: &str, profile: &Profile, relay: &Path, relay_ready: bool, dry_run: bool) -> Result<Done, String> {
    let (diff, fingerprint, warning, settings_path) = if agent == "claude" {
        let p = hooks::preview_at(true, &claude_settings(profile), relay)?;
        (p.diff, p.fingerprint, String::new(), p.settings_path)
    } else {
        let p = agent_hooks::preview_in(agent, true, profile)?;
        (p.diff, p.fingerprint, p.version_warning, p.settings_path)
    };
    let mut done = Done { outcome: Outcome::AlreadySetUp, warning, settings_path, backup: String::new() };
    if diff == "No change." {
        return Ok(done);
    }
    if dry_run {
        done.outcome = Outcome::WouldInstall;
        return Ok(done);
    }
    if !relay_ready || !relay.is_file() {
        return Err("Coucou relay (coucou-hook.exe) is unavailable; nothing was written.".into());
    }
    done.backup = if agent == "claude" {
        hooks::write_at(true, &fingerprint, &claude_settings(profile), relay)?
    } else {
        agent_hooks::apply_in(agent, true, &fingerprint, profile)?
    };
    done.outcome = Outcome::Installed;
    Ok(done)
}

/// Removes Coucou's hooks from every agent config that has them, with a
/// backup each time. Configs without Coucou entries are left alone.
pub fn remove_all(profile: &Profile, dry_run: bool) -> SetupReport {
    let relay = profile.relay();
    let mut agents = Vec::new();
    for d in detect_all(profile) {
        let mut r = result(&d, Outcome::Error);
        match remove_one(&d.agent, profile, dry_run) {
            Ok((outcome, settings_path, backup)) => {
                r.outcome = outcome;
                r.settings_path = settings_path;
                r.backup = backup;
                if outcome == Outcome::Removed {
                    r.follow_up = format!("Restart {} so it stops loading the removed hooks.", d.label);
                }
            }
            Err(err) => r.message = err,
        }
        agents.push(r);
    }
    let ok = agents.iter().all(|a| a.outcome != Outcome::Error);
    SetupReport {
        action: "remove".into(),
        dry_run,
        relay: relay.to_string_lossy().into(),
        relay_ready: relay.is_file(),
        relay_message: String::new(),
        agents,
        ok,
    }
}

fn remove_one(agent: &str, profile: &Profile, dry_run: bool) -> Result<(Outcome, String, String), String> {
    if !configured(agent, profile)? {
        return Ok((Outcome::NotInstalled, String::new(), String::new()));
    }
    let relay = profile.relay();
    let (fingerprint, path) = if agent == "claude" {
        let p = hooks::preview_at(false, &claude_settings(profile), &relay)?;
        (p.fingerprint, p.settings_path)
    } else {
        let p = agent_hooks::preview_in(agent, false, profile)?;
        (p.fingerprint, p.settings_path)
    };
    if dry_run {
        return Ok((Outcome::WouldRemove, path, String::new()));
    }
    let backup = if agent == "claude" {
        hooks::write_at(false, &fingerprint, &claude_settings(profile), &relay)?
    } else {
        agent_hooks::apply_in(agent, false, &fingerprint, profile)?
    };
    Ok((Outcome::Removed, path, backup))
}

// ── Report ────────────────────────────────────────────────────────────────────

pub fn report_path(profile: &Profile) -> PathBuf {
    profile.local_app_data.join("Coucou").join("setup-report.txt")
}

pub fn report_text(report: &SetupReport, stamp: &str) -> String {
    let mut out = String::new();
    let title = match (report.action.as_str(), report.dry_run) {
        ("remove", true) => "Coucou agent removal — DRY RUN (nothing was changed)",
        ("remove", false) => "Coucou agent removal",
        (_, true) => "Coucou agent setup — DRY RUN (nothing was changed)",
        _ => "Coucou agent setup",
    };
    out.push_str(&format!("{title}\r\n{stamp}\r\n\r\n"));
    if report.action == "setup" {
        out.push_str(&format!(
            "Relay: {} — {}\r\n\r\n",
            report.relay,
            if report.relay_message.is_empty() { "unknown" } else { &report.relay_message }
        ));
    }
    for a in &report.agents {
        out.push_str(&format!("{:<12} {}", a.label, a.outcome.text()));
        if !a.detected_by.is_empty() {
            out.push_str(&format!("  (found: {})", a.detected_by));
        }
        out.push_str("\r\n");
        if !a.message.is_empty() {
            out.push_str(&format!("             {}\r\n", a.message));
        }
        if !a.warning.is_empty() {
            out.push_str(&format!("             warning: {}\r\n", a.warning));
        }
        if !a.settings_path.is_empty() {
            out.push_str(&format!("             config: {}\r\n", a.settings_path));
        }
        if !a.backup.is_empty() {
            out.push_str(&format!("             backup: {}\r\n", a.backup));
        }
    }
    let follow: Vec<&AgentResult> = report.agents.iter().filter(|a| !a.follow_up.is_empty()).collect();
    if !follow.is_empty() {
        out.push_str("\r\nWhat to do next:\r\n");
        for (i, a) in follow.iter().enumerate() {
            out.push_str(&format!("  {}. {}: {}\r\n", i + 1, a.label, a.follow_up));
        }
    }
    out.push_str(&format!(
        "\r\nResult: {}\r\n",
        if report.ok { "OK" } else { "some agents failed — see the errors above" }
    ));
    out
}

/// Writes setup-report.txt next to the log. Coucou's own file, never an agent's.
/// The console `type` command and old code pages mangle non-ASCII punctuation,
/// so the report keeps to plain ASCII.
fn ascii_report(text: &str) -> String {
    text.chars()
        .map(|c| match c {
            '—' | '–' => '-',
            '‘' | '’' => '\'',
            '“' | '”' => '"',
            '…' => '.',
            '·' => '-',
            c if c.is_ascii() => c,
            _ => '?',
        })
        .collect()
}

pub fn write_report(profile: &Profile, text: &str) -> Result<PathBuf, String> {
    let text = &ascii_report(text);
    let path = report_path(profile);
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("could not create {}: {e}", dir.display()))?;
    }
    std::fs::write(&path, text.as_bytes()).map_err(|e| format!("could not write {}: {e}", path.display()))?;
    Ok(path)
}

pub fn local_stamp() -> String {
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!(
        "{:04}-{:02}-{:02} {:02}:{:02}:{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicU64, Ordering};

    #[test]
    fn report_text_is_plain_ascii() {
        let out = ascii_report("Relay: x — ready … ‘a’ “b”");
        assert!(out.is_ascii());
        assert_eq!(out, "Relay: x - ready . 'a' \"b\"");
    }


    static NEXT: AtomicU64 = AtomicU64::new(0);

    /// A throwaway USERPROFILE / LOCALAPPDATA / PATH. Nothing here ever reads
    /// or writes the real profile: every path goes through `profile`.
    struct Sandbox {
        root: PathBuf,
        profile: Profile,
        relay_source: PathBuf,
    }

    impl Sandbox {
        fn new() -> Self {
            let root = std::env::temp_dir().join(format!(
                "coucou-setup-{}-{}",
                std::process::id(),
                NEXT.fetch_add(1, Ordering::Relaxed)
            ));
            let _ = std::fs::remove_dir_all(&root);
            for d in ["home", "local", "bin", "install"] {
                std::fs::create_dir_all(root.join(d)).unwrap();
            }
            let relay_source = root.join("install").join("coucou-hook.exe");
            std::fs::write(&relay_source, b"relay fixture").unwrap();
            let profile = Profile {
                home: root.join("home"),
                local_app_data: root.join("local"),
                hermes_home: None,
                path: Some(root.join("bin").into_os_string()),
            };
            Self { root, profile, relay_source }
        }
        fn home(&self, rest: &str) -> PathBuf {
            self.profile.home.join(rest)
        }
        fn local(&self, rest: &str) -> PathBuf {
            self.profile.local_app_data.join(rest)
        }
        fn mkdir(&self, path: PathBuf) -> PathBuf {
            std::fs::create_dir_all(&path).unwrap();
            path
        }
        fn file(&self, path: PathBuf, bytes: &[u8]) -> PathBuf {
            std::fs::create_dir_all(path.parent().unwrap()).unwrap();
            std::fs::write(&path, bytes).unwrap();
            path
        }
        fn cli(&self, name: &str, version: &str) {
            self.file(self.root.join("bin").join(format!("{name}.cmd")), format!("@echo {version}\r\n").as_bytes());
        }
        fn sources(&self) -> Vec<PathBuf> {
            vec![self.relay_source.clone()]
        }
        fn run(&self, dry_run: bool) -> SetupReport {
            setup_all_detected(&self.profile, &self.sources(), dry_run)
        }
    }

    impl Drop for Sandbox {
        fn drop(&mut self) {
            let _ = std::fs::remove_dir_all(&self.root);
        }
    }

    fn outcome(report: &SetupReport, agent: &str) -> Outcome {
        report.agents.iter().find(|a| a.agent == agent).unwrap().outcome
    }

    fn agent<'a>(report: &'a SetupReport, agent: &str) -> &'a AgentResult {
        report.agents.iter().find(|a| a.agent == agent).unwrap()
    }

    fn tree(root: &Path) -> Vec<(PathBuf, Vec<u8>)> {
        let mut out = Vec::new();
        let mut stack = vec![root.to_path_buf()];
        while let Some(dir) = stack.pop() {
            for e in std::fs::read_dir(&dir).unwrap().flatten() {
                let p = e.path();
                if p.is_dir() {
                    out.push((p.clone(), Vec::new()));
                    stack.push(p);
                } else {
                    out.push((p.clone(), std::fs::read(&p).unwrap()));
                }
            }
        }
        out.sort();
        out
    }

    #[test]
    fn an_empty_profile_detects_nothing() {
        let s = Sandbox::new();
        for d in detect_all(&s.profile) {
            assert!(!d.found, "{}: {d:?}", d.agent);
        }
        let empty = Profile::default();
        assert!(detect_all(&empty).iter().all(|d| !d.found));
    }

    #[test]
    fn each_signal_alone_detects_its_agent() {
        type Make = fn(&Sandbox);
        let cases: &[(&str, &str, Make)] = &[
            ("claude", "config folder", |s| { s.mkdir(s.home(".claude")); }),
            ("claude", "desktop app", |s| { s.mkdir(s.local(r"Packages\Claude_pzs8sxrjxfjjc")); }),
            ("claude", "desktop app", |s| { s.mkdir(s.local("AnthropicClaude")); }),
            ("claude", "CLI", |s| s.cli("claude", "2.0.0")),
            ("codex", "config folder", |s| { s.mkdir(s.home(".codex")); }),
            ("codex", "desktop app", |s| { s.mkdir(s.local(r"Packages\OpenAI.Codex_2p2nqsd0c76g0")); }),
            ("codex", "CLI", |s| s.cli("codex", "codex-cli 0.157.0")),
            ("kimi-code", "config folder", |s| { s.mkdir(s.home(".kimi-code")); }),
            ("kimi-code", "desktop app", |s| { s.file(s.local(r"Programs\Kimi Code\Kimi Code.exe"), b"x"); }),
            ("kimi-code", "CLI", |s| s.cli("kimi", "2.1.1")),
            ("hermes", "config folder", |s| { s.mkdir(s.home(".hermes")); }),
            ("hermes", "config folder", |s| { s.mkdir(s.local("hermes")); }),
            ("hermes", "CLI", |s| s.cli("hermes", "Hermes Agent v0.21.5")),
        ];
        for (target, signal, make) in cases {
            let s = Sandbox::new();
            make(&s);
            for d in detect_all(&s.profile) {
                if d.agent == *target {
                    assert!(d.found, "{target} via {signal}");
                    assert_eq!(d.signals(), *signal, "{target}");
                } else {
                    assert!(!d.found, "{} must not be found by {target}'s {signal}", d.agent);
                }
            }
        }
    }

    #[test]
    fn look_alike_signals_do_not_count() {
        let s = Sandbox::new();
        // A file where a folder is expected, an unrelated package, a Kimi
        // folder without the app, HERMES_HOME pointing nowhere.
        s.file(s.home(".claude"), b"not a dir");
        s.mkdir(s.local(r"Packages\ClaudeOther"));
        s.mkdir(s.local(r"Packages\OpenAI.ChatGPT_x"));
        s.mkdir(s.local(r"Programs\Kimi Code"));
        let mut profile = s.profile.clone();
        profile.hermes_home = Some(s.root.join("missing-hermes-home"));
        assert!(detect_all(&profile).iter().all(|d| !d.found), "{:?}", detect_all(&profile));
        let custom = s.mkdir(s.root.join("custom-hermes"));
        profile.hermes_home = Some(custom.clone());
        assert_eq!(detect_agent("hermes", &profile).config_dir, Some(custom));
    }

    #[test]
    fn fresh_setup_installs_detected_agents_and_skips_the_rest() {
        let s = Sandbox::new();
        let claude_original = b"{\n  \"model\": \"opus\"\n}\n";
        let claude = s.file(s.home(r".claude\settings.json"), claude_original);
        let codex_original = b"model = 'x'\n";
        let codex = s.file(s.home(r".codex\config.toml"), codex_original);
        s.cli("codex", "codex-cli 0.157.0");

        let report = s.run(false);
        assert!(report.ok, "{report:#?}");
        assert!(report.relay_ready);
        assert_eq!(std::fs::read(s.profile.relay()).unwrap(), b"relay fixture");
        assert_eq!(outcome(&report, "claude"), Outcome::Installed);
        assert_eq!(outcome(&report, "codex"), Outcome::Installed);
        assert_eq!(outcome(&report, "kimi-code"), Outcome::Skipped);
        assert_eq!(outcome(&report, "hermes"), Outcome::Skipped);
        assert!(!s.home(".kimi-code").exists() && !s.home(".hermes").exists(), "missing agents got configs");
        assert!(!s.local("hermes").exists());

        assert!(std::fs::read_to_string(&claude).unwrap().contains("coucou-hook"));
        assert!(std::fs::read_to_string(&codex).unwrap().contains("--agent codex Stop"));
        assert_eq!(std::fs::read(&agent(&report, "claude").backup).unwrap(), claude_original);
        assert_eq!(std::fs::read(&agent(&report, "codex").backup).unwrap(), codex_original);
        assert!(agent(&report, "codex").follow_up.contains("/hooks"));
        assert!(agent(&report, "codex").warning.is_empty(), "tested CLI version: no warning");

        let text = report_text(&report, "now");
        assert!(text.contains("Claude Code  installed"), "{text}");
        assert!(text.contains("Kimi Code    skipped: not found"), "{text}");
        assert!(text.contains("What to do next:"));
        let written = write_report(&s.profile, &text).unwrap();
        assert!(written.starts_with(&s.profile.local_app_data));
        assert_eq!(report.exit_code(), 0);
    }

    #[test]
    fn a_second_run_is_already_set_up_and_writes_nothing() {
        let s = Sandbox::new();
        s.file(s.home(r".claude\settings.json"), b"{}");
        s.file(s.home(r".codex\config.toml"), b"model = 'x'\n");
        s.mkdir(s.home(".kimi-code"));
        s.file(s.home(r".hermes\config.yaml"), b"model: x\n");
        s.cli("codex", "codex-cli 0.157.0");
        s.cli("kimi", "2.1.1");
        s.cli("hermes", "Hermes Agent v0.21.5");
        let first = s.run(false);
        assert!(first.ok, "{first:#?}");
        for a in AGENTS {
            assert_eq!(outcome(&first, a), Outcome::Installed, "{a}");
        }
        let before = tree(&s.root);
        let second = s.run(false);
        assert!(second.ok, "{second:#?}");
        for a in AGENTS {
            assert_eq!(outcome(&second, a), Outcome::AlreadySetUp, "{a}");
            assert!(agent(&second, a).backup.is_empty());
        }
        assert_eq!(tree(&s.root), before, "an idempotent run must not touch a byte");
        assert!(unconfigured_detected(&s.profile).is_empty());
    }

    #[test]
    fn desktop_only_kimi_without_cli_installs_with_a_warning() {
        let s = Sandbox::new();
        s.file(s.local(r"Programs\Kimi Code\Kimi Code.exe"), b"app");
        assert_eq!(unconfigured_detected(&s.profile), vec!["Kimi Code".to_string()]);
        let status = agent_hooks::status_in("kimi-code", &s.profile).unwrap();
        assert!(status.available && !status.cli_found);
        assert!(status.version_warning.contains("CLI not found; desktop app detected"), "{}", status.version_warning);

        let report = s.run(false);
        assert!(report.ok, "{report:#?}");
        let kimi = agent(&report, "kimi-code");
        assert_eq!(kimi.outcome, Outcome::Installed);
        assert!(kimi.warning.contains("CLI not found; desktop app detected"), "{}", kimi.warning);
        let config = std::fs::read_to_string(s.home(r".kimi-code\config.toml")).unwrap();
        assert!(config.contains("--agent kimi-code Stop"));
        assert!(kimi.follow_up.contains("Restart Kimi Code"));
        assert_eq!(outcome(&report, "claude"), Outcome::Skipped);
    }

    #[test]
    fn an_agent_with_no_trace_still_cannot_be_installed_by_hand() {
        let s = Sandbox::new();
        let Err(err) = agent_hooks::preview_in("codex", true, &s.profile) else { panic!("codex had no trace but was installable") };
        assert!(err.contains("no desktop app or config folder"), "{err}");
        assert!(!agent_hooks::status_in("codex", &s.profile).unwrap().available);
    }

    #[test]
    fn dry_run_reports_without_writing_anything() {
        let s = Sandbox::new();
        s.file(s.home(r".claude\settings.json"), b"{\"model\":\"x\"}");
        s.file(s.home(r".codex\config.toml"), b"model = 'x'\n");
        s.mkdir(s.local(r"Packages\OpenAI.Codex_abc"));
        let before = tree(&s.root);
        let report = s.run(true);
        assert!(report.ok, "{report:#?}");
        assert!(report.dry_run);
        assert_eq!(outcome(&report, "claude"), Outcome::WouldInstall);
        assert_eq!(outcome(&report, "codex"), Outcome::WouldInstall);
        assert!(agent(&report, "codex").warning.contains("desktop app detected"));
        assert!(report.relay_message.starts_with("would be copied"), "{}", report.relay_message);
        assert_eq!(tree(&s.root), before, "a dry run must not write");
        assert!(report_text(&report, "t").contains("DRY RUN"));
    }

    #[test]
    fn a_missing_relay_is_an_error_and_writes_no_config() {
        let s = Sandbox::new();
        s.file(s.home(r".codex\config.toml"), b"model = 'x'\n");
        s.cli("codex", "codex-cli 0.157.0");
        let report = setup_all_detected(&s.profile, &[s.root.join("nope.exe")], false);
        assert!(!report.ok && !report.relay_ready);
        assert_eq!(outcome(&report, "codex"), Outcome::Error);
        assert_eq!(report.exit_code(), 1);
        assert_eq!(std::fs::read(s.home(r".codex\config.toml")).unwrap(), b"model = 'x'\n");
    }

    #[test]
    fn a_broken_config_is_reported_and_others_still_install() {
        let s = Sandbox::new();
        s.file(s.home(r".claude\settings.json"), b"{ broken");
        s.file(s.home(r".codex\config.toml"), b"model = 'x'\n");
        s.cli("codex", "codex-cli 0.157.0");
        let report = s.run(false);
        assert_eq!(outcome(&report, "claude"), Outcome::Error);
        assert!(agent(&report, "claude").message.contains("isn't valid JSON"));
        assert_eq!(outcome(&report, "codex"), Outcome::Installed);
        assert_eq!(std::fs::read(s.home(r".claude\settings.json")).unwrap(), b"{ broken");
        assert_eq!(report.exit_code(), 1);
    }

    #[test]
    fn remove_round_trip_restores_every_config_byte_for_byte() {
        let s = Sandbox::new();
        let claude_original =
            serde_json::to_string_pretty(&serde_json::json!({ "model": "opus", "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "mine.exe" } ] } ] } })).unwrap()
                + "\n";
        let files = [
            (s.home(r".claude\settings.json"), claude_original.into_bytes()),
            (s.home(r".codex\config.toml"), b"# keep\r\nmodel = 'x'\r\n".to_vec()),
            (s.home(r".kimi-code\config.toml"), b"model = 'k'".to_vec()),
            (s.home(r".hermes\config.yaml"), b"model: h\n".to_vec()),
        ];
        for (p, b) in &files {
            s.file(p.clone(), b);
        }
        let installed = s.run(false);
        assert!(installed.ok, "{installed:#?}");
        for (p, b) in &files {
            assert_ne!(&std::fs::read(p).unwrap(), b, "{} was not installed", p.display());
        }
        let dry = remove_all(&s.profile, true);
        for a in AGENTS {
            assert_eq!(outcome(&dry, a), Outcome::WouldRemove, "{a}");
        }
        let removed = remove_all(&s.profile, false);
        assert!(removed.ok, "{removed:#?}");
        for a in AGENTS {
            assert_eq!(outcome(&removed, a), Outcome::Removed, "{a}");
            assert!(!agent(&removed, a).backup.is_empty(), "{a}: removal must back up first");
        }
        for (p, b) in &files {
            assert_eq!(&std::fs::read(p).unwrap(), b, "{} not restored", p.display());
        }
        let again = remove_all(&s.profile, false);
        for a in AGENTS {
            assert_eq!(outcome(&again, a), Outcome::NotInstalled, "{a}");
        }
    }

    #[test]
    fn hermes_uses_the_windows_installer_home_when_there_is_no_dot_folder() {
        let s = Sandbox::new();
        s.file(s.local(r"hermes\config.yaml"), b"model: h\n");
        let report = s.run(false);
        assert_eq!(outcome(&report, "hermes"), Outcome::Installed, "{report:#?}");
        assert!(std::fs::read_to_string(s.local(r"hermes\config.yaml")).unwrap().contains("--agent hermes"));
        assert!(!s.home(".hermes").exists());
        assert!(agent(&report, "hermes").follow_up.contains("hermes --accept-hooks"));
    }
}
