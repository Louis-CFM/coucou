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
// * the one shell command that goes in the settings;
// * the Windows form of a Linux path from a session in WSL (`/home/me/proj` →
//   `\\wsl.localhost\Ubuntu\home\me\proj`), for the diff's ↗ and "open the
//   folder", which hand the path to VS Code or Explorer on the Windows side.

// Only Windows hands a session's Linux path to an editor; the rest is still built
// (and tested) everywhere.
#![cfg_attr(not(windows), allow(dead_code))]

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
    /// The relay is Coucou's status line there (the plan usage gauge).
    pub plan_installed: bool,
    /// Coucou's commands there start a relay that is not the current one (the
    /// app moved or was reinstalled elsewhere): they would do nothing.
    pub stale: bool,
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

// ── What a distro's settings.json says about Coucou ───────────────────────────

/// The status line command in a distro's settings.json. Claude Code hands the
/// session's JSON to it on standard input and shows what it prints. The input is
/// read once, sent to the relay in the background (it only wants the plan limits,
/// and must never delay the line) and handed to the user's own status line, run
/// here in the distro, so it keeps working as before. With none of their own,
/// nothing is printed. The whole background group lets go of standard output:
/// one that kept it would hold the line back until the relay had finished.
pub fn status_line_command(relay: &str, previous: Option<&str>) -> String {
    let relay = sh_quote(relay);
    let own = match previous.map(str::trim) {
        Some(command) if !command.is_empty() => format!("{{ {command}\n}}"),
        _ => ":".to_string(),
    };
    format!(
        "input=$(cat); {{ [ -x {relay} ] && printf '%s' \"$input\" | {relay} --statusline --no-previous; }} >/dev/null 2>&1 & \
         printf '%s' \"$input\" | {own}"
    )
}

/// The first single-quoted word of a shell command, unquoted: the relay's path in
/// the commands Coucou writes (`[ -x '<relay>' ] && '<relay>' <Event> || true`).
pub fn first_quoted(command: &str) -> Option<String> {
    let start = command.find('\'')?;
    let rest: Vec<char> = command[start + 1..].chars().collect();
    let mut out = String::new();
    let mut i = 0;
    loop {
        while i < rest.len() && rest[i] != '\'' {
            out.push(rest[i]);
            i += 1;
        }
        if i >= rest.len() {
            return None;
        }
        // `'\''` is a quote inside the word: close, escaped quote, open again.
        if rest.get(i + 1..i + 4) == Some(&['\\', '\'', '\''][..]) {
            out.push('\'');
            i += 4;
            continue;
        }
        return Some(out);
    }
}

/// What Coucou has in a settings.json read from a distro.
#[derive(Debug, Default, PartialEq)]
pub struct Found {
    pub installed: bool,
    pub plan: bool,
    pub stale: bool,
}

/// Whether the hooks and the status line in `settings` are Coucou's, and whether
/// the relay they start is `expected` (as the distro writes its path). A relay
/// that is not a Windows program (a Coucou for Linux in the distro, say) is
/// somebody's own install and is left alone, never called stale.
pub fn inspect(settings: &serde_json::Value, expected: Option<&str>) -> Found {
    const MARKER: &str = "coucou-hook";
    let mut found = Found::default();
    let mut check = |command: &str, plan: bool| {
        if !command.contains(MARKER) {
            return;
        }
        if plan {
            found.plan = true;
        } else {
            found.installed = true;
        }
        let ours = first_quoted(command).filter(|p| p.to_ascii_lowercase().ends_with(".exe"));
        if let (Some(ours), Some(expected)) = (ours, expected) {
            if ours != expected {
                found.stale = true;
            }
        }
    };
    if let Some(hooks) = settings.get("hooks").and_then(serde_json::Value::as_object) {
        for group in hooks.values().filter_map(serde_json::Value::as_array).flatten() {
            for hook in group.get("hooks").and_then(serde_json::Value::as_array).into_iter().flatten() {
                if let Some(command) = hook.get("command").and_then(serde_json::Value::as_str) {
                    check(command, false);
                }
            }
        }
    }
    if let Some(command) = settings.get("statusLine").and_then(|v| v.get("command")).and_then(serde_json::Value::as_str) {
        check(command, true);
    }
    found
}

// ── A session's Linux paths, seen from Windows ───────────────────────────────

