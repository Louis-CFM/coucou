// The Spotify pill on Windows.
//
// The Mac uses AppleScript and Linux uses MPRIS; Windows has the System Media
// Transport Controls, the same thing that feeds the media flyout next to the
// volume control. Spotify publishes its track, cover, playback state, timeline,
// shuffle and repeat there, and takes play/pause, next/previous, seek, shuffle
// and repeat back. Volume is not part of it: that is Spotify's own session in
// the Windows volume mixer (Core Audio), set without touching anything else.
//
// While the pill is declared one thread reads all of it twice a second and
// tells the island only when something it shows has changed (the page runs the
// position on by itself from a timestamp). Turning the pill off ends the thread.

use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use tauri::{AppHandle, Emitter};
use windows::core::Interface;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Media::MediaPlaybackAutoRepeatMode;
use windows::Storage::Streams::DataReader;
use windows::Win32::Media::Audio::{
    eMultimedia, eRender, IAudioSessionControl2, IAudioSessionManager2, IMMDeviceEnumerator,
    ISimpleAudioVolume, MMDeviceEnumerator,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};

use super::{data_url, emit_state, now_ms, short_artist, short_title, Artwork, PlayerState, Track, ARTWORK_EVENT, ARTWORK_LIMIT};

const DOWNLOAD_URL: &str = "https://www.spotify.com/download/windows/";
const TICK: Duration = Duration::from_millis(500);

struct Shared {
    active: bool,
    generation: u64,
    state: PlayerState,
    /// The cover last sent, by track id, so it goes out once per track.
    art: Option<(String, String)>,
}

static SHARED: LazyLock<Mutex<Shared>> = LazyLock::new(|| {
    Mutex::new(Shared { active: false, generation: 0, state: PlayerState::default(), art: None })
});

/// COM (and WinRT) on the calling thread; harmless when already done.
fn com() {
    let _ = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
}

pub fn sync(app: &AppHandle, on: bool) {
    let generation = {
        let mut s = SHARED.lock().unwrap();
        if s.active == on {
            return;
        }
        s.active = on;
        s.generation += 1;
        s.art = None;
        s.state = PlayerState { installed: installed(), ..PlayerState::default() };
        s.generation
    };
    if on {
        let app = app.clone();
        let spawned = std::thread::Builder::new()
            .name("coucou-spotify".into())
            .spawn(move || watch(app, generation));
        if let Err(err) = spawned {
            crate::log::line(format!("spotify: no watcher thread: {err}"));
        }
    } else {
        let state = SHARED.lock().unwrap().state.clone();
        emit_state(app, &state);
    }
}

fn current(generation: u64) -> bool {
    let s = SHARED.lock().unwrap();
    s.active && s.generation == generation
}

fn watch(app: AppHandle, generation: u64) {
    com();
    let mut tick: u32 = 0;
    while current(generation) {
        // The mixer is asked less often than the player: its volume rarely moves.
        update(&app, Some(generation), tick % 4 == 0);
        tick = tick.wrapping_add(1);
        std::thread::sleep(TICK);
    }
}

/// Reads Spotify, folds it into the shared state and tells the island when
/// what it shows changed. `None` means "send it anyway" (a refresh).
fn update(app: &AppHandle, generation: Option<u64>, with_volume: bool) -> Option<PlayerState> {
    let session = find_session();
    let read = session.as_ref().and_then(read_player);
    let volume = if with_volume { mixer_volume() } else { None };
    let track_id = read.as_ref().and_then(|r| r.track.as_ref()).map(|t| t.id.clone());

    let (state, changed, want_art) = {
        let mut s = SHARED.lock().unwrap();
        if !s.active || generation.is_some_and(|g| g != s.generation) {
            return None;
        }
        let before = s.state.clone();
        let now = now_ms();
        let mut next = PlayerState {
            running: session.is_some(),
            installed: session.is_some() || before.installed,
            volume: volume.unwrap_or(before.volume),
            ..before.clone()
        };
        match read {
            Some(r) => {
                next.track = r.track;
                next.playing = r.playing && next.track.is_some();
                next.shuffle = r.shuffle;
                next.repeat = r.repeat;
                next.position = r.position;
                next.position_at = now;
            }
            None => next.clear(now),
        }
        let changed = generation.is_none() || differs(&before, &next, now);
        let want_art = next
            .track
            .as_ref()
            .is_some_and(|t| s.art.as_ref().map(|(id, _)| id) != Some(&t.id));
        s.state = next.clone();
        (next, changed, want_art)
    };
    if changed {
        emit_state(app, &state);
    }
    if want_art {
        if let (Some(session), Some(id)) = (session.as_ref(), track_id) {
            send_cover(app, session, id);
        }
    }
    Some(state)
}

