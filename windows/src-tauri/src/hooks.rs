// Claude Code hook installation.
//
// The rule from CLAUDE.md is strict and is followed to the letter:
// read %USERPROFILE%\.claude\settings.json, take a dated backup, merge without
// touching anybody else's hooks, show the diff, and write only after an explicit
// click. Uninstall removes Coucou's entries and nothing else.
//
// The command is only the quoted exe path in forward slashes plus the event name:
// on Windows Claude Code runs hook commands through Git Bash, and anything with
// PowerShell or cmd in it breaks.
//
// Reading, the diff, the backup and the write itself live in config_file.rs,
// shared with every other agent's installer (agents.rs).

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Map, Value};
use tauri::{AppHandle, Manager};
use crate::agents::{self, Shell};
use crate::config_file::{self, FileEdit};
use crate::{platform, settings};

/// Every event the island reacts to, with the hook timeout written to settings.json.
/// PermissionRequest waits for a human, so it gets the decision timeout + 10 s.
pub const HOOK_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("SessionEnd", 10),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PostToolUse", 10),
    ("PostToolUseFailure", 10),
    ("PermissionRequest", 120),
    ("Notification", 10),
    ("Stop", 10),
    ("StopFailure", 10),
    ("SubagentStart", 10),
    ("SubagentStop", 10),
];

/// Marker that identifies a Coucou entry inside settings.json.
const MARKER: &str = "coucou-hook";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookStatus {
    pub installed: bool,
    /// Coucou's status line relay (plan usage) is the one in settings.json.
    pub plan_relay_installed: bool,
    pub settings_path: String,
    pub hook_path: String,
    pub hook_ready: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookPreview {
    pub diff: String,
    pub backup: String,
    pub settings_path: String,
    /// Identifies the bytes this diff was computed from; handed back to `write`
    /// so we only ever apply what the user actually looked at.
    pub fingerprint: String,
}

pub fn settings_path() -> PathBuf {
    platform::home_dir().join(".claude").join("settings.json")
}

/// The settings as they are, or an empty object when we cannot tell. Only for
/// read-only paths like `status()`, which must never fail loudly; anything that
/// writes goes through `config_file`, which surfaces the error instead.
fn read_settings_lossy() -> Value {
    config_file::read(&settings_path())
        .ok()
        .and_then(|bytes| config_file::parse_json(bytes.as_deref(), "settings.json").ok())
        .unwrap_or_else(|| json!({}))
}

/// On Windows Claude Code runs hook commands through Git Bash; on Linux through
/// `sh`. Either way the relay path is one quoted shell word.
fn hook_command(event: &str) -> String {
    agents::relay_command(Shell::Sh, event)
}

fn entry_is_ours(entry: &Value) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .map(|hooks| {
            hooks.iter().any(|h| {
                h.get("command")
                    .and_then(Value::as_str)
                    .map(|c| c.contains(MARKER))
                    .unwrap_or(false)
            })
        })
        .unwrap_or(false)
}

/// The status line in settings.json is Coucou's relay (old installs wrote
/// `coucou-hook StatusLine`, new ones `coucou-hook --statusline`; both match).
fn status_line_is_ours(v: &Value) -> bool {
    v.get("command").and_then(Value::as_str).is_some_and(|c| c.contains(MARKER))
}

/// Settings with Coucou's hooks added; everything else is left untouched. A
/// `hooks` (or one of its events) that is not what Claude Code documents is
/// refused rather than replaced.
fn merged(existing: &Value) -> Result<Value, String> {
    merged_with(existing, &hook_command)
}

/// `merged` with the command to write for each event: the Windows relay's, or
/// the one a WSL distro runs it by (wsl.rs).
fn merged_with(existing: &Value, command: &dyn Fn(&str) -> String) -> Result<Value, String> {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let mut hooks = match root.get("hooks") {
        None => Map::new(),
        Some(Value::Object(h)) => h.clone(),
        Some(_) => return Err(unexpected("\"hooks\"")),
    };

    for (event, timeout) in HOOK_EVENTS {
        let mut list = match hooks.get(*event) {
            None => Vec::new(),
            Some(Value::Array(list)) => list.clone(),
            Some(_) => return Err(unexpected(&format!("\"hooks\".\"{event}\""))),
        };
        list.retain(|entry| !entry_is_ours(entry));
        list.push(json!({
            "hooks": [{
                "type": "command",
                "command": command(event),
                "timeout": timeout,
            }]
        }));
        hooks.insert((*event).to_string(), Value::Array(list));
    }

    root.insert("hooks".into(), Value::Object(hooks));
    Ok(Value::Object(root))
}

