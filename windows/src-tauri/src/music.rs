// What's playing, for the Music pill and Mochi's dance — port of the macOS
// MusicController, widened to every player.
//
// Windows: the system media controls (the same feed as the volume flyout's
// player), so Spotify, Apple Music, Media Player, browsers and any app that
// reports to it all show up. Event-driven: nothing runs until a session
// changes, so a quiet PC costs nothing.
//
// Only music makes Mochi dance: a session counts as music unless it says it's
// video or comes from a browser (a YouTube video there reports itself as
// plain media, so the browser is the reliable tell). Browsers still show up,
// with their controls.

use serde::Serialize;

#[derive(Serialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct NowPlaying {
    pub title: String,
    pub artist: String,
    /// The player, in words ("Spotify", "Apple Music", "Chrome"…).
    pub app: String,
    pub playing: bool,
    /// Music (not a video, not a browser): what Mochi dances to.
    pub music: bool,
}

/// An installed web app (Chrome/Edge "Install as app", e.g. YouTube Music):
/// its own window, so it's an app, not a browser tab.
fn is_web_app(app_id: &str) -> bool {
    app_id.to_lowercase().contains("_crx_")
}

/// Browsers report videos (YouTube…) as ordinary media sessions. Installed
/// web apps aren't tabs, so they don't count.
fn is_browser(app_id: &str) -> bool {
    let id = app_id.to_lowercase();
    !is_web_app(app_id) && [
        "chrome", "msedge", "firefox", "brave", "opera", "vivaldi", "thebrowsercompany", "zen", "floorp",
        "librewolf", "thorium", "chromium", "iexplore", "waterfox",
        // Firefox reports this hash instead of its name.
        "308046b0af4a39cb",
    ]
    .iter()
    .any(|b| id.contains(b))
}

/// A player's AppUserModelId ("Spotify.exe", "AppleInc.AppleMusicWin_…!App")
/// in words.
fn app_name(app_id: &str) -> String {
    let id = app_id.to_lowercase();
    if is_web_app(app_id) {
        // Chrome shortens the app id ("cinhi…lkffjgod" is YouTube Music's).
        return if id.contains("_crx_cinhi") { "YouTube Music" } else { "Web app" }.to_string();
    }
    let known = [
        ("spotify", "Spotify"),
        ("applemusic", "Apple Music"),
        ("zunemusic", "Media Player"),
        ("msedge", "Edge"),
        ("chrome", "Chrome"),
        ("firefox", "Firefox"),
        ("brave", "Brave"),
        ("opera", "Opera"),
        ("vlc", "VLC"),
        ("tidal", "TIDAL"),
        ("deezer", "Deezer"),
        ("amazonmusic", "Amazon Music"),
        ("foobar", "foobar2000"),
        ("musicbee", "MusicBee"),
        ("itunes", "iTunes"),
    ];
    if let Some((_, name)) = known.iter().find(|(k, _)| id.contains(k)) {
        return name.to_string();
    }
    // "C:\…\Player.exe", "Vendor.Player_hash!App": the readable middle.
    let last = app_id.rsplit(['\\', '/']).next().unwrap_or(app_id);
    let last = last.split(['!', '_']).next().unwrap_or(last);
    let last = last.strip_suffix(".exe").or_else(|| last.strip_suffix(".EXE")).unwrap_or(last);
    last.rsplit('.').next().unwrap_or(last).to_string()
}

#[cfg(windows)]
mod imp {
    use std::sync::{mpsc, Mutex};
    use std::time::Duration;

    use tauri::{AppHandle, Emitter};
    use windows::Foundation::TypedEventHandler;
    use windows::Media::Control::{
        GlobalSystemMediaTransportControlsSession as Session,
        GlobalSystemMediaTransportControlsSessionManager as Manager,
        GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
    };
    use windows::Media::MediaPlaybackType;

    use super::{app_name, is_browser, NowPlaying};
    use crate::log;

    /// What's on show, and the session its controls act on.
    static LAST: Mutex<Option<NowPlaying>> = Mutex::new(None);
    static TARGET: Mutex<Option<Session>> = Mutex::new(None);

