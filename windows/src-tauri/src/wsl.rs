// Claude Code running inside WSL.
//
// A Claude Code session in a WSL distro runs Linux: it reads the distro's own
// ~/.claude/settings.json and cannot see the Windows named pipe the island
// listens on. What it can do is start Windows programs (WSL interop), and
// coucou-hook.exe is one: it reads the hook on its standard input, talks to the
// island over the pipe, and prints its answer, so an Allow or Deny clicked in
// the island reaches the session in WSL like any other. A call costs about 60 ms,
// nearly all of it WSL's own start-up of a Windows process.
//
// This module only finds the places and writes the command (hooks.rs does the
// installing, with the same diff, backup and fingerprint as for Windows):
// * which distros there are, and which of them are running (reading a stopped
//   distro's files would start it, so those are left alone);
// * which Linux users have a ~/.claude, and where their settings.json is, as the
//   `\\wsl.localhost\<distro>\…` path Windows reaches it by;
// * the relay's path as the distro writes it (`/mnt/c/Users/…`), from the
//   distro's own automount root;
// * the one shell command that goes in the settings.

use std::path::PathBuf;

use serde::Serialize;

/// Distros WSL itself keeps for Docker Desktop: nobody runs Claude Code there.
const SKIPPED: &[&str] = &["docker-desktop", "docker-desktop-data"];

/// A Linux user of a distro who has a `~/.claude`.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WslUser {
    pub name: String,
    /// `\\wsl.localhost\<distro>\home\<user>\.claude\settings.json`
    pub settings_path: String,
    /// Coucou's hooks are in that settings.json.
    pub installed: bool,
}

#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct WslDistro {
    pub name: String,
    pub running: bool,
    /// Only filled in for a running distro.
    pub users: Vec<WslUser>,
}

/// What an install needs, once the names have been checked against the real list.
#[derive(Debug, PartialEq)]
pub struct Target {
    pub settings_path: PathBuf,
    /// The relay as this distro writes its path: `/mnt/c/Users/…/coucou-hook.exe`.
    pub relay: String,
}

// ── Names ─────────────────────────────────────────────────────────────────────

