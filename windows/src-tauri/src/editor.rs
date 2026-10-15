// The editor that "Open terminal" and the diff's ↗ open folders and files in:
// VS Code or PhpStorm, picked in Settings (`editor` in settings.json).
//
// No shell anywhere near this: the launcher is found here and the path is
// handed over as a separate argument, so a folder name stays a path.

use serde::Deserialize;
use std::ffi::OsString;
use std::path::{Path, PathBuf};

/// A file bigger than this is not read to find a line in.
const MAX_SEARCHED_BYTES: u64 = 4 * 1024 * 1024;

/// Where the first change of a diff is, said by what is around it: a diff of an
/// Edit holds the edited text, not the file, so its own line numbers are the
/// text's. `block` is a run of consecutive lines of the file as the edit left
/// it, and `offset` the one of them that was changed.
#[derive(Debug, Clone, Deserialize)]
pub struct LineHint {
    pub block: Vec<String>,
    pub offset: usize,
}

impl LineHint {
    /// The 1-based line of the file that is the changed one: where the block
    /// first appears in it. None when the file has changed since, or is too big
    /// or not text.
    pub fn locate_in(&self, file: &Path) -> Option<u32> {
        if self.block.is_empty() || self.offset >= self.block.len() {
            return None;
        }
        if std::fs::metadata(file).ok()?.len() > MAX_SEARCHED_BYTES {
            return None;
        }
        let text = std::fs::read_to_string(file).ok()?;
        self.locate_in_text(&text)
    }

