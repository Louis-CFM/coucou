// Windows media transport and per-application mixer access. Spotify and Apple Music have independent state and events.
use crate::media::*;
use tauri::AppHandle;
use std::collections::VecDeque;
use std::path::PathBuf;
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::{LazyLock, Mutex};

use windows::core::Interface;
use windows::Foundation::TypedEventHandler;
use windows::Media::Control::{
    GlobalSystemMediaTransportControlsSession as Session,
    GlobalSystemMediaTransportControlsSessionManager as Manager,
    GlobalSystemMediaTransportControlsSessionMediaProperties as MediaProperties,
    GlobalSystemMediaTransportControlsSessionPlaybackStatus as Status,
};
use windows::Media::MediaPlaybackAutoRepeatMode;
use windows::Storage::Streams::DataReader;
use windows::Win32::Foundation::CloseHandle;
use windows::Win32::Media::Audio::{
    DEVICE_STATE_ACTIVE, eRender, IAudioSessionControl2, IAudioSessionManager2, IMMDeviceEnumerator, ISimpleAudioVolume,
    MMDeviceEnumerator,
};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CoUninitialize, CLSCTX_ALL, COINIT_MULTITHREADED};
use windows::Win32::System::Threading::{
    OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
};

/// What wakes the listener.
enum Wake {
    /// The session's track, status or timeline moved.
    Changed,
    /// A player appeared or went away: find the selected player's session again.
    Sessions,
    Stop,
}

struct Shared {
    /// Bumped on every start and stop: a listener from an older one quits.
    generation: u64,
    active: bool,
    wake: Option<Sender<Wake>>,
    state: PlayerState,
}

static SPOTIFY: LazyLock<Mutex<Shared>> =
    LazyLock::new(|| Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default() }));

static APPLE: LazyLock<Mutex<Shared>> =
    LazyLock::new(|| Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default() }));

#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Player { Spotify, AppleMusic }

impl Player {
    fn shared(self) -> &'static Mutex<Shared> { match self { Self::Spotify => &SPOTIFY, Self::AppleMusic => &APPLE } }
    fn matches(self, id: &str) -> bool { match self { Self::Spotify => crate::spotify::is_spotify_app(id), Self::AppleMusic => crate::apple_music::matches(id) } }
    fn name(self) -> &'static str { match self { Self::Spotify => "spotify", Self::AppleMusic => "apple-music" } }
    fn executable(self) -> &'static str { match self { Self::Spotify => "spotify.exe", Self::AppleMusic => "AppleMusic.exe" } }
    fn artwork_event(self) -> &'static str { match self { Self::Spotify => crate::spotify::ARTWORK_EVENT, Self::AppleMusic => "apple-music-artwork" } }
    fn emit(self, app: &AppHandle, state: &PlayerState) {
        use tauri::Emitter;
        let event = match self { Self::Spotify => crate::spotify::STATE_EVENT, Self::AppleMusic => "apple-music" };
        let _ = app.emit_to(crate::island::WINDOW_LABEL, event, state);
    }
}

fn apple_entry() -> Option<windows::ApplicationModel::Core::AppListEntry> {
    let manager = windows::Management::Deployment::PackageManager::new().ok()?;
    let packages = manager.FindPackagesByUserSecurityId(&windows::core::HSTRING::new()).ok()?;
    for package in packages {
        let Ok(name) = package.Id().and_then(|id| id.Name()) else { continue };
        let name = name.to_string_lossy();
        if !name.eq_ignore_ascii_case("AppleInc.AppleMusicWin") { continue; }
        let entries = package.GetAppListEntriesAsync().ok()?.get().ok()?;
        for entry in entries {
            if entry.AppUserModelId().is_ok_and(|id| crate::apple_music::matches(&id.to_string_lossy())) { return Some(entry); }
        }
    }
    None
}

/// Covers already read, by the track's art key; the newest last.
static ART: LazyLock<Mutex<VecDeque<(String, String)>>> = LazyLock::new(|| Mutex::new(VecDeque::new()));

