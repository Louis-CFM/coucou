// "Coucou 0.6.0 is out" in the island, and on Windows one click to install it.
// Port of MacUpdate.swift / MacUpdater.swift (the Mac's GitHub build).
//
// Nothing is asked of GitHub before the user says yes: the island asks once
// (again a day later at most if the card was left unanswered), or Settings →
// General → Updates. "Check now" is a click, so it works either way. Once
// allowed, Coucou looks at launch and every 6 hours: one unauthenticated
// `GET /repos/Louis-CFM/coucou/releases`, no cookies, nothing about the user.
//
// Windows: the installer this copy came from — the per-user setup.exe in
// %LOCALAPPDATA%\Coucou, the per-machine .msi under Program Files — is
// downloaded from GitHub only (redirects to github.com, api.github.com and
// *.githubusercontent.com, nothing else), checked against the SHA-256 GitHub
// publishes for that asset, then run; Coucou quits and the installer starts it
// again. Anything else (the portable exe, every Linux package) gets the
// release page: people update those the way they installed them.
//
// The rules are pure functions below, unit-tested at the bottom of the file.

use std::path::{Path, PathBuf};
use std::sync::{Mutex, MutexGuard, OnceLock, PoisonError};
use std::time::Duration;

use reqwest::Url;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter};

use crate::i18n::t;
use crate::island::WINDOW_LABEL;

pub const RELEASES_URL: &str = "https://api.github.com/repos/Louis-CFM/coucou/releases?per_page=30";
/// Where "What's new" goes when no release is known.
pub const RELEASES_PAGE: &str = "https://github.com/Louis-CFM/coucou/releases";

/// This platform's release tags: `windows-vX.Y.Z` / `linux-vX.Y.Z`. Never the
/// rolling `windows-latest` / `linux-latest`, nor the Mac's `v…` or Android's.
#[cfg(windows)]
pub const TAG_PREFIX: &str = "windows-v";
#[cfg(not(windows))]
pub const TAG_PREFIX: &str = "linux-v";

/// Once allowed, a look every 6 hours (GitHub allows 60 unauthenticated calls an hour).
pub const CHECK_INTERVAL: i64 = 6 * 3600;
/// "Later", or the card shown once: that version stays quiet for a day. A newer one shows at once.
pub const SNOOZE: i64 = 24 * 3600;
/// The question comes back a day later at most when it was left unanswered.
pub const ASK_AGAIN: i64 = 24 * 3600;
/// The first look, after launch: never on top of the greeting.
const FIRST_TICK: Duration = Duration::from_secs(30);
/// How often the schedule is looked at; GitHub is only called when `should_check` says so.
const TICK: Duration = Duration::from_secs(3600);
/// An installer bigger than this is not Coucou's (0.5.0's .msi is 14 MB).
const MAX_INSTALLER: u64 = 512 * 1024 * 1024;

// ── Releases ──────────────────────────────────────────────────────────────────

#[derive(Clone, Debug, PartialEq)]
pub struct Asset {
    pub name: String,
    pub url: String,
    pub size: u64,
    /// GitHub's `digest` for the file, `sha256:<hex>`.
    pub digest: Option<String>,
}

#[derive(Clone, Debug, PartialEq)]
pub struct Release {
    pub version: String,
    pub tag: String,
    pub page_url: String,
    /// The first "What's new" line, without its Markdown.
    pub headline: Option<String>,
    pub assets: Vec<Asset>,
}

/// "windows-v0.5.1" → "0.5.1" with the prefix "windows-v"; "windows-latest",
/// "v0.5.1", "linux-v0.5.0" or "windows-v0.5.0-beta" → None.
pub fn version_from_tag(tag: &str, prefix: &str) -> Option<String> {
    let v = tag.strip_prefix(prefix)?;
    let parts: Vec<&str> = v.split('.').collect();
    let numeric = parts.iter().all(|p| !p.is_empty() && p.len() <= 9 && p.bytes().all(|b| b.is_ascii_digit()));
    ((2..=4).contains(&parts.len()) && numeric).then(|| v.to_string())
}

fn numbers(v: &str) -> Vec<u64> {
    v.split('.').map(|p| p.parse().unwrap_or(0)).collect()
}

/// Numeric comparison: 0.10.0 is newer than 0.9.3, 0.5.1 than 0.5.
pub fn is_newer(a: &str, than: &str) -> bool {
    let (x, y) = (numbers(a), numbers(than));
    for i in 0..x.len().max(y.len()) {
        let (l, r) = (x.get(i).copied().unwrap_or(0), y.get(i).copied().unwrap_or(0));
        if l != r {
            return l > r;
        }
    }
    false
}

/// The bold part of the first bullet under "## What's new", else the bullet's
/// start, as on the Mac.
pub fn headline(body: Option<&str>) -> Option<String> {
    let lines: Vec<&str> = body?.lines().collect();
    let start = lines.iter().position(|l| l.trim().to_lowercase().starts_with("## what"))?;
    for line in &lines[start + 1..] {
        let t = line.trim();
        if t.starts_with("## ") {
            break;
        }
        let Some(item) = t.strip_prefix("- ").or_else(|| t.strip_prefix("* ")) else { continue };
        if let Some(rest) = item.strip_prefix("**") {
            if let Some(end) = rest.find("**") {
                return Some(rest[..end].to_string());
            }
        }
        let plain = item.replace('*', "");
        return Some(if plain.chars().count() > 70 {
            format!("{}…", plain.chars().take(68).collect::<String>())
        } else {
            plain
        });
    }
    None
}

