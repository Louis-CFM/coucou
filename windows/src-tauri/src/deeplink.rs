// Open the exact session inside a desktop agent app.

use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum App { Claude, Codex, Hermes }

pub fn app_of(image_path: &str) -> Option<App> {
    let lower = image_path.to_ascii_lowercase().replace('/', "\\");
    let name = lower.rsplit('\\').next().unwrap_or("");
    match name {
        "claude.exe" if lower.contains("\\windowsapps\\claude_") || lower.contains("\\anthropicclaude\\") => Some(App::Claude),
        "chatgpt.exe" | "codex.exe" if lower.contains("\\windowsapps\\openai.codex_") || lower.contains("\\openai\\") => Some(App::Codex),
        "hermes.exe" if lower.contains("\\hermes\\") => Some(App::Hermes),
        _ => None,
    }
}

fn is_uuid(value: &str) -> bool {
    let parts: Vec<&str> = value.split('-').collect();
    parts.len() == 5 && parts.iter().zip([8, 4, 4, 4, 12]).all(|(part, length)| part.len() == length && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn is_safe_key(value: &str) -> bool {
    !value.is_empty() && value.len() <= 128 && value.bytes().all(|byte| byte.is_ascii_alphanumeric() || byte == b'_' || byte == b'-')
}

pub fn url_for(app: App, session_id: &str, claude_local: impl FnOnce(&str) -> Option<String>) -> Option<String> {
    let id = session_id.trim();
    match app {
        App::Codex => is_uuid(id).then(|| format!("codex://threads/{}", id.to_ascii_lowercase())),
        App::Hermes => is_safe_key(id).then(|| format!("hermes://open/{id}")),
        App::Claude => {
            let local = if id.starts_with("local_") { Some(id.to_string()) } else { claude_local(id) }?;
            is_safe_key(&local).then(|| format!("claude://code/continue?session={local}"))
        }
    }
}

fn claude_session_roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        let packages = Path::new(&local).join("Packages");
        if let Ok(entries) = std::fs::read_dir(&packages) {
            for entry in entries.flatten() {
                if entry.file_name().to_string_lossy().to_ascii_lowercase().starts_with("claude_") {
                    roots.push(entry.path().join("LocalCache\\Roaming\\Claude\\claude-code-sessions"));
                }
            }
        }
    }
    if let Some(roaming) = std::env::var_os("APPDATA") { roots.push(Path::new(&roaming).join("Claude\\claude-code-sessions")); }
    roots
}

pub fn claude_local_id(cli_id: &str) -> Option<String> { claude_local_id_in(&claude_session_roots(), cli_id) }

pub fn claude_local_id_in(roots: &[PathBuf], cli_id: &str) -> Option<String> {
    if !is_uuid(cli_id) { return None; }
    let mut best: Option<(std::time::SystemTime, String)> = None;
    let mut stack: Vec<(PathBuf, u8)> = roots.iter().map(|root| (root.clone(), 0)).collect();
    while let Some((dir, depth)) = stack.pop() {
        let Ok(entries) = std::fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let name = entry.file_name().to_string_lossy().into_owned();
            let Ok(metadata) = entry.metadata() else { continue };
            if metadata.is_dir() {
                if depth < 3 { stack.push((path, depth + 1)); }
                continue;
            }
            if !(name.starts_with("local_") && name.ends_with(".json")) { continue; }
            let Ok(text) = std::fs::read_to_string(&path) else { continue };
            if !text.contains(cli_id) { continue; }
            let Ok(json) = serde_json::from_str::<serde_json::Value>(&text) else { continue };
            if json.get("cliSessionId").and_then(|value| value.as_str()) != Some(cli_id) || json.get("isArchived").and_then(|value| value.as_bool()) == Some(true) { continue; }
            let Some(id) = json.get("sessionId").and_then(|value| value.as_str()) else { continue };
            let modified = metadata.modified().unwrap_or(std::time::UNIX_EPOCH);
            if best.as_ref().is_none_or(|(time, _)| modified > *time) { best = Some((modified, id.to_string())); }
        }
    }
    best.map(|(_, id)| id)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn links_carry_safe_sessions() {
        assert_eq!(url_for(App::Codex, "01A10D15-c4d9-7f51-b367-49aad5dafd84", |_| None).as_deref(), Some("codex://threads/01a10d15-c4d9-7f51-b367-49aad5dafd84"));
        assert_eq!(url_for(App::Hermes, "20261005_095224_2cdd8e", |_| None).as_deref(), Some("hermes://open/20261005_095224_2cdd8e"));
        assert_eq!(url_for(App::Hermes, "../settings", |_| None), None);
    }
}