/// A distro or user name that cannot lead anywhere else: it comes from the
/// settings window and ends up in a path.
pub fn is_safe_name(name: &str) -> bool {
    !name.is_empty()
        && name != "."
        && name != ".."
        && !name.chars().any(|c| c.is_control() || matches!(c, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|'))
}

// ── wsl.exe's output ──────────────────────────────────────────────────────────

/// What `wsl.exe -l -q` prints: UTF-16 (no BOM, CRLF), one distro a line; or
/// UTF-8 when `WSL_UTF8` is set. Docker's own distros are left out.
pub fn parse_distro_list(bytes: &[u8]) -> Vec<String> {
    let text = if bytes.contains(&0) {
        let units: Vec<u16> = bytes.chunks_exact(2).map(|p| u16::from_le_bytes([p[0], p[1]])).collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    };
    text.trim_start_matches('\u{feff}')
        .lines()
        .map(|line| line.trim().trim_end_matches(" (Default)").trim().to_string())
        .filter(|name| !name.is_empty() && !SKIPPED.contains(&name.as_str()))
        .collect()
}

// ── Paths ─────────────────────────────────────────────────────────────────────

/// `[automount] root = /mnt/` from a distro's /etc/wsl.conf; `/mnt/` when it
/// says nothing (or something that is not an absolute path).
pub fn parse_automount_root(wsl_conf: &str) -> String {
    let mut in_automount = false;
    for line in wsl_conf.lines() {
        let line = line.split('#').next().unwrap_or("").trim();
        if let Some(section) = line.strip_prefix('[').and_then(|l| l.strip_suffix(']')) {
            in_automount = section.trim().eq_ignore_ascii_case("automount");
        } else if in_automount {
            if let Some((key, value)) = line.split_once('=') {
                let value = value.trim().trim_matches('"');
                if key.trim().eq_ignore_ascii_case("root") && value.starts_with('/') {
                    return with_trailing_slash(value);
                }
            }
        }
    }
    "/mnt/".to_string()
}

fn with_trailing_slash(path: &str) -> String {
    if path.ends_with('/') { path.to_string() } else { format!("{path}/") }
}

/// `C:\Users\me\x.exe` → `/mnt/c/Users/me/x.exe`. A path that is not on a
/// drive letter (a network share) has no such form.
pub fn to_wsl_path(windows_path: &str, automount_root: &str) -> Option<String> {
    let mut chars = windows_path.chars();
    let drive = chars.next().filter(char::is_ascii_alphabetic)?;
    let rest = chars.as_str().strip_prefix(':')?;
    let rest = rest.strip_prefix(['\\', '/'])?;
    let rest = rest.replace('\\', "/");
    if rest.is_empty() || rest.contains("//") || rest.split('/').any(|part| part == "..") {
        return None;
    }
    Some(format!("{}{}/{rest}", with_trailing_slash(automount_root), drive.to_ascii_lowercase()))
}

/// `'…'` as one POSIX shell word: `'` becomes `'\''`.
fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

/// The hook command written in the distro's settings.json. The relay answers
/// nothing and exits 0 when Coucou is closed; and when it cannot be started at
/// all (Windows interop turned off, the file gone) the `|| true` keeps Claude
/// Code from reporting a failing hook on every event.
pub fn relay_command(relay: &str, event: &str) -> String {
    let relay = sh_quote(relay);
    format!("[ -x {relay} ] && {relay} {event} || true")
}

// ── Where things are (Windows) ────────────────────────────────────────────────

fn root(distro: &str) -> PathBuf {
    PathBuf::from(format!(r"\\wsl.localhost\{distro}"))
}

fn settings_of(distro: &str, user: &str) -> PathBuf {
    root(distro).join("home").join(user).join(".claude").join("settings.json")
}

/// Runs `wsl.exe` and returns what it printed, or nothing if it does not
/// answer within a few seconds (it never should for `-l`).
#[cfg(windows)]
fn wsl_output(args: &[&str]) -> Option<Vec<u8>> {
    use std::process::{Command, Stdio};
    use std::time::{Duration, Instant};

    let mut command = Command::new("wsl.exe");
    command.args(args).stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::null());
    crate::platform::no_console(&mut command);
    let mut child = command.spawn().ok()?;
    let deadline = Instant::now() + Duration::from_secs(5);
    loop {
        match child.try_wait() {
            Ok(Some(_)) => break,
            Ok(None) if Instant::now() < deadline => std::thread::sleep(Duration::from_millis(20)),
            _ => {
                let _ = child.kill();
                return None;
            }
        }
    }
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut child.stdout.take()?, &mut out).ok()?;
    Some(out)
}

#[cfg(not(windows))]
fn wsl_output(_args: &[&str]) -> Option<Vec<u8>> {
    None
}

/// Every distro, running or not. Nothing here starts one.
fn distros() -> Vec<(String, bool)> {
    let all = wsl_output(&["-l", "-q"]).map(|b| parse_distro_list(&b)).unwrap_or_default();
    let running = wsl_output(&["-l", "--running", "-q"]).map(|b| parse_distro_list(&b)).unwrap_or_default();
    all.into_iter()
        .filter(|name| is_safe_name(name))
        .map(|name| {
            let up = running.contains(&name);
            (name, up)
        })
        .collect()
}

/// The Linux users of a running distro who have a ~/.claude.
fn users(distro: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(root(distro).join("home")) else { return Vec::new() };
    let mut names: Vec<String> = entries
        .flatten()
        .filter(|e| e.path().join(".claude").is_dir())
        .filter_map(|e| e.file_name().into_string().ok())
        .filter(|name| is_safe_name(name))
        .collect();
    names.sort();
    names
}

