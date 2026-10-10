// The music pills on Windows: Apple Music, Spotify and "Now Playing" (any app).
//
// Linux reads Spotify over MPRIS (spotify.rs). Windows has one place every
// player reports to: the system media transport controls (the media flyout
// next to the volume OSD). Apple Music for Windows, Spotify, browsers, VLC…
// all publish their track, status and timeline there and take play/pause,
// next, seek, shuffle and repeat from it.
//
// Nothing runs on a timer. One worker thread wakes only for the manager's
// SessionsChanged / CurrentSessionChanged and the sessions' change events,
// coalesces bursts (a track change fires three events at once), reads once and
// emits the same `spotify` event the Linux client does, so the page needs no
// second player model. The page runs the position on from its anchor.

use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{LazyLock, Mutex};

use tauri::{AppHandle, Emitter};
use windows::Foundation::TypedEventHandler;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Media::MediaPlaybackAutoRepeatMode;
use windows::Storage::Streams::DataReader;

use crate::spotify::{short_artist, short_title, sniff_image, PlayerState, Track};

pub const SPOTIFY_PILL: &str = crate::spotify::PILL_ID;
pub const MUSIC_PILL: &str = "integration_music";
pub const MEDIA_PILL: &str = "integration_media";
pub const PILLS: [&str; 3] = [SPOTIFY_PILL, MUSIC_PILL, MEDIA_PILL];

const APPLE_MUSIC_AUMID: &str = "AppleInc.AppleMusicWin_nzyj5cx40ttqa!App";
const APPLE_MUSIC_PACKAGE: &str = "AppleInc.AppleMusicWin_nzyj5cx40ttqa";
const SPOTIFY_PACKAGE: &str = "SpotifyAB.SpotifyMusic_zpdnekdrzrea0";
const ARTWORK_LIMIT: u64 = 3 * 1024 * 1024;
/// 1601 → 1970, in 100 ns ticks.
const TICKS_TO_UNIX: i64 = 116_444_736_000_000_000;

enum Msg {
    /// Sessions came or went, or one started / stopped playing: choose again.
    Rescan,
    /// A session changed its track or timeline.
    Read,
    Stop,
}

#[derive(Default)]
struct Shared {
    declared: Vec<String>,
    manager: Option<Manager>,
    aumid: Option<String>,
    state: PlayerState,
    art_key: Option<String>,
    tx: Option<Sender<Msg>>,
}

static SHARED: LazyLock<Mutex<Shared>> = LazyLock::new(Default::default);

/// Which declared pill a player belongs to: its own pill, else "Now Playing".
pub fn pill_for(aumid: &str, declared: &[String]) -> Option<&'static str> {
    let a = aumid.to_ascii_lowercase();
    let has = |id: &str| declared.iter().any(|d| d == id);
    let own = if a.contains("spotify") {
        Some(SPOTIFY_PILL)
    } else if a.contains("applemusic") || a.contains("itunes") {
        Some(MUSIC_PILL)
    } else {
        None
    };
    match own {
        Some(id) if has(id) => Some(id),
        _ if has(MEDIA_PILL) => Some(MEDIA_PILL),
        _ => None,
    }
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

fn emit(app: &AppHandle, state: &PlayerState) {
    let _ = app.emit_to(crate::island::WINDOW_LABEL, "spotify", state);
}

// ── Lifecycle ─────────────────────────────────────────────────────────────────

/// Starts the worker when a music pill is declared, stops it when none is.
pub fn sync(app: &AppHandle, active: &[String]) {
    let declared: Vec<String> = active.iter().filter(|id| PILLS.contains(&id.as_str())).cloned().collect();
    let mut s = SHARED.lock().unwrap();
    s.declared = declared.clone();
    if declared.is_empty() {
        if let Some(tx) = s.tx.take() {
            let _ = tx.send(Msg::Stop);
        }
        s.aumid = None;
        s.state = PlayerState::default();
        return;
    }
    if let Some(tx) = s.tx.as_ref() {
        // Another pill declared: the same worker chooses again.
        let _ = tx.send(Msg::Rescan);
        return;
    }
    let (tx, rx) = channel();
    s.tx = Some(tx.clone());
    drop(s);
    let app = app.clone();
    let _ = std::thread::Builder::new().name("coucou-media".into()).spawn(move || {
        if let Err(err) = run(&app, tx, rx) {
            crate::log::line(format!("media: {err}"));
        }
        SHARED.lock().unwrap().manager = None;
    });
}