/// Only GitHub serves the update (its assets redirect to githubusercontent.com).
pub fn allowed_host(host: Option<&str>) -> bool {
    let Some(h) = host.map(str::to_ascii_lowercase) else { return false };
    h == "github.com" || h == "api.github.com" || h.ends_with(".githubusercontent.com")
}

pub fn allowed_url(url: &str) -> bool {
    Url::parse(url).is_ok_and(|u| u.scheme() == "https" && allowed_host(u.host_str()))
}

/// The newest published release with this platform's tag in `GET /releases`.
pub fn latest(json: &[u8], prefix: &str) -> Option<Release> {
    let Ok(Value::Array(list)) = serde_json::from_slice::<Value>(json) else { return None };
    let releases = list.iter().filter_map(|r| {
        if r.get("draft").and_then(Value::as_bool) == Some(true)
            || r.get("prerelease").and_then(Value::as_bool) == Some(true)
        {
            return None;
        }
        let tag = r.get("tag_name")?.as_str()?;
        let version = version_from_tag(tag, prefix)?;
        let page_url = r.get("html_url")?.as_str().filter(|u| allowed_url(u))?.to_string();
        let assets = r
            .get("assets")
            .and_then(Value::as_array)
            .map(|assets| {
                assets
                    .iter()
                    .filter_map(|a| {
                        Some(Asset {
                            name: a.get("name")?.as_str()?.to_string(),
                            url: a.get("browser_download_url")?.as_str()?.to_string(),
                            size: a.get("size").and_then(Value::as_u64).unwrap_or(0),
                            digest: a.get("digest").and_then(Value::as_str).map(str::to_string),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        Some(Release {
            version,
            tag: tag.to_string(),
            page_url,
            headline: headline(r.get("body").and_then(Value::as_str)),
            assets,
        })
    });
    releases.fold(None, |best: Option<Release>, r| match best {
        Some(b) if !is_newer(&r.version, &b.version) => Some(b),
        _ => Some(r),
    })
}

/// "sha256:E823…" → the 64 lowercase hex digits; anything else → None.
pub fn parse_digest(digest: &str) -> Option<String> {
    let hex = digest.strip_prefix("sha256:")?;
    (hex.len() == 64 && hex.bytes().all(|b| b.is_ascii_hexdigit())).then(|| hex.to_ascii_lowercase())
}

// ── How this copy was installed ───────────────────────────────────────────────

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum InstallKind {
    /// The per-user setup.exe (NSIS): %LOCALAPPDATA%\Coucou.
    Setup,
    /// The per-machine .msi (WiX): Program Files\Coucou.
    Msi,
    /// Anything else — the portable exe, a build, Linux: the release page only.
    Manual,
}

/// A Windows path for comparing: backslashes, no trailing one, lowercase.
fn win_path(p: &str) -> String {
    p.replace('/', "\\").trim_end_matches('\\').to_lowercase()
}

/// The installer that put `exe` where it is, from its folder alone: Tauri's
/// NSIS installer (per user) uses %LOCALAPPDATA%\Coucou, its MSI (per machine)
/// Program Files\Coucou. `has_uninstaller` is whether NSIS's uninstall.exe sits
/// next to it, so a portable exe someone copied into that folder isn't taken
/// for an installed one.
#[cfg_attr(not(windows), allow(dead_code))]
pub fn install_kind(exe: &str, has_uninstaller: bool, local_app_data: Option<&str>, program_files: &[String]) -> InstallKind {
    let exe = win_path(exe);
    let Some((dir, _)) = exe.rsplit_once('\\') else { return InstallKind::Manual };
    if let Some(local) = local_app_data.filter(|l| !l.trim().is_empty()) {
        if dir == format!("{}\\coucou", win_path(local)) {
            return if has_uninstaller { InstallKind::Setup } else { InstallKind::Manual };
        }
    }
    if program_files.iter().filter(|p| !p.trim().is_empty()).any(|p| dir == format!("{}\\coucou", win_path(p))) {
        return InstallKind::Msi;
    }
    InstallKind::Manual
}

/// The release asset for an install kind: exactly the name the release
/// workflow publishes, nothing else.
pub fn asset_name(kind: InstallKind, version: &str) -> Option<String> {
    match kind {
        InstallKind::Setup => Some(format!("Coucou-Windows-{version}-setup.exe")),
        InstallKind::Msi => Some(format!("Coucou-Windows-{version}.msi")),
        InstallKind::Manual => None,
    }
}

pub fn pick_asset(release: &Release, kind: InstallKind) -> Option<&Asset> {
    let name = asset_name(kind, &release.version)?;
    release.assets.iter().find(|a| a.name == name && allowed_url(&a.url))
}

/// What runs the downloaded installer. The setup.exe with Tauri's own update
/// flags: `/P` passive (a progress bar, no questions), `/UPDATE` (no "reinstall
/// or uninstall?" step, the old uninstaller never runs, shortcuts are left as
/// they are), `/R` (start Coucou again once done). The MSI through msiexec,
/// passive, with Tauri's `AUTOLAUNCHAPP` to start it again; being per machine
/// it asks for admin rights, as installing it by hand does.
pub fn installer_command(kind: InstallKind, file: &Path, system_root: Option<&str>) -> Option<(PathBuf, Vec<String>)> {
    let file_arg = file.to_string_lossy().to_string();
    match kind {
        InstallKind::Setup => Some((file.to_path_buf(), vec!["/P".into(), "/UPDATE".into(), "/R".into()])),
        InstallKind::Msi => {
            let msiexec = match system_root.filter(|r| !r.trim().is_empty()) {
                Some(root) => PathBuf::from(format!("{}\\System32\\msiexec.exe", root.trim_end_matches(['\\', '/']))),
                None => PathBuf::from("msiexec.exe"),
            };
            Some((msiexec, vec!["/i".into(), file_arg, "/passive".into(), "AUTOLAUNCHAPP=True".into()]))
        }
        InstallKind::Manual => None,
    }
}

// ── Schedule ──────────────────────────────────────────────────────────────────

/// A clock set back counts as due, so a wrong date can't stop the checks for good.
fn due(last: Option<i64>, now: i64, interval: i64) -> bool {
    last.is_none_or(|last| now - last >= interval || now < last)
}

pub fn should_check(last: Option<i64>, now: i64) -> bool {
    due(last, now, CHECK_INTERVAL)
}

pub fn should_ask(asked_at: Option<i64>, now: i64) -> bool {
    due(asked_at, now, ASK_AGAIN)
}

/// Whether Mochi says "Coucou X is out": newer than what runs, and not shown
/// or put off for that version in the last day.
pub fn should_announce(version: &str, current: &str, snoozed_version: Option<&str>, snoozed_at: Option<i64>, now: i64) -> bool {
    if !is_newer(version, current) {
        return false;
    }
    !(snoozed_version == Some(version) && !due(snoozed_at, now, SNOOZE))
}

// ── State ─────────────────────────────────────────────────────────────────────

/// update.json in the config folder. Not secrets.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Prefs {
    /// None: not asked yet. true: Coucou may look at GitHub. false: never on its own.
    consent: Option<bool>,
    last_check: Option<i64>,
    snoozed_version: Option<String>,
    snoozed_at: Option<i64>,
    asked_at: Option<i64>,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Phase {
    Idle,
    Downloading { fraction: f64 },
    Verifying,
    Installing,
    Error { message: String },
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum CheckState {
    None,
    Checking,
    UpToDate,
    Unreachable,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LatestView {
    version: String,
    headline: Option<String>,
    page_url: String,
}

/// What the island and the settings window show.
#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Status {
    consent: Option<bool>,
    current: String,
    latest: Option<LatestView>,
    /// "Update now" can install it here (Windows, setup.exe or MSI install).
    can_install: bool,
    phase: Phase,
    check: CheckState,
    platform: &'static str,
}

struct Inner {
    prefs: Prefs,
    latest: Option<Release>,
    phase: Phase,
    check: CheckState,
}

impl Inner {
    fn busy(&self) -> bool {
        matches!(self.phase, Phase::Downloading { .. } | Phase::Verifying | Phase::Installing)
    }
}

fn state() -> MutexGuard<'static, Inner> {
    static S: OnceLock<Mutex<Inner>> = OnceLock::new();
    S.get_or_init(|| {
        Mutex::new(Inner { prefs: load_prefs(), latest: None, phase: Phase::Idle, check: CheckState::None })
    })
    .lock()
    .unwrap_or_else(PoisonError::into_inner)
}

pub fn current_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

fn now() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs() as i64).unwrap_or(0)
}

fn prefs_path() -> PathBuf {
    crate::platform::config_dir().join("update.json")
}

fn load_prefs() -> Prefs {
    std::fs::read(prefs_path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
}

fn save_prefs(prefs: &Prefs) {
    let path = prefs_path();
    let Some(dir) = path.parent() else { return };
    let temp = path.with_extension(format!("json.coucou-{}", std::process::id()));
    let written = crate::platform::ensure_private_dir(dir)
        .and_then(|()| serde_json::to_vec(prefs).map_err(std::io::Error::other))
        .and_then(|json| std::fs::write(&temp, json))
        .and_then(|()| std::fs::rename(&temp, &path));
    if let Err(err) = written {
        let _ = std::fs::remove_file(&temp);
        crate::log::line(format!("update: could not save update.json: {err}"));
    }
}

/// How this copy was installed, for "Update now".
pub fn this_install() -> InstallKind {
    #[cfg(windows)]
    {
        let Ok(exe) = std::env::current_exe() else { return InstallKind::Manual };
        let has_uninstaller = exe.parent().is_some_and(|d| d.join("uninstall.exe").is_file());
        let env = |k: &str| std::env::var(k).ok();
        let program_files: Vec<String> =
            ["ProgramFiles", "ProgramW6432", "ProgramFiles(x86)"].iter().filter_map(|k| env(k)).collect();
        install_kind(&exe.to_string_lossy(), has_uninstaller, env("LOCALAPPDATA").as_deref(), &program_files)
    }
    // Linux: AppImage, .deb, .rpm and the Arch package update the way they were installed.
    #[cfg(not(windows))]
    {
        InstallKind::Manual
    }
}

fn can_install(latest: Option<&Release>) -> bool {
    let kind = this_install();
    latest.is_some_and(|r| pick_asset(r, kind).is_some())
}

pub fn status() -> Status {
    let s = state();
    let latest = s.latest.as_ref().filter(|r| is_newer(&r.version, current_version()));
    Status {
        consent: s.prefs.consent,
        current: current_version().to_string(),
        latest: latest.map(|r| LatestView {
            version: r.version.clone(),
            headline: r.headline.clone(),
            page_url: r.page_url.clone(),
        }),
        can_install: can_install(latest),
        phase: s.phase.clone(),
        check: s.check,
        platform: if cfg!(windows) { "windows" } else { "linux" },
    }
}

/// Tells both windows, and the tray's "Update Coucou to X…".
fn changed(app: &AppHandle) {
    let status = status();
    crate::tray::set_update(app, status.latest.as_ref().map(|l| l.version.as_str()));
    let _ = app.emit("update-status", status);
}

/// Asks the island to open its update card: "ask", "announce" or "show". The
/// island opens it only when nothing else waits there, and says so with
/// `update_shown`.
fn offer(app: &AppHandle, kind: &str) {
    let _ = app.emit_to(WINDOW_LABEL, "update-offer", kind.to_string());
}

fn set_phase(app: &AppHandle, phase: Phase) {
    state().phase = phase;
    changed(app);
}

// ── Schedule loop ─────────────────────────────────────────────────────────────

/// At launch: a first look 30 s in, then every hour (GitHub only every 6 h).
/// The task sleeps in between: nothing runs while nothing is due.
pub fn start(app: AppHandle) {
    remove_old_downloads();
    tauri::async_runtime::spawn(async move {
        tokio::time::sleep(FIRST_TICK).await;
        let mut launch = true;
        loop {
            tick(&app, launch).await;
            launch = false;
            tokio::time::sleep(TICK).await;
        }
    });
}

async fn tick(app: &AppHandle, launch: bool) {
    // Paused means paused: no call out, no card.
    if crate::integrations::PAUSED.load(std::sync::atomic::Ordering::Relaxed) {
        return;
    }
    let (consent, asked_at, last_check) = {
        let s = state();
        (s.prefs.consent, s.prefs.asked_at, s.prefs.last_check)
    };
    match consent {
        None if should_ask(asked_at, now()) => offer(app, "ask"),
        Some(true) if launch || should_check(last_check, now()) => check(app, false).await,
        Some(true) => announce_if_due(app),
        _ => {}
    }
}

fn announce_if_due(app: &AppHandle) {
    let due = {
        let s = state();
        !s.busy()
            && s.latest.as_ref().is_some_and(|r| {
                should_announce(&r.version, current_version(), s.prefs.snoozed_version.as_deref(), s.prefs.snoozed_at, now())
            })
    };
    if due {
        offer(app, "announce");
    }
}

// ── Check ─────────────────────────────────────────────────────────────────────

/// The client for GitHub: no cookies (reqwest keeps none), a bare user agent
/// (GitHub refuses requests without one), and redirects followed only to
/// GitHub over https.
fn github_client(timeout: Duration) -> Result<reqwest::Client, String> {
    let policy = reqwest::redirect::Policy::custom(|attempt| {
        if attempt.previous().len() >= 5 {
            attempt.error("too many redirects")
        } else if attempt.url().scheme() == "https" && allowed_host(attempt.url().host_str()) {
            attempt.follow()
        } else {
            attempt.stop()
        }
    });
    reqwest::Client::builder()
        .connect_timeout(Duration::from_secs(15))
        .timeout(timeout)
        .user_agent("Coucou")
        .redirect(policy)
        .build()
        .map_err(|e| e.to_string())
}

async fn fetch_latest() -> Result<Option<Release>, String> {
    let response = github_client(Duration::from_secs(30))?
        .get(RELEASES_URL)
        .header("Accept", "application/vnd.github+json")
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if response.status().as_u16() != 200 {
        return Err(format!("HTTP {}", response.status().as_u16()));
    }
    let body = crate::net::read_capped(response, crate::net::MAX_BODY).await?;
    Ok(latest(&body, TAG_PREFIX))
}

/// One look at GitHub. `manual`: "Check now" in Settings, which opens the card
/// when a new version is out.
pub async fn check(app: &AppHandle, manual: bool) {
    {
        let mut s = state();
        if s.busy() || s.check == CheckState::Checking {
            return;
        }
        s.check = CheckState::Checking;
    }
    changed(app);
    let result = fetch_latest().await;
    let newer = {
        let mut s = state();
        s.prefs.last_check = Some(now());
        save_prefs(&s.prefs);
        match result {
            Err(err) => {
                crate::log::line(format!("update: GitHub unreachable: {err}"));
                s.check = CheckState::Unreachable;
                false
            }
            Ok(Some(release)) if is_newer(&release.version, current_version()) => {
                if s.latest.as_ref().map(|r| &r.version) != Some(&release.version) {
                    crate::log::line(format!("update: {} is out (running {})", release.version, current_version()));
                }
                s.latest = Some(release);
                s.check = CheckState::None;
                true
            }
            Ok(_) => {
                s.latest = None;
                s.check = CheckState::UpToDate;
                if matches!(s.phase, Phase::Error { .. }) {
                    s.phase = Phase::Idle;
                }
                false
            }
        }
    };
    changed(app);
    if newer {
        if manual {
            offer(app, "show");
        } else {
            announce_if_due(app);
        }
    }
}

// ── Install (Windows) ─────────────────────────────────────────────────────────

/// Old downloads left in the temp folder by an update that ran: Coucou quits
/// before the installer is done with its file, so they go at the next launch.
fn remove_old_downloads() {
    let Ok(entries) = std::fs::read_dir(std::env::temp_dir()) else { return };
    for entry in entries.flatten() {
        if entry.file_name().to_string_lossy().starts_with("coucou-update-") {
            let _ = std::fs::remove_dir_all(entry.path());
        }
    }
}

/// "Update now": downloads, checks and runs the installer, then quits.
pub fn install(app: &AppHandle) {
    let kind = this_install();
    let release = {
        let mut s = state();
        if s.busy() {
            return;
        }
        let Some(release) = s.latest.clone().filter(|r| is_newer(&r.version, current_version())) else { return };
        if pick_asset(&release, kind).is_none() {
            // Nothing to install here: the card offers the release page instead.
            return;
        }
        s.phase = Phase::Downloading { fraction: 0.0 };
        release
    };
    changed(app);
    let app = app.clone();
    tauri::async_runtime::spawn(async move {
        match run(&app, &release, kind).await {
            Ok(()) => {
                crate::log::line(format!("update: running the {kind:?} installer for {}, quitting", release.version));
                set_phase(&app, Phase::Installing);
                // Long enough for the card to say so; the installer closes a Coucou still open.
                tokio::time::sleep(Duration::from_millis(1200)).await;
                app.exit(0);
            }
            Err(message) => {
                crate::log::line(format!("update: failed: {message}"));
                set_phase(&app, Phase::Error { message });
            }
        }
    });
}

async fn run(app: &AppHandle, release: &Release, kind: InstallKind) -> Result<(), String> {
    let asset = pick_asset(release, kind).ok_or_else(|| t("The download failed. Try again, or get the new version on GitHub."))?;
    let expected = asset
        .digest
        .as_deref()
        .and_then(parse_digest)
        .ok_or_else(|| t("GitHub gave no checksum for this download, so nothing was installed."))?;
    if asset.size == 0 || asset.size > MAX_INSTALLER {
        return Err(t("The download isn't the file GitHub published for this version, so nothing was installed."));
    }
    let nonce = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.subsec_nanos()).unwrap_or(0);
    let dir = std::env::temp_dir().join(format!("coucou-update-{}-{nonce}", std::process::id()));
    std::fs::create_dir_all(&dir).map_err(|_| t("The download failed. Try again, or get the new version on GitHub."))?;
    let path = dir.join(&asset.name);

    let got = download(app, asset, &path).await.inspect_err(|_| {
        let _ = std::fs::remove_dir_all(&dir);
    })?;
    set_phase(app, Phase::Verifying);
    if got != expected {
        let _ = std::fs::remove_dir_all(&dir);
        return Err(t("The download isn't the file GitHub published for this version, so nothing was installed."));
    }

    let system_root = std::env::var("SystemRoot").ok();
    let (program, args) = installer_command(kind, &path, system_root.as_deref())
        .ok_or_else(|| t("The download failed. Try again, or get the new version on GitHub."))?;
    std::process::Command::new(program).args(args).spawn().map_err(|err| {
        crate::log::line(format!("update: could not start the installer: {err}"));
        t("Windows blocked the installer. Get the new version from its release page instead.")
    })?;
    Ok(())
}

/// Streams the asset to `path` from GitHub only, hashing as it comes, with the
/// progress on the card. Returns the SHA-256 of exactly `asset.size` bytes.
async fn download(app: &AppHandle, asset: &Asset, path: &Path) -> Result<String, String> {
    use std::io::Write;
    let failed = || t("The download failed. Try again, or get the new version on GitHub.");
    if !allowed_url(&asset.url) {
        return Err(failed());
    }
    let mut response = github_client(Duration::from_secs(900))?
        .get(&asset.url)
        .header("Accept", "application/octet-stream")
        .send()
        .await
        .map_err(|_| failed())?;
    if response.status().as_u16() != 200 || response.url().scheme() != "https" || !allowed_host(response.url().host_str()) {
        return Err(failed());
    }
    let mut out = std::fs::File::create(path).map_err(|_| failed())?;
    let mut hash = ring::digest::Context::new(&ring::digest::SHA256);
    let mut got: u64 = 0;
    let mut last_emit = std::time::Instant::now();
    while let Some(chunk) = response.chunk().await.map_err(|_| failed())? {
        got += chunk.len() as u64;
        if got > asset.size {
            return Err(t("The download isn't the file GitHub published for this version, so nothing was installed."));
        }
        // Defender holding or removing the file shows up here.
        out.write_all(&chunk).map_err(|_| t("Windows blocked the installer. Get the new version from its release page instead."))?;
        hash.update(&chunk);
        if last_emit.elapsed() > Duration::from_millis(250) {
            last_emit = std::time::Instant::now();
            set_phase(app, Phase::Downloading { fraction: got as f64 / asset.size as f64 });
        }
    }
    out.flush().map_err(|_| failed())?;
    drop(out);
    if got != asset.size {
        return Err(failed());
    }
    Ok(hash.finish().as_ref().iter().map(|b| format!("{b:02x}")).collect())
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub fn update_status() -> Status {
    status()
}

/// The island's question, or Settings' toggle.
#[tauri::command]
pub fn update_set_consent(app: AppHandle, allowed: bool) {
    {
        let mut s = state();
        s.prefs.consent = Some(allowed);
        save_prefs(&s.prefs);
    }
    changed(&app);
    if allowed {
        tauri::async_runtime::spawn(async move { check(&app, false).await });
    }
}

/// "Check now" (a click: works with the toggle off too).
#[tauri::command]
pub async fn update_check(app: AppHandle) -> Status {
    check(&app, true).await;
    status()
}

/// The island opened the card it was offered: the question waits a day before
/// coming back, the announced version a day before it is announced again.
#[tauri::command]
pub fn update_shown(kind: String) {
    let mut s = state();
    match kind.as_str() {
        "ask" => s.prefs.asked_at = Some(now()),
        "announce" => {
            let Some(version) = s.latest.as_ref().map(|r| r.version.clone()) else { return };
            s.prefs.snoozed_version = Some(version);
            s.prefs.snoozed_at = Some(now());
        }
        _ => return,
    }
    save_prefs(&s.prefs);
}

/// Settings → "Install X": opens the island's card on it.
#[tauri::command]
pub fn update_show(app: AppHandle) {
    offer(&app, "show");
}

/// "Later": this version stays quiet for a day; the tray and Settings keep offering it.
#[tauri::command]
pub fn update_later(app: AppHandle) {
    {
        let mut s = state();
        if let Some(version) = s.latest.as_ref().map(|r| r.version.clone()) {
            s.prefs.snoozed_version = Some(version);
            s.prefs.snoozed_at = Some(now());
            save_prefs(&s.prefs);
        }
        if matches!(s.phase, Phase::Error { .. }) {
            s.phase = Phase::Idle;
        }
    }
    changed(&app);
}

/// "OK" on a failed update: back to offering it.
#[tauri::command]
pub fn update_dismiss(app: AppHandle) {
    {
        let mut s = state();
        if matches!(s.phase, Phase::Error { .. }) {
            s.phase = Phase::Idle;
        }
    }
    changed(&app);
}

#[tauri::command]
pub fn update_install(app: AppHandle) {
    install(&app);
}

/// "What's new" / "Get it on GitHub": the release's page (only ever a github.com address).
#[tauri::command]
pub fn update_open_page() {
    let page = state().latest.as_ref().map(|r| r.page_url.clone()).filter(|u| allowed_url(u));
    crate::platform::open_url(page.as_deref().unwrap_or(RELEASES_PAGE));
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A trimmed `GET /releases` answer, as GitHub gave it on 2026-10-20: Mac,
    /// Linux, Android and Windows releases mixed, the rolling `*-latest` ones,
    /// drafts and a prerelease.
    fn fixture() -> Vec<u8> {
        serde_json::json!([
            { "tag_name": "windows-v0.6.0", "draft": true, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.6.0", "assets": [] },
            { "tag_name": "windows-v0.7.0", "draft": false, "prerelease": true,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.7.0", "assets": [] },
            { "tag_name": "v0.9.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/v0.9.0",
              "body": "## What's new\n\n- **WhatsApp in one click** — Mac",
              "assets": [{ "name": "Coucou.zip", "size": 34228988,
                "browser_download_url": "https://github.com/Louis-CFM/coucou/releases/download/v0.9.0/Coucou.zip",
                "digest": "sha256:24175a765704082c8b2e751f8b5ccb76b1eb3440ff2fd1e9c4cbe780c2193baa" }] },
            { "tag_name": "windows-v0.5.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.5.0",
              "body": "Coucou for Windows 0.5.0 — Mochi at the top of your screen.\n\n## What's new\n\n- **Flow dictation** on Windows — hold right Ctrl\n- Other things",
              "assets": [
                { "name": "Coucou-Windows-0.5.0-setup.exe", "size": 10950620,
                  "browser_download_url": "https://github.com/Louis-CFM/coucou/releases/download/windows-v0.5.0/Coucou-Windows-0.5.0-setup.exe",
                  "digest": "sha256:e8234a092e8fe1bf6eed0395e6db13052be8fe47413949c2b7fa368467342337" },
                { "name": "Coucou-Windows-0.5.0.msi", "size": 14086144,
                  "browser_download_url": "https://github.com/Louis-CFM/coucou/releases/download/windows-v0.5.0/Coucou-Windows-0.5.0.msi",
                  "digest": "sha256:79bced83c414722e84d47e99005a37910147624dc5e4edf55aa66ff6462cd09f" }] },
            { "tag_name": "windows-latest", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/windows-latest",
              "assets": [{ "name": "Coucou-Windows-setup.exe", "size": 10950620,
                "browser_download_url": "https://github.com/Louis-CFM/coucou/releases/download/windows-latest/Coucou-Windows-setup.exe",
                "digest": "sha256:e8234a092e8fe1bf6eed0395e6db13052be8fe47413949c2b7fa368467342337" }] },
            { "tag_name": "linux-v0.5.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/linux-v0.5.0", "body": "Coucou for Linux 0.5.0",
              "assets": [{ "name": "Coucou-Linux-0.5.0-x86_64.AppImage", "size": 107960824,
                "browser_download_url": "https://github.com/Louis-CFM/coucou/releases/download/linux-v0.5.0/Coucou-Linux-0.5.0-x86_64.AppImage",
                "digest": "sha256:b59e0a8e432b782ea029cc825d37675033e7ff4069d70d376c1d268495a242af" }] },
            { "tag_name": "linux-latest", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/linux-latest", "assets": [] },
            { "tag_name": "android-v0.2.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/android-v0.2.0", "assets": [] },
            { "tag_name": "windows-v0.10.0", "draft": false, "prerelease": false,
              "html_url": "https://evil.example.com/windows-v0.10.0", "assets": [] },
            { "tag_name": "windows-v0.4.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.4.0", "assets": [] },
            { "tag_name": "linux-v0.4.0", "draft": false, "prerelease": false,
              "html_url": "https://github.com/Louis-CFM/coucou/releases/tag/linux-v0.4.0", "assets": [] }
        ])
        .to_string()
        .into_bytes()
    }

    #[test]
    fn only_this_platforms_numbered_tags_count() {
        assert_eq!(version_from_tag("windows-v0.5.1", "windows-v").as_deref(), Some("0.5.1"));
        assert_eq!(version_from_tag("windows-v1.2", "windows-v").as_deref(), Some("1.2"));
        assert_eq!(version_from_tag("linux-v0.5.0", "linux-v").as_deref(), Some("0.5.0"));
        for tag in ["windows-latest", "v0.5.1", "linux-v0.5.0", "android-v0.2.0", "windows-v0.5.0-beta", "windows-v", "windows-v1", "windows-v1..2", "windows-v1.2.3.4.5"] {
            assert_eq!(version_from_tag(tag, "windows-v"), None, "{tag}");
        }
        assert_eq!(version_from_tag("windows-v0.5.0", "linux-v"), None);
    }

    #[test]
    fn versions_compare_as_numbers() {
        assert!(is_newer("0.10.0", "0.9.3"));
        assert!(is_newer("0.5.1", "0.5"));
        assert!(is_newer("1.0", "0.99.99"));
        assert!(!is_newer("0.5.0", "0.5.0"));
        assert!(!is_newer("0.5", "0.5.0"));
        assert!(!is_newer("0.4.9", "0.5.0"));
    }

    #[test]
    fn the_newest_published_release_of_this_platform_is_picked() {
        let w = latest(&fixture(), "windows-v").unwrap();
        // Not the draft 0.6.0, the prerelease 0.7.0, the Mac's 0.9.0 or the 0.10.0 whose page isn't GitHub's.
        assert_eq!(w.version, "0.5.0");
        assert_eq!(w.tag, "windows-v0.5.0");
        assert_eq!(w.page_url, "https://github.com/Louis-CFM/coucou/releases/tag/windows-v0.5.0");
        assert_eq!(w.headline.as_deref(), Some("Flow dictation"));
        assert_eq!(w.assets.len(), 2);
        let l = latest(&fixture(), "linux-v").unwrap();
        assert_eq!(l.version, "0.5.0");
        assert_eq!(l.headline, None);
        assert_eq!(latest(b"{\"message\":\"API rate limit exceeded\"}", "windows-v"), None);
        assert_eq!(latest(b"not json", "windows-v"), None);
        assert_eq!(latest(b"[]", "windows-v"), None);
    }

    #[test]
    fn the_headline_is_the_first_bold_bullet_of_whats_new() {
        let h = |s: &str| headline(Some(s));
        assert_eq!(h("Intro\n\n## What's new\n\n- **WhatsApp in one click** *(macOS)* — more\n- second").as_deref(), Some("WhatsApp in one click"));
        assert_eq!(h("## What’s new\n* Plain *first* item\n").as_deref(), Some("Plain first item"));
        assert_eq!(h("## What's new\n\n## Install\n- **Not this**"), None);
        assert_eq!(h("- **No section**"), None);
        assert_eq!(headline(None), None);
        let long = format!("## What's new\n- {}", "a".repeat(80));
        let got = h(&long).unwrap();
        assert_eq!(got.chars().count(), 69);
        assert!(got.ends_with('…'));
    }

    #[test]
    fn only_github_may_serve_the_download() {
        for host in ["github.com", "api.github.com", "objects.githubusercontent.com", "release-assets.githubusercontent.com", "GitHub.com"] {
            assert!(allowed_host(Some(host)), "{host}");
        }
        for host in ["evil.com", "github.com.evil.com", "githubusercontent.com.evil.com", "notgithub.com", "githubusercontent.com", ""] {
            assert!(!allowed_host(Some(host)), "{host}");
        }
        assert!(!allowed_host(None));
        assert!(allowed_url("https://github.com/Louis-CFM/coucou/releases/download/x/y.msi"));
        assert!(!allowed_url("http://github.com/Louis-CFM/coucou"));
        assert!(!allowed_url("file:///C:/Windows/notepad.exe"));
        assert!(!allowed_url("not a url"));
    }

    #[test]
    fn the_installer_follows_how_this_copy_was_installed() {
        let local = Some(r"C:\Users\Ana\AppData\Local");
        let pf = vec![r"C:\Program Files".to_string(), r"C:\Program Files (x86)".to_string()];
        let kind = |exe: &str, uninst: bool| install_kind(exe, uninst, local, &pf);
        assert_eq!(kind(r"C:\Users\Ana\AppData\Local\Coucou\coucou.exe", true), InstallKind::Setup);
        assert_eq!(kind(r"c:\users\ana\appdata\local\COUCOU\Coucou.exe", true), InstallKind::Setup);
        // A portable exe copied there: no NSIS uninstaller next to it.
        assert_eq!(kind(r"C:\Users\Ana\AppData\Local\Coucou\coucou.exe", false), InstallKind::Manual);
        assert_eq!(kind(r"C:\Program Files\Coucou\coucou.exe", false), InstallKind::Msi);
        assert_eq!(kind(r"C:\Program Files (x86)\Coucou\coucou.exe", false), InstallKind::Msi);
        // The portable exe, a build, a folder that only looks alike.
        assert_eq!(kind(r"C:\Users\Ana\Downloads\coucou.exe", true), InstallKind::Manual);
        assert_eq!(kind(r"C:\dev\coucou\windows\target\release\coucou.exe", false), InstallKind::Manual);
        assert_eq!(kind(r"C:\Program Files\Coucou\bin\coucou.exe", false), InstallKind::Manual);
        assert_eq!(kind(r"C:\Users\Ana\AppData\Local\Coucou\bin\coucou-hook.exe", true), InstallKind::Manual);
        assert_eq!(kind("coucou.exe", true), InstallKind::Manual);
        assert_eq!(install_kind(r"C:\Program Files\Coucou\coucou.exe", false, None, &[]), InstallKind::Manual);
        assert_eq!(install_kind("/opt/Coucou/coucou", false, Some(""), &[String::new()]), InstallKind::Manual);
    }

    #[test]
    fn the_asset_is_the_exact_installer_for_the_kind() {
        let w = latest(&fixture(), "windows-v").unwrap();
        assert_eq!(pick_asset(&w, InstallKind::Setup).unwrap().name, "Coucou-Windows-0.5.0-setup.exe");
        assert_eq!(pick_asset(&w, InstallKind::Msi).unwrap().name, "Coucou-Windows-0.5.0.msi");
        assert_eq!(pick_asset(&w, InstallKind::Manual), None);
        // A look-alike name, or one served from elsewhere, is never picked.
        let mut odd = w.clone();
        odd.assets = vec![
            Asset { name: "Coucou-Windows-setup.exe".into(), url: w.assets[0].url.clone(), size: 1, digest: None },
            Asset { name: "Coucou-Windows-0.5.0.msi".into(), url: "https://evil.example.com/x.msi".into(), size: 1, digest: None },
        ];
        assert_eq!(pick_asset(&odd, InstallKind::Setup), None);
        assert_eq!(pick_asset(&odd, InstallKind::Msi), None);
    }

    #[test]
    fn digests_are_sha256_hex_only() {
        let hex = "e8234a092e8fe1bf6eed0395e6db13052be8fe47413949c2b7fa368467342337";
        assert_eq!(parse_digest(&format!("sha256:{hex}")).as_deref(), Some(hex));
        assert_eq!(parse_digest(&format!("sha256:{}", hex.to_uppercase())).as_deref(), Some(hex));
        assert_eq!(parse_digest(hex), None);
        assert_eq!(parse_digest(&format!("sha512:{hex}")), None);
        assert_eq!(parse_digest(&format!("sha256:{}", &hex[1..])), None);
        assert_eq!(parse_digest(&format!("sha256:{}z", &hex[1..])), None);
        assert_eq!(parse_digest(""), None);
    }

    #[test]
    fn installers_run_with_tauris_update_flags() {
        let file = Path::new(r"C:\Temp\coucou-update-1\Coucou-Windows-0.6.0-setup.exe");
        let (program, args) = installer_command(InstallKind::Setup, file, Some(r"C:\Windows")).unwrap();
        assert_eq!(program, file);
        assert_eq!(args, ["/P", "/UPDATE", "/R"]);
        let msi = Path::new(r"C:\Temp\coucou-update-1\Coucou-Windows-0.6.0.msi");
        let (program, args) = installer_command(InstallKind::Msi, msi, Some(r"C:\Windows\")).unwrap();
        assert_eq!(program, PathBuf::from(r"C:\Windows\System32\msiexec.exe"));
        assert_eq!(args, ["/i", r"C:\Temp\coucou-update-1\Coucou-Windows-0.6.0.msi", "/passive", "AUTOLAUNCHAPP=True"]);
        assert_eq!(installer_command(InstallKind::Msi, msi, None).unwrap().0, PathBuf::from("msiexec.exe"));
        assert_eq!(installer_command(InstallKind::Manual, file, None), None);
    }

    #[test]
    fn checks_every_six_hours_and_asks_again_after_a_day() {
        let now = 1_000_000;
        assert!(should_check(None, now));
        assert!(!should_check(Some(now - CHECK_INTERVAL + 1), now));
        assert!(should_check(Some(now - CHECK_INTERVAL), now));
        assert!(should_check(Some(now + 60), now)); // clock set back
        assert!(should_ask(None, now));
        assert!(!should_ask(Some(now - 3600), now));
        assert!(should_ask(Some(now - ASK_AGAIN), now));
    }

    #[test]
    fn a_version_is_announced_once_a_day_and_a_newer_one_at_once() {
        let now = 1_000_000;
        assert!(should_announce("0.6.0", "0.5.0", None, None, now));
        assert!(!should_announce("0.5.0", "0.5.0", None, None, now));
        assert!(!should_announce("0.4.0", "0.5.0", None, None, now));
        assert!(!should_announce("0.6.0", "0.5.0", Some("0.6.0"), Some(now - 3600), now));
        assert!(should_announce("0.6.0", "0.5.0", Some("0.6.0"), Some(now - SNOOZE), now));
        assert!(should_announce("0.6.1", "0.5.0", Some("0.6.0"), Some(now - 60), now));
        assert!(should_announce("0.6.0", "0.5.0", Some("0.6.0"), Some(now + 600), now));
    }

    #[test]
    fn prefs_load_from_older_or_partial_files() {
        let p: Prefs = serde_json::from_str(r#"{"consent":true}"#).unwrap();
        assert_eq!(p.consent, Some(true));
        assert_eq!(p.last_check, None);
        let p: Prefs = serde_json::from_str("{}").unwrap();
        assert_eq!(p, Prefs::default());
        let round: Prefs = serde_json::from_str(&serde_json::to_string(&Prefs {
            consent: Some(false), last_check: Some(5), snoozed_version: Some("0.6.0".into()), snoozed_at: Some(6), asked_at: Some(7),
        }).unwrap()).unwrap();
        assert_eq!(round.snoozed_version.as_deref(), Some("0.6.0"));
        assert_eq!(round.asked_at, Some(7));
    }
}