/// WinRT and Core Audio need COM on the calling thread. A thread that has it
/// already, in either model, keeps it.
struct ComGuard(bool);
impl Drop for ComGuard { fn drop(&mut self) { if self.0 { unsafe { CoUninitialize(); } } } }
fn com() -> ComGuard { ComGuard(unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).is_ok() }) }

fn current(player: Player, generation: u64) -> bool {
    let s = player.shared().lock().unwrap();
    s.active && s.generation == generation
}

// ── Start / stop ──────────────────────────────────────────────────────────

pub fn sync(app: &AppHandle, on: bool, player: Player) {
    let (tx, rx) = mpsc::channel();
    let (old, generation, state) = {
        let mut s = player.shared().lock().unwrap();
        if s.active == on {
            return;
        }
        s.active = on;
        s.generation += 1;
        s.state = PlayerState { installed: installed(player), ..PlayerState::default() };
        let old = s.wake.take();
        if on {
            s.wake = Some(tx.clone());
        }
        (old, s.generation, s.state.clone())
    };
    if let Some(old) = old {
        let _ = old.send(Wake::Stop);
    }
    if on {
        let app = app.clone();
        let spawned = std::thread::Builder::new()
            .name(format!("coucou-{}", player.name()))
            .spawn(move || listen(app, generation, tx, rx, player));
        if let Err(err) = spawned {
            crate::log::line(format!("{}: no listener thread: {err}", player.name()));
        }
    } else {
        player.emit(app, &state);
    }
}

/// Waits on the session's events and tells the island what changed. Nothing
/// runs between events.
fn listen(app: AppHandle, generation: u64, tx: Sender<Wake>, rx: Receiver<Wake>, player: Player) {
    let _com = com();
    let manager = match Manager::RequestAsync().and_then(|op| op.get()) {
        Ok(m) => m,
        Err(err) => {
            crate::log::line(format!("{}: no media sessions: {err}", player.name()));
            return;
        }
    };
    let sessions_token = {
        let tx = tx.clone();
        manager
            .SessionsChanged(&TypedEventHandler::new(move |_, _| {
                let _ = tx.send(Wake::Sessions);
                Ok(())
            }))
            .ok()
    };

    let mut bound: Option<Bound> = None;
    let mut rebind = true;
    while current(player, generation) {
        if rebind {
            if let Some(b) = bound.take() {
                b.unbind();
            }
            bound = find_session(&manager, player).and_then(|s| Bound::bind(s, &tx));
            rebind = false;
        }
        read_and_emit(&app, generation, bound.as_ref().map(|b| &b.session), player);

        // Events come in bursts (a new track moves everything): one read each.
        let mut stop = false;
        match rx.recv() {
            Ok(Wake::Changed) => {}
            Ok(Wake::Sessions) => rebind = true,
            Ok(Wake::Stop) | Err(_) => stop = true,
        }
        while let Ok(more) = rx.try_recv() {
            match more {
                Wake::Changed => {}
                Wake::Sessions => rebind = true,
                Wake::Stop => stop = true,
            }
        }
        if stop {
            break;
        }
    }

    if let Some(b) = bound {
        b.unbind();
    }
    if let Some(token) = sessions_token {
        let _ = manager.RemoveSessionsChanged(token);
    }
}

/// The selected player's session, with the event handlers that wake the listener.
struct Bound {
    session: Session,
    tokens: [Option<i64>; 3],
}

impl Bound {
    fn bind(session: Session, tx: &Sender<Wake>) -> Option<Bound> {
        let tokens = [
            session.MediaPropertiesChanged(&wake_on(tx)).ok(),
            session.PlaybackInfoChanged(&wake_on(tx)).ok(),
            session.TimelinePropertiesChanged(&wake_on(tx)).ok(),
        ];
        Some(Bound { session, tokens })
    }

    fn unbind(self) {
        let [media, playback, timeline] = self.tokens;
        if let Some(t) = media {
            let _ = self.session.RemoveMediaPropertiesChanged(t);
        }
        if let Some(t) = playback {
            let _ = self.session.RemovePlaybackInfoChanged(t);
        }
        if let Some(t) = timeline {
            let _ = self.session.RemoveTimelinePropertiesChanged(t);
        }
    }
}

