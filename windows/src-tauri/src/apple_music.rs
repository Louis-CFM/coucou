// Apple Music is an independent Windows integration. Its official app owns playback and sign-in.
use crate::media::PlayerState;
use tauri::AppHandle;
#[cfg(windows)]
use crate::media_windows as win;

pub const PILL_ID: &str = "integration_music";

pub fn sync(app: &AppHandle, active_integrations: &[String]) {
    #[cfg(windows)]
    win::sync(app, active_integrations.iter().any(|id| id == PILL_ID), win::Player::AppleMusic);
    #[cfg(not(windows))]
    let _ = (app, active_integrations);
}

/// The native Apple Music app, never a browser or another media player.
pub fn matches(app_id: &str) -> bool {
    let id = app_id.to_ascii_lowercase();
    id == "applemusic.exe" || id.starts_with("appleinc.applemusicwin_")
}

/// Apple Music's packaged library agent owns the Core Audio session on Windows.
/// Check its OS package identity so an unrelated executable with that name is excluded.
pub fn owns_audio_process(executable: &str, package_family: Option<&str>) -> bool {
    if executable.eq_ignore_ascii_case("AppleMusic.exe") { return true; }
    executable.eq_ignore_ascii_case("AMPLibraryAgent.exe")
        && package_family.is_some_and(|family| family.to_ascii_lowercase().starts_with("appleinc.applemusicwin_"))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn only_apple_music_sessions_are_recognized() {
        assert!(crate::apple_music::matches("AppleMusic.exe"));
        assert!(crate::apple_music::matches("AppleInc.AppleMusicWin_example!App"));
        assert!(!crate::apple_music::matches("chrome.exe"));
        assert!(!crate::apple_music::matches("Spotify.exe"));
    }

    #[cfg(windows)]
    #[test]
    #[ignore = "requires the installed Apple Music app; reads native registration and sessions only"]
    fn live_apple_music_registration() {
        println!("Apple Music installed; active media session: {}", crate::media_windows::probe_apple_music().expect("native discovery"));
    }

    #[test]
    fn the_audio_agent_must_belong_to_apple_music() {
        assert!(owns_audio_process("AMPLibraryAgent.exe", Some("AppleInc.AppleMusicWin_nzyj5cx40ttqa")));
        assert!(!owns_audio_process("AMPLibraryAgent.exe", None));
        assert!(!owns_audio_process("AMPLibraryAgent.exe", Some("AppleInc.iTunes_other")));
        assert!(!owns_audio_process("Spotify.exe", Some("AppleInc.AppleMusicWin_nzyj5cx40ttqa")));
    }
}

#[tauri::command]
pub async fn apple_music_refresh(app: AppHandle) -> Option<PlayerState> {
    #[cfg(windows)]
    { tauri::async_runtime::spawn_blocking(move || win::refresh(&app, win::Player::AppleMusic)).await.ok().flatten() }
    #[cfg(not(windows))]
    { let _ = app; None }
}

#[tauri::command]
pub async fn apple_music_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
    #[cfg(windows)]
    { tauri::async_runtime::spawn_blocking(move || win::control(&app, &action, value, win::Player::AppleMusic)).await.unwrap_or(false) }
    #[cfg(not(windows))]
    { let _ = (app, action, value); false }
}

#[tauri::command]
pub async fn apple_music_open() -> bool {
    #[cfg(windows)]
    { tauri::async_runtime::spawn_blocking(|| win::open(win::Player::AppleMusic)).await.unwrap_or(false) }
    #[cfg(not(windows))]
    { false }
}