fn unexpected(what: &str) -> String {
    crate::i18n::tf("settings.json: {what} has an unexpected type — Coucou has not touched it.", &[("what", what)])
}

/// Settings with every Coucou entry removed, and nothing else changed.
fn without_ours(existing: &Value) -> Result<Value, String> {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let hooks = match root.get("hooks") {
        None => return Ok(Value::Object(root)),
        Some(Value::Object(h)) => h.clone(),
        Some(_) => return Err(unexpected("\"hooks\"")),
    };
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let kept: Vec<Value> =
                    list.iter().filter(|e| !entry_is_ours(e)).cloned().collect();
                if !kept.is_empty() {
                    out.insert(event, Value::Array(kept));
                }
            }
            None => {
                out.insert(event, value);
            }
        }
    }
    if out.is_empty() {
        root.remove("hooks");
    } else {
        root.insert("hooks".into(), Value::Object(out));
    }
    Ok(Value::Object(root))
}

fn edits(install: bool) -> Vec<FileEdit<'static>> {
    vec![FileEdit {
        path: settings_path(),
        edit: config_file::json_edit("settings.json".into(), move |current| {
            if install { merged(current).map(Some) } else { without_ours(current).map(Some) }
        }),
    }]
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn status() -> HookStatus {
    let current = read_settings_lossy();
    let installed = current
        .get("hooks")
        .and_then(Value::as_object)
        .map(|hooks| {
            hooks
                .values()
                .filter_map(Value::as_array)
                .flatten()
                .any(entry_is_ours)
        })
        .unwrap_or(false);
    let hook_path = settings::hook_exe_path();
    HookStatus {
        installed,
        plan_relay_installed: plan_relay_installed(&current),
        settings_path: settings_path().to_string_lossy().to_string(),
        hook_ready: hook_path.exists(),
        hook_path: hook_path.to_string_lossy().to_string(),
    }
}

pub fn preview(install: bool) -> Result<HookPreview, String> {
    Ok(plan_to_preview(config_file::preview(&edits(install))?))
}

fn plan_to_preview(plan: config_file::Plan) -> HookPreview {
    HookPreview {
        diff: plan.diff,
        backup: plan.backup,
        settings_path: plan.path,
        fingerprint: plan.fingerprint,
    }
}

/// Writes the merged (or cleaned) settings after taking a dated backup, and
/// returns where the backup went ("" when there was no file to back up).
///
/// `fingerprint` is the one the preview was computed from: a settings.json that
/// changed in between is refused rather than overwritten (see config_file).
pub fn write(install: bool, fingerprint: &str) -> Result<String, String> {
    let backups = config_file::apply(&edits(install), fingerprint)?;
    Ok(backups.first().map(|p| p.to_string_lossy().to_string()).unwrap_or_default())
}

// ── Claude Code in WSL ────────────────────────────────────────────────────────
//
// The same hooks, written in a WSL distro's own ~/.claude/settings.json, which
// Windows reaches as \\wsl.localhost\<distro>\home\<user>\.claude\. Only the
// command differs: it starts coucou-hook.exe through WSL interop (wsl.rs). The
// reading, the diff, the dated backup and the fingerprint are the same code.

/// A settings.json as a value; None when it is missing, unreadable or not JSON.
pub fn read_settings_lossy_at(path: &Path) -> Option<Value> {
    config_file::read(path).ok().and_then(|bytes| config_file::parse_json(bytes.as_deref(), "settings.json").ok())
}

fn wsl_edits(target: &crate::wsl::Target, install: bool) -> Vec<FileEdit<'static>> {
    let relay = target.relay.clone();
    vec![FileEdit {
        path: target.settings_path.clone(),
        edit: config_file::json_edit("settings.json".into(), move |current| {
            if install {
                merged_with(current, &|event| crate::wsl::relay_command(&relay, event)).map(Some)
            } else {
                without_ours(current).map(Some)
            }
        }),
    }]
}

pub fn wsl_preview(distro: &str, user: &str, install: bool) -> Result<HookPreview, String> {
    let target = crate::wsl::resolve(distro, user)?;
    Ok(plan_to_preview(config_file::preview(&wsl_edits(&target, install))?))
}