/// `\\wsl.localhost\<distro>\home\me\proj` for `/home/me/proj`. Only a full
/// Linux path with nothing in it that could lead elsewhere: no `..`, no NUL, no
/// backslash (a Linux file name may hold one, a Windows path would read it as a
/// separator).
pub fn unc_path(distro: &str, linux_path: &str) -> Option<PathBuf> {
    if !is_safe_name(distro) || !linux_path.starts_with('/') {
        return None;
    }
    if linux_path.contains(['\\', '\0']) || linux_path.split('/').any(|part| part == "..") {
        return None;
    }
    let mut path = root(distro);
    for part in linux_path.split('/').filter(|p| !p.is_empty() && *p != ".") {
        path.push(part);
    }
    Some(path)
}

/// Which of `distros` has `linux_path`, and where it is seen from Windows. The
/// first that has it: two distros with the very same folder cannot be told apart
/// from the path alone.
pub fn locate(linux_path: &str, distros: &[String], exists: impl Fn(&std::path::Path) -> bool) -> Option<(String, PathBuf)> {
    distros.iter().find_map(|distro| {
        let unc = unc_path(distro, linux_path)?;
        exists(&unc).then(|| (distro.clone(), unc))
    })
}

/// Whether VS Code's Remote - WSL extension is installed, from the names in
/// `~/.vscode/extensions`: with it a WSL folder opens in a window that runs in
/// the distro (its terminal, its extensions), without it as a plain network path.
pub fn has_remote_wsl(extension_dirs: &[String]) -> bool {
    // `remote-wsl-0.88.5`, not `remote-wsl-recommender-0.0.19`: a version follows.
    extension_dirs.iter().any(|name| {
        name.to_ascii_lowercase()
            .strip_prefix("ms-vscode-remote.remote-wsl-")
            .and_then(|rest| rest.chars().next())
            .is_some_and(|c| c.is_ascii_digit())
    })
}

/// The arguments `code` gets for a path in a distro.
pub fn editor_args(distro: &str, linux_path: &str, unc: &std::path::Path, remote: bool) -> Vec<std::ffi::OsString> {
    if remote {
        vec!["--remote".into(), format!("wsl+{distro}").into(), linux_path.into()]
    } else {
        vec![unc.as_os_str().to_owned()]
    }
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

/// The running distros, asked of `wsl.exe` at most every half minute.
fn running_distros() -> Vec<String> {
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    static CACHE: Mutex<Option<(Instant, Vec<String>)>> = Mutex::new(None);
    let mut cache = CACHE.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, list)) = cache.as_ref() {
        if at.elapsed() < Duration::from_secs(30) {
            return list.clone();
        }
    }
    let list: Vec<String> = wsl_output(&["-l", "--running", "-q"])
        .map(|b| parse_distro_list(&b))
        .unwrap_or_default()
        .into_iter()
        .filter(|name| is_safe_name(name))
        .collect();
    *cache = Some((Instant::now(), list.clone()));
    list
}

/// A path that came from a session in WSL, as a distro and a Windows path.
/// Only running distros are looked in: reading a stopped one would start it.
pub fn resolve_linux_path(linux_path: &str) -> Option<(String, PathBuf)> {
    locate(linux_path, &running_distros(), |p| std::fs::metadata(p).is_ok())
}

/// Remote - WSL is among VS Code's extensions (see `has_remote_wsl`).
pub fn remote_wsl_installed() -> bool {
    let dir = crate::platform::home_dir().join(".vscode").join("extensions");
    let names: Vec<String> = std::fs::read_dir(dir)
        .map(|entries| entries.flatten().filter_map(|e| e.file_name().into_string().ok()).collect())
        .unwrap_or_default();
    has_remote_wsl(&names)
}