fn run(app: &AppHandle, tx: Sender<Msg>, rx: Receiver<Msg>) -> windows::core::Result<()> {
    let manager = Manager::RequestAsync()?.get()?;
    SHARED.lock().unwrap().manager = Some(manager.clone());
    let t = tx.clone();
    let sessions_token = manager.SessionsChanged(&TypedEventHandler::new(move |_, _| {
        let _ = t.send(Msg::Rescan);
        Ok(())
    }))?;
    let t = tx.clone();
    let current_token = manager.CurrentSessionChanged(&TypedEventHandler::new(move |_, _| {
        let _ = t.send(Msg::Rescan);
        Ok(())
    }))?;

    let mut hooks: Vec<(Session, [i64; 3])> = Vec::new();
    let mut pending = Some(Msg::Rescan);
    loop {
        let first = match pending.take() {
            Some(m) => m,
            None => match rx.recv() {
                Ok(m) => m,
                Err(_) => break,
            },
        };
        // Coalesce a burst into one read.
        let (mut rescan, mut stop) = (false, false);
        for m in std::iter::once(first).chain(rx.try_iter()) {
            match m {
                Msg::Rescan => rescan = true,
                Msg::Read => {}
                Msg::Stop => stop = true,
            }
        }
        if stop {
            break;
        }
        if rescan {
            unhook(&mut hooks);
            hook_all(&manager, &tx, &mut hooks);
        }
        refresh_from(app, &manager);
    }
    unhook(&mut hooks);
    let _ = manager.RemoveSessionsChanged(sessions_token);
    let _ = manager.RemoveCurrentSessionChanged(current_token);
    Ok(())
}

/// Every session reports play/pause (so the one that starts playing wins);
/// all three change events end in one coalesced read.
fn hook_all(manager: &Manager, tx: &Sender<Msg>, hooks: &mut Vec<(Session, [i64; 3])>) {
    let Ok(list) = manager.GetSessions() else { return };
    for session in list {
        let (a, b, c) = (tx.clone(), tx.clone(), tx.clone());
        let tokens = (|| -> windows::core::Result<[i64; 3]> {
            Ok([
                session.PlaybackInfoChanged(&TypedEventHandler::new(move |_, _| {
                    let _ = a.send(Msg::Rescan);
                    Ok(())
                }))?,
                session.MediaPropertiesChanged(&TypedEventHandler::new(move |_, _| {
                    let _ = b.send(Msg::Read);
                    Ok(())
                }))?,
                session.TimelinePropertiesChanged(&TypedEventHandler::new(move |_, _| {
                    let _ = c.send(Msg::Read);
                    Ok(())
                }))?,
            ])
        })();
        if let Ok(tokens) = tokens {
            hooks.push((session, tokens));
        }
    }
}

fn unhook(hooks: &mut Vec<(Session, [i64; 3])>) {
    for (s, [a, b, c]) in hooks.drain(..) {
        let _ = s.RemovePlaybackInfoChanged(a);
        let _ = s.RemoveMediaPropertiesChanged(b);
        let _ = s.RemoveTimelinePropertiesChanged(c);
    }
}

// ── Reading ───────────────────────────────────────────────────────────────────

fn is_playing(s: &Session) -> bool {
    s.GetPlaybackInfo().and_then(|i| i.PlaybackStatus()).map(|st| st == Status::Playing).unwrap_or(false)
}

/// The session to show: a playing one first, then the system's current one,
/// then any — among players a declared pill takes.
fn choose(manager: &Manager, declared: &[String]) -> Option<(Session, String, &'static str)> {
    let list = manager.GetSessions().ok()?;
    let mut candidates: Vec<(Session, String, &'static str)> = Vec::new();
    for s in list {
        let Ok(aumid) = s.SourceAppUserModelId().map(|h| h.to_string()) else { continue };
        if let Some(pill) = pill_for(&aumid, declared) {
            candidates.push((s, aumid, pill));
        }
    }
    let current = manager.GetCurrentSession().ok().and_then(|s| s.SourceAppUserModelId().ok()).map(|h| h.to_string());
    candidates.sort_by_key(|c| (!is_playing(&c.0), current.as_deref() != Some(c.1.as_str())));
    candidates.into_iter().next()
}

fn installed(pill: &str) -> bool {
    let local = std::env::var_os("LOCALAPPDATA").map(std::path::PathBuf::from);
    let roaming = std::env::var_os("APPDATA").map(std::path::PathBuf::from);
    let pkg = |name: &str| local.as_ref().is_some_and(|l| l.join("Packages").join(name).is_dir());
    match pill {
        MUSIC_PILL => pkg(APPLE_MUSIC_PACKAGE),
        SPOTIFY_PILL => pkg(SPOTIFY_PACKAGE) || roaming.is_some_and(|r| r.join("Spotify").join("Spotify.exe").is_file()),
        _ => true,
    }
}

/// The pill the idle card speaks for: the first declared.
fn idle_pill(declared: &[String]) -> &'static str {
    PILLS.iter().copied().find(|id| declared.iter().any(|d| d == id)).unwrap_or(SPOTIFY_PILL)
}