/// A handler that wakes the listener, for any of the session's events.
fn wake_on<A: windows::core::RuntimeType + 'static>(tx: &Sender<Wake>) -> TypedEventHandler<Session, A> {
    let tx = tx.clone();
    TypedEventHandler::new(move |_, _| {
        let _ = tx.send(Wake::Changed);
        Ok(())
    })
}

fn find_session(manager: &Manager, player: Player) -> Option<Session> {
    let sessions = manager.GetSessions().ok()?;
    (0..sessions.Size().ok()?)
        .filter_map(|i| sessions.GetAt(i).ok())
        .find(|s| s.SourceAppUserModelId().is_ok_and(|id| player.matches(&id.to_string_lossy())))
}

// ── Reading ───────────────────────────────────────────────────────────────

/// Everything the session says, as it is now.
struct Snapshot {
    track: Option<Track>,
    playing: bool,
    can_seek: bool,
    position: f64,
    /// When Windows last updated the position (Unix ms), if it says.
    updated_at: Option<f64>,
    shuffle: bool,
    repeat: bool,
}

fn snapshot(session: &Session, player: Player) -> windows::core::Result<(Snapshot, MediaProperties)> {
    let props = session.TryGetMediaPropertiesAsync()?.get()?;
    let timeline = session.GetTimelineProperties()?;
    let start = timeline.StartTime()?.Duration;
    let duration = ticks_to_secs(timeline.EndTime()?.Duration - start);
    let track = windows_track(
        &props.Title()?.to_string_lossy(),
        &props.Artist()?.to_string_lossy(),
        &props.AlbumTitle()?.to_string_lossy(),
        duration,
        if player == Player::AppleMusic { "apple-music" } else { "spotify" },
    );
    let info = session.GetPlaybackInfo()?;
    let snapshot = Snapshot {
        playing: info.PlaybackStatus()? == Status::Playing && track.is_some(),
        can_seek: info.Controls().and_then(|c| c.IsPlaybackPositionEnabled()).unwrap_or(false),
        track,
        position: ticks_to_secs(timeline.Position()?.Duration - start),
        updated_at: windows_time_to_unix_ms(timeline.LastUpdatedTime()?.UniversalTime),
        shuffle: info.IsShuffleActive().and_then(|r| r.Value()).unwrap_or(false),
        repeat: info
            .AutoRepeatMode()
            .and_then(|r| r.Value())
            .is_ok_and(|mode| mode != MediaPlaybackAutoRepeatMode::None),
    };
    Ok((snapshot, props))
}

fn read_and_emit(app: &AppHandle, generation: u64, session: Option<&Session>, player: Player) {
    let read = session.and_then(|s| snapshot(s, player).ok());
    let volume = read.as_ref().and_then(|_| player_volume(player));
    let now = now_ms();
    let (state, props) = {
        let mut s = player.shared().lock().unwrap();
        if !(s.active && s.generation == generation) {
            return;
        }
        let props = match read {
            Some((snap, props)) => {
                s.state.running = true;
                s.state.installed = true;
                s.state.track = snap.track;
                s.state.playing = snap.playing;
                s.state.can_seek = snap.can_seek;
                // The position was true when Windows last updated it; while
                // playing, the page runs it on from there.
                let at = snap.updated_at.filter(|&t| t <= now).unwrap_or(now);
                s.state.anchor(snap.position, at);
                s.state.shuffle = snap.shuffle;
                s.state.repeat = snap.repeat;
                if let Some(v) = volume {
                    s.state.volume = v;
                }
                Some(props)
            }
            None => {
                s.state.running = false;
                s.state.installed = installed(player);
                s.state.clear(now);
                None
            }
        };
        (s.state.clone(), props)
    };
    player.emit(app, &state);
    if let (Some(props), Some(track)) = (props, state.track.as_ref()) {
        artwork(app, track, &props, player);
    }
}

// ── Artwork ───────────────────────────────────────────────────────────────