/// Whether the island would show something different. The position always
/// moves while playing; only a jump (a seek) counts.
fn differs(a: &PlayerState, b: &PlayerState, now: f64) -> bool {
    a.running != b.running
        || a.installed != b.installed
        || a.track != b.track
        || a.playing != b.playing
        || a.shuffle != b.shuffle
        || a.repeat != b.repeat
        || a.volume != b.volume
        || (a.position_at_time(now) - b.position_at_time(now)).abs() > 2.0
}

// ── The media session ─────────────────────────────────────────────────────────

/// Spotify's session among everything playing: "Spotify.exe" for the
/// installer's build, "SpotifyAB.SpotifyMusic_…!Spotify" for the Store's.
fn find_session() -> Option<Session> {
    let manager = Manager::RequestAsync().ok()?.get().ok()?;
    let sessions = manager.GetSessions().ok()?;
    (0..sessions.Size().ok()?)
        .filter_map(|i| sessions.GetAt(i).ok())
        .find(|s| s.SourceAppUserModelId().is_ok_and(|id| is_spotify(&id.to_string())))
}

fn is_spotify(app_id: &str) -> bool {
    app_id.to_lowercase().contains("spotify")
}

struct Read {
    track: Option<Track>,
    playing: bool,
    shuffle: bool,
    repeat: bool,
    position: f64,
}

fn read_player(session: &Session) -> Option<Read> {
    let props = session.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
    let title = props.Title().map(|s| s.to_string()).unwrap_or_default();
    let artist = props.Artist().map(|s| s.to_string()).unwrap_or_default();
    let album = props.AlbumTitle().map(|s| s.to_string()).unwrap_or_default();
    let info = session.GetPlaybackInfo().ok()?;
    let playing = info.PlaybackStatus().ok() == Some(Status::Playing);
    let shuffle = info.IsShuffleActive().and_then(|v| v.Value()).unwrap_or(false);
    let repeat = info
        .AutoRepeatMode()
        .and_then(|v| v.Value())
        .is_ok_and(|m| m != MediaPlaybackAutoRepeatMode::None);

    let timeline = session.GetTimelineProperties().ok();
    let secs = |t: windows::Foundation::TimeSpan| t.Duration as f64 / 10_000_000.0;
    let (start, end, mut position) = match &timeline {
        Some(tl) => (
            tl.StartTime().map(secs).unwrap_or(0.0),
            tl.EndTime().map(secs).unwrap_or(0.0),
            tl.Position().map(secs).unwrap_or(0.0),
        ),
        None => (0.0, 0.0, 0.0),
    };
    // Spotify stamps the position when it reports it: run it on to now.
    if playing {
        if let Some(updated) = timeline.as_ref().and_then(|tl| tl.LastUpdatedTime().ok()) {
            let since = (now_ms() - filetime_ms(updated.UniversalTime)) / 1000.0;
            if (0.0..86_400.0).contains(&since) {
                position += since;
            }
        }
    }
    let duration = (end - start).max(0.0);

    let track = track_of(&title, &artist, &album, duration);
    let position = match &track {
        Some(t) if t.duration > 0.0 => position.clamp(0.0, t.duration),
        _ => position.max(0.0),
    };
    Some(Read { track, playing, shuffle, repeat, position })
}

/// Windows file time (100 ns since 1601) → Unix milliseconds.
fn filetime_ms(ticks: i64) -> f64 {
    (ticks - 116_444_736_000_000_000) as f64 / 10_000.0
}

/// What the media session reports → the pill's track. The session has no
/// Spotify URI, so the id is made of what identifies a song on screen; Spotify
/// names its adverts "Advertisement", and they get the Mac's ad id so the card
/// treats them as it does there.
fn track_of(title: &str, artist: &str, album: &str, duration: f64) -> Option<Track> {
    if title.trim().is_empty() {
        return None;
    }
    let kind = if title == "Advertisement" || (artist.is_empty() && title == "Spotify") { "ad" } else { "track" };
    let id = format!("spotify:{kind}:{artist}\u{1f}{title}\u{1f}{album}");
    Some(Track {
        art_url: Some(format!("smtc:{id}")),
        id,
        title: short_title(title),
        artist: short_artist(artist),
        album: album.to_string(),
        duration,
        object_path: String::new(),
    })
}

