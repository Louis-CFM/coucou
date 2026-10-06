// Claude Code under WSL.
//
// WSL interop runs coucou-hook.exe as a Windows process under the user's
// account, so a Claude Code running inside a distro reaches the named pipe like
// any Windows terminal. What it needs is a small relay script in the distro and
// the hooks in the distro's own ~/.claude/settings.json.
//
// Both are written through `\\wsl.localhost\<distro>\…`, and the settings.json
// follows exactly the same rule as on Windows (hooks.rs): dated backup, merge,
// diff, and nothing written until the user clicks.

use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::time::{Duration, Instant};

use serde::Serialize;

use crate::hooks::{self, HookPreview, Target};
use crate::{platform, settings};

/// A distro that is starting up can take a few seconds to answer; one that is
/// wedged must not hang the settings window.
const WSL_TIMEOUT: Duration = Duration::from_secs(15);

/// The relay script, as published in hook/. Only its `EXE=` line is rewritten,
/// to the WSL path of this machine's coucou-hook.exe.
const RELAY_TEMPLATE: &str = include_str!("../../hook/coucou-hook-wsl.sh");

/// Where the relay lives inside the distro, relative to $HOME.
const RELAY_REL: &str = ".claude/hooks/coucou-hook-wsl.sh";

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WslStatus {
    pub distro: String,
    pub installed: bool,
    /// The Linux path, the way the user knows it.
    pub settings_path: String,
    pub relay_path: String,
    /// The relay script is in place and matches what Coucou would write.
    pub relay_ready: bool,
    /// Claude Code inside the distro, if installed — what "Use for Mochi" runs.
    pub claude_cli: Option<String>,
    /// Set when the distro could not be reached; nothing else is meaningful then.
    pub error: Option<String>,
}

/// Everything about one distro that the other calls need.
struct Distro {
    name: String,
    /// `/home/<user>`
    home: String,
    /// `\\wsl.localhost\<distro>` (or `\\wsl$\<distro>` on older Windows).
    unc_root: PathBuf,
    /// coucou-hook.exe as seen from inside the distro (`/mnt/c/...`).
    exe_in_wsl: String,
}

impl Distro {
    fn unc(&self, linux_path: &str) -> PathBuf {
        let mut p = self.unc_root.clone();
        for part in linux_path.split('/').filter(|s| !s.is_empty()) {
            p.push(part);
        }
        p
    }

    fn settings_linux(&self) -> String {
        format!("{}/.claude/settings.json", self.home)
    }

    fn relay_linux(&self) -> String {
        format!("{}/{RELAY_REL}", self.home)
    }

    fn target(&self) -> Target {
        Target {
            settings_path: self.unc(&self.settings_linux()),
            // Run through `sh` so the script works without its executable bit,
            // which a file written from Windows does not get.
            command: Box::new(|event| format!("sh \"$HOME/{RELAY_REL}\" {event}")),
        }
    }