/// The track's cover, as a data URL (the page may not load anything
/// remote). Read once per track; Spotify sometimes adds the thumbnail a
/// moment after the title, and the next event brings it then.
fn artwork(app: &AppHandle, track: &Track, props: &MediaProperties, player: Player) {
    use tauri::Emitter;
    let Some(key) = track.art_url.clone() else { return };
    let cached = ART.lock().unwrap().iter().find(|(k, _)| *k == key).map(|(_, d)| d.clone());
    let data = match cached {
        Some(data) => data,
        None => {
            let Some(data) = thumbnail(props).as_deref().and_then(data_url) else { return };
            let mut art = ART.lock().unwrap();
            art.push_back((key.clone(), data.clone()));
            while art.len() > 12 {
                art.pop_front();
            }
            data
        }
    };
    let _ = app.emit_to(crate::island::WINDOW_LABEL, player.artwork_event(), Artwork { art_url: key, data_url: data });
}

fn thumbnail(props: &MediaProperties) -> Option<Vec<u8>> {
    let stream = props.Thumbnail().ok()?.OpenReadAsync().ok()?.get().ok()?;
    let size = stream.Size().ok()?;
    if size == 0 || size > ARTWORK_LIMIT as u64 {
        return None;
    }
    let reader = DataReader::CreateDataReader(&stream).ok()?;
    let loaded = reader.LoadAsync(size as u32).ok()?.get().ok()?;
    let mut bytes = vec![0u8; loaded as usize];
    reader.ReadBytes(&mut bytes).ok()?;
    Some(bytes)
}

// ── Volume: the selected player in the Windows mixer ──────────────────────────────────

/// The player's sessions on every active output, including an app-specific headset route.
fn player_audio(player: Player) -> Vec<ISimpleAudioVolume> {
    let _com = com();
    let mut out = Vec::new();
    unsafe {
        let Ok(devices) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else { return out };
        let Ok(endpoints) = devices.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE) else { return out };
        for endpoint in 0..endpoints.GetCount().unwrap_or(0) {
            let Ok(device) = endpoints.Item(endpoint) else { continue };
            let Ok(manager) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) else { continue };
            let Ok(sessions) = manager.GetSessionEnumerator() else { continue };
            for i in 0..sessions.GetCount().unwrap_or(0) {
                let Ok(control) = sessions.GetSession(i) else { continue };
                let Ok(control) = control.cast::<IAudioSessionControl2>() else { continue };
                let pid = control.GetProcessId().unwrap_or(0);
                if pid != 0 && is_player_process(pid, player) {
                    if let Ok(volume) = control.cast::<ISimpleAudioVolume>() { out.push(volume); }
                }
            }
        }
    }
    out
}

fn is_player_process(pid: u32, player: Player) -> bool {
    unsafe {
        let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
        let mut buf = [0u16; 1024];
        let mut len = buf.len() as u32;
        let named = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
        let mut family = [0u16; 512];
        let mut family_len = family.len() as u32;
        let packaged = windows::Win32::Storage::Packaging::Appx::GetPackageFamilyName(process, &mut family_len, Some(windows::core::PWSTR(family.as_mut_ptr())));
        let _ = CloseHandle(process);
        if named.is_err() { return false; }
        let path = String::from_utf16_lossy(&buf[..len as usize]);
        let executable = path.rsplit(['\\', '/']).next().unwrap_or("");
        if player == Player::AppleMusic {
            let family = (packaged == windows::Win32::Foundation::ERROR_SUCCESS && family_len as usize <= family.len())
                .then(|| String::from_utf16_lossy(&family[..family_len.saturating_sub(1) as usize]));
            crate::apple_music::owns_audio_process(executable, family.as_deref())
        } else { executable.eq_ignore_ascii_case(player.executable()) }
    }
}

/// 0…100, or None while the player has no audio session (nothing played yet).
fn player_volume(player: Player) -> Option<i32> {
    let level = unsafe { player_audio(player).first()?.GetMasterVolume().ok()? };
    Some((level * 100.0).round().clamp(0.0, 100.0) as i32)
}

fn set_player_volume(percent: f64, player: Player) -> bool {
    let level = (percent / 100.0).clamp(0.0, 1.0) as f32;
    let sessions = player_audio(player);
    let mut done = false;
    for volume in &sessions {
        done |= unsafe { volume.SetMasterVolume(level, std::ptr::null()).is_ok() };
    }
    done
}