/// As `write`, for a distro's settings.json; returns where the backup went.
pub fn wsl_write(distro: &str, user: &str, install: bool, fingerprint: &str) -> Result<String, String> {
    let target = crate::wsl::resolve(distro, user)?;
    let backups = config_file::apply(&wsl_edits(&target, install), fingerprint)?;
    Ok(backups.first().map(|p| p.to_string_lossy().to_string()).unwrap_or_default())
}

// ── Status line (plan usage) ──────────────────────────────────────────────────
//
// Claude Code runs one `statusLine` command and hands it the plan limits. Coucou
// puts its relay there; a status line the user already had is kept in
// statusline-previous.json beside the relay, and the relay still runs it, so it
// keeps working. Installing and removing it is separate from the hooks, and
// goes through the same hardened writer (config_file.rs): strict read, diff,
// fingerprint, dated backup, then the write.

/// Where the user's own status line waits while the relay stands in for it.
pub fn status_line_previous_path() -> PathBuf {
    settings::hook_exe_path().with_file_name("statusline-previous.json")
}

fn read_previous_at(path: &Path) -> Option<Value> {
    let bytes = std::fs::read(path).ok()?;
    serde_json::from_slice::<Value>(&bytes).ok().filter(Value::is_object)
}

/// True when the `statusLine` in settings.json is Coucou's relay.
pub fn plan_relay_installed(settings: &Value) -> bool {
    settings.get("statusLine").is_some_and(status_line_is_ours)
}

/// The command of the user's own status line, the one that was there before
/// Coucou's (still in settings.json, or saved when the relay took its place).
fn own_status_line_command(existing: Option<&Value>, previous: Option<&Value>) -> Option<String> {
    let command = |v: &Value| v.get("command").and_then(Value::as_str).map(str::to_string);
    match existing {
        Some(v) if v.is_object() && !status_line_is_ours(v) => command(v),
        Some(v) if status_line_is_ours(v) => previous.and_then(command),
        _ => None,
    }
}

/// `statusLine` as it reads after installing or removing the relay. `None`: the
/// key goes. Installing swaps only `command`, so `padding`, `refreshInterval`
/// and the rest of the user's status line stay as they were. `command` is what
/// goes in, given the user's own command (None if they had none).
fn status_line_after(
    existing: Option<&Value>,
    install: bool,
    previous: Option<&Value>,
    command: &dyn Fn(Option<&str>) -> String,
) -> Option<Value> {
    if install {
        let own = own_status_line_command(existing, previous);
        let mut sl = existing.filter(|v| v.is_object()).cloned().unwrap_or_else(|| json!({}));
        let obj = sl.as_object_mut().expect("an object");
        obj.entry("type").or_insert_with(|| json!("command"));
        obj.insert("command".into(), json!(command(own.as_deref())));
        Some(sl)
    } else if existing.is_some_and(status_line_is_ours) {
        previous.cloned()
    } else {
        existing.cloned() // not ours any more (the user changed it): leave it alone
    }
}

#[cfg(test)]
fn status_line_settings(current: &Value, install: bool, previous: Option<&Value>) -> Result<Value, String> {
    status_line_settings_with(current, install, previous, &|_| hook_command("--statusline"))
}

fn status_line_settings_with(
    current: &Value,
    install: bool,
    previous: Option<&Value>,
    command: &dyn Fn(Option<&str>) -> String,
) -> Result<Value, String> {
    let mut root = current.as_object().cloned().unwrap_or_default();
    // A statusLine that is not an object is something we do not understand:
    // refuse rather than replace it.
    if install && root.get("statusLine").is_some_and(|v| !v.is_object()) {
        return Err(unexpected("\"statusLine\""));
    }
    match status_line_after(root.get("statusLine"), install, previous, command) {
        Some(sl) => root.insert("statusLine".into(), sl),
        None => root.remove("statusLine"),
    };
    Ok(Value::Object(root))
}

/// Where the status line goes in and out, and what goes in: Windows' own
/// settings.json, or a WSL distro's.
/// Builds the status line command for the relay at the given path (`None`: no previous one).
type StatusLineCommand = Box<dyn Fn(Option<&str>) -> String>;

struct StatusLineTarget {
    settings: PathBuf,
    /// Where the user's own status line waits while the relay stands in for it.
    previous: PathBuf,
    command: StatusLineCommand,
}