    fn relay_script(&self) -> String {
        RELAY_TEMPLATE
            .lines()
            .map(|line| {
                if line.starts_with("EXE=") {
                    format!("EXE='{}'", self.exe_in_wsl.replace('\'', r"'\''"))
                } else {
                    line.to_string()
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
            + "\n"
    }

    fn relay_ready(&self) -> bool {
        std::fs::read_to_string(self.unc(&self.relay_linux()))
            .map(|current| current == self.relay_script())
            .unwrap_or(false)
    }
}

/// Runs wsl.exe with no window, under a deadline. `None` on any failure —
/// including everywhere but on Windows, where there is no wsl.exe to run.
pub(crate) fn run_wsl(args: &[&str]) -> Option<String> {
    let mut wsl = Command::new("wsl.exe");
    wsl.args(args)
        // Newer WSL prints its own messages in UTF-16 unless asked otherwise.
        .env("WSL_UTF8", "1")
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null());
    let mut child = platform::no_console(&mut wsl).spawn().ok()?;
    let deadline = Instant::now() + WSL_TIMEOUT;
    loop {
        match child.try_wait() {
            Ok(Some(status)) if status.success() => break,
            Ok(Some(_)) | Err(_) => return None,
            Ok(None) if Instant::now() >= deadline => {
                let _ = child.kill();
                return None;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
        }
    }
    let mut out = Vec::new();
    std::io::Read::read_to_end(&mut child.stdout.take()?, &mut out).ok()?;
    Some(decode(&out))
}

/// wsl.exe speaks UTF-16LE when WSL_UTF8 is not honoured (older builds).
fn decode(bytes: &[u8]) -> String {
    if bytes.len() >= 2 && bytes.iter().skip(1).step_by(2).take(8).all(|b| *b == 0) {
        let units: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    }
}

/// Installed distros, without starting any of them. Docker Desktop's internal
/// distros are not places anybody runs Claude Code.
pub fn distros() -> Vec<String> {
    let Some(out) = run_wsl(&["--list", "--quiet"]) else { return Vec::new() };
    parse_distros(&out)
}

fn parse_distros(out: &str) -> Vec<String> {
    out.lines()
        .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\0'))
        .filter(|l| !l.is_empty() && is_distro_name(l) && !l.starts_with("docker-desktop"))
        .map(str::to_string)
        .collect()
}

/// Same rule as the island's "Open terminal": a name is letters, digits, `.`,
/// `-` and `_`, or it never reaches a command line or a UNC path.
pub fn is_distro_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && name.chars().all(|c| c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_'))
}

/// Asks the distro for its $HOME and for the WSL path of coucou-hook.exe. This
/// starts the distro if it is not running.
fn resolve(name: &str) -> Result<Distro, String> {
    if !distros().iter().any(|d| d == name) {
        return Err(format!("{name} isn't an installed WSL distribution."));
    }
    let unreachable = || format!("Can't reach {name}. Start it once from a terminal, then refresh.");

    let home = run_wsl(&["-d", name, "--exec", "printenv", "HOME"])
        .map(|s| s.trim().to_string())
        .filter(|h| h.starts_with('/'))
        .ok_or_else(unreachable)?;

    let exe = settings::hook_exe_path();
    let exe_in_wsl = run_wsl(&["-d", name, "--exec", "wslpath", "-u", &exe.to_string_lossy()])
        .map(|s| s.trim().to_string())
        .filter(|p| p.starts_with('/'))
        .ok_or_else(unreachable)?;

    let unc_root = [r"\\wsl.localhost", r"\\wsl$"]
        .iter()
        .map(|base| PathBuf::from(format!(r"{base}\{name}")))
        .find(|p| p.join("etc").is_dir())
        .ok_or_else(unreachable)?;

    Ok(Distro { name: name.to_string(), home, unc_root, exe_in_wsl })
}

// ── Public API ────────────────────────────────────────────────────────────────

pub fn status(name: &str) -> WslStatus {
    match resolve(name) {
        Ok(d) => WslStatus {
            installed: hooks::installed_at(&d.target().settings_path),
            settings_path: d.settings_linux(),
            relay_path: d.relay_linux(),
            relay_ready: d.relay_ready(),
            claude_cli: crate::local_claude::wsl_cli(&d.name),
            distro: d.name,
            error: None,
        },
        Err(err) => WslStatus {
            distro: name.to_string(),
            installed: false,
            settings_path: String::new(),
            relay_path: String::new(),
            relay_ready: false,
            claude_cli: None,
            error: Some(err),
        },
    }
}

pub fn preview(name: &str, install: bool) -> Result<HookPreview, String> {
    let d = resolve(name)?;
    let mut plan = hooks::preview_for(&d.target(), install)?;
    // Show the Linux paths: they are the ones the user recognises.
    plan.settings_path = d.settings_linux();
    plan.backup = plan
        .backup
        .rsplit(['\\', '/'])
        .next()
        .map(|file| format!("{}/.claude/{file}", d.home))
        .unwrap_or(plan.backup);
    Ok(plan)
}

/// Writes the relay script (on install) and the settings.json, after a backup.
/// On uninstall the script goes too, once the hooks no longer point at it.
pub fn write(name: &str, install: bool, fingerprint: &str) -> Result<String, String> {
    let d = resolve(name)?;
    let relay = d.unc(&d.relay_linux());
    if install {
        if let Some(dir) = relay.parent() {
            std::fs::create_dir_all(dir).map_err(|e| format!("Can't create {}: {e}", dir.display()))?;
        }
        std::fs::write(&relay, d.relay_script())
            .map_err(|e| format!("Can't write the relay script: {e}"))?;
    }
    let backup = hooks::write_for(&d.target(), install, fingerprint)?;
    if !install {
        let _ = std::fs::remove_file(&relay);
    }
    Ok(backup
        .rsplit(['\\', '/'])
        .next()
        .map(|file| format!("{}/.claude/{file}", d.home))
        .unwrap_or(backup))
}

// WSL paths are Windows UNC paths: they only mean anything, and only join the
// way these tests expect, on Windows.
#[cfg(all(test, windows))]
mod tests {
    use super::*;

    #[test]
    fn distro_listing_skips_docker_and_blank_lines() {
        let out = "Ubuntu\r\n\r\ndocker-desktop\r\nDebian\r\ndocker-desktop-data\r\n";
        assert_eq!(parse_distros(out), vec!["Ubuntu", "Debian"]);
    }

    #[test]
    fn utf16_output_is_decoded() {
        let bytes: Vec<u8> = "Ubuntu\r\n".encode_utf16().flat_map(u16::to_le_bytes).collect();
        assert_eq!(decode(&bytes), "Ubuntu\r\n");
        assert_eq!(decode(b"Ubuntu\n"), "Ubuntu\n");
    }

    #[test]
    fn odd_distro_names_are_refused() {
        assert!(is_distro_name("Ubuntu-24.04"));
        assert!(!is_distro_name("a b"));
        assert!(!is_distro_name("x&calc"));
        assert!(!is_distro_name(""));
    }

    #[test]
    fn the_relay_script_points_at_this_machines_exe() {
        let d = Distro {
            name: "Ubuntu".into(),
            home: "/home/me".into(),
            unc_root: PathBuf::from(r"\\wsl.localhost\Ubuntu"),
            exe_in_wsl: "/mnt/c/Users/O'Brien/AppData/Local/Coucou/bin/coucou-hook.exe".into(),
        };
        let script = d.relay_script();
        assert!(script.contains(r"EXE='/mnt/c/Users/O'\''Brien/AppData/Local/Coucou/bin/coucou-hook.exe'"));
        assert!(script.contains("WSLENV="), "the distro name must still be forwarded");
        assert!(!script.contains('\r'), "a CRLF script breaks sh");
        assert_eq!(
            d.unc("/home/me/.claude/settings.json"),
            PathBuf::from(r"\\wsl.localhost\Ubuntu\home\me\.claude\settings.json")
        );
        assert_eq!((d.target().command)("Stop"), r#"sh "$HOME/.claude/hooks/coucou-hook-wsl.sh" Stop"#);
    }
}