/// The distros, and for each running one its users with what Coucou has in their
/// settings.json. Read-only.
pub fn list() -> Vec<WslDistro> {
    distros()
        .into_iter()
        .map(|(name, running)| {
            let users = if running {
                let expected = to_wsl_path(&crate::settings::hook_exe_path().to_string_lossy(), &automount_root(&name));
                users(&name)
                    .into_iter()
                    .map(|user| {
                        let path = settings_of(&name, &user);
                        let found = crate::hooks::read_settings_lossy_at(&path)
                            .map(|settings| inspect(&settings, expected.as_deref()))
                            .unwrap_or_default();
                        WslUser {
                            installed: found.installed,
                            plan_installed: found.plan,
                            stale: found.stale,
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

/// Whether Claude Code in some running distro reaches Coucou: its hooks are in a
/// user's settings.json and start the current relay. Answers from what it knew
/// half a minute ago: it asks `wsl.exe` and reads files over the share, and the
/// island asks every time it opens.
pub fn hooks_connected() -> bool {
    use std::sync::Mutex;
    use std::time::{Duration, Instant};
    static CACHE: Mutex<Option<(Instant, bool)>> = Mutex::new(None);
    if let Some((at, connected)) = *CACHE.lock().unwrap_or_else(|e| e.into_inner()) {
        if at.elapsed() < Duration::from_secs(30) {
            return connected;
        }
    }
    let connected = list().iter().flat_map(|d| &d.users).any(|u| u.installed && !u.stale);
    *CACHE.lock().unwrap_or_else(|e| e.into_inner()) = Some((Instant::now(), connected));
    connected
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
    fn a_linux_path_becomes_a_path_on_the_distros_share() {
        assert_eq!(
            unc_path("Ubuntu", "/home/me/proj/src/main.rs"),
            Some(PathBuf::from(r"\\wsl.localhost\Ubuntu").join("home").join("me").join("proj").join("src").join("main.rs"))
        );
        assert_eq!(unc_path("Ubuntu", "/"), Some(PathBuf::from(r"\\wsl.localhost\Ubuntu")));
        // Doubled and dotted separators are tidied.
        assert_eq!(unc_path("Ubuntu", "/home//me/./x"), unc_path("Ubuntu", "/home/me/x"));
        // Not a full Linux path, or one that could lead elsewhere.
        for bad in ["home/me", "", "C:\\Users\\me", "/home/../etc", "/home/me/..", "/a\\b", "/a\0b"] {
            assert_eq!(unc_path("Ubuntu", bad), None, "{bad:?}");
        }
        assert_eq!(unc_path("../x", "/home"), None);
        assert_eq!(unc_path("", "/home"), None);
    }

    #[test]
    fn the_distro_that_has_the_path_is_the_one_used() {
        let distros = ["Debian".to_string(), "Ubuntu".to_string()];
        let only_ubuntu = |p: &std::path::Path| p.to_string_lossy().contains("Ubuntu");
        let (distro, unc) = locate("/home/me/proj", &distros, only_ubuntu).unwrap();
        assert_eq!(distro, "Ubuntu");
        assert_eq!(Some(unc), unc_path("Ubuntu", "/home/me/proj"));
        // Both have it: the first. None has it, or there is no distro: nothing.
        assert_eq!(locate("/home/me", &distros, |_| true).unwrap().0, "Debian");
        assert_eq!(locate("/home/me", &distros, |_| false), None);
        assert_eq!(locate("/home/me", &[], |_| true), None);
        assert_eq!(locate("../x", &distros, |_| true), None);
    }

    #[test]
    fn code_opens_a_distros_path_in_its_remote_window_when_it_can() {
        let unc = PathBuf::from(r"\\wsl.localhost\Ubuntu").join("home").join("me");
        let remote = editor_args("Ubuntu", "/home/me", &unc, true);
        assert_eq!(remote, vec!["--remote", "wsl+Ubuntu", "/home/me"]);
        let plain = editor_args("Ubuntu", "/home/me", &unc, false);
        assert_eq!(plain, vec![unc.as_os_str().to_owned()]);
        let names = |l: &[&str]| l.iter().map(|s| s.to_string()).collect::<Vec<_>>();
        assert!(has_remote_wsl(&names(&["ms-python.python-2024.1", "ms-vscode-remote.remote-wsl-0.88.5"])));
        assert!(!has_remote_wsl(&names(&["ms-vscode-remote.remote-ssh-0.100.0", "ms-vscode-remote.remote-wsl-recommender-0.0.1x"])));
        assert!(!has_remote_wsl(&[]));
    }

    #[test]
    fn the_relay_is_read_back_out_of_a_command() {
        assert_eq!(first_quoted("[ -x '/mnt/c/a/coucou-hook.exe' ] && '/mnt/c/a/coucou-hook.exe' Stop || true").as_deref(), Some("/mnt/c/a/coucou-hook.exe"));
        assert_eq!(first_quoted(r"'/mnt/c/O'\''Neil/x.exe' Stop").as_deref(), Some("/mnt/c/O'Neil/x.exe"));
        assert_eq!(first_quoted("echo 'a b' 'c'").as_deref(), Some("a b"));
        // Nothing quoted, or never closed.
        assert_eq!(first_quoted("bash ~/.claude/statusline.sh"), None);
        assert_eq!(first_quoted("echo 'open"), None);
        assert_eq!(first_quoted(""), None);
        // It is what relay_command wrote.
        let odd = "/mnt/c/Users/O'Neil Jr/bin/coucou-hook.exe";
        assert_eq!(first_quoted(&relay_command(odd, "Stop")).as_deref(), Some(odd));
        assert_eq!(first_quoted(&status_line_command(odd, Some("bash x.sh"))).as_deref(), Some(odd));
    }

    #[test]
    fn a_distros_settings_say_whether_coucou_is_there_and_whether_it_would_run() {
        use serde_json::json;
        let current = "/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe";
        let moved = "/mnt/d/Coucou/bin/coucou-hook.exe";
        let theirs = json!({ "hooks": { "Stop": [{ "hooks": [{ "type": "command", "command": "/home/me/pulse/notify.sh" }] }] } });
        assert_eq!(inspect(&theirs, Some(current)), Found::default());
        assert_eq!(inspect(&json!({}), Some(current)), Found::default());

        let hooks = |relay: &str| json!({ "hooks": { "Stop": [{ "hooks": [{ "command": relay_command(relay, "Stop") }] }] } });
        assert_eq!(inspect(&hooks(current), Some(current)), Found { installed: true, plan: false, stale: false });
        // The relay is somewhere else now: still there, but it would do nothing.
        assert_eq!(inspect(&hooks(moved), Some(current)), Found { installed: true, plan: false, stale: true });
        // Nothing to compare with (the relay is not on a drive): not called stale.
        assert!(!inspect(&hooks(moved), None).stale);

        // The status line counts apart, and goes stale on its own.
        let line = |relay: &str| json!({ "statusLine": { "type": "command", "command": status_line_command(relay, None) } });
        assert_eq!(inspect(&line(current), Some(current)), Found { installed: false, plan: true, stale: false });
        assert_eq!(inspect(&line(moved), Some(current)), Found { installed: false, plan: true, stale: true });
        // Somebody's own status line is not ours.
        assert_eq!(inspect(&json!({ "statusLine": { "command": "bash ~/.claude/statusline.sh" } }), Some(current)), Found::default());

        // A Coucou for Linux inside the distro is its own install, not a stale one.
        let native = json!({ "hooks": { "Stop": [{ "hooks": [{ "command": "'/home/me/.local/share/coucou/bin/coucou-hook' Stop" }] }] } });
        assert_eq!(inspect(&native, Some(current)), Found { installed: true, plan: false, stale: false });
    }

    #[test]
    fn the_status_line_runs_the_users_own_in_the_distro_and_feeds_the_relay_beside_it() {
        let relay = "/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe";
        let with = status_line_command(relay, Some("bash ~/.claude/statusline.sh"));
        assert!(with.starts_with("input=$(cat); "), "{with}");
        assert!(with.contains("'/mnt/c/Users/Me/AppData/Local/Coucou/bin/coucou-hook.exe' --statusline --no-previous; }"), "{with}");
        // In the background, with no hold on the output, so it never delays the
        // line; and the user's command last.
        assert!(with.contains("; } >/dev/null 2>&1 & "), "{with}");
        assert!(with.trim_end().ends_with("{ bash ~/.claude/statusline.sh\n}"), "{with}");
        // None of their own: nothing printed.
        for none in [None, Some(""), Some("   ")] {
            let c = status_line_command(relay, none);
            assert!(c.ends_with("| :"), "{c}");
        }
        // The marker the rest of Coucou recognises its entries by.
        assert!(with.contains("coucou-hook"));
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
        // Empty when the hooks are already in, as an install changes nothing then.
        println!("backup would go to: {}\n{}", preview.backup, preview.diff);
        println!("connected: {}", hooks_connected());
        let line = crate::hooks::wsl_status_line_preview(&distro, &user, true).unwrap();
        println!("status line diff:\n{}", line.diff);
        assert!(line.diff.contains("--no-previous"));
    }
}
