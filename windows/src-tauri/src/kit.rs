// The Kit page's keeping (src/views/kit.ts): the focus timer's settings and
// sessions, the water log, the to-do list and the file shelf, in kit.json next
// to settings.json. Nothing leaves the PC. The page owns the logic
// (src/core/kit.ts); this only stores it and does what a page can't: look at a
// file, open it, show it in its folder, put it on the clipboard.

use std::path::{Path, PathBuf};

use serde::Serialize;
use serde_json::Value;

fn path() -> PathBuf {
    crate::platform::config_dir().join("kit.json")
}

/// What was saved, or null the first time (the page starts from its defaults).
#[tauri::command]
pub fn kit_load() -> Value {
    std::fs::read(path()).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or(Value::Null)
}

/// Written whole, through a temporary file, so a crash never leaves half a list.
#[tauri::command]
pub fn kit_save(data: Value) -> Result<(), String> {
    let path = path();
    let dir = path.parent().ok_or("no folder")?;
    let temp = path.with_extension(format!("json.coucou-{}", std::process::id()));
    let written = crate::platform::ensure_private_dir(dir)
        .and_then(|()| serde_json::to_vec(&data).map_err(std::io::Error::other))
        .and_then(|json| std::fs::write(&temp, json))
        .and_then(|()| std::fs::rename(&temp, &path));
    written.map_err(|err| {
        let _ = std::fs::remove_file(&temp);
        crate::log::line(format!("kit: could not save kit.json: {err}"));
        err.to_string()
    })
}

#[derive(Serialize, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct FileInfo {
    path: String,
    name: String,
    size: u64,
    dir: bool,
    exists: bool,
}

pub fn file_info(path: &str) -> FileInfo {
    let p = Path::new(path);
    let name = p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| path.to_string());
    match std::fs::metadata(p) {
        Ok(m) => FileInfo { path: path.into(), name, size: if m.is_dir() { 0 } else { m.len() }, dir: m.is_dir(), exists: true },
        Err(_) => FileInfo { path: path.into(), name, size: 0, dir: false, exists: false },
    }
}

/// The shelf keeps paths, not copies: what each one is now (moved or deleted shows).
#[tauri::command]
pub fn kit_files(paths: Vec<String>) -> Vec<FileInfo> {
    paths.iter().map(|p| file_info(p)).collect()
}

/// Opens it with its app, as a double-click in Explorer would.
#[tauri::command]
pub fn kit_open(path: String) -> Result<(), String> {
    if !Path::new(&path).exists() {
        return Err("gone".into());
    }
    #[cfg(windows)]
    {
        std::process::Command::new("explorer.exe").arg(&path).spawn().map(|_| ()).map_err(|e| e.to_string())
    }
    #[cfg(not(windows))]
    {
        std::process::Command::new("xdg-open").arg(&path).spawn().map(|_| ()).map_err(|e| e.to_string())
    }
}

/// Explorer on its folder, with it selected.
#[tauri::command]
pub fn kit_reveal(path: String) -> Result<(), String> {
    #[cfg(windows)]
    {
        std::process::Command::new("explorer.exe")
            .arg(format!("/select,{path}"))
            .spawn()
            .map(|_| ())
            .map_err(|e| e.to_string())
    }
    #[cfg(not(windows))]
    {
        let dir = Path::new(&path).parent().map(Path::to_path_buf).unwrap_or_default();
        std::process::Command::new("xdg-open").arg(dir).spawn().map(|_| ()).map_err(|e| e.to_string())
    }
}

/// The files on the clipboard, as Explorer's Copy puts them: Ctrl+V drops them
/// into a chat, an email or a folder.
#[tauri::command]
pub fn kit_copy_files(paths: Vec<String>) -> bool {
    let present: Vec<String> = paths.into_iter().filter(|p| Path::new(p).exists()).collect();
    !present.is_empty() && crate::clipboard::copy_files(&present)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_file_says_what_it_is_and_a_missing_one_says_so() {
        let dir = std::env::temp_dir().join(format!("coucou-kit-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let f = dir.join("beach.txt");
        std::fs::write(&f, b"12345").unwrap();
        let info = file_info(&f.to_string_lossy());
        assert_eq!((info.name.as_str(), info.size, info.dir, info.exists), ("beach.txt", 5, false, true));
        let d = file_info(&dir.to_string_lossy());
        assert!(d.dir && d.exists && d.size == 0);
        let gone = file_info(&dir.join("gone.jpg").to_string_lossy());
        assert_eq!((gone.name.as_str(), gone.exists), ("gone.jpg", false));
        let _ = std::fs::remove_dir_all(&dir);
    }
}