impl StatusLineTarget {
    fn windows() -> Self {
        StatusLineTarget {
            settings: settings_path(),
            previous: status_line_previous_path(),
            command: Box::new(|_| hook_command("--statusline")),
        }
    }

    /// A distro's: its command embeds the user's own, which runs in the distro
    /// (wsl.rs), so what is saved beside settings.json is only for taking the
    /// relay out again.
    fn wsl(target: &crate::wsl::Target) -> Self {
        let relay = target.relay.clone();
        StatusLineTarget {
            settings: target.settings_path.clone(),
            previous: target.settings_path.with_file_name("coucou-statusline-previous.json"),
            command: Box::new(move |own| crate::wsl::status_line_command(&relay, own)),
        }
    }
}

fn status_line_edits(target: StatusLineTarget, install: bool, previous: Option<Value>) -> Vec<FileEdit<'static>> {
    let StatusLineTarget { settings, command, .. } = target;
    vec![FileEdit {
        path: settings,
        edit: config_file::json_edit("settings.json".into(), move |current| {
            Ok(Some(status_line_settings_with(current, install, previous.as_ref(), &*command)?))
        }),
    }]
}

/// The diff the user has to look at before the relay goes in or out.
pub fn status_line_preview(install: bool) -> Result<HookPreview, String> {
    status_line_preview_at(StatusLineTarget::windows(), install)
}

fn status_line_preview_at(target: StatusLineTarget, install: bool) -> Result<HookPreview, String> {
    let previous = read_previous_at(&target.previous);
    Ok(plan_to_preview(config_file::preview(&status_line_edits(target, install, previous))?))
}

/// Installs or removes the relay, after the same backup and fingerprint checks as
/// the hooks. Installing first saves a status line of the user's own, removing
/// puts it back (or removes the key if there was none).
pub fn status_line_write(install: bool, fingerprint: &str) -> Result<String, String> {
    status_line_write_at(StatusLineTarget::windows(), install, fingerprint)
}

fn status_line_write_at(target: StatusLineTarget, install: bool, fingerprint: &str) -> Result<String, String> {
    let before = config_file::read(&target.settings)
        .and_then(|bytes| config_file::parse_json(bytes.as_deref(), "settings.json"))?;
    let previous_path = target.previous.clone();
    let previous = read_previous_at(&previous_path);
    let own = before.get("statusLine").filter(|v| !status_line_is_ours(v)).cloned();
    let saved = match (install, own.as_ref()) {
        (true, Some(own)) => {
            save_previous_at(&previous_path, own).map_err(|_| {
                crate::i18n::t("Could not save your current status line next to the relay; nothing was changed.")
            })?;
            true
        }
        _ => false,
    };
    let result = config_file::apply(&status_line_edits(target, install, previous), fingerprint);
    match &result {
        // Back in settings.json: the saved copy has done its job.
        Ok(_) if !install => {
            let _ = std::fs::remove_file(&previous_path);
        }
        // Nothing was written: do not leave a stale copy behind.
        Err(_) if saved => {
            let _ = std::fs::remove_file(&previous_path);
        }
        _ => {}
    }
    let backups = result?;
    Ok(backups.first().map(|p| p.to_string_lossy().to_string()).unwrap_or_default())
}

fn save_previous_at(path: &Path, status_line: &Value) -> std::io::Result<()> {
    if let Some(dir) = path.parent() {
        std::fs::create_dir_all(dir)?;
    }
    config_file::write_like(path, path, config_file::pretty(status_line).as_bytes())
}

// ── The plan usage gauge in WSL ───────────────────────────────────────────────

pub fn wsl_status_line_preview(distro: &str, user: &str, install: bool) -> Result<HookPreview, String> {
    let target = crate::wsl::resolve(distro, user)?;
    status_line_preview_at(StatusLineTarget::wsl(&target), install)
}

pub fn wsl_status_line_write(distro: &str, user: &str, install: bool, fingerprint: &str) -> Result<String, String> {
    let target = crate::wsl::resolve(distro, user)?;
    status_line_write_at(StatusLineTarget::wsl(&target), install, fingerprint)
}