    fn read(s: &Session) -> Option<NowPlaying> {
        let app_id = s.SourceAppUserModelId().ok()?.to_string();
        let info = s.GetPlaybackInfo().ok()?;
        let playing = info.PlaybackStatus().ok()? == Status::Playing;
        let video = info
            .PlaybackType()
            .ok()
            .and_then(|t| t.Value().ok())
            .is_some_and(|t| t == MediaPlaybackType::Video);
        let props = s.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
        let title = props.Title().ok()?.to_string();
        if title.trim().is_empty() {
            return None;
        }
        let artist = props.Artist().map(|a| a.to_string()).unwrap_or_default();
        Some(NowPlaying { title, artist, app: app_name(&app_id), playing, music: !video && !is_browser(&app_id) })
    }

    /// The session worth showing: playing beats paused, music beats the rest,
    /// and the system's own current session wins a tie.
    fn pick(manager: &Manager) -> Option<(Session, NowPlaying)> {
        let current = manager.GetCurrentSession().ok().and_then(|s| s.SourceAppUserModelId().ok());
        let mut best: Option<(i32, Session, NowPlaying)> = None;
        for s in manager.GetSessions().ok()? {
            let Some(np) = read(&s) else { continue };
            let is_current = current.as_ref().is_some_and(|c| s.SourceAppUserModelId().ok().as_ref() == Some(c));
            let score = (np.playing as i32) * 4 + (np.music as i32) * 2 + is_current as i32;
            if best.as_ref().is_none_or(|(b, _, _)| score > *b) {
                best = Some((score, s, np));
            }
        }
        best.map(|(_, s, np)| (s, np))
    }

    /// Listens to every session's track and play state; the tokens let the
    /// handlers go when the set of sessions changes.
    struct Watched {
        session: Session,
        props: i64,
        playback: i64,
    }

    fn watch(manager: &Manager, tx: &mpsc::Sender<()>, watched: &mut Vec<Watched>) {
        for w in watched.drain(..) {
            let _ = w.session.RemoveMediaPropertiesChanged(w.props);
            let _ = w.session.RemovePlaybackInfoChanged(w.playback);
        }
        let Ok(sessions) = manager.GetSessions() else { return };
        for session in sessions {
            let (t1, t2) = (tx.clone(), tx.clone());
            let (Ok(props), Ok(playback)) = (
                session.MediaPropertiesChanged(&TypedEventHandler::new(move |_, _| {
                    let _ = t1.send(());
                    Ok(())
                })),
                session.PlaybackInfoChanged(&TypedEventHandler::new(move |_, _| {
                    let _ = t2.send(());
                    Ok(())
                })),
            ) else {
                continue;
            };
            watched.push(Watched { session, props, playback });
        }
    }

    pub fn start(app: AppHandle) {
        std::thread::spawn(move || {
            unsafe {
                let _ = windows::Win32::System::Com::CoInitializeEx(None, windows::Win32::System::Com::COINIT_MULTITHREADED);
            }
            let manager = match Manager::RequestAsync().and_then(|op| op.get()) {
                Ok(m) => m,
                Err(err) => {
                    log::line(format!("music: no media controls ({err})"));
                    return;
                }
            };
            // "sessions": the set changed (re-watch); "()": something to re-read.
            let (tx, rx) = mpsc::channel::<()>();
            let (sessions_tx, sessions_rx) = mpsc::channel::<()>();
            let _ = manager.SessionsChanged(&TypedEventHandler::new({
                let (tx, sessions_tx) = (tx.clone(), sessions_tx.clone());
                move |_, _| {
                    let _ = sessions_tx.send(());
                    let _ = tx.send(());
                    Ok(())
                }
            }));
            let _ = manager.CurrentSessionChanged(&TypedEventHandler::new({
                let tx = tx.clone();
                move |_, _| {
                    let _ = tx.send(());
                    Ok(())
                }
            }));
            let mut watched = Vec::new();
            watch(&manager, &tx, &mut watched);
            let _ = tx.send(());

            while rx.recv().is_ok() {
                // A track change fires a burst of events: read once after it.
                std::thread::sleep(Duration::from_millis(150));
                while rx.try_recv().is_ok() {}
                if sessions_rx.try_recv().is_ok() {
                    while sessions_rx.try_recv().is_ok() {}
                    watch(&manager, &tx, &mut watched);
                }
                let picked = pick(&manager);
                let now = picked.as_ref().map(|(_, np)| np.clone());
                *TARGET.lock().unwrap() = picked.map(|(s, _)| s);
                let mut last = LAST.lock().unwrap();
                if *last != now {
                    log::line(match &now {
                        Some(np) => format!(
                            "music: {} - {} ({}, {}{})",
                            np.title,
                            np.artist,
                            np.app,
                            if np.playing { "playing" } else { "paused" },
                            if np.music { ", dances" } else { "" }
                        ),
                        None => "music: nothing playing".to_string(),
                    });
                    *last = now.clone();
                    let _ = app.emit("now-playing", now);
                }
            }
        });
    }

