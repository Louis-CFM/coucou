//! Discover models through the installed Codex CLI and its ChatGPT sign-in.
pub mod rpc;

use crate::chat::ModelInfo;
use std::time::Duration;

pub fn installed() -> bool {
    !crate::platform::codex_candidates().is_empty()
}

fn client() -> Result<rpc::Client, String> {
    let exe = crate::platform::codex_candidates()
        .into_iter()
        .next()
        .ok_or("Codex CLI was not found. Install it and sign in with codex login.")?;
    rpc::Client::start(
        &exe,
        &crate::platform::home_dir(),
        Duration::from_secs(20),
        false,
    )
}

pub async fn models() -> Result<Vec<ModelInfo>, String> {
    tauri::async_runtime::spawn_blocking(|| {
        client()?.models().map(|models| {
            models
                .into_iter()
                .map(|(id, label)| ModelInfo { id, label })
                .collect()
        })
    })
    .await
    .map_err(|_| "Codex model check failed.".to_string())?
}
