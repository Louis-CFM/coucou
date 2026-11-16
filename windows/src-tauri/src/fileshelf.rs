// CouCou Desk: File Shelf Native Windows System Operations
// Provides native file picking (IFileOpenDialog with multi-select),
// default app launching (ShellExecute), and Explorer reveal.

use std::path::{Path, PathBuf};
use serde::Serialize;
use tauri::AppHandle;

#[derive(Serialize, Clone, Debug)]
#[serde(rename_all = "camelCase")]
pub struct FileShelfItemInfo {
    pub path: String,
    pub name: String,
    pub size: u64,
    pub exists: bool,
    pub extension: String,
}

/// Opens native Windows file dialog allowing multi-file selection.
/// Supports Ctrl+Click, Shift+Click, and multiple folders if supported by the OS.
#[tauri::command]
pub async fn fileshelf_pick_files(app: AppHandle) -> Result<Vec<String>, String> {
    let chosen = crate::platform::pick_files(&app, None, "Select files to park on Desk");
    Ok(chosen.unwrap_or_default())
}

/// Opens a parked file in its default registered Windows application.
#[tauri::command]
pub async fn fileshelf_open_file(path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);
    if !p.exists() {
        return Err(format!("File does not exist: {path}"));
    }

    #[cfg(target_os = "windows")]
    {
        use std::os::windows::process::CommandExt;
        std::process::Command::new("cmd")
            .args(&["/c", "start", "", &p.to_string_lossy()])
            .creation_flags(0x08000000) // CREATE_NO_WINDOW
            .spawn()
            .map_err(|e| format!("Failed to open file: {e}"))?;
    }

    #[cfg(not(target_os = "windows"))]
    {
        std::process::Command::new("xdg-open")
            .arg(&p)
            .spawn()
            .map_err(|e| format!("Failed to open file: {e}"))?;
    }

    Ok(())
}

/// Reveals the file in Windows File Explorer with the file highlighted (/select).
#[tauri::command]
pub async fn fileshelf_reveal_file(path: String) -> Result<(), String> {
    let p = PathBuf::from(&path);

    #[cfg(target_os = "windows")]
    {
        if p.exists() {
            let path_str = p.to_string_lossy().to_string();
            // explorer.exe /select,"C:\path\to\file"
            let _ = std::process::Command::new("explorer")
                .arg(format!("/select,{path_str}"))
                .spawn()
                .map_err(|e| format!("Failed to reveal file: {e}"))?;
        } else if let Some(parent) = p.parent() {
            if parent.exists() {
                let _ = std::process::Command::new("explorer")
                    .arg(parent.to_string_lossy().to_string())
                    .spawn()
                    .map_err(|e| format!("Failed to open folder: {e}"))?;
            } else {
                return Err(format!("File and parent folder do not exist: {path}"));
            }
        } else {
            return Err(format!("File does not exist: {path}"));
        }
    }

    #[cfg(not(target_os = "windows"))]
    {
        let target = if p.is_file() {
            p.parent().unwrap_or(&p)
        } else {
            &p
        };
        std::process::Command::new("xdg-open")
            .arg(target)
            .spawn()
            .map_err(|e| format!("Failed to reveal file: {e}"))?;
    }

    Ok(())
}

/// Queries filesystem metadata for a list of file paths.
#[tauri::command]
pub async fn fileshelf_get_file_info(paths: Vec<String>) -> Result<Vec<FileShelfItemInfo>, String> {
    let mut results = Vec::with_capacity(paths.len());

    for path_str in paths {
        let p = Path::new(&path_str);
        let exists = p.exists();
        let size = if exists {
            std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
        } else {
            0
        };

        let name = p
            .file_name()
            .map(|n| n.to_string_lossy().to_string())
            .unwrap_or_else(|| path_str.clone());

        let extension = p
            .extension()
            .map(|e| e.to_string_lossy().to_lowercase())
            .unwrap_or_default();

        results.push(FileShelfItemInfo {
            path: path_str,
            name,
            size,
            exists,
            extension,
        });
    }

    Ok(results)
}
