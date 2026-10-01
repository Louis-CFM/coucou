// Claude Code running inside WSL.
//
// A distro has its own ~/.claude/settings.json, which Claude Code in WSL reads
// instead of %USERPROFILE%\.claude\settings.json. We reach it from Windows over
// `\\wsl$\<distro>\…`, and the hook command points back at the same
// coucou-hook.exe through WSL interop, so it still talks to the named pipe.
//
// Only the settings window calls into here: `wsl.exe -d` starts a stopped
// distro, and the app must not boot every distro on launch.

use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::Command;

const CREATE_NO_WINDOW: u32 = 0x0800_0000;

/// Docker Desktop's own distros: nobody runs Claude Code in them.
const IGNORED: &[&str] = &["docker-desktop", "docker-desktop-data"];

/// Installed distros, by name. Empty when WSL is not installed.
pub fn distros() -> Vec<String> {
    let Ok(out) = Command::new("wsl.exe")
        .args(["--list", "--quiet"])
        .env("WSL_UTF8", "1")
        .creation_flags(CREATE_NO_WINDOW)
        .output()
    else {
        return Vec::new();
    };
    if !out.status.success() {
        return Vec::new();
    }
    parse_list(&out.stdout)
}

/// `wsl --list` prints UTF-16LE unless WSL_UTF8 is honoured (newer WSL only).
fn parse_list(bytes: &[u8]) -> Vec<String> {
    let text = if bytes.len() >= 2 && bytes[1] == 0 {
        let units: Vec<u16> = bytes
            .chunks_exact(2)
            .map(|c| u16::from_le_bytes([c[0], c[1]]))
            .collect();
        String::from_utf16_lossy(&units)
    } else {
        String::from_utf8_lossy(bytes).into_owned()
    };
    text.lines()
        .map(|l| l.trim_matches(|c: char| c.is_whitespace() || c == '\u{feff}'))
        .filter(|l| !l.is_empty() && !IGNORED.contains(&l.to_lowercase().as_str()))
        .map(str::to_string)
        .collect()
}

/// Where the distro's settings.json is, seen from Windows, and the Linux path
/// of `exe`. Asks the distro itself: $HOME of the default user (the one who
/// runs Claude Code) and `wslpath`, which knows a custom automount root.
pub fn locate(distro: &str, exe: &str) -> Result<(PathBuf, String), String> {
    let out = Command::new("wsl.exe")
        .args(["-d", distro, "-e", "sh", "-c", r#"printf '%s\n' "$HOME"; wslpath -u "$1""#, "sh", exe])
        .creation_flags(CREATE_NO_WINDOW)
        .output()
        .map_err(|e| format!("Can't run wsl.exe: {e}"))?;
    let text = String::from_utf8_lossy(&out.stdout);
    let mut lines = text.lines().map(str::trim);
    match (out.status.success(), lines.next(), lines.next()) {
        (true, Some(home), Some(linux_exe)) if home.starts_with('/') && linux_exe.starts_with('/') => {
            Ok((unc(distro, home).join(".claude").join("settings.json"), linux_exe.to_string()))
        }
        _ => Err(format!(
            "Can't reach the WSL distro {distro}: {}",
            String::from_utf8_lossy(&out.stderr).trim()
        )),
    }
}

/// `/home/me` in `Ubuntu` → `\\wsl$\Ubuntu\home\me`. `\\wsl$` rather than
/// `\\wsl.localhost`: it works on every WSL 2 build.
pub fn unc(distro: &str, linux_path: &str) -> PathBuf {
    PathBuf::from(format!(r"\\wsl$\{distro}{}", linux_path.replace('/', "\\")))
}

/// The reverse, for "Open terminal": `\\wsl$\Ubuntu\home\me` (or
/// `\\wsl.localhost\…`) → `("Ubuntu", "/home/me")`.
pub fn split_unc(path: &str) -> Option<(String, String)> {
    let lower = path.to_lowercase();
    let rest = ["\\\\wsl$\\", "\\\\wsl.localhost\\"]
        .iter()
        .find(|p| lower.starts_with(*p))
        .map(|p| &path[p.len()..])?;
    let (distro, tail) = rest.split_once('\\').unwrap_or((rest, ""));
    (!distro.is_empty()).then(|| (distro.to_string(), format!("/{}", tail.replace('\\', "/"))))
}

/// sh single quotes: nothing inside is special except the quote itself.
pub fn sh_quote(s: &str) -> String {
    format!("'{}'", s.replace('\'', r"'\''"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_list_is_read_in_both_encodings() {
        let utf16: Vec<u8> = "Ubuntu-24.04\r\ndocker-desktop\r\nDebian\r\n"
            .encode_utf16()
            .flat_map(u16::to_le_bytes)
            .collect();
        assert_eq!(parse_list(&utf16), ["Ubuntu-24.04", "Debian"]);
        assert_eq!(parse_list(b"Ubuntu\n\n"), ["Ubuntu"]);
        assert!(parse_list(b"").is_empty());
    }

    #[test]
    fn unc_paths_go_both_ways() {
        let p = unc("Ubuntu", "/home/me/proj");
        assert_eq!(p.to_string_lossy(), r"\\wsl$\Ubuntu\home\me\proj");
        assert_eq!(split_unc(&p.to_string_lossy()), Some(("Ubuntu".into(), "/home/me/proj".into())));
        assert_eq!(split_unc(r"\\wsl.localhost\Debian"), Some(("Debian".into(), "/".into())));
        assert_eq!(split_unc(r"C:\Users\me"), None);
    }

    #[test]
    fn quoting_survives_spaces_and_quotes() {
        assert_eq!(sh_quote("/mnt/c/Users/Jo G/x.exe"), "'/mnt/c/Users/Jo G/x.exe'");
        assert_eq!(sh_quote("it's"), r"'it'\''s'");
    }
}
