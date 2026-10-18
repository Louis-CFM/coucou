//! Antigravity uses its own cached account through the installed `agy` CLI.
pub mod rpc;

use crate::chat::ModelInfo;
use std::path::PathBuf;

pub fn executable() -> Result<PathBuf, String> {
    let home = crate::platform::home_dir();
    let stem = if cfg!(windows) { "agy.exe" } else { "agy" };
    crate::platform::find_on_path(stem)
        .or_else(|| {
            [
                home.join(".local/bin").join(stem),
                home.join(".antigravity/bin").join(stem),
                home.join(".local/share/antigravity/bin").join(stem),
            ]
            .into_iter()
            .find(|p| p.is_file())
        })
        .ok_or_else(|| {
            "Antigravity CLI (agy) was not found. Install it and sign in by running agy first."
                .into()
        })
}

pub async fn models() -> Result<Vec<ModelInfo>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        rpc::models(&executable()?, &crate::platform::home_dir()).map(|models| {
            models
                .into_iter()
                .map(|(id, label)| ModelInfo { id, label })
                .collect()
        })
    })
    .await
    .map_err(|_| "Antigravity model check failed.".to_string())?
}