fn ticks_to_secs(t: i64) -> f64 {
    t.max(0) as f64 / 10_000_000.0
}

fn read_state(session: &Session, aumid: &str, pill: &'static str) -> PlayerState {
    let now = now_ms();
    let mut st = PlayerState {
        source: pill.to_string(),
        app: app_name(aumid),
        running: true,
        installed: true,
        position_at: now,
        ..Default::default()
    };
    let props = session.TryGetMediaPropertiesAsync().and_then(|op| op.get()).ok();
    let text = |f: &dyn Fn(&windows::Media::Control::GlobalSystemMediaTransportControlsSessionMediaProperties) -> windows::core::Result<windows::core::HSTRING>| {
        props.as_ref().and_then(|p| f(p).ok()).map(|h| h.to_string()).unwrap_or_default()
    };
    let title = text(&|p| p.Title());
    if title.is_empty() {
        return st;
    }
    let artist = text(&|p| p.Artist());
    let album = text(&|p| p.AlbumTitle());
    let has_art = props.as_ref().is_some_and(|p| p.Thumbnail().is_ok());
    let id = format!("{aumid}\u{1}{title}\u{1}{artist}\u{1}{album}");

    let tl = session.GetTimelineProperties().ok();
    let span = |f: &dyn Fn(&windows::Media::Control::GlobalSystemMediaTransportControlsSessionTimelineProperties) -> windows::core::Result<windows::Foundation::TimeSpan>| {
        tl.as_ref().and_then(|t| f(t).ok()).map(|t| t.Duration).unwrap_or(0)
    };
    let (start, end, pos) = (span(&|t| t.StartTime()), span(&|t| t.EndTime()), span(&|t| t.Position()));
    let updated = tl.as_ref().and_then(|t| t.LastUpdatedTime().ok()).map(|d| d.UniversalTime).unwrap_or(0);

    let info = session.GetPlaybackInfo().ok();
    st.playing = info.as_ref().and_then(|i| i.PlaybackStatus().ok()) == Some(Status::Playing);
    st.shuffle = info.as_ref().and_then(|i| i.IsShuffleActive().ok()).and_then(|r| r.Value().ok()).unwrap_or(false);
    st.repeat = info
        .as_ref()
        .and_then(|i| i.AutoRepeatMode().ok())
        .and_then(|r| r.Value().ok())
        .is_some_and(|m| m != MediaPlaybackAutoRepeatMode::None);
    st.volume = crate::audio::master_volume().map(|v| (v * 100.0).round() as i32).unwrap_or(50);

    st.position = ticks_to_secs(pos - start);
    // The timeline is stamped when the player wrote it; the page runs on from there.
    if updated > TICKS_TO_UNIX {
        st.position_at = (((updated - TICKS_TO_UNIX) / 10_000) as f64).min(now);
    }
    st.track = Some(Track {
        art_url: has_art.then(|| format!("gsmtc:{:x}", fnv(&id))),
        id,
        title: short_title(&title),
        artist: short_artist(&artist),
        album,
        duration: ticks_to_secs(end - start),
        object_path: String::new(),
    });
    st
}

fn fnv(s: &str) -> u64 {
    s.bytes().fold(0xcbf29ce484222325u64, |h, b| (h ^ b as u64).wrapping_mul(0x100000001b3))
}