// ── Commands ──────────────────────────────────────────────────────────────

pub fn refresh(app: &AppHandle, player: Player) -> Option<PlayerState> {
    let generation = {
        let s = player.shared().lock().unwrap();
        if !s.active {
            return None;
        }
        s.generation
    };
    let _com = com();
    let manager = Manager::RequestAsync().and_then(|op| op.get()).ok();
    let session = manager.as_ref().and_then(|m| find_session(m, player));
    read_and_emit(app, generation, session.as_ref(), player);
    let s = player.shared().lock().unwrap();
    (s.active && s.generation == generation).then(|| s.state.clone())
}

pub fn control(app: &AppHandle, action: &str, value: Option<f64>, player: Player) -> bool {
    let state = {
        let s = player.shared().lock().unwrap();
        if !(s.active && s.state.running) {
            return false;
        }
        s.state.clone()
    };
    let _com = com();
    let Some(session) = Manager::RequestAsync().and_then(|op| op.get()).ok().and_then(|m| find_session(&m, player)) else {
        return false;
    };
    let v = value.unwrap_or(0.0);
    let seek_to = state.track.as_ref().map(|t| v.clamp(0.0, (t.duration - 1.0).max(0.0)));
    let done = execute(&session, action, v, seek_to, player);
    if !done {
        return false;
    }
    // Show these at once, as the Mac does; the session's events confirm them.
    let optimistic = matches!(action, "seek" | "shuffle" | "repeat" | "volume");
    if optimistic {
        let state = {
            let mut s = player.shared().lock().unwrap();
            match action {
                "seek" => {
                    if let Some(target) = seek_to {
                        s.state.anchor(target, now_ms());
                    }
                }
                "shuffle" => s.state.shuffle = v != 0.0,
                "repeat" => s.state.repeat = v != 0.0,
                _ => s.state.volume = v.round().clamp(0.0, 100.0) as i32,
            }
            s.state.clone()
        };
        player.emit(app, &state);
    }
    true
}

fn execute(session: &Session, action: &str, v: f64, seek_to: Option<f64>, player: Player) -> bool {
    if !v.is_finite() { return false; }
    // A request Windows passed on, and the player said yes to.
    macro_rules! asked {
        ($op:expr) => {
            $op.and_then(|op| op.get()).unwrap_or(false)
        };
    }
    match action {
        "playPause" => asked!(session.TryTogglePlayPauseAsync()),
        "next" => asked!(session.TrySkipNextAsync()),
        "previous" => asked!(session.TrySkipPreviousAsync()),
        "seek" => match (seek_to, session.GetTimelineProperties().and_then(|t| t.StartTime())) {
            (Some(target), Ok(start)) => {
                // Some players accept the request even while advertising that
                // seeking is unavailable. Do not show an invented new position.
                if !session.GetPlaybackInfo().and_then(|i| i.Controls())
                    .and_then(|c| c.IsPlaybackPositionEnabled()).unwrap_or(false) {
                    return false;
                }
                asked!(session.TryChangePlaybackPositionAsync(start.Duration + (target * 10_000_000.0) as i64))
            }
            _ => false,
        },
        "shuffle" => asked!(session.TryChangeShuffleActiveAsync(v != 0.0)),
        "repeat" => asked!(session.TryChangeAutoRepeatModeAsync(if v != 0.0 {
            MediaPlaybackAutoRepeatMode::List
        } else {
            MediaPlaybackAutoRepeatMode::None
        })),
        "volume" => set_player_volume(v, player),
        _ => false,
    }
}

// ── Launching ─────────────────────────────────────────────────────────────

/// The installer's copy, or the Microsoft Store's (its app alias).
pub fn installed(player: Player) -> bool {
    if player == Player::AppleMusic {
        let _com = com();
        static INSTALLED: std::sync::OnceLock<bool> = std::sync::OnceLock::new();
        return *INSTALLED.get_or_init(|| apple_entry().is_some());
    }
    let under = |var: &str, rest: &str| std::env::var_os(var).map(|base| PathBuf::from(base).join(rest));
    let desktop = under("APPDATA", r"Spotify\Spotify.exe").is_some_and(|p| p.is_file());
    // An app execution alias is a reparse point that is_file() can't open.
    let store = under("LOCALAPPDATA", r"Microsoft\WindowsApps\Spotify.exe")
        .is_some_and(|p| std::fs::symlink_metadata(p).is_ok());
    desktop || store
}