    fn locate_in_text(&self, text: &str) -> Option<u32> {
        let lines: Vec<&str> = text.lines().collect();
        let at = lines.windows(self.block.len()).position(|w| w.iter().zip(&self.block).all(|(a, b)| a == b))?;
        u32::try_from(at + self.offset + 1).ok()
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Editor {
    VsCode,
    PhpStorm,
}

impl Editor {
    /// The editor a settings value names; anything unknown is VS Code, the default.
    pub fn from_id(id: &str) -> Editor {
        match id {
            "phpstorm" => Editor::PhpStorm,
            _ => Editor::VsCode,
        }
    }

    /// The program that opens things in this editor, if it is installed.
    pub fn launcher(self) -> Option<PathBuf> {
        match self {
            Editor::VsCode => crate::platform::find_on_path("code"),
            Editor::PhpStorm => first_file(&phpstorm_candidates()),
        }
    }

    /// The arguments that open a target. `vscode_args` are the ones VS Code is
    /// given (they may reach into WSL, which PhpStorm has no use for); `local`
    /// is the target as this machine reaches it; `line` is a line of a file to
    /// land on, which only PhpStorm is asked for.
    pub fn args(self, local: &Path, vscode_args: &[OsString], line: Option<u32>) -> Vec<OsString> {
        match self {
            Editor::VsCode => vscode_args.to_vec(),
            Editor::PhpStorm => phpstorm_args(local, line),
        }
    }
}

/// `phpstorm --line N <file>`; without a line, `phpstorm <path>`.
fn phpstorm_args(local: &Path, line: Option<u32>) -> Vec<OsString> {
    let mut args = Vec::new();
    if let Some(n) = line.filter(|n| *n > 0) {
        args.push("--line".into());
        args.push(n.to_string().into());
    }
    args.push(local.as_os_str().to_owned());
    args
}

/// Where PhpStorm's launcher may be, best first: $PATH, then the JetBrains
/// Toolbox's scripts folder and the snap, which a desktop launch often leaves
/// out of $PATH.
fn phpstorm_candidates() -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = ["phpstorm", "phpstorm.sh", "pstorm", "phpstorm64"]
        .iter()
        .filter_map(|stem| crate::platform::find_on_path(stem))
        .collect();
    #[cfg(windows)]
    if let Some(local) = std::env::var_os("LOCALAPPDATA").map(PathBuf::from).filter(|p| p.is_absolute()) {
        out.push(local.join("JetBrains").join("Toolbox").join("scripts").join("phpstorm.cmd"));
    }
    #[cfg(not(windows))]
    {
        let home = crate::platform::home_dir();
        out.push(home.join(".local/share/JetBrains/Toolbox/scripts/phpstorm"));
        out.push(PathBuf::from("/snap/bin/phpstorm"));
    }
    out
}

fn first_file(candidates: &[PathBuf]) -> Option<PathBuf> {
    candidates.iter().find(|p| p.is_file()).cloned()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_setting_names_the_editor_and_unknown_means_vs_code() {
        assert_eq!(Editor::from_id("vscode"), Editor::VsCode);
        assert_eq!(Editor::from_id("phpstorm"), Editor::PhpStorm);
        assert_eq!(Editor::from_id(""), Editor::VsCode);
        assert_eq!(Editor::from_id("PhpStorm"), Editor::VsCode);
        assert_eq!(Editor::from_id("emacs"), Editor::VsCode);
    }

    #[test]
    fn phpstorm_lands_on_the_line_and_vs_code_is_left_as_it_was() {
        let file = Path::new("/p/src/a.php");
        let vscode: Vec<OsString> = vec!["/p/src/a.php".into()];
        let os = |args: &[&str]| args.iter().map(OsString::from).collect::<Vec<_>>();
        assert_eq!(Editor::PhpStorm.args(file, &vscode, Some(12)), os(&["--line", "12", "/p/src/a.php"]));
        assert_eq!(Editor::PhpStorm.args(file, &vscode, None), os(&["/p/src/a.php"]));
        assert_eq!(Editor::PhpStorm.args(file, &vscode, Some(0)), os(&["/p/src/a.php"]));
        // VS Code is given its own arguments, whatever the line.
        assert_eq!(Editor::VsCode.args(file, &vscode, Some(12)), vscode);
    }

    #[test]
    fn phpstorm_gets_the_path_the_machine_reaches_not_vs_codes_wsl_arguments() {
        let unc = Path::new(r"\\wsl$\Ubuntu\home\me\proj");
        let remote: Vec<OsString> = vec!["--remote".into(), "wsl+Ubuntu".into(), "/home/me/proj".into()];
        assert_eq!(Editor::PhpStorm.args(unc, &remote, None), vec![unc.as_os_str().to_owned()]);
    }

    #[test]
    fn the_changed_line_is_found_by_the_lines_around_it() {
        let hint = |block: &[&str], offset| LineHint { block: block.iter().map(|s| s.to_string()).collect(), offset };
        let file = "<?php\n\nfunction a() {\n    return 1;\n}\n\nfunction b() {\n    return 1;\n}\n";
        // The same line twice: the block says which one.
        assert_eq!(hint(&["function b() {", "    return 1;"], 1).locate_in_text(file), Some(8));
        assert_eq!(hint(&["function a() {", "    return 1;"], 1).locate_in_text(file), Some(4));
        assert_eq!(hint(&["<?php"], 0).locate_in_text(file), Some(1));
        // Windows line endings do not matter.
        assert_eq!(hint(&["function b() {"], 0).locate_in_text(&file.replace('\n', "\r\n")), Some(7));
        // The text is gone, or the hint is empty or points outside its block.
        assert_eq!(hint(&["function c() {"], 0).locate_in_text(file), None);
        assert_eq!(hint(&[], 0).locate_in(Path::new("/nowhere")), None);
        assert_eq!(hint(&["<?php"], 1).locate_in(Path::new("/nowhere")), None);
    }

    #[test]
    fn the_first_launcher_that_exists_wins() {
        let dir = std::env::temp_dir().join(format!("coucou-editor-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let second = dir.join("second");
        std::fs::write(&second, "").unwrap();
        let third = dir.join("third");
        std::fs::write(&third, "").unwrap();
        let missing = dir.join("missing");
        assert_eq!(first_file(&[missing.clone(), second.clone(), third]), Some(second));
        assert_eq!(first_file(&[missing]), None);
        assert_eq!(first_file(&[]), None);
        // A folder is not a launcher.
        assert_eq!(first_file(&[dir.clone()]), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
