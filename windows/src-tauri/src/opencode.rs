// opencode plugin installation.
//
// Unlike the Claude Code hooks (which merge commands into
// `~/.claude/settings.json`), opencode loads every JS file dropped into its
// plugin directories automatically. Installing Coucou's opencode support is
// therefore a single file copy:
//
//   <bundled coucou.js> → %USERPROFILE%\.config\opencode\plugins\coucou.js
//
// The same strict rules as hooks.rs apply: take a dated backup, show what
// will change, and write only after an explicit click. Uninstall removes
// Coucou's file and nothing else. Project-level `.opencode/plugins/` dirs
// are left alone on purpose — a global install covers every project.
//
// The plugin file carries `const COUCOU_PLUGIN_VERSION = N`; the installer
// compares the bundled version against the installed copy to offer updates.

use std::path::PathBuf;

use serde::Serialize;

use crate::settings;

/// File name inside opencode's plugin directories.
pub const PLUGIN_FILE: &str = "coucou.js";

/// Marker matched inside the plugin source. Must stay in sync with
/// windows/opencode-plugin/coucou.js (and the `const` name with the comment
/// there). Version comparison is parsed from the file text, so no manual
/// constant needs bumping here.
const VERSION_MARKER: &str = "const COUCOU_PLUGIN_VERSION =";

/// The plugin source bundled with the app (see tauri.conf.json `resources`).
const BUNDLED: &str = include_str!("../../opencode-plugin/coucou.js");

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpencodeStatus {
    pub installed: bool,
    pub plugin_path: String,
    pub relay_ready: bool,
    pub bundled_version: i64,
    pub installed_version: Option<i64>,
    pub needs_update: bool,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpencodePreview {
    pub diff: String,
    pub backup: String,
    pub plugin_path: String,
    /// Identifies the bytes this preview was computed from; handed back to
    /// `write` so we only ever apply what the user actually looked at.
    pub fingerprint: String,
}

pub fn plugin_dir() -> PathBuf {
    std::env::var_os("USERPROFILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."))
        .join(".config")
        .join("opencode")
        .join("plugins")
}

pub fn plugin_path() -> PathBuf {
    plugin_dir().join(PLUGIN_FILE)
}

/// Parses `const COUCOU_PLUGIN_VERSION = N` out of plugin source.
/// Returns None when the file is foreign (not ours) or unparsable.
fn parse_version(text: &str) -> Option<i64> {
    for line in text.lines() {
        let t = line.trim();
        if let Some(rest) = t.strip_prefix(VERSION_MARKER) {
            let num: String = rest
                .trim()
                .trim_end_matches(';')
                .chars()
                .take_while(|c| c.is_ascii_digit() || *c == '-')
                .collect();
            if let Ok(v) = num.parse::<i64>() {
                return Some(v);
            }
        }
    }
    None
}

fn bundled_version() -> i64 {
    parse_version(BUNDLED).unwrap_or(0)
}

/// FNV-1a over the exact bytes, same rationale as hooks.rs.
fn fingerprint(bytes: &[u8]) -> String {
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for b in bytes {
        hash ^= *b as u64;
        hash = hash.wrapping_mul(0x1000_0000_01b3);
    }
    format!("{hash:016x}")
}

fn current_bytes() -> Vec<u8> {
    std::fs::read(plugin_path()).unwrap_or_default()
}

fn current_fingerprint() -> String {
    match std::fs::read(plugin_path()) {
        Ok(bytes) => fingerprint(&bytes),
        Err(_) => fingerprint(b""),
    }
}

fn stamp() -> String {
    format!("{}", chrono_stamp())
}

/// Local timestamp without pulling in chrono: reuses the same shape as
/// hooks.rs (`yyyyMMdd-HHmmss`) via the Win32 clock.
fn chrono_stamp() -> String {
    // hooks.rs already depends on windows::GetLocalTime; duplicate the tiny
    // call here rather than reaching into that module.
    let t = unsafe { windows::Win32::System::SystemInformation::GetLocalTime() };
    format!(
        "{:04}{:02}{:02}-{:02}{:02}{:02}",
        t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond
    )
}