/// Copies the relay (coucou-hook.exe / coucou-hook) into the local data dir's
/// bin/ on launch. In a bundled install it comes from the app resources; in
/// `tauri dev` it sits next to the app binary in the workspace target directory.
///
/// Every candidate is tried rather than just the first, because getting this
/// wrong is silent and fatal: `resources` used to be a glob, which made NSIS
/// mirror the source path into `_up_\target\release\`, no candidate matched, and
/// the relay was simply never installed. It only looked healthy on a developer
/// machine, where a leftover copy from `tauri dev` was already sitting in bin/.
pub fn ensure_hook_exe(app: &AppHandle) {
    let dest = settings::hook_exe_path();
    let Some(dir) = dest.parent() else { return };
    // Nobody else may swap the relay Claude Code runs: its folder is ours only.
    if platform::ensure_private_dir(&settings::local_dir()).is_err()
        || std::fs::create_dir_all(dir).is_err()
    {
        return;
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(p) = app.path().resolve(platform::HOOK_EXE, tauri::path::BaseDirectory::Resource) {
        candidates.push(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            // Installed build, then `tauri dev` (target/debug) next to the
            // release hook the pre-build step produces.
            candidates.push(parent.join(platform::HOOK_EXE));
            candidates.push(parent.join("../release").join(platform::HOOK_EXE));
            // Belt and braces: where the old glob form used to land it.
            candidates.push(parent.join("_up_/target/release").join(platform::HOOK_EXE));
        }
    }

    let tried: Vec<String> = candidates.iter().map(|p| p.display().to_string()).collect();
    let Some(src) = candidates.into_iter().find(|p| p.exists()) else {
        crate::log::line(format!(
            "{} not found — Claude Code hooks cannot work. Looked in: {}",
            platform::HOOK_EXE,
            tried.join(", ")
        ));
        return;
    };
    install_relay(&src, &dest);
}

#[cfg(windows)]
fn install_relay(src: &Path, dest: &Path) {
    let same = match (std::fs::metadata(src), std::fs::metadata(dest)) {
        (Ok(a), Ok(b)) => a.len() == b.len() && a.modified().ok() == b.modified().ok(),
        _ => false,
    };
    if same {
        return;
    }
    // A hook may be running right now and hold the file open; keeping the old
    // copy is fine, it is the same relay.
    if let Err(err) = std::fs::copy(src, dest) {
        if !dest.exists() {
            crate::log::line(format!("could not install {}: {err}", platform::HOOK_EXE));
        }
    }
}

/// Linux does not keep the modification time on copy, so the contents decide.
/// The new relay is written beside the old one and renamed over it: a hook
/// starting at that moment runs either the old relay or the new one, never half
/// of one, and a relay that is running right now does not block the update.
#[cfg(unix)]
fn install_relay(src: &Path, dest: &Path) {
    use std::os::unix::fs::PermissionsExt;
    if matches!((std::fs::read(src), std::fs::read(dest)), (Ok(a), Ok(b)) if a == b) {
        return;
    }
    let temp = dest.with_extension(format!("new-{}", std::process::id()));
    let result = std::fs::copy(src, &temp)
        .and_then(|_| std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o755)))
        .and_then(|_| std::fs::rename(&temp, dest));
    if let Err(err) = result {
        let _ = std::fs::remove_file(&temp);
        crate::log::line(format!("could not install {}: {err}", platform::HOOK_EXE));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_wsl_hooks_sit_beside_the_users_own_and_go_again_cleanly() {
        let relay = "/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe";
        let command = |event: &str| crate::wsl::relay_command(relay, event);
        let theirs = json!({
            "model": "opus",
            "statusLine": { "type": "command", "command": "~/bin/line" },
            "hooks": {
                "PreToolUse": [{ "hooks": [{ "type": "command", "command": "rtk hook claude" }] }],
                "Stop": [{ "hooks": [{ "type": "command", "command": "/home/me/pulse/notify.sh" }] }],
            }
        });
        let after = merged_with(&theirs, &command).unwrap();
        // Everything that was there is still there, in its place.
        assert_eq!(after["model"], "opus");
        assert_eq!(after["statusLine"], theirs["statusLine"]);
        assert_eq!(after["hooks"]["PreToolUse"][0], theirs["hooks"]["PreToolUse"][0]);
        assert_eq!(after["hooks"]["Stop"][0], theirs["hooks"]["Stop"][0]);
        // Ours is added to every event, with the WSL command and the right timeout.
        for (event, timeout) in HOOK_EVENTS {
            let list = after["hooks"][event].as_array().unwrap();
            let ours = list.last().unwrap();
            assert!(entry_is_ours(ours), "{event}");
            assert_eq!(ours["hooks"][0]["command"], command(event));
            assert_eq!(ours["hooks"][0]["timeout"], *timeout);
        }
        // Again: still one of ours per event.
        let twice = merged_with(&after, &command).unwrap();
        assert_eq!(twice, after);
        // Removing it gives back exactly what the user had.
        assert_eq!(without_ours(&after).unwrap(), theirs);
    }

    #[test]
    fn the_wsl_status_line_embeds_the_users_own_and_gives_it_back() {
        let relay = "/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe";
        let command = |own: Option<&str>| crate::wsl::status_line_command(relay, own);
        let own = json!({ "type": "command", "command": "bash ~/.claude/statusline.sh", "padding": 1 });
        let theirs = json!({ "model": "opus", "statusLine": own });

        let installed = status_line_settings_with(&theirs, true, None, &command).unwrap();
        let line = &installed["statusLine"];
        assert!(status_line_is_ours(line));
        assert!(line["command"].as_str().unwrap().contains("bash ~/.claude/statusline.sh"));
        assert_eq!(line["padding"], 1);
        assert_eq!(installed["model"], "opus");

        // Installing again keeps their command in it, taken from the saved copy
        // now that settings.json no longer holds it.
        let again = status_line_settings_with(&installed, true, Some(&own), &command).unwrap();
        assert_eq!(again, installed);

        // Taking it out gives back exactly what they had.
        assert_eq!(status_line_settings_with(&installed, false, Some(&own), &command).unwrap(), theirs);

        // None of their own: the relay alone, and the key goes when it leaves.
        let bare = status_line_settings_with(&json!({}), true, None, &command).unwrap();
        assert!(bare["statusLine"]["command"].as_str().unwrap().ends_with("| :"));
        assert!(status_line_settings_with(&bare, false, None, &command).unwrap().get("statusLine").is_none());
    }

    #[test]
    fn the_hooks_leave_the_status_line_alone() {
        let theirs = json!({ "statusLine": { "type": "command", "command": "~/bin/my-line" } });
        assert_eq!(merged(&theirs).unwrap()["statusLine"], theirs["statusLine"]);
        assert_eq!(without_ours(&theirs).unwrap()["statusLine"], theirs["statusLine"]);
        assert!(merged(&json!({})).unwrap().get("statusLine").is_none());
    }

    #[test]
    fn the_relay_takes_the_status_line_and_keeps_the_users_other_fields() {
        // None yet: ours is added.
        let fresh = status_line_settings(&json!({ "model": "opus" }), true, None).unwrap();
        assert!(status_line_is_ours(&fresh["statusLine"]));
        assert_eq!(fresh["statusLine"]["type"], "command");
        assert_eq!(fresh["model"], "opus");

        // Their own: only the command is swapped; padding and refresh stay.
        let own = json!({ "statusLine": { "type": "command", "command": "~/bin/my-line", "padding": 2, "refreshInterval": 5 } });
        let taken = status_line_settings(&own, true, None).unwrap();
        assert!(status_line_is_ours(&taken["statusLine"]));
        assert_eq!(taken["statusLine"]["padding"], 2);
        assert_eq!(taken["statusLine"]["refreshInterval"], 5);

        // Installing again keeps ours and its extra fields.
        let again = status_line_settings(&taken, true, None).unwrap();
        assert_eq!(again["statusLine"]["padding"], 2);
        assert!(status_line_is_ours(&again["statusLine"]));
    }

    #[test]
    fn removing_the_relay_restores_what_was_there_and_never_touches_anything_else() {
        let previous = json!({ "type": "command", "command": "~/bin/my-line", "padding": 2 });
        let ours = status_line_settings(&json!({}), true, None).unwrap();

        // There was one before: it comes back exactly.
        assert_eq!(status_line_settings(&ours, false, Some(&previous)).unwrap()["statusLine"], previous);
        // There was none: the key goes.
        assert!(status_line_settings(&ours, false, None).unwrap().get("statusLine").is_none());
        // The user changed it since: not ours, so untouched.
        let theirs = json!({ "statusLine": { "type": "command", "command": "~/bin/other" } });
        assert_eq!(status_line_settings(&theirs, false, Some(&previous)).unwrap()["statusLine"], theirs["statusLine"]);
        // A statusLine we do not understand is refused, never replaced.
        assert!(status_line_settings(&json!({ "statusLine": "echo hi" }), true, None).is_err());
    }

    #[test]
    fn merging_keeps_every_other_setting_and_every_foreign_hook() {
        let existing = serde_json::json!({
            "model": "claude-opus-5",
            "theme": "dark",
            "enabledPlugins": ["a", "b"],
            "hooks": {
                "PreToolUse": [
                    { "hooks": [{ "type": "command", "command": "someone-elses-tool.exe" }] }
                ],
                "SomeEventWeDoNotTouch": [
                    { "hooks": [{ "type": "command", "command": "keep-me.exe" }] }
                ]
            }
        });

        let after = merged(&existing).unwrap();
        assert_eq!(after["model"], "claude-opus-5");
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["enabledPlugins"], serde_json::json!(["a", "b"]));

        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(
            pre.iter().any(|e| serde_json::to_string(e).unwrap().contains("someone-elses-tool.exe")),
            "another tool's hook was dropped"
        );
        assert!(pre.iter().any(entry_is_ours), "our own hook was not added");
        assert!(after["hooks"]["SomeEventWeDoNotTouch"].is_array());

        // Installing twice still leaves one entry of ours per event. (Compared
        // by count: another test points HOME elsewhere meanwhile, which moves
        // the relay path.)
        let twice = merged(&after).unwrap();
        assert_eq!(twice["hooks"]["PreToolUse"].as_array().unwrap().iter().filter(|e| entry_is_ours(e)).count(), 1);

        // And removing ours puts it back exactly as it was.
        let cleaned = without_ours(&after).unwrap();
        assert_eq!(cleaned, existing);
    }

    #[test]
    fn values_of_an_unexpected_type_are_refused_not_replaced() {
        for odd in [
            json!({ "hooks": "a string" }),
            json!({ "hooks": [1, 2] }),
            json!({ "hooks": { "PreToolUse": { "not": "a list" } } }),
        ] {
            assert!(merged(&odd).is_err(), "{odd}");
        }
        assert!(without_ours(&json!({ "hooks": 3 })).is_err());
        // An event we do not install stays as it is, whatever its shape.
        let kept = json!({ "hooks": { "Custom": "anything" } });
        assert_eq!(without_ours(&kept).unwrap(), kept);
    }

    /// Everything filesystem-shaped lives in one test on purpose: it points
    /// the home directory at a temp directory, and that is process-wide.
    #[test]
    fn writing_backs_up_preserves_and_refuses_a_changed_file() {
        let tmp = std::env::temp_dir().join(format!("coucou-hooks-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&tmp);
        std::fs::create_dir_all(tmp.join(".claude")).unwrap();
        std::env::set_var(platform::HOME_VAR, &tmp);

        let path = settings_path();
        assert!(path.starts_with(&tmp), "the test must not touch the real home");

        // A real-shaped file, written the way PowerShell 5 would: UTF-8 with BOM.
        let original = r#"{"model":"claude-opus-5","theme":"dark","tui":{"x":1},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool.exe"}]}]}}"#;
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(original.as_bytes());
        std::fs::write(&path, &bytes).unwrap();

        // Install.
        let plan = preview(true).expect("a BOM must not stop the preview");
        assert!(plan.diff.contains("coucou-hook"), "the diff must show what changes");
        let backup = write(true, &plan.fingerprint).expect("install should succeed");

        // The backup holds the original bytes, BOM and all.
        assert_eq!(std::fs::read(&backup).unwrap(), bytes);

        // Everything else survived, and so did the other tool's hook.
        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after["model"], "claude-opus-5");
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["tui"]["x"], 1);
        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(pre.iter().any(|e| serde_json::to_string(e).unwrap().contains("other-tool.exe")));
        assert!(status().installed);

        // A file that moved since the preview is refused, and left alone.
        let stale = preview(false).unwrap();
        std::fs::write(&path, br#"{"model":"someone-else-edited-this"}"#).unwrap();
        let err = write(false, &stale.fingerprint).unwrap_err();
        assert!(err.contains("changed since the preview"), "got: {err}");
        let untouched: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(untouched["model"], "someone-else-edited-this");

        // Content we cannot parse is refused before anything is written.
        std::fs::write(&path, b"{ broken").unwrap();
        assert!(preview(true).is_err());
        assert!(write(true, "whatever").is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"{ broken");

        let _ = std::fs::remove_dir_all(&tmp);
    }
}