/// The cover, read from the session's thumbnail and sent as a data URL. The
/// thumbnail can lag the track by a moment, so it is read again shortly after.
fn send_cover(app: &AppHandle, session: &Session, id: String) {
    let Some(data) = thumbnail(session).as_deref().and_then(data_url) else { return };
    let art_url = format!("smtc:{id}");
    {
        let mut s = SHARED.lock().unwrap();
        if s.state.track.as_ref().map(|t| &t.id) != Some(&id) {
            return;
        }
        s.art = Some((id.clone(), data.clone()));
    }
    let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: art_url.clone(), data_url: data.clone() });

    let app = app.clone();
    let session = session.clone();
    std::thread::spawn(move || {
        com();
        std::thread::sleep(Duration::from_millis(1500));
        let Some(later) = thumbnail(&session).as_deref().and_then(data_url) else { return };
        if later == data {
            return;
        }
        let mut s = SHARED.lock().unwrap();
        if s.state.track.as_ref().map(|t| &t.id) != Some(&id) {
            return;
        }
        s.art = Some((id, later.clone()));
        drop(s);
        let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url, data_url: later });
    });
}

fn thumbnail(session: &Session) -> Option<Vec<u8>> {
    let props = session.TryGetMediaPropertiesAsync().ok()?.get().ok()?;
    let stream = props.Thumbnail().ok()?.OpenReadAsync().ok()?.get().ok()?;
    let size = stream.Size().ok()?;
    if size == 0 || size as usize > ARTWORK_LIMIT {
        return None;
    }
    let reader = DataReader::CreateDataReader(&stream).ok()?;
    let loaded = reader.LoadAsync(size as u32).ok()?.get().ok()?;
    let mut bytes = vec![0u8; loaded as usize];
    reader.ReadBytes(&mut bytes).ok()?;
    Some(bytes)
}

// ── Volume: Spotify's session in the Windows volume mixer ─────────────────────

/// Spotify's own volume control in the mixer, once it has played something.
fn mixer_session() -> Option<ISimpleAudioVolume> {
    com();
    unsafe {
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).ok()?;
        let device = devices.GetDefaultAudioEndpoint(eRender, eMultimedia).ok()?;
        let manager: IAudioSessionManager2 = device.Activate(CLSCTX_ALL, None).ok()?;
        let sessions = manager.GetSessionEnumerator().ok()?;
        for i in 0..sessions.GetCount().ok()? {
            let Ok(control) = sessions.GetSession(i) else { continue };
            let Ok(control2) = control.cast::<IAudioSessionControl2>() else { continue };
            let Ok(pid) = control2.GetProcessId() else { continue };
            if crate::platform::exe_of_pid(pid).as_deref() == Some("spotify.exe") {
                return control.cast::<ISimpleAudioVolume>().ok();
            }
        }
        None
    }
}

fn mixer_volume() -> Option<i32> {
    let level = unsafe { mixer_session()?.GetMasterVolume().ok()? };
    Some((level * 100.0).round().clamp(0.0, 100.0) as i32)
}

fn set_mixer_volume(percent: f64) -> bool {
    let Some(session) = mixer_session() else { return false };
    let level = (percent / 100.0).clamp(0.0, 1.0) as f32;
    unsafe { session.SetMasterVolume(level, std::ptr::null()).is_ok() }
}

// ── Commands ──────────────────────────────────────────────────────────────────

pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
    com();
    update(app, None, true)
}