fn automount_root(distro: &str) -> String {
    std::fs::read_to_string(root(distro).join("etc").join("wsl.conf"))
        .map(|text| parse_automount_root(&text))
        .unwrap_or_else(|_| "/mnt/".to_string())
}

/// The distros, and for each running one its users with whether Coucou's hooks
/// are in their settings.json. Read-only.
pub fn list() -> Vec<WslDistro> {
    distros()
        .into_iter()
        .map(|(name, running)| {
            let users = if running {
                users(&name)
                    .into_iter()
                    .map(|user| {
                        let path = settings_of(&name, &user);
                        WslUser {
                            installed: crate::hooks::settings_file_has_ours(&path),
                            settings_path: path.to_string_lossy().to_string(),
                            name: user,
                        }
                    })
                    .collect()
            } else {
                Vec::new()
            };
            WslDistro { name, running, users }
        })
        .collect()
}

/// The settings.json and relay path for `distro` and `user`, after checking
/// that both are really there: the names come from the settings window and end
/// up in a path.
pub fn resolve(distro: &str, user: &str) -> Result<Target, String> {
    if !is_safe_name(distro) || !is_safe_name(user) {
        return Err(crate::i18n::t("That WSL distro or user is not valid."));
    }
    let known = list_running_users(distro);
    if !known.iter().any(|u| u == user) {
        return Err(crate::i18n::tf(
            "{user} has no ~/.claude in {distro}, or {distro} is not running.",
            &[("user", user), ("distro", distro)],
        ));
    }
    let exe = crate::settings::hook_exe_path();
    let relay = to_wsl_path(&exe.to_string_lossy(), &automount_root(distro))
        .ok_or_else(|| crate::i18n::t("The relay is not on a local drive, so WSL cannot run it."))?;
    Ok(Target { settings_path: settings_of(distro, user), relay })
}