/// "AppleInc.AppleMusicWin_…!App" → "Apple Music", "Spotify.exe" → "Spotify".
pub fn app_name(aumid: &str) -> String {
    let a = aumid.to_ascii_lowercase();
    const KNOWN: [(&str, &str); 11] = [
        ("applemusic", "Apple Music"),
        ("spotify", "Spotify"),
        ("msedge", "Edge"),
        ("chrome", "Chrome"),
        ("firefox", "Firefox"),
        ("brave", "Brave"),
        ("opera", "Opera"),
        ("vlc", "VLC"),
        ("zunemusic", "Media Player"),
        ("zunevideo", "Movies & TV"),
        ("youtube", "YouTube"),
    ];
    if let Some((_, name)) = KNOWN.iter().find(|(k, _)| a.contains(k)) {
        return name.to_string();
    }
    let stem = aumid.rsplit(['\\', '/']).next().unwrap_or(aumid);
    let stem = stem.split(['!', '_']).next().unwrap_or(stem);
    let stem = stem.strip_suffix(".exe").unwrap_or(stem);
    stem.rsplit('.').next().unwrap_or(stem).to_string()
}

fn refresh_from(app: &AppHandle, manager: &Manager) {
    let declared = SHARED.lock().unwrap().declared.clone();
    let (state, session) = match choose(manager, &declared) {
        Some((session, aumid, pill)) => {
            let st = read_state(&session, &aumid, pill);
            SHARED.lock().unwrap().aumid = Some(aumid);
            (st, Some(session))
        }
        None => {
            SHARED.lock().unwrap().aumid = None;
            let pill = idle_pill(&declared);
            let st = PlayerState { source: pill.to_string(), installed: installed(pill), position_at: now_ms(), ..Default::default() };
            (st, None)
        }
    };
    let art = state.track.as_ref().and_then(|t| t.art_url.clone());
    let new_art = {
        let mut s = SHARED.lock().unwrap();
        s.state = state.clone();
        let new = art.is_some() && s.art_key != art;
        if new {
            s.art_key = art.clone();
        }
        new
    };
    emit(app, &state);
    if let (true, Some(key), Some(session)) = (new_art, art, session) {
        if let Some(data) = read_artwork(&session) {
            let _ = app.emit_to(
                crate::island::WINDOW_LABEL,
                "spotify-artwork",
                serde_json::json!({ "artUrl": key, "dataUrl": data }),
            );
        }
    }
}

fn read_artwork(session: &Session) -> Option<String> {
    let props = session.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
    let stream = props.Thumbnail().ok()?.OpenReadAsync().ok()?.get().ok()?;
    let size = stream.Size().ok()?;
    if size == 0 || size > ARTWORK_LIMIT {
        return None;
    }
    let reader = DataReader::CreateDataReader(&stream).ok()?;
    reader.LoadAsync(size as u32).ok()?.get().ok()?;
    let mut bytes = vec![0u8; size as usize];
    reader.ReadBytes(&mut bytes).ok()?;
    let mime = sniff_image(&bytes)?;
    Some(format!("data:{mime};base64,{}", crate::claude::base64_for(&bytes)))
}

// ── Commands (through spotify.rs) ─────────────────────────────────────────────

fn current_session() -> Option<Session> {
    let (manager, aumid) = {
        let s = SHARED.lock().unwrap();
        (s.manager.clone()?, s.aumid.clone()?)
    };
    manager
        .GetSessions()
        .ok()?
        .into_iter()
        .find(|x| x.SourceAppUserModelId().map(|h| h.to_string() == aumid).unwrap_or(false))
}

pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
    let manager = SHARED.lock().unwrap().manager.clone()?;
    refresh_from(app, &manager);
    Some(SHARED.lock().unwrap().state.clone())
}

pub fn control(app: &AppHandle, action: &str, value: Option<f64>) -> bool {
    let v = value.unwrap_or(0.0);
    if action == "volume" {
        // ponytail: system volume, not the player's own; per-app needs the WASAPI session of its process.
        let ok = crate::audio::set_master_volume((v / 100.0).clamp(0.0, 1.0) as f32);
        let state = {
            let mut s = SHARED.lock().unwrap();
            s.state.volume = v.round().clamp(0.0, 100.0) as i32;
            s.state.clone()
        };
        emit(app, &state);
        return ok;
    }
    let Some(session) = current_session() else { return false };
    let op = match action {
        "playPause" => session.TryTogglePlayPauseAsync(),
        "next" => session.TrySkipNextAsync(),
        "previous" => session.TrySkipPreviousAsync(),
        "seek" => {
            let start = session.GetTimelineProperties().and_then(|t| t.StartTime()).map(|t| t.Duration).unwrap_or(0);
            session.TryChangePlaybackPositionAsync(start + (v.max(0.0) * 10_000_000.0) as i64)
        }
        "shuffle" => session.TryChangeShuffleActiveAsync(v != 0.0),
        "repeat" => session.TryChangeAutoRepeatModeAsync(if v != 0.0 {
            MediaPlaybackAutoRepeatMode::List
        } else {
            MediaPlaybackAutoRepeatMode::None
        }),
        _ => return false,
    };
    let done = op.and_then(|o| o.get()).unwrap_or(false);
    if done && matches!(action, "seek" | "shuffle" | "repeat") {
        // Some players don't signal these: show them at once, as the Mac does.
        let state = {
            let mut s = SHARED.lock().unwrap();
            match action {
                "seek" => {
                    s.state.position = v.max(0.0);
                    s.state.position_at = now_ms();
                }
                "shuffle" => s.state.shuffle = v != 0.0,
                _ => s.state.repeat = v != 0.0,
            }
            s.state.clone()
        };
        emit(app, &state);
    }
    done
}