/// `playPause`, `next`, `previous`, `seek` (seconds), `shuffle` / `repeat`
/// (1 on, 0 off), `volume` (0…100).
pub fn control(app: &AppHandle, action: &str, value: Option<f64>) -> bool {
    com();
    if !SHARED.lock().unwrap().active {
        return false;
    }
    let v = value.unwrap_or(0.0);
    let done = if action == "volume" {
        set_mixer_volume(v)
    } else {
        let Some(session) = find_session() else { return false };
        let asked = match action {
            "playPause" => session.TryTogglePlayPauseAsync(),
            "next" => session.TrySkipNextAsync(),
            "previous" => session.TrySkipPreviousAsync(),
            "seek" => {
                let duration = SHARED.lock().unwrap().state.track.as_ref().map(|t| t.duration).unwrap_or(0.0);
                let target = v.clamp(0.0, (duration - 1.0).max(0.0));
                session.TryChangePlaybackPositionAsync((target * 10_000_000.0) as i64)
            }
            "shuffle" => session.TryChangeShuffleActiveAsync(v != 0.0),
            "repeat" => session.TryChangeAutoRepeatModeAsync(if v != 0.0 {
                MediaPlaybackAutoRepeatMode::List
            } else {
                MediaPlaybackAutoRepeatMode::None
            }),
            _ => return false,
        };
        asked.and_then(|op| op.get()).unwrap_or(false)
    };
    if !done {
        return false;
    }
    // Show the result at once, as the Mac does, then read Spotify again once it
    // has caught up.
    {
        let mut s = SHARED.lock().unwrap();
        let now = now_ms();
        match action {
            "seek" => {
                let duration = s.state.track.as_ref().map(|t| t.duration).unwrap_or(0.0);
                s.state.position = v.clamp(0.0, (duration - 1.0).max(0.0));
                s.state.position_at = now;
            }
            "shuffle" => s.state.shuffle = v != 0.0,
            "repeat" => s.state.repeat = v != 0.0,
            "volume" => s.state.volume = v.round().clamp(0.0, 100.0) as i32,
            _ => {}
        }
        let state = s.state.clone();
        drop(s);
        emit_state(app, &state);
    }
    let app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(Duration::from_millis(350));
        com();
        update(&app, None, true);
    });
    true
}

/// The Spotify the user has: the installer's, or the Microsoft Store's alias.
pub fn installed() -> bool {
    let exists = |base: Option<std::ffi::OsString>, tail: &str| {
        base.map(std::path::PathBuf::from).is_some_and(|b| b.join(tail).is_file())
    };
    exists(std::env::var_os("APPDATA"), r"Spotify\Spotify.exe")
        || exists(std::env::var_os("LOCALAPPDATA"), r"Microsoft\WindowsApps\Spotify.exe")
}

/// Brings Spotify forward or starts it through its `spotify:` link; without
/// Spotify, opens its download page.
pub fn open() -> bool {
    if installed() {
        crate::platform::open_url("spotify:");
        true
    } else {
        crate::platform::open_url(DOWNLOAD_URL);
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn spotify_is_found_by_either_build() {
        assert!(is_spotify("Spotify.exe"));
        assert!(is_spotify("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify"));
        assert!(!is_spotify("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"));
        assert!(!is_spotify("chrome.exe"));
    }

    #[test]
    fn a_session_becomes_a_track_and_an_empty_one_none() {
        let t = track_of("Song - Remastered 2011", "Artist feat. Other", "Album", 215.0).unwrap();
        assert_eq!(t.title, "Song");
        assert_eq!(t.artist, "Artist");
        assert_eq!(t.album, "Album");
        assert_eq!(t.duration, 215.0);
        assert!(t.id.starts_with("spotify:track:"));
        assert_eq!(t.art_url.as_deref(), Some(format!("smtc:{}", t.id).as_str()));
        // Same song, same id; another song, another id.
        assert_eq!(track_of("Song - Remastered 2011", "Artist feat. Other", "Album", 215.0).unwrap().id, t.id);
        assert_ne!(track_of("Other", "Artist", "Album", 100.0).unwrap().id, t.id);
        assert!(track_of("", "Artist", "Album", 0.0).is_none());
        assert!(track_of("Advertisement", "", "", 30.0).unwrap().id.starts_with("spotify:ad:"));
    }

    #[test]
    fn windows_file_times_become_unix_milliseconds() {
        // 2024-01-01T00:00:00Z
        assert_eq!(filetime_ms(133_485_408_000_000_000), 1_704_067_200_000.0);
    }

    #[test]
    fn only_a_jump_in_position_counts_as_a_change() {
        let track = track_of("Song", "Artist", "Album", 200.0);
        let a = PlayerState { running: true, track: track.clone(), playing: true, position: 10.0, position_at: 0.0, ..PlayerState::default() };
        // Half a second later, half a second further: nothing to tell.
        let b = PlayerState { position: 10.5, position_at: 500.0, ..a.clone() };
        assert!(!differs(&a, &b, 500.0));
        // A seek to 1:30.
        let c = PlayerState { position: 90.0, position_at: 500.0, ..a.clone() };
        assert!(differs(&a, &c, 500.0));
        let d = PlayerState { playing: false, ..b.clone() };
        assert!(differs(&b, &d, 500.0));
    }
}
