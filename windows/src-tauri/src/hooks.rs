// Claude Code and Codex hook installation.
//
// The rule from CLAUDE.md is strict and is followed to the letter:
// read %USERPROFILE%\.claude\settings.json, take a dated backup, merge without
// touching anybody else's hooks, show the diff, and write only after an explicit
// click. Uninstall removes Coucou's entries and nothing else.
//
// Commands use a quoted executable path in forward slashes, an explicit provider,
// and the event name. Claude Code runs commands through Git Bash, so shell
// wrappers are deliberately avoided.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::{json, Map, Value};
use tauri::{AppHandle, Manager};
use windows::Win32::System::SystemInformation::GetLocalTime;

use crate::settings;

/// Events Coucou consumes from Claude Code. PermissionRequest waits for a human.
const CLAUDE_EVENTS: &[(&str, u64)] = &[
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

/// Codex's event vocabulary and timeout limits. In particular, Codex does not
/// define Claude's Notification, PostToolUseFailure, or StopFailure events.
/// SessionEnd and Interrupt have a three-second maximum timeout in Codex.
const CODEX_EVENTS: &[(&str, u64)] = &[
    ("SessionStart", 10),
    ("SessionEnd", 3),
    ("UserPromptSubmit", 10),
    ("PreToolUse", 10),
    ("PostToolUse", 10),
    ("PermissionRequest", 120),
    ("Stop", 10),
    ("SubagentStart", 10),
    ("SubagentStop", 10),
    ("Interrupt", 3),
    ("PreCompact", 10),
    ("PostCompact", 10),
];

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum Provider {
    Claude,
    Codex,
}

impl Provider {
    fn parse(value: &str) -> Result<Self, String> {
        match value {
            "claude" => Ok(Self::Claude),
            "codex" => Ok(Self::Codex),
            _ => Err(format!(
                "Unknown hook provider '{value}'. Expected 'claude' or 'codex'."
            )),
        }
    }

    fn name(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
        }
    }

    fn events(self) -> &'static [(&'static str, u64)] {
        match self {
            Self::Claude => CLAUDE_EVENTS,
            Self::Codex => CODEX_EVENTS,
        }
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct HookStatus {
    pub installed: bool,
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

fn resolve_settings_path(
    provider: Provider,
    codex_home: Option<&std::ffi::OsStr>,
    user_profile: Option<&std::ffi::OsStr>,
) -> PathBuf {
    let home = user_profile
        .filter(|value| !value.is_empty())
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    match provider {
        Provider::Claude => home.join(".claude").join("settings.json"),
        Provider::Codex => codex_home
            .filter(|value| !value.is_empty())
            .map(PathBuf::from)
            .unwrap_or_else(|| home.join(".codex"))
            .join("hooks.json"),
    }
}

fn provider_settings_path(provider: Provider) -> PathBuf {
    resolve_settings_path(
        provider,
        std::env::var_os("CODEX_HOME").as_deref(),
        std::env::var_os("USERPROFILE").as_deref(),
    )
}

/// Legacy path helper retained for existing callers and tests.
pub fn settings_path() -> PathBuf {
    provider_settings_path(Provider::Claude)
}

/// Read one provider settings file from an explicit path.
///
/// The only error that means "start from nothing" is the file not being there.
/// Everything else — a lock held by another process, a permission problem, JSON
/// we cannot parse — is reported, because the alternative is treating somebody's
/// unreadable settings as an empty object and then writing that back over them.
fn read_settings_at(path: &Path) -> Result<Value, String> {
    let (bytes, _) = read_file_snapshot(path)?;
    parse_settings(&bytes, &path.display().to_string())
}

fn read_file_snapshot(path: &Path) -> Result<(Vec<u8>, bool), String> {
    match std::fs::read(path) {
        Ok(bytes) => Ok((bytes, true)),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok((Vec::new(), false)),
        // A lock, a permission problem, a bad drive: all of them mean we do not
        // know what is in there, and not knowing is not the same as empty.
        Err(err) => Err(format!("Can't read {}: {err}", path.display())),
    }
}

fn read_settings_snapshot(path: &Path) -> Result<(Value, String), String> {
    let (bytes, _) = read_file_snapshot(path)?;
    let current = parse_settings(&bytes, &path.display().to_string())?;
    Ok((current, fingerprint(&bytes)))
}

/// Parse bytes independently so malformed settings can be tested without a
/// real home directory.
fn parse_settings(bytes: &[u8], path: &str) -> Result<Value, String> {
    // PowerShell writes a UTF-8 BOM with `Set-Content -Encoding utf8`, and
    // serde_json refuses it. Stripping it is safe and well defined; guessing at
    // anything else is not.
    let text = bytes.strip_prefix(&[0xEF, 0xBB, 0xBF]).unwrap_or(bytes);
    if text.iter().all(u8::is_ascii_whitespace) {
        return Ok(json!({}));
    }
    match serde_json::from_slice::<Value>(text) {
        Ok(v) if v.is_object() => Ok(v),
        Ok(_) => Err(format!("{path} isn't a JSON object — Coucou won't touch it.")),
        Err(err) => Err(format!(
            "{path} isn't valid JSON ({err}). Fix or move it, then try again — Coucou won't overwrite it."
        )),
    }
}

/// The settings as they are, or an empty object when we cannot tell. Only for
/// read-only paths like `status()`, which must never fail loudly; anything that
/// writes uses `read_settings()` and surfaces the error instead.
fn read_settings_lossy_at(path: &Path) -> Value {
    read_settings_at(path).unwrap_or_else(|_| json!({}))
}

fn hook_command(provider: Provider, event: &str) -> String {
    let exe = settings::hook_exe_path()
        .to_string_lossy()
        .replace('\\', "/");
    format!("\"{exe}\" {} {event}", provider.name())
}

fn hook_command_windows(provider: Provider, event: &str) -> String {
    let path = settings::hook_exe_path();
    let exe = path.to_string_lossy();
    format!("\"{exe}\" {} {event}", provider.name())
}

/// Split a hook command into its executable and whitespace-delimited arguments.
/// Coucou writes a quoted executable path, which also handles install paths with
/// spaces. Unquoted paths are accepted for older settings files.
fn hook_command_parts(command: &str) -> Option<(&str, Vec<&str>)> {
    let command = command.trim();
    let (executable, rest) = if let Some(quoted) = command.strip_prefix('"') {
        let close = quoted.find('"')?;
        let rest = &quoted[close + 1..];
        if !rest.is_empty() && !rest.chars().next().is_some_and(char::is_whitespace) {
            return None;
        }
        (&quoted[..close], rest)
    } else {
        match command.find(char::is_whitespace) {
            Some(first_space) => (&command[..first_space], &command[first_space..]),
            None => (command, ""),
        }
    };
    Some((executable, rest.split_whitespace().collect()))
}

/// Kept as a small helper for tests that verify generated Windows commands.
#[cfg(test)]
fn hook_args(command: &str) -> Option<Vec<&str>> {
    hook_command_parts(command).map(|(_, args)| args)
}

fn is_coucou_hook_executable(executable: &str) -> bool {
    let basename = executable.rsplit(['/', '\\']).next().unwrap_or(executable);
    basename.eq_ignore_ascii_case("coucou-hook") || basename.eq_ignore_ascii_case("coucou-hook.exe")
}

fn known_hook_event(event: &str) -> bool {
    CLAUDE_EVENTS.iter().any(|(known, _)| *known == event)
        || CODEX_EVENTS.iter().any(|(known, _)| *known == event)
}

fn command_is_ours(command: &str, provider: Provider) -> bool {
    let Some((executable, args)) = hook_command_parts(command) else {
        return false;
    };
    if !is_coucou_hook_executable(executable) {
        return false;
    }

    if args.len() == 2 {
        args[0] == provider.name() && known_hook_event(args[1])
    } else {
        // Older Coucou installs only supported Claude and called
        // `coucou-hook <Event>`. Preserve this narrow backwards-compatibility
        // path while refusing marker-like commands and unknown events.
        provider == Provider::Claude
            && args.len() == 1
            && CLAUDE_EVENTS.iter().any(|(known, _)| *known == args[0])
    }
}

fn handler_is_ours(handler: &Value, provider: Provider) -> bool {
    let Some(object) = handler.as_object() else {
        return false;
    };
    ["command", "commandWindows"].iter().any(|field| {
        object
            .get(*field)
            .and_then(Value::as_str)
            .is_some_and(|command| command_is_ours(command, provider))
    })
}

fn entry_is_ours(entry: &Value, provider: Provider) -> bool {
    entry
        .get("hooks")
        .and_then(Value::as_array)
        .is_some_and(|hooks| {
            hooks
                .iter()
                .any(|handler| handler_is_ours(handler, provider))
        })
}

/// Remove Coucou's handler from a matcher group while preserving the group's
/// matcher, metadata, and any foreign handlers alongside it. The group itself
/// disappears only when its handler list becomes empty.
fn remove_ours_from_entry(entry: &Value, provider: Provider) -> (Option<Value>, bool) {
    let Some(object) = entry.as_object() else {
        return (Some(entry.clone()), false);
    };
    let Some(handlers) = object.get("hooks").and_then(Value::as_array) else {
        return (Some(entry.clone()), false);
    };
    let kept: Vec<Value> = handlers
        .iter()
        .filter(|handler| !handler_is_ours(handler, provider))
        .cloned()
        .collect();
    if kept.len() == handlers.len() {
        return (Some(entry.clone()), false);
    }
    if kept.is_empty() {
        return (None, true);
    }
    let mut retained = object.clone();
    retained.insert("hooks".into(), Value::Array(kept));
    (Some(Value::Object(retained)), true)
}

fn remove_ours_from_list(list: &[Value], provider: Provider) -> (Vec<Value>, bool) {
    let mut kept = Vec::with_capacity(list.len());
    let mut removed_any = false;
    for entry in list {
        let (entry, removed) = remove_ours_from_entry(entry, provider);
        if let Some(entry) = entry {
            kept.push(entry);
        }
        removed_any |= removed;
    }
    (kept, removed_any)
}

/// Settings with Coucou's hooks added; everything else is left untouched.
fn merged(existing: &Value, provider: Provider) -> Result<Value, String> {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let mut hooks = match root.get("hooks") {
        None => Map::new(),
        Some(Value::Object(hooks)) => hooks.clone(),
        Some(_) => {
            return Err(
                "The existing 'hooks' setting isn't an object; refusing to replace it.".into(),
            )
        }
    };

    // Remove only this provider's old entries, including stale event names.
    // Keep malformed or foreign event values intact unless a target event must
    // be appended, in which case fail rather than clobbering them.
    let mut empty_after_cleanup = Vec::new();
    for (event, value) in hooks.iter_mut() {
        if let Some(list) = value.as_array_mut() {
            let (kept, had_ours) = remove_ours_from_list(list, provider);
            *list = kept;
            if had_ours && list.is_empty() {
                empty_after_cleanup.push(event.clone());
            }
        }
    }
    for event in empty_after_cleanup {
        hooks.remove(&event);
    }

    for (event, timeout) in provider.events() {
        let mut list = match hooks.get(*event) {
            None => Vec::new(),
            Some(Value::Array(entries)) => entries.clone(),
            Some(_) => {
                return Err(format!(
                    "The existing '{event}' hooks setting isn't an array; refusing to replace it."
                ))
            }
        };
        let mut handler = json!({
            "type": "command",
            "command": hook_command(provider, event),
            "timeout": timeout,
        });
        if provider == Provider::Codex {
            // Codex supports an explicit Windows command override. Keep the
            // portable `command` marker stable for cleanup and use native
            // separators for the Windows CLI's invocation path.
            handler["commandWindows"] = json!(hook_command_windows(provider, event));
        }
        list.push(json!({ "hooks": [handler] }));
        hooks.insert((*event).to_string(), Value::Array(list));
    }

    root.insert("hooks".into(), Value::Object(hooks));
    Ok(Value::Object(root))
}

/// Settings with every Coucou entry removed, and nothing else changed.
fn without_ours(existing: &Value, provider: Provider) -> Value {
    let mut root = existing.as_object().cloned().unwrap_or_default();
    let Some(hooks) = root.get("hooks").and_then(Value::as_object).cloned() else {
        return Value::Object(root);
    };
    let mut out = Map::new();
    for (event, value) in hooks {
        match value.as_array() {
            Some(list) => {
                let (kept, removed_any) = remove_ours_from_list(list, provider);
                if !kept.is_empty() || !removed_any {
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
    Value::Object(root)
}

fn pretty(v: &Value) -> String {
    serde_json::to_string_pretty(v).unwrap_or_default()
}

/// Down to the second: installing then uninstalling in the same minute must not
/// quietly overwrite the first backup.
fn stamp() -> String {
    let t = unsafe { GetLocalTime() };
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

fn backup_path_for(path: &Path) -> PathBuf {
    let stem = format!(
        "{}.bak-{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        stamp()
    );
    let mut candidate = path.with_file_name(&stem);
    let mut suffix = 1u32;
    while candidate.exists() {
        candidate = path.with_file_name(format!("{stem}-{suffix}"));
        suffix = suffix.saturating_add(1);
    }
    candidate
}

/// Create a unique backup without ever replacing an earlier snapshot, even if
/// two installs land in the same second or two Coucou processes race.
fn create_backup(path: &Path, bytes: &[u8]) -> Result<PathBuf, String> {
    let stem = format!(
        "{}.bak-{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        stamp()
    );
    for suffix in 0u32.. {
        let candidate = if suffix == 0 {
            path.with_file_name(&stem)
        } else {
            path.with_file_name(format!("{stem}-{suffix}"))
        };
        let mut file = match std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&candidate)
        {
            Ok(file) => file,
            Err(err) if err.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(err) => return Err(format!("backup failed: {err}")),
        };
        if let Err(err) = file.write_all(bytes) {
            let _ = std::fs::remove_file(&candidate);
            return Err(format!("backup failed: {err}"));
        }
        return Ok(candidate);
    }
    Err("backup failed: exhausted unique backup names".into())
}

/// Identifies the exact bytes a preview was computed from. FNV-1a is plenty:
/// the question is only "is this still the file I showed the user?".
fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

fn current_fingerprint_at(path: &Path) -> Result<String, String> {
    let (bytes, _) = read_file_snapshot(path)?;
    Ok(fingerprint(&bytes))
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn status() -> HookStatus {
    status_at(Provider::Claude, &settings_path())
}

/// Return status for one explicitly selected provider. Unknown provider names
/// are errors instead of silently querying the Claude installation.
pub fn status_for(provider: &str) -> Result<HookStatus, String> {
    let provider = Provider::parse(provider)?;
    Ok(status_at(provider, &provider_settings_path(provider)))
}

fn status_at(provider: Provider, path: &Path) -> HookStatus {
    let current = read_settings_lossy_at(path);
    let installed = current
        .get("hooks")
        .and_then(Value::as_object)
        .map(|hooks| {
            hooks
                .values()
                .filter_map(Value::as_array)
                .flatten()
                .any(|entry| entry_is_ours(entry, provider))
        })
        .unwrap_or(false);
    let hook_path = settings::hook_exe_path();
    HookStatus {
        installed,
        settings_path: path.to_string_lossy().to_string(),
        hook_ready: hook_path.exists(),
        hook_path: hook_path.to_string_lossy().to_string(),
    }
}

pub fn preview_for(provider: &str, install: bool) -> Result<HookPreview, String> {
    let provider = Provider::parse(provider)?;
    preview_at(provider, &provider_settings_path(provider), install)
}

fn preview_at(provider: Provider, path: &Path, install: bool) -> Result<HookPreview, String> {
    let (current, current_fingerprint) = read_settings_snapshot(path)?;
    let next = if install {
        merged(&current, provider)?
    } else {
        without_ours(&current, provider)
    };
    Ok(HookPreview {
        diff: unified_diff(&pretty(&current), &pretty(&next)),
        backup: backup_path_for(path).to_string_lossy().to_string(),
        settings_path: path.to_string_lossy().to_string(),
        fingerprint: current_fingerprint,
    })
}

/// Writes the merged (or cleaned) settings after taking a dated backup.
///
/// `fingerprint` is the one the preview was computed from. If the file changed
/// in between — another tool, another window, the user's own editor — we stop
/// and make them look at a fresh diff, because the only thing worse than not
/// installing the hooks is silently reverting somebody else's edit.
pub fn write_for(provider: &str, install: bool, fingerprint: &str) -> Result<String, String> {
    let provider = Provider::parse(provider)?;
    write_at(
        provider,
        &provider_settings_path(provider),
        install,
        fingerprint,
    )
}

fn write_at(
    provider: Provider,
    path: &Path,
    install: bool,
    expected_fingerprint: &str,
) -> Result<String, String> {
    let dir = path.parent().unwrap_or(Path::new("."));

    // Read exactly once before preparing the update. This both rejects corrupt
    // or unreadable settings and makes the preview fingerprint apply to the
    // same snapshot that is merged below.
    let (current_bytes, existed) = read_file_snapshot(path)?;
    if fingerprint(&current_bytes) != expected_fingerprint {
        return Err(format!(
            "{} changed since the preview. Nothing was written — review the new diff.",
            path.display()
        ));
    }
    let current = parse_settings(&current_bytes, &path.display().to_string())?;
    let next = if install {
        merged(&current, provider)?
    } else {
        without_ours(&current, provider)
    };
    let mut text = pretty(&next);
    text.push('\n');

    std::fs::create_dir_all(dir).map_err(|e| e.to_string())?;

    let backup = if existed {
        create_backup(path, &current_bytes)?
    } else {
        backup_path_for(path)
    };

    // Write beside the target and rename over it: a crash or a full disk leaves
    // the original settings.json intact rather than half a file.
    let extension = path.extension().and_then(|s| s.to_str()).unwrap_or("json");
    let temp = path.with_extension(format!("{extension}.coucou-{}", std::process::id()));
    std::fs::write(&temp, text.as_bytes()).map_err(|e| format!("write failed: {e}"))?;
    // A second check narrows the race with another config editor between the
    // initial read and the atomic replace.
    let latest_fingerprint = match current_fingerprint_at(path) {
        Ok(fingerprint) => fingerprint,
        Err(err) => {
            let _ = std::fs::remove_file(&temp);
            return Err(err);
        }
    };
    if latest_fingerprint != expected_fingerprint {
        let _ = std::fs::remove_file(&temp);
        return Err(format!(
            "{} changed while Coucou was preparing the update. Nothing was written — review the new diff.",
            path.display()
        ));
    }
    if let Err(err) = std::fs::rename(&temp, &path) {
        let _ = std::fs::remove_file(&temp);
        return Err(format!("write failed: {err}"));
    }
    Ok(backup.to_string_lossy().to_string())
}

/// Copies coucou-hook.exe into %LOCALAPPDATA%\Coucou\bin on launch.
/// In a bundled install it comes from the app resources; in `tauri dev` it sits
/// next to coucou.exe in the workspace target directory.
///
/// Every candidate is tried rather than just the first, because getting this
/// wrong is silent and fatal: `resources` used to be a glob, which made NSIS
/// mirror the source path into `_up_\target\release\`, no candidate matched, and
/// the relay was simply never installed. It only looked healthy on a developer
/// machine, where a leftover copy from `tauri dev` was already sitting in bin/.
pub fn ensure_hook_exe(app: &AppHandle) {
    let dest = settings::hook_exe_path();
    let Some(dir) = dest.parent() else { return };
    if std::fs::create_dir_all(dir).is_err() {
        return;
    }

    let mut candidates: Vec<PathBuf> = Vec::new();
    if let Ok(p) = app
        .path()
        .resolve("coucou-hook.exe", tauri::path::BaseDirectory::Resource)
    {
        candidates.push(p);
    }
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            // Installed build, then `tauri dev` (target/debug) next to the
            // release hook the pre-build step produces.
            candidates.push(parent.join("coucou-hook.exe"));
            candidates.push(parent.join("../release/coucou-hook.exe"));
            // Belt and braces: where the old glob form used to land it.
            candidates.push(parent.join("_up_/target/release/coucou-hook.exe"));
        }
    }

    let tried: Vec<String> = candidates.iter().map(|p| p.display().to_string()).collect();
    let Some(src) = candidates.into_iter().find(|p| p.exists()) else {
        crate::log::line(format!(
            "coucou-hook.exe not found — local agent hooks cannot work. Looked in: {}",
            tried.join(", ")
        ));
        return;
    };

    let same = match (std::fs::metadata(&src), std::fs::metadata(&dest)) {
        (Ok(a), Ok(b)) => a.len() == b.len() && a.modified().ok() == b.modified().ok(),
        _ => false,
    };
    if same {
        return;
    }
    // A hook may be running right now and hold the file open; keeping the old
    // copy is fine, it is the same relay.
    if let Err(err) = std::fs::copy(&src, &dest) {
        if !dest.exists() {
            crate::log::line(format!("could not install coucou-hook.exe: {err}"));
        }
    }
}

// ── Minimal unified diff (LCS) ────────────────────────────────────────────────

/// settings.json is short, so a plain O(n·m) LCS is the simplest honest diff.
fn unified_diff(before: &str, after: &str) -> String {
    let a: Vec<&str> = before.lines().collect();
    let b: Vec<&str> = after.lines().collect();
    let (n, m) = (a.len(), b.len());

    let mut lcs = vec![vec![0usize; m + 1]; n + 1];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            lcs[i][j] = if a[i] == b[j] {
                lcs[i + 1][j + 1] + 1
            } else {
                lcs[i + 1][j].max(lcs[i][j + 1])
            };
        }
    }

    let mut out: Vec<String> = Vec::new();
    let (mut i, mut j) = (0usize, 0usize);
    while i < n && j < m {
        if a[i] == b[j] {
            out.push(format!("  {}", a[i]));
            i += 1;
            j += 1;
        } else if lcs[i + 1][j] >= lcs[i][j + 1] {
            out.push(format!("- {}", a[i]));
            i += 1;
        } else {
            out.push(format!("+ {}", b[j]));
            j += 1;
        }
    }
    while i < n {
        out.push(format!("- {}", a[i]));
        i += 1;
    }
    while j < m {
        out.push(format!("+ {}", b[j]));
        j += 1;
    }

    // Keep three lines of context around each change so the panel stays readable.
    let changed: Vec<usize> = out
        .iter()
        .enumerate()
        .filter(|(_, l)| l.starts_with('+') || l.starts_with('-'))
        .map(|(i, _)| i)
        .collect();
    if changed.is_empty() {
        return "No change.".into();
    }
    let mut keep = vec![false; out.len()];
    for idx in changed {
        let lo = idx.saturating_sub(3);
        let hi = (idx + 4).min(out.len());
        for k in lo..hi {
            keep[k] = true;
        }
    }
    let mut result = String::new();
    let mut gap = false;
    for (idx, line) in out.iter().enumerate() {
        if keep[idx] {
            result.push_str(line);
            result.push('\n');
            gap = false;
        } else if !gap {
            result.push_str("  …\n");
            gap = true;
        }
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    const WHERE: &str = "settings.json";

    #[test]
    fn a_utf8_bom_is_stripped_not_treated_as_corruption() {
        // PowerShell 5's `Set-Content -Encoding utf8` produces exactly this.
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(br#"{"model":"opus","hooks":{}}"#);
        let parsed = parse_settings(&bytes, WHERE).expect("a BOM must not defeat the parser");
        assert_eq!(parsed["model"], "opus");
    }

    #[test]
    fn unreadable_content_is_an_error_never_an_empty_object() {
        // This is the whole bug: returning {} here meant `merged()` produced a
        // file containing nothing but Coucou's hooks, and the write replaced
        // everything the user had.
        for bad in [&b"{ not json"[..], &b"[1,2,3]"[..], &b"\"a string\""[..]] {
            assert!(
                parse_settings(bad, WHERE).is_err(),
                "content we cannot use must refuse, not come back empty"
            );
        }
    }

    #[test]
    fn empty_and_whitespace_files_start_from_nothing() {
        assert_eq!(parse_settings(b"", WHERE).unwrap(), json!({}));
        assert_eq!(parse_settings(b"  \n\t", WHERE).unwrap(), json!({}));
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

        let after = merged(&existing, Provider::Claude).unwrap();
        assert_eq!(after["model"], "claude-opus-5");
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["enabledPlugins"], serde_json::json!(["a", "b"]));

        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(
            pre.iter().any(|e| serde_json::to_string(e)
                .unwrap()
                .contains("someone-elses-tool.exe")),
            "another tool's hook was dropped"
        );
        assert!(
            pre.iter()
                .any(|entry| entry_is_ours(entry, Provider::Claude)),
            "our own hook was not added"
        );
        assert!(after["hooks"]["SomeEventWeDoNotTouch"].is_array());

        // And removing ours puts it back exactly as it was.
        let cleaned = without_ours(&after, Provider::Claude);
        assert_eq!(cleaned, existing);
    }

    #[test]
    fn mixed_matcher_group_preserves_metadata_and_foreign_handlers() {
        let existing = json!({
            "hooks": {
                "PreToolUse": [{
                    "matcher": "Bash",
                    "description": "owned by another integration",
                    "customMetadata": {"keep": true},
                    "hooks": [
                        {"type": "command", "command": "foreign-check.exe"},
                        {"type": "command", "command": "C:/old/coucou-hook.exe codex PreToolUse"}
                    ]
                }]
            }
        });

        let installed = merged(&existing, Provider::Codex).unwrap();
        let pre = installed["hooks"]["PreToolUse"].as_array().unwrap();
        let mixed = pre
            .iter()
            .find(|entry| entry["matcher"] == "Bash")
            .expect("the existing matcher group should remain");
        assert_eq!(mixed["description"], "owned by another integration");
        assert_eq!(mixed["customMetadata"]["keep"], true);
        assert_eq!(mixed["hooks"].as_array().unwrap().len(), 1);
        assert_eq!(mixed["hooks"][0]["command"], "foreign-check.exe");

        let cleaned = without_ours(&installed, Provider::Codex);
        assert_eq!(
            cleaned,
            json!({
                "hooks": {
                    "PreToolUse": [{
                        "matcher": "Bash",
                        "description": "owned by another integration",
                        "customMetadata": {"keep": true},
                        "hooks": [{"type": "command", "command": "foreign-check.exe"}]
                    }]
                }
            })
        );
    }

    #[test]
    fn cleanup_does_not_claim_near_marker_or_malformed_commands() {
        let foreign_commands = [
            "C:/tools/fake-coucou-hook.exe codex PreToolUse",
            "C:/tools/coucou-hook-backup.exe codex PreToolUse",
            "C:/tools/coucou-hook.exe notcodex PreToolUse",
            "C:/tools/coucou-hook.exe codex NotARealEvent",
            "C:/tools/coucou-hook.exe codex PreToolUse extra",
            "\"C:/tools/coucou-hook.exe\"codex PreToolUse",
            "echo coucou-hook.exe codex PreToolUse",
        ];
        let existing = json!({
            "hooks": {
                "PreToolUse": foreign_commands.iter().map(|command| json!({
                    "matcher": "Bash",
                    "hooks": [{"type": "command", "command": command}]
                })).collect::<Vec<_>>()
            }
        });

        let installed = merged(&existing, Provider::Codex).unwrap();
        let retained = installed["hooks"]["PreToolUse"].as_array().unwrap();
        for command in foreign_commands {
            assert!(
                retained.iter().any(|entry| {
                    entry["hooks"].as_array().is_some_and(|handlers| {
                        handlers.iter().any(|handler| handler["command"] == command)
                    })
                }),
                "near marker command was removed: {command}"
            );
        }
        assert_eq!(without_ours(&installed, Provider::Codex), existing);
    }

    #[test]
    fn a_fingerprint_notices_any_change() {
        assert_eq!(fingerprint(b"{}"), fingerprint(b"{}"));
        assert_ne!(fingerprint(b"{}"), fingerprint(b"{ }"));
        assert_ne!(fingerprint(b""), fingerprint(b"{}"));
    }

    #[test]
    fn codex_home_path_precedence_is_resolved_without_process_environment_mutation() {
        use std::ffi::OsStr;
        let home = Path::new(r"C:\temporary\profile");
        let codex = Path::new(r"D:\isolated\codex");
        assert_eq!(
            resolve_settings_path(
                Provider::Codex,
                Some(OsStr::new(codex.to_str().unwrap())),
                Some(home.as_os_str())
            ),
            codex.join("hooks.json")
        );
        assert_eq!(
            resolve_settings_path(Provider::Codex, None, Some(home.as_os_str())),
            home.join(".codex").join("hooks.json")
        );
        assert_eq!(
            resolve_settings_path(
                Provider::Claude,
                Some(OsStr::new(codex.to_str().unwrap())),
                Some(home.as_os_str())
            ),
            home.join(".claude").join("settings.json")
        );
    }

    #[test]
    fn codex_installation_is_idempotent_and_isolated_from_claude() {
        let existing = serde_json::json!({
            "description": "keep this",
            "model": "keep-this-too",
            "hooks": {
                "PreToolUse": [
                    { "hooks": [{ "type": "command", "command": "foreign.exe" }] },
                    { "hooks": [{ "type": "command", "command": "C:/old/coucou-hook.exe PreToolUse" }] },
                    { "hooks": [{ "type": "command", "command": "C:/old/coucou-hook.exe claude PreToolUse" }] },
                    { "hooks": [{ "type": "command", "command": "C:/old/coucou-hook.exe codex PreToolUse" }] }
                ],
                "Notification": [
                    { "hooks": [{ "type": "command", "command": "C:/old/coucou-hook.exe codex Notification" }] }
                ],
                "ForeignEvent": [
                    { "hooks": [{ "type": "command", "command": "leave-this.exe" }] }
                ]
            }
        });

        let installed = merged(&existing, Provider::Codex).unwrap();
        let installed_twice = merged(&installed, Provider::Codex).unwrap();
        assert_eq!(
            installed_twice, installed,
            "repeated install must not add duplicate entries"
        );
        assert_eq!(installed["description"], "keep this");
        assert_eq!(installed["model"], "keep-this-too");
        assert!(installed["hooks"]["PreToolUse"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| { entry["hooks"][0]["command"].as_str().unwrap() == "foreign.exe" }));
        let pre = installed["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(pre
            .iter()
            .any(|entry| entry_is_ours(entry, Provider::Claude)));
        assert!(pre
            .iter()
            .any(|entry| entry_is_ours(entry, Provider::Codex)));
        assert!(!installed["hooks"]
            .as_object()
            .unwrap()
            .contains_key("Notification"));
        assert!(installed["hooks"]["ForeignEvent"].is_array());

        let codex_names: Vec<&str> = CODEX_EVENTS.iter().map(|(event, _)| *event).collect();
        let configured: Vec<&str> = installed["hooks"]
            .as_object()
            .unwrap()
            .keys()
            .map(String::as_str)
            .collect();
        for event in codex_names {
            assert!(configured.contains(&event), "missing Codex event {event}");
            let entries = installed["hooks"][event].as_array().unwrap();
            let entry = entries
                .iter()
                .find(|entry| entry_is_ours(entry, Provider::Codex))
                .expect("Codex event should have a Coucou hook");
            let windows_command = entry["hooks"][0]["commandWindows"].as_str().unwrap();
            assert_eq!(hook_args(windows_command).unwrap(), vec!["codex", event]);
        }
        let removed = without_ours(&installed, Provider::Codex);
        assert!(removed["hooks"]["PreToolUse"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| { entry_is_ours(entry, Provider::Claude) }));
        assert!(removed["hooks"]["PreToolUse"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| { entry["hooks"][0]["command"].as_str() == Some("foreign.exe") }));
        assert!(!removed["hooks"]["PreToolUse"]
            .as_array()
            .unwrap()
            .iter()
            .any(|entry| { entry_is_ours(entry, Provider::Codex) }));
        assert!(
            removed["hooks"].get("Notification").is_none(),
            "stale provider-only events are cleaned up"
        );
    }

    #[test]
    fn malformed_hooks_are_rejected_instead_of_overwritten() {
        assert!(merged(&json!({"hooks": []}), Provider::Codex).is_err());
        assert!(merged(
            &json!({"hooks": {"Interrupt": {"foreign": true}}}),
            Provider::Codex
        )
        .is_err());
        assert_eq!(
            without_ours(&json!({"hooks": []}), Provider::Codex),
            json!({"hooks": []})
        );
        assert!(Provider::parse("other").is_err());
        assert!(status_for("other").is_err());
        assert!(preview_for("other", true).is_err());
        assert!(write_for("other", true, "unused").is_err());
    }

    #[test]
    fn preview_write_backup_stale_and_malformed_paths_are_safe() {
        let tmp = unique_temp_dir();
        let path = tmp.join(".codex").join("hooks.json");
        std::fs::create_dir_all(path.parent().unwrap()).unwrap();

        // A real-shaped file, written the way PowerShell 5 would: UTF-8 with BOM.
        let original = r#"{"description":"existing codex hooks","theme":"dark","other":{"x":1},"hooks":{"PreToolUse":[{"hooks":[{"type":"command","command":"other-tool.exe"}]}]}}"#;
        let mut bytes = vec![0xEF, 0xBB, 0xBF];
        bytes.extend_from_slice(original.as_bytes());
        std::fs::write(&path, &bytes).unwrap();

        // Install.
        let plan =
            preview_at(Provider::Codex, &path, true).expect("a BOM must not stop the preview");
        assert!(
            plan.diff.contains("coucou-hook"),
            "the diff must show what changes"
        );
        let backup = write_at(Provider::Codex, &path, true, &plan.fingerprint)
            .expect("install should succeed");

        // The backup holds the original bytes, BOM and all.
        assert_eq!(std::fs::read(&backup).unwrap(), bytes);

        // Everything else survived, and so did the other tool's hook.
        let after: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(after["description"], "existing codex hooks");
        assert_eq!(after["theme"], "dark");
        assert_eq!(after["other"]["x"], 1);
        let pre = after["hooks"]["PreToolUse"].as_array().unwrap();
        assert!(pre
            .iter()
            .any(|e| serde_json::to_string(e).unwrap().contains("other-tool.exe")));
        assert!(status_at(Provider::Codex, &path).installed);

        // Same-second writes use a new backup path and retain the prior one.
        let installed_bytes = std::fs::read(&path).unwrap();
        let remove = preview_at(Provider::Codex, &path, false).unwrap();
        let backup2 = write_at(Provider::Codex, &path, false, &remove.fingerprint).unwrap();
        assert_ne!(backup, backup2);
        assert_eq!(std::fs::read(&backup2).unwrap(), installed_bytes);
        assert_eq!(std::fs::read(&backup).unwrap(), bytes);

        // A file that moved since the preview is refused, and left alone.
        let stale = preview_at(Provider::Codex, &path, false).unwrap();
        std::fs::write(&path, br#"{"theme":"someone-else-edited-this"}"#).unwrap();
        let err = write_at(Provider::Codex, &path, false, &stale.fingerprint).unwrap_err();
        assert!(err.contains("changed since the preview"), "got: {err}");
        let untouched: Value = serde_json::from_slice(&std::fs::read(&path).unwrap()).unwrap();
        assert_eq!(untouched["theme"], "someone-else-edited-this");

        // Content we cannot parse is refused before anything is written.
        std::fs::write(&path, b"{ broken").unwrap();
        assert!(preview_at(Provider::Codex, &path, true).is_err());
        let bad_fingerprint = fingerprint(b"{ broken");
        assert!(write_at(Provider::Codex, &path, true, &bad_fingerprint).is_err());
        assert_eq!(std::fs::read(&path).unwrap(), b"{ broken");

        let _ = std::fs::remove_dir_all(&tmp);
    }

    fn unique_temp_dir() -> PathBuf {
        use std::time::{SystemTime, UNIX_EPOCH};
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        std::env::temp_dir().join(format!("coucou-hooks-{}-{nonce}", std::process::id()))
    }
}
