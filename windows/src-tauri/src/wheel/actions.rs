// The wheel's Actions ring: what can be done with any file or folder.

use std::path::{Path, PathBuf};

/// The files on the clipboard, ready to paste in Explorer.
pub fn copy(paths: &[PathBuf]) -> Result<(), String> {
    os::copy_files(paths)
}

/// Their full paths as text, one per line.
pub fn copy_path(paths: &[PathBuf]) -> Result<(), String> {
    let text = paths.iter().map(|p| p.display().to_string()).collect::<Vec<_>>().join("\r\n");
    if crate::flow::paste::copy(&text) {
        Ok(())
    } else {
        Err("the clipboard is busy".into())
    }
}

/// Moved into a folder picked in Windows' own dialog; None when cancelled.
pub fn move_to(paths: &[PathBuf]) -> Result<Option<Vec<PathBuf>>, String> {
    let Some(folder) = os::pick_folder() else { return Ok(None) };
    let mut moved = Vec::new();
    for p in paths {
        let name = p.file_name().ok_or("no file name")?;
        let mut dest = folder.join(name);
        if dest.exists() {
            let ext = p.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_default();
            dest = super::formats::output_path(&folder.join(name), None, &ext);
        }
        if std::fs::rename(p, &dest).is_err() {
            // Another drive: copy, then remove the original.
            if p.is_dir() {
                return Err(format!("{} is a folder on another drive: move it in Explorer", p.display()));
            }
            std::fs::copy(p, &dest).map_err(|e| e.to_string())?;
            std::fs::remove_file(p).map_err(|e| e.to_string())?;
        }
        moved.push(dest);
    }
    Ok(Some(moved))
}

/// The folder (a file's own folder) in a terminal.
pub fn terminal(path: &Path) -> Result<(), String> {
    let dir = if path.is_dir() { path.to_path_buf() } else { path.parent().ok_or("no folder")?.to_path_buf() };
    os::terminal(&dir)
}

/// Explorer, with the file selected.
pub fn reveal(path: &Path) -> Result<(), String> {
    os::reveal(path)
}

#[cfg(windows)]
mod os {
    use std::os::windows::process::CommandExt;
    use std::path::{Path, PathBuf};
    use std::process::Command;

    const CREATE_NEW_CONSOLE: u32 = 0x0000_0010;

    pub fn copy_files(paths: &[PathBuf]) -> Result<(), String> {
        use clipboard_win::{raw, Clipboard};
        let list: Vec<String> = paths.iter().map(|p| p.display().to_string()).collect();
        let _clip = Clipboard::new_attempts(10).map_err(|e| e.to_string())?;
        raw::empty().map_err(|e| e.to_string())?;
        raw::set_file_list(&list).map_err(|e| e.to_string())
    }

    pub fn pick_folder() -> Option<PathBuf> {
        rfd::FileDialog::new().pick_folder()
    }

    pub fn terminal(dir: &Path) -> Result<(), String> {
        // Windows Terminal when it is there, else PowerShell in its own console.
        if Command::new("wt.exe").arg("-d").arg(dir).spawn().is_ok() {
            return Ok(());
        }
        Command::new("powershell.exe")
            .args(["-NoExit", "-NoLogo", "-Command", "Set-Location -LiteralPath $args[0]"])
            .arg(dir)
            .creation_flags(CREATE_NEW_CONSOLE)
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }

    pub fn reveal(path: &Path) -> Result<(), String> {
        Command::new("explorer.exe")
            .raw_arg(format!("/select,\"{}\"", path.display()))
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
}

#[cfg(not(windows))]
mod os {
    use std::path::{Path, PathBuf};

    pub fn copy_files(_paths: &[PathBuf]) -> Result<(), String> {
        Err("not on this system".into())
    }
    pub fn pick_folder() -> Option<PathBuf> {
        None
    }
    pub fn terminal(dir: &Path) -> Result<(), String> {
        std::process::Command::new("x-terminal-emulator").current_dir(dir).spawn().map(|_| ()).map_err(|e| e.to_string())
    }
    pub fn reveal(path: &Path) -> Result<(), String> {
        let dir = path.parent().unwrap_or(path);
        std::process::Command::new("xdg-open").arg(dir).spawn().map(|_| ()).map_err(|e| e.to_string())
    }
}