fn list_running_users(distro: &str) -> Vec<String> {
    match distros().into_iter().find(|(name, _)| name == distro) {
        Some((name, true)) => users(&name),
        _ => Vec::new(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn utf16(text: &str) -> Vec<u8> {
        text.encode_utf16().flat_map(|u| u.to_le_bytes()).collect()
    }

    #[test]
    fn wsl_exe_lists_distros_in_utf16() {
        let out = utf16("Ubuntu\r\ndocker-desktop\r\nDebian\r\ndocker-desktop-data\r\n");
        assert_eq!(parse_distro_list(&out), vec!["Ubuntu", "Debian"]);
        // With a byte order mark, and with the default one tagged.
        let bom = [&[0xFF, 0xFE][..], &utf16("Ubuntu-22.04 (Default)\r\n")].concat();
        assert_eq!(parse_distro_list(&bom), vec!["Ubuntu-22.04"]);
        // WSL_UTF8=1, or an empty answer.
        assert_eq!(parse_distro_list(b"Ubuntu\nArch\n"), vec!["Ubuntu", "Arch"]);
        assert!(parse_distro_list(b"").is_empty());
        assert!(parse_distro_list(&utf16("\r\n\r\n")).is_empty());
    }

    #[test]
    fn the_automount_root_comes_from_wsl_conf() {
        assert_eq!(parse_automount_root(""), "/mnt/");
        assert_eq!(parse_automount_root("[boot]\nsystemd=true\n[user]\ndefault=me\n"), "/mnt/");
        assert_eq!(parse_automount_root("[automount]\nroot = /\n"), "/");
        assert_eq!(parse_automount_root("[automount]\nenabled=true\nroot=\"/win\"  # my drives\n"), "/win/");
        // `root` in another section, a relative one, or a comment: not it.
        assert_eq!(parse_automount_root("[network]\nroot=/x\n"), "/mnt/");
        assert_eq!(parse_automount_root("[automount]\nroot=mnt\n"), "/mnt/");
        assert_eq!(parse_automount_root("[automount]\n# root=/x\n"), "/mnt/");
        assert_eq!(parse_automount_root("[AUTOMOUNT]\nROOT=/d\n"), "/d/");
    }

    #[test]
    fn a_windows_path_becomes_the_distros_path() {
        let exe = r"C:\Users\Seguineaud\AppData\Local\Coucou\bin\coucou-hook.exe";
        assert_eq!(
            to_wsl_path(exe, "/mnt/").as_deref(),
            Some("/mnt/c/Users/Seguineaud/AppData/Local/Coucou/bin/coucou-hook.exe")
        );
        assert_eq!(to_wsl_path(r"D:\x\y.exe", "/").as_deref(), Some("/d/x/y.exe"));
        assert_eq!(to_wsl_path(r"d:/x/y.exe", "/win").as_deref(), Some("/win/d/x/y.exe"));
        // Not on a drive, or trying to leave it.
        assert_eq!(to_wsl_path(r"\\server\share\x.exe", "/mnt/"), None);
        assert_eq!(to_wsl_path(r"C:relative\x.exe", "/mnt/"), None);
        assert_eq!(to_wsl_path(r"C:\a\..\b.exe", "/mnt/"), None);
        assert_eq!(to_wsl_path(r"C:\a\\b.exe", "/mnt/"), None);
        assert_eq!(to_wsl_path(r"C:\", "/mnt/"), None);
        assert_eq!(to_wsl_path("", "/mnt/"), None);
    }

    #[test]
    fn the_command_is_one_quoted_word_and_never_fails() {
        let relay = "/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe";
        assert_eq!(
            relay_command(relay, "PermissionRequest"),
            "[ -x '/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe' ] && \
             '/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe' PermissionRequest || true"
        );
        // A space or an apostrophe in the path stays inside the word.
        let odd = relay_command("/mnt/c/Users/O'Neil Jr/bin/coucou-hook.exe", "Stop");
        assert!(odd.contains(r"'/mnt/c/Users/O'\''Neil Jr/bin/coucou-hook.exe' Stop"), "{odd}");
        // The marker hooks.rs recognises Coucou's entries by.
        assert!(odd.contains("coucou-hook"));
    }

    #[test]
    fn names_that_could_lead_elsewhere_are_refused() {
        for ok in ["Ubuntu", "Ubuntu-22.04", "seguineaud", "my user"] {
            assert!(is_safe_name(ok), "{ok}");
        }
        for bad in ["", ".", "..", "a/b", r"a\b", "a:b", "x\n", "..\\..", "a|b", "*", "a\"b"] {
            assert!(!is_safe_name(bad), "{bad:?}");
        }
    }

    #[test]
    fn the_settings_are_reached_through_the_distros_share() {
        assert_eq!(
            settings_of("Ubuntu", "me"),
            PathBuf::from(r"\\wsl.localhost\Ubuntu").join("home").join("me").join(".claude").join("settings.json")
        );
    }

    /// Needs a running WSL distro with a ~/.claude. Read-only: lists what is
    /// there and shows the diff an install would make. `cargo test -- --ignored`.
    #[cfg(windows)]
    #[test]
    #[ignore = "needs a running WSL distro"]
    fn the_real_distros_are_found_and_an_install_is_previewed() {
        let found = list();
        println!("{found:#?}");
        let (distro, user) = found
            .iter()
            .find_map(|d| d.users.first().map(|u| (d.name.clone(), u.name.clone())))
            .expect("no running distro with a ~/.claude");
        let target = resolve(&distro, &user).unwrap();
        println!("relay as {distro} writes it: {}", target.relay);
        let preview = crate::hooks::wsl_preview(&distro, &user, true).unwrap();
        println!("backup would go to: {}\n{}", preview.backup, preview.diff);
        assert!(preview.diff.contains("coucou-hook"));
    }
}