/// "Open": the player in front (or started); not installed → where to get it.
pub fn open() -> bool {
    let (aumid, pill) = {
        let s = SHARED.lock().unwrap();
        (s.aumid.clone(), s.state.source.clone())
    };
    let shell = |id: &str| {
        crate::platform::no_console(&mut std::process::Command::new("explorer.exe"))
            .arg(format!("shell:AppsFolder\\{id}"))
            .spawn()
            .is_ok()
    };
    // A packaged player is activated (brought forward, or started) by its AUMID.
    if let Some(a) = aumid.as_deref().filter(|a| a.contains('!')) {
        return shell(a);
    }
    match pill.as_str() {
        MUSIC_PILL if installed(MUSIC_PILL) => shell(APPLE_MUSIC_AUMID),
        MUSIC_PILL => {
            crate::platform::open_url("ms-windows-store://pdp/?productid=9PFHDD62MXS1");
            false
        }
        SPOTIFY_PILL if installed(SPOTIFY_PILL) => {
            crate::platform::open_url("spotify:");
            true
        }
        SPOTIFY_PILL => {
            crate::platform::open_url("https://www.spotify.com/download/windows/");
            false
        }
        _ => false,
    }
}

/// For Settings: whether the declared music pill's player is there to launch.
pub fn installed_for(pill: &str) -> bool {
    installed(pill)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn d(ids: &[&str]) -> Vec<String> {
        ids.iter().map(|s| s.to_string()).collect()
    }

    #[test]
    fn players_land_on_their_own_pill_or_now_playing() {
        let all = d(&PILLS);
        assert_eq!(pill_for(APPLE_MUSIC_AUMID, &all), Some(MUSIC_PILL));
        assert_eq!(pill_for("Spotify.exe", &all), Some(SPOTIFY_PILL));
        assert_eq!(pill_for("MSEdge", &all), Some(MEDIA_PILL));
        // Without its own pill, a player goes to Now Playing, or nowhere.
        assert_eq!(pill_for("Spotify.exe", &d(&[MEDIA_PILL])), Some(MEDIA_PILL));
        assert_eq!(pill_for("MSEdge", &d(&[SPOTIFY_PILL])), None);
    }

    #[test]
    fn app_names_read_well() {
        assert_eq!(app_name(APPLE_MUSIC_AUMID), "Apple Music");
        assert_eq!(app_name("Spotify.exe"), "Spotify");
        assert_eq!(app_name("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"), "Media Player");
        assert_eq!(app_name("C:\\Tools\\foobar2000.exe"), "foobar2000");
    }
}

#[cfg(test)]
mod live {
    /// `cargo test -p coucou live_sessions -- --ignored --nocapture`: what this PC's players report.
    #[test]
    #[ignore]
    fn live_sessions() {
        let m = super::Manager::RequestAsync().unwrap().get().unwrap();
        for s in m.GetSessions().unwrap() {
            let aumid = s.SourceAppUserModelId().unwrap().to_string();
            let st = super::read_state(&s, &aumid, super::MEDIA_PILL);
            println!("{aumid} → {:?} playing={} pos={:.1}/{:.1}", st.track.as_ref().map(|t| (&t.title, &t.artist)), st.playing, st.position, st.track.as_ref().map(|t| t.duration).unwrap_or(0.0));
            if let Some(a) = super::read_artwork(&s) { println!("  artwork: {} bytes of data URL", a.len()); }
        }
    }
}