/// Launch the selected native application, or open its official installation page.
pub fn open(player: Player) -> bool {
    if player == Player::AppleMusic {
        let _com = com();
        if let Some(entry) = apple_entry() { return entry.LaunchAsync().and_then(|op| op.get()).unwrap_or(false); }
        crate::platform::open_url("https://support.apple.com/guide/music-windows/mus19e7bc658/windows");
        return false;
    }
    let running = player.shared().lock().unwrap().state.running;
    if running || installed(player) {
        crate::platform::open_url("spotify:");
        return true;
    }
    crate::platform::open_url(crate::spotify::DOWNLOAD_URL);
    false
}

#[cfg(test)]
pub fn probe_apple_music() -> Result<bool, String> {
    let _com = com();
    let entry = apple_entry().ok_or("Apple Music is not installed")?;
    let id = entry.AppUserModelId().map_err(|e| e.to_string())?;
    if !crate::apple_music::matches(&id.to_string_lossy()) { return Err("Unexpected music application".into()); }
    let manager = Manager::RequestAsync().and_then(|op| op.get()).map_err(|e| e.to_string())?;
    let sessions = manager.GetSessions().map_err(|e| e.to_string())?;
    for index in 0..sessions.Size().unwrap_or(0) {
        let session = sessions.GetAt(index).map_err(|e| e.to_string())?;
        let id = session.SourceAppUserModelId().map_err(|e| e.to_string())?.to_string_lossy();
        if !Player::AppleMusic.matches(&id) { continue; }
        let info = session.GetPlaybackInfo().map_err(|e| e.to_string())?;
        let props = session.TryGetMediaPropertiesAsync().and_then(|op| op.get()).map_err(|e| e.to_string())?;
        println!("Apple Music session {index}: status={} title_chars={}", info.PlaybackStatus().map_err(|e| e.to_string())?.0, props.Title().map_err(|e| e.to_string())?.len());
        let controls = info.Controls().map_err(|e| e.to_string())?;
        println!("Apple Music native controls: play={:?} pause={:?} toggle={:?} seek={:?}",
            controls.IsPlayEnabled(), controls.IsPauseEnabled(), controls.IsPlayPauseToggleEnabled(), controls.IsPlaybackPositionEnabled());
    }
    if let Some(session) = find_session(&manager, Player::AppleMusic) {
        let (state, _) = snapshot(&session, Player::AppleMusic).map_err(|e| e.to_string())?;
        println!("Apple Music native state: track={} playing={} position={:.1}s volume={:?}", state.track.is_some(), state.playing, state.position, player_volume(Player::AppleMusic));
        return Ok(true);
    }
    Ok(false)
}

#[test]
#[ignore = "Reads native mixer process names and levels; no playback changes"]
fn live_media_audio_routes() {
    let _com = com();
    unsafe {
        let devices: IMMDeviceEnumerator = CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL).unwrap();
        let endpoints = devices.EnumAudioEndpoints(eRender, DEVICE_STATE_ACTIVE).unwrap();
        for endpoint in 0..endpoints.GetCount().unwrap_or(0) {
            let device = endpoints.Item(endpoint).unwrap();
            let manager = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None).unwrap();
            let sessions = manager.GetSessionEnumerator().unwrap();
            for i in 0..sessions.GetCount().unwrap_or(0) {
                let control = sessions.GetSession(i).unwrap().cast::<IAudioSessionControl2>().unwrap();
                let pid = control.GetProcessId().unwrap_or(0);
                let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { continue };
                let mut buf = [0u16; 1024]; let mut len = buf.len() as u32;
                let named = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
                let _ = CloseHandle(process);
                if named.is_err() { continue; }
                let path = String::from_utf16_lossy(&buf[..len as usize]);
                let volume = control.cast::<ISimpleAudioVolume>().ok().and_then(|v| v.GetMasterVolume().ok());
                println!("endpoint={endpoint} process={} apple_package={} level={volume:?}", path.rsplit(['\\', '/']).next().unwrap_or(""), path.contains("AppleInc.AppleMusicWin_"));
            }
        }
    }
}