fn backup_path() -> PathBuf {
    plugin_dir().join(format!("{PLUGIN_FILE}.bak-{}", stamp()))
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn status() -> OpencodeStatus {
    let path = plugin_path();
    let existing = std::fs::read_to_string(&path).ok();
    let ours = existing.as_deref().map(parse_version);
    let installed = matches!(ours, Some(_));
    let installed_version = ours.flatten();
    let bundled = bundled_version();
    OpencodeStatus {
        installed,
        plugin_path: path.to_string_lossy().to_string(),
        relay_ready: settings::hook_exe_path().exists(),
        bundled_version: bundled,
        installed_version,
        needs_update: matches!(installed_version, Some(v) if v < bundled),
    }
}

pub fn preview(install: bool) -> Result<OpencodePreview, String> {
    let path = plugin_path();
    let current = std::fs::read(&path).unwrap_or_default();
    let (diff, backup) = if install {
        let next = BUNDLED.as_bytes();
        let d = if current == next {
            "Already up to date — writing would change nothing.".to_string()
        } else if current.is_empty() {
            format!(
                "+ new file {} ({} bytes, plugin v{})\n  Relay: {}",
                path.display(),
                next.len(),
                bundled_version(),
                settings::hook_exe_path().display(),
            )
        } else {
            format!(
                "~ {} will be replaced (backup first)\n- installed: {} bytes{}\n+ bundled:   {} bytes (plugin v{})",
                path.display(),
                current.len(),
                match std::fs::read_to_string(&path).ok().as_deref().map(parse_version) {
                    Some(Some(v)) => format!(", plugin v{v}"),
                    _ => ", not a Coucou plugin — will NOT be touched".to_string(),
                },
                next.len(),
                bundled_version(),
            )
        };
        // Refuse to overwrite a foreign coucou.js: somebody else owns that name.
        if !current.is_empty() && parse_version(&String::from_utf8_lossy(&current)).is_none() {
            return Err(format!(
                "{} exists and is not a Coucou plugin — Coucou won't overwrite it. Remove or rename it first.",
                path.display()
            ));
        }
        (d, backup_path().to_string_lossy().to_string())
    } else {
        if current.is_empty() {
            ("Nothing to remove — the plugin is not installed.".to_string(), String::new())
        } else if parse_version(&String::from_utf8_lossy(&current)).is_none() {
            return Err(format!(
                "{} exists and is not a Coucou plugin — Coucou won't remove it.",
                path.display()
            ));
        } else {
            (
                format!("- remove {} (backup first)", path.display()),
                backup_path().to_string_lossy().to_string(),
            )
        }
    };
    Ok(OpencodePreview {
        diff,
        backup,
        plugin_path: path.to_string_lossy().to_string(),
        fingerprint: current_fingerprint(),
    })
}

/// Writes (or removes) the plugin after taking a dated backup.
/// `fingerprint` must be the one from the preview the user reviewed.
pub fn write(install: bool, fingerprint: &str) -> Result<String, String> {
    let path = plugin_path();
    if current_fingerprint() != fingerprint {
        return Err(format!(
            "{} changed since the preview. Nothing was written — review the new diff.",
            path.display()
        ));
    }
    std::fs::create_dir_all(plugin_dir()).map_err(|e| e.to_string())?;

    let current = std::fs::read(&path).unwrap_or_default();
    if !current.is_empty() && parse_version(&String::from_utf8_lossy(&current)).is_none() {
        return Err(format!(
            "{} is not a Coucou plugin — refusing to touch it.",
            path.display()
        ));
    }

    let mut backup = String::new();
    if !current.is_empty() {
        let b = backup_path();
        std::fs::copy(&path, &b).map_err(|e| format!("backup failed: {e}"))?;
        backup = b.to_string_lossy().to_string();
    }

    if install {
        // Write beside the target and rename over it, like hooks.rs.
        let temp = plugin_dir().join(format!("coucou.js.coucou-{}", std::process::id()));
        std::fs::write(&temp, BUNDLED.as_bytes()).map_err(|e| format!("write failed: {e}"))?;
        if let Err(err) = std::fs::rename(&temp, &path) {
            let _ = std::fs::remove_file(&temp);
            return Err(format!("write failed: {err}"));
        }
    } else if path.exists() {
        std::fs::remove_file(&path).map_err(|e| format!("remove failed: {e}"))?;
    }
    Ok(backup)
}

/// Copies the bundled plugin into the global plugin dir on launch when it is
/// missing or older than the bundle. Never overwrites a foreign `coucou.js`,
/// and never touches project-level `.opencode/plugins/` directories.
pub fn ensure_plugin() {
    let s = status();
    if s.installed && !s.needs_update {
        return;
    }
    if s.installed && current_bytes().is_empty() {
        return;
    }
    // Foreign file with our name: hands off, the settings window explains.
    if let Ok(text) = std::fs::read_to_string(plugin_path()) {
        if parse_version(&text).is_none() {
            crate::log::line("opencode plugin: foreign coucou.js present — leaving it alone");
            return;
        }
    }
    if std::fs::create_dir_all(plugin_dir()).is_err() {
        return;
    }
    let current = current_bytes();
    if current == BUNDLED.as_bytes() {
        return;
    }
    if let Err(err) = std::fs::write(plugin_path(), BUNDLED.as_bytes()) {
        crate::log::line(format!("could not install opencode plugin: {err}"));
    } else {
        crate::log::line(format!(
            "opencode plugin installed (v{})",
            bundled_version()
        ));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn version_parses_from_bundled_source() {
        assert_eq!(parse_version(BUNDLED), Some(1));
    }

    #[test]
    fn version_rejects_foreign_or_broken_files() {
        assert_eq!(parse_version(""), None);
        assert_eq!(parse_version("export const x = 1;\n"), None);
        assert_eq!(
            parse_version("const COUCOU_PLUGIN_VERSION = 12;\n"),
            Some(12)
        );
        assert_eq!(
            parse_version("  const COUCOU_PLUGIN_VERSION = 3\n"),
            Some(3)
        );
    }

    #[test]
    fn fingerprint_notices_any_change() {
        assert_eq!(fingerprint(b"{}"), fingerprint(b"{}"));
        assert_ne!(fingerprint(b"{}"), fingerprint(b"{ }"));
    }

    #[test]
    fn bundled_source_mentions_relay_and_agent() {
        assert!(BUNDLED.contains("coucou-hook.exe"));
        assert!(BUNDLED.contains("\"agent\": \"opencode\""));
        assert!(BUNDLED.contains("permission.asked"));
    }
}