    pub fn now() -> Option<NowPlaying> {
        LAST.lock().unwrap().clone()
    }

    pub fn control(action: &str) -> Result<(), String> {
        let session = TARGET.lock().unwrap().clone().ok_or("Nothing is playing.")?;
        let op = match action {
            "toggle" => session.TryTogglePlayPauseAsync(),
            "next" => session.TrySkipNextAsync(),
            "previous" => session.TrySkipPreviousAsync(),
            _ => return Err(format!("Unknown control \"{action}\".")),
        };
        op.and_then(|o| o.get()).map(|_| ()).map_err(|e| e.to_string())
    }
}

// ponytail: Linux would read MPRIS over D-Bus; until then the Music pill just
// says nothing is playing.
#[cfg(not(windows))]
mod imp {
    use super::NowPlaying;

    pub fn start(_app: tauri::AppHandle) {}
    pub fn now() -> Option<NowPlaying> {
        None
    }
    pub fn control(_action: &str) -> Result<(), String> {
        Err("Music controls aren't available on Linux yet.".into())
    }
}

pub use imp::start;

/// What's playing right now (the page asks once at start; then it's events).
#[tauri::command]
pub fn music_now() -> Option<NowPlaying> {
    imp::now()
}

/// Play/pause, next or previous on the player that's on show.
#[tauri::command]
pub async fn music_control(action: String) -> Result<(), String> {
    tauri::async_runtime::spawn_blocking(move || imp::control(&action)).await.map_err(|e| e.to_string())?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn browsers_never_count_as_music() {
        for id in ["chrome.exe", "msedge.exe", "MSEdge", "firefox.exe", "308046B0AF4A39CB", "Brave", "TheBrowserCompany.Arc_ttt!Arc"] {
            assert!(is_browser(id), "{id}");
        }
        for id in ["Spotify.exe", "AppleInc.AppleMusicWin_nzyj5cx40ttqa!App", "Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"] {
            assert!(!is_browser(id), "{id}");
        }
    }

    #[test]
    fn players_get_their_names() {
        assert_eq!(app_name("Spotify.exe"), "Spotify");
        assert_eq!(app_name("AppleInc.AppleMusicWin_nzyj5cx40ttqa!App"), "Apple Music");
        assert_eq!(app_name("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"), "Media Player");
        assert_eq!(app_name("msedge.exe"), "Edge");
        assert_eq!(app_name(r"C:\Apps\Plexamp.exe"), "Plexamp");
        assert_eq!(app_name("Vendor.Cider_abc!App"), "Cider");
        // The installed YouTube Music app (a Chrome web app) is music, not a tab.
        let ytm = "Chrome._crx_cinhiknlkffjgod.UserData.Profile1";
        assert_eq!(app_name(ytm), "YouTube Music");
        assert!(!is_browser(ytm));
        assert_eq!(app_name("MSEdge._crx_abcdef.UserData.Default"), "Web app");
    }
}