#[test]
#[ignore = "Controls the user's running Apple Music; requires explicit permission, leaves volume at 5 percent"]
fn live_apple_music_controls_quiet() {
    let _com = com();
    let player = Player::AppleMusic;
    // Never begin playback unless the real audio session confirms the quiet level.
    assert!(set_player_volume(5.0, player), "Apple Music has no controllable audio session; playback was not started");
    assert_eq!(player_volume(player), Some(5));
    let manager = Manager::RequestAsync().and_then(|op| op.get()).expect("media session manager");
    let session = find_session(&manager, player).expect("running Apple Music media session");
    let (original, properties) = snapshot(&session, player).expect("track snapshot");
    println!("native volume: 5% confirmed; selected track={}", original.track.is_some());
    struct Restore { session: Session, playing: bool, position: Option<f64> }
    impl Drop for Restore {
        fn drop(&mut self) {
            if let (Some(position), Ok(timeline)) = (self.position, self.session.GetTimelineProperties().and_then(|t| t.StartTime())) {
                let _ = self.session.TryChangePlaybackPositionAsync(timeline.Duration + (position * 10_000_000.0) as i64).and_then(|op| op.get());
            }
            if self.playing { let _ = self.session.TryPlayAsync().and_then(|op| op.get()); }
            else { let _ = self.session.TryPauseAsync().and_then(|op| op.get()); }
            let _ = set_player_volume(5.0, Player::AppleMusic);
        }
    }
    let was_playing = session.GetPlaybackInfo().and_then(|info| info.PlaybackStatus()).is_ok_and(|status| status == Status::Playing);
    let _restore = Restore { session: session.clone(), playing: was_playing, position: original.track.as_ref().map(|_| original.position) };
    let (original, properties) = if original.track.is_none() {
        // The user authorized playback testing. A dormant native session may publish
        // its track only after playback starts; the guard restores its initial state.
        assert!(session.TryPlayAsync().and_then(|op| op.get()).unwrap_or(false), "Apple Music has no playable selection; select a song in the app");
        let mut loaded = None;
        for _ in 0..50 {
            if let Ok(value) = snapshot(&session, player) {
                if value.0.track.is_some() { loaded = Some(value); break; }
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        loaded.expect("Apple Music did not publish a selected track; select a song in the app")
    } else { (original, properties) };
    let original_track = original.track.as_ref().unwrap();
    println!("native discovery: track present; duration={:.1}s; playing={}", original_track.duration, original.playing);
    if let Some(artwork) = thumbnail(&properties) {
        assert!(data_url(&artwork).is_some(), "supported artwork image");
        println!("native artwork: {} bytes", artwork.len());
    } else { println!("native artwork: player supplied none for this track"); }
    let wait_for = |wanted: bool| {
        for _ in 0..30 {
            if snapshot(&session, player).is_ok_and(|(s, _)| s.playing == wanted) { return true; }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        false
    };
    assert!(execute(&session, "playPause", 0.0, None, player));
    assert!(wait_for(!original.playing), "player did not confirm play/pause");
    assert!(execute(&session, "playPause", 0.0, None, player));
    assert!(wait_for(original.playing), "player did not confirm restored playback state");
    println!("native play/pause: both state changes confirmed");
    let target = (original.position + 5.0).min((original_track.duration - 1.0).max(0.0));
    let accepted = execute(&session, "seek", target, Some(target), player);
    if accepted {
        let mut confirmed = false;
        for _ in 0..30 {
            if snapshot(&session, player).is_ok_and(|(s, _)| (s.position - target).abs() < 2.0) { confirmed = true; break; }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        assert!(confirmed, "player accepted seek but did not confirm position");
    }
    println!("native seek supported and accepted: {accepted}");
    assert_eq!(player_volume(player), Some(5));
}
