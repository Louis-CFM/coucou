// The Spotify pill — port of SpotifyController.swift.
//
// The Mac listens to Spotify's distributed notification and drives it over
// AppleScript. Linux has MPRIS instead: Spotify owns
// `org.mpris.MediaPlayer2.spotify` on the session bus, publishes its track,
// playback status, shuffle, loop status and volume as properties, and takes
// PlayPause, Next, Previous, SetPosition… as method calls.
//
// Nothing runs on a timer. While the pill is declared, one thread blocks on the
// bus and wakes only for Spotify's PropertiesChanged and Seeked signals and for
// the bus telling us Spotify started or quit (NameOwnerChanged). Position is
// not signalled, so it is read when the status or the track changes and when
// the card comes on screen; the page runs it on from a timestamp while playing,
// as the Mac's `position(at:)` does. Turning the pill off ends the thread.
//
// Windows reads the system media controls instead (see "Windows" below): the
// same state reaches the island, from events rather than D-Bus signals.

// The MPRIS parts below are only reached from the Linux client and the tests.
#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use serde::Serialize;
use tauri::AppHandle;

pub const PILL_ID: &str = "integration_spotify";
/// Where "Get Spotify" leads when it isn't installed.
#[cfg(not(windows))]
pub const DOWNLOAD_URL: &str = "https://www.spotify.com/download/linux/";
#[cfg(windows)]
pub const DOWNLOAD_URL: &str = "https://www.spotify.com/download/windows/";
/// Island events: the player's state, and a track's cover as a data URL.
const STATE_EVENT: &str = "spotify";
const ARTWORK_EVENT: &str = "spotify-artwork";
/// The biggest cover we read (Spotify's are 640 px JPEGs, ~100 KB).
const ARTWORK_LIMIT: usize = 3 * 1024 * 1024;

// ── Values ────────────────────────────────────────────────────────────────────

/// A D-Bus value as far as MPRIS needs it, so the parsing is plain Rust that
/// can be tested without a bus.
#[derive(Clone, Debug, PartialEq)]
pub enum Value {
    Str(String),
    Strs(Vec<String>),
    Int(i64),
    Float(f64),
    Bool(bool),
    Map(Vec<(String, Value)>),
    Other,
}

impl Value {
    fn str(&self) -> Option<&str> {
        match self {
            Value::Str(s) => Some(s),
            _ => None,
        }
    }

    fn int(&self) -> Option<i64> {
        match self {
            Value::Int(n) => Some(*n),
            Value::Float(f) => Some(*f as i64),
            _ => None,
        }
    }

    /// Text, or a list of texts joined (xesam:artist is a list).
    fn text(&self) -> String {
        match self {
            Value::Str(s) => s.clone(),
            Value::Strs(list) => list
                .iter()
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join(", "),
            _ => String::new(),
        }
    }
}

fn find<'a>(map: &'a [(String, Value)], key: &str) -> Option<&'a Value> {
    map.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

// ── State ─────────────────────────────────────────────────────────────────────

/// The track Spotify has loaded (SpotifyTrack on macOS).
#[derive(Serialize, Clone, Debug, PartialEq, Default)]
#[serde(rename_all = "camelCase")]
pub struct Track {
    /// spotify:track:…, spotify:episode:…, spotify:ad:… — the Mac's ids.
    pub id: String,
    pub title: String,
    pub artist: String,
    pub album: String,
    /// Seconds.
    pub duration: f64,
    pub art_url: Option<String>,
    /// mpris:trackid as Spotify gave it, for SetPosition.
    #[serde(skip)]
    pub object_path: String,
}

/// What the island is told, whenever it changes.
#[derive(Serialize, Clone, Debug, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct PlayerState {
    /// Spotify owns its name on the bus.
    pub running: bool,
    /// A `spotify` (or the Flatpak / Snap) is there to launch.
    pub installed: bool,
    pub track: Option<Track>,
    pub playing: bool,
    /// Seconds at `position_at`; while playing, the real position runs on from there.
    pub position: f64,
    /// Unix milliseconds.
    pub position_at: f64,
    pub shuffle: bool,
    /// LoopStatus is not "None" (the Mac's `repeating`).
    pub repeat: bool,
    /// 0…100.
    pub volume: i32,
}

impl Default for PlayerState {
    fn default() -> Self {
        PlayerState {
            running: false,
            installed: false,
            track: None,
            playing: false,
            position: 0.0,
            position_at: 0.0,
            shuffle: false,
            repeat: false,
            volume: 50,
        }
    }
}

/// What a change touched, so the caller knows what to read next.
#[derive(Clone, Copy, Debug, Default, PartialEq)]
pub struct Applied {
    pub track_changed: bool,
    pub status_changed: bool,
    pub position_set: bool,
}

impl PlayerState {
    /// Where playback is at `now_ms`, extrapolated from the last anchor and
    /// capped at the track's end (SpotifyController.position(at:)).
    pub fn position_at_time(&self, now_ms: f64) -> f64 {
        let elapsed = if self.playing { ((now_ms - self.position_at) / 1000.0).max(0.0) } else { 0.0 };
        let p = self.position + elapsed;
        match &self.track {
            Some(t) if t.duration > 0.0 => p.min(t.duration),
            _ => p,
        }
    }

    fn anchor(&mut self, position: f64, now_ms: f64) {
        self.position = position.max(0.0);
        self.position_at = now_ms;
    }

    /// Spotify is gone, or the pill is off: nothing is playing.
    pub fn clear(&mut self, now_ms: f64) {
        self.track = None;
        self.playing = false;
        self.anchor(0.0, now_ms);
    }

    /// Applies Player properties (GetAll, or a PropertiesChanged). The
    /// metadata goes first and the position last, whatever order they came in.
    pub fn apply(&mut self, props: &[(String, Value)], now_ms: f64) -> Applied {
        let mut applied = Applied::default();
        let rank = |k: &str| match k {
            "Metadata" => 0,
            "PlaybackStatus" => 1,
            "Position" => 3,
            _ => 2,
        };
        let mut ordered: Vec<&(String, Value)> = props.iter().collect();
        ordered.sort_by_key(|(k, _)| rank(k));
        let mut stopped = false;
        for (key, value) in ordered {
            match key.as_str() {
                "Metadata" => {
                    let track = match value {
                        Value::Map(map) => parse_metadata(map),
                        _ => None,
                    };
                    let same = match (&self.track, &track) {
                        (Some(a), Some(b)) => a.id == b.id && a.object_path == b.object_path,
                        (None, None) => true,
                        _ => false,
                    };
                    if !same {
                        applied.track_changed = true;
                        self.anchor(0.0, now_ms);
                    }
                    self.track = track;
                }
                "PlaybackStatus" => {
                    let Some(status) = value.str() else { continue };
                    stopped = status == "Stopped";
                    let playing = status == "Playing";
                    if playing != self.playing {
                        // Freeze or restart the clock where it is now.
                        let at = self.position_at_time(now_ms);
                        self.anchor(at, now_ms);
                        self.playing = playing;
                        applied.status_changed = true;
                    }
                }
                "Shuffle" => {
                    if let Value::Bool(on) = value {
                        self.shuffle = *on;
                    }
                }
                "LoopStatus" => {
                    if let Some(s) = value.str() {
                        self.repeat = s != "None";
                    }
                }
                "Volume" => {
                    if let Value::Float(v) = value {
                        self.volume = (v * 100.0).round().clamp(0.0, 100.0) as i32;
                    }
                }
                "Position" => {
                    if let Some(us) = value.int() {
                        self.anchor(us as f64 / 1_000_000.0, now_ms);
                        applied.position_set = true;
                    }
                }
                _ => {}
            }
        }
        if stopped && self.track.is_some() {
            self.clear(now_ms);
            applied.track_changed = true;
        }
        if self.track.is_none() {
            self.playing = false;
        }
        applied
    }
}

/// xesam / mpris metadata → the track, or None when nothing is loaded.
pub fn parse_metadata(map: &[(String, Value)]) -> Option<Track> {
    let object_path = find(map, "mpris:trackid").map(Value::text).unwrap_or_default();
    let title = find(map, "xesam:title").map(Value::text).unwrap_or_default();
    if object_path.is_empty() && title.is_empty() {
        return None;
    }
    // An unloaded player says /org/mpris/MediaPlayer2/TrackList/NoTrack.
    if object_path.ends_with("/NoTrack") {
        return None;
    }
    let duration = find(map, "mpris:length")
        .and_then(Value::int)
        .map(|us| us.max(0) as f64 / 1_000_000.0)
        .unwrap_or(0.0);
    let art_url = find(map, "mpris:artUrl").map(Value::text).filter(|s| !s.is_empty());
    let id = spotify_id(&object_path, find(map, "xesam:url").map(Value::text).as_deref());
    Some(Track {
        id,
        title: short_title(&title),
        artist: short_artist(&find(map, "xesam:artist").map(Value::text).unwrap_or_default()),
        album: find(map, "xesam:album").map(Value::text).unwrap_or_default(),
        duration,
        art_url,
        object_path,
    })
}

/// "/com/spotify/track/ID" → "spotify:track:ID", the id the Mac gets. Older
/// Spotify builds already gave "spotify:track:ID"; failing both, the page URL.
pub fn spotify_id(trackid: &str, url: Option<&str>) -> String {
    if trackid.starts_with("spotify:") {
        return trackid.to_string();
    }
    if let Some(rest) = trackid.strip_prefix("/com/spotify/") {
        let parts: Vec<&str> = rest.split('/').filter(|s| !s.is_empty()).collect();
        if parts.len() >= 2 {
            return format!("spotify:{}:{}", parts[0], parts[1..].join(":"));
        }
    }
    if let Some(rest) = url.and_then(|u| u.strip_prefix("https://open.spotify.com/")) {
        let parts: Vec<&str> = rest.split(['/', '?']).collect();
        if parts.len() >= 2 && !parts[0].is_empty() && !parts[1].is_empty() {
            return format!("spotify:{}:{}", parts[0], parts[1]);
        }
    }
    trackid.to_string()
}

/// "Song - Remastered 2011 (Live) [Mono]" → "Song" (SpotifyController.shortTitle).
pub fn short_title(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let mut s: &str = raw;
    if let Some(i) = s.find(" - ") {
        s = &s[..i];
    }
    loop {
        let t = s.trim();
        let Some(last) = t.chars().last() else { break };
        if last != ')' && last != ']' {
            break;
        }
        let open = if last == ')' { '(' } else { '[' };
        let Some(idx) = t.rfind(open) else { break };
        let candidate = t[..idx].trim();
        if candidate.is_empty() {
            break;
        }
        s = candidate;
    }
    let result = s.trim();
    if result.is_empty() { raw.to_string() } else { result.to_string() }
}

/// "Artist feat. Someone" → "Artist" (SpotifyController.shortArtist).
pub fn short_artist(raw: &str) -> String {
    if raw.is_empty() {
        return String::new();
    }
    let lower = raw.to_lowercase();
    for tag in [" feat.", " ft."] {
        if let Some(i) = lower.find(tag) {
            // Lowercasing can move byte offsets; only cut where it lines up.
            if lower.len() == raw.len() && raw.is_char_boundary(i) {
                let result = raw[..i].trim();
                return if result.is_empty() { raw.to_string() } else { result.to_string() };
            }
        }
    }
    raw.to_string()
}

// ── Artwork ───────────────────────────────────────────────────────────────────

/// Where a cover may be read from. The URL comes from another program: only
/// Spotify's own image CDN, or a local file (a local track's cover).
#[derive(Debug, PartialEq)]
pub enum ArtSource {
    Https(String),
    File(std::path::PathBuf),
}

pub fn artwork_source(raw: &str) -> Option<ArtSource> {
    // Some Spotify builds point at open.spotify.com/image/ID, which only
    // redirects to the CDN.
    let raw = match raw.strip_prefix("https://open.spotify.com/image/") {
        Some(id) => format!("https://i.scdn.co/image/{id}"),
        None => raw.to_string(),
    };
    let url = reqwest::Url::parse(&raw).ok()?;
    match url.scheme() {
        "https" => {
            let host = url.host_str()?.to_ascii_lowercase();
            let ours = host == "i.scdn.co" || host.ends_with(".scdn.co") || host.ends_with(".spotifycdn.com");
            (ours && url.port().is_none() && url.username().is_empty()).then(|| ArtSource::Https(url.to_string()))
        }
        "file" => {
            if url.host_str().is_some_and(|h| !h.is_empty() && h != "localhost") {
                return None;
            }
            let path = url.to_file_path().ok()?;
            path.is_absolute().then_some(ArtSource::File(path))
        }
        _ => None,
    }
}

/// The image type, from its first bytes — never from what the file claims.
pub fn sniff_image(bytes: &[u8]) -> Option<&'static str> {
    if bytes.starts_with(&[0xFF, 0xD8, 0xFF]) {
        Some("image/jpeg")
    } else if bytes.starts_with(b"\x89PNG\r\n\x1a\n") {
        Some("image/png")
    } else if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        Some("image/webp")
    } else if bytes.starts_with(b"GIF87a") || bytes.starts_with(b"GIF89a") {
        Some("image/gif")
    } else {
        None
    }
}

fn data_url(bytes: &[u8]) -> Option<String> {
    let mime = sniff_image(bytes)?;
    Some(format!("data:{mime};base64,{}", crate::claude::base64_for(bytes)))
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct Artwork {
    art_url: String,
    data_url: String,
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

fn emit_state(app: &AppHandle, state: &PlayerState) {
    use tauri::Emitter;
    let _ = app.emit_to(crate::island::WINDOW_LABEL, STATE_EVENT, state);
}

// ── Commands ──────────────────────────────────────────────────────────────────

/// The player as it is now, read again from Spotify (the card coming on
/// screen: seeks made in Spotify's own window are never signalled).
#[tauri::command]
pub async fn spotify_refresh(app: AppHandle) -> Option<PlayerState> {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux::refresh(&linux::Out::App(app))).await.ok().flatten()
    }
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(move || win::refresh(&app)).await.ok().flatten()
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        let _ = app;
        None
    }
}

/// A control from the card or the pill: `playPause`, `next`, `previous`,
/// `seek` (seconds), `shuffle` / `repeat` (1 on, 0 off), `volume` (0…100).
#[tauri::command]
pub async fn spotify_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux::control(&linux::Out::App(app), &action, value)).await.unwrap_or(false)
    }
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(move || win::control(&app, &action, value)).await.unwrap_or(false)
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        let _ = (app, action, value);
        false
    }
}

/// "Open Spotify": brings it forward, or starts it. Without Spotify, its
/// download page. True when Spotify was reached or started.
#[tauri::command]
pub async fn spotify_open() -> bool {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(linux::open).await.unwrap_or(false)
    }
    #[cfg(windows)]
    {
        tauri::async_runtime::spawn_blocking(win::open).await.unwrap_or(false)
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        false
    }
}

/// For Settings: whether there is a Spotify to launch.
#[tauri::command]
pub fn spotify_installed() -> bool {
    #[cfg(target_os = "linux")]
    {
        linux::installed()
    }
    #[cfg(windows)]
    {
        win::installed()
    }
    #[cfg(not(any(target_os = "linux", windows)))]
    {
        false
    }
}

/// Starts the listener when the pill is declared, stops it when it is not.
/// Called at launch and after every settings save.
pub fn sync(app: &AppHandle, active_integrations: &[String]) {
    let on = active_integrations.iter().any(|id| id == PILL_ID);
    #[cfg(target_os = "linux")]
    linux::sync(app, on);
    #[cfg(windows)]
    win::sync(app, on);
    #[cfg(not(any(target_os = "linux", windows)))]
    let _ = (app, on);
}

// ── Linux: MPRIS over D-Bus ───────────────────────────────────────────────────

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use std::collections::VecDeque;
    use std::path::PathBuf;
    use std::process::{Command, Stdio};
    use std::sync::{LazyLock, Mutex};
    use std::time::Duration;

    use dbus::arg::{ArgType, PropMap, RefArg};
    use dbus::blocking::stdintf::org_freedesktop_dbus::Properties;
    use dbus::blocking::Connection;
    use dbus::message::MessageType;
    use dbus::Message;
    use tauri::Emitter;

    const BUS: &str = "org.mpris.MediaPlayer2.spotify";
    const PATH: &str = "/org/mpris/MediaPlayer2";
    const ROOT: &str = "org.mpris.MediaPlayer2";
    const PLAYER: &str = "org.mpris.MediaPlayer2.Player";
    const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
    const DBUS: &str = "org.freedesktop.DBus";
    /// A call to Spotify never holds anything up for longer.
    const CALL: Duration = Duration::from_millis(1500);
    /// The listener sleeps on the bus; this only bounds a lost wake-up.
    const IDLE_WAIT: Duration = Duration::from_secs(3600);
    const FLATPAK_ID: &str = "com.spotify.Client";

    const RULES: [&str; 3] = [
        "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0='org.mpris.MediaPlayer2.spotify'",
        "type='signal',sender='org.mpris.MediaPlayer2.spotify',path='/org/mpris/MediaPlayer2',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'",
        "type='signal',sender='org.mpris.MediaPlayer2.spotify',path='/org/mpris/MediaPlayer2',interface='org.mpris.MediaPlayer2.Player',member='Seeked'",
    ];

    struct Shared {
        /// Bumped on every start and stop: a listener from an older one quits.
        generation: u64,
        active: bool,
        /// The listener's unique name, to wake it when it has to stop.
        listener: Option<String>,
        /// Spotify's unique name while it runs: signals from anyone else are ignored.
        owner: Option<String>,
        state: PlayerState,
    }

    static SHARED: LazyLock<Mutex<Shared>> = LazyLock::new(|| {
        Mutex::new(Shared { generation: 0, active: false, listener: None, owner: None, state: PlayerState::default() })
    });

    /// The connection the controls and reads go through, made on first use.
    static CONTROL: LazyLock<Mutex<Option<Connection>>> = LazyLock::new(|| Mutex::new(None));

    struct ArtCache {
        entries: VecDeque<(String, String)>,
        loading: Option<String>,
    }

    static ART: LazyLock<Mutex<ArtCache>> =
        LazyLock::new(|| Mutex::new(ArtCache { entries: VecDeque::new(), loading: None }));

    /// Where the listener's news goes: the island, or a test.
    #[derive(Clone)]
    pub enum Out {
        App(AppHandle),
        #[cfg(test)]
        Test(std::sync::mpsc::Sender<PlayerState>),
    }

    impl Out {
        fn state(&self, state: &PlayerState) {
            match self {
                Out::App(app) => {
                    emit_state(app, state);
                    want_artwork(app, state);
                }
                #[cfg(test)]
                Out::Test(tx) => {
                    let _ = tx.send(state.clone());
                }
            }
        }
    }

    // ── Values from the bus ───────────────────────────────────────────────────

    /// A D-Bus argument as a plain Value (variants unwrapped).
    pub fn value_of(arg: &dyn RefArg) -> Value {
        match arg.arg_type() {
            ArgType::Variant => arg.as_iter().and_then(|mut it| it.next().map(value_of)).unwrap_or(Value::Other),
            ArgType::String | ArgType::ObjectPath | ArgType::Signature => {
                arg.as_str().map(|s| Value::Str(s.to_string())).unwrap_or(Value::Other)
            }
            ArgType::Boolean => arg.as_i64().map(|n| Value::Bool(n != 0)).unwrap_or(Value::Other),
            ArgType::Double => arg.as_f64().map(Value::Float).unwrap_or(Value::Other),
            ArgType::UInt64 => arg.as_u64().map(|n| Value::Int(n.min(i64::MAX as u64) as i64)).unwrap_or(Value::Other),
            ArgType::Byte | ArgType::Int16 | ArgType::UInt16 | ArgType::Int32 | ArgType::UInt32 | ArgType::Int64 => {
                arg.as_i64().map(Value::Int).unwrap_or(Value::Other)
            }
            ArgType::Array => {
                let Some(items) = arg.as_iter() else { return Value::Other };
                if arg.signature().starts_with("a{") {
                    let mut map = Vec::new();
                    let mut items = items;
                    while let (Some(k), Some(v)) = (items.next(), items.next()) {
                        if let Some(key) = k.as_str() {
                            map.push((key.to_string(), value_of(v)));
                        }
                    }
                    Value::Map(map)
                } else {
                    Value::Strs(
                        items
                            .filter_map(|v| match value_of(v) {
                                Value::Str(s) => Some(s),
                                _ => None,
                            })
                            .collect(),
                    )
                }
            }
            _ => Value::Other,
        }
    }

    pub fn props_of(map: &PropMap) -> Vec<(String, Value)> {
        map.iter().map(|(k, v)| (k.clone(), value_of(&v.0))).collect()
    }

    // ── Start / stop ──────────────────────────────────────────────────────────

    pub fn sync(app: &AppHandle, on: bool) {
        set_active(Out::App(app.clone()), on);
    }

    pub fn set_active(out: Out, on: bool) {
        let wake = {
            let mut s = SHARED.lock().unwrap();
            if s.active == on {
                return;
            }
            s.active = on;
            s.generation += 1;
            s.owner = None;
            s.state = PlayerState { installed: installed(), ..PlayerState::default() };
            s.listener.take()
        };
        if on {
            let generation = SHARED.lock().unwrap().generation;
            let spawned = std::thread::Builder::new()
                .name("coucou-spotify".into())
                .spawn(move || listen(out, generation));
            if let Err(err) = spawned {
                crate::log::line(format!("spotify: no listener thread: {err}"));
            }
        } else {
            if let Some(name) = wake {
                wake_listener(&name);
            }
            let state = SHARED.lock().unwrap().state.clone();
            out.state(&state);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    /// Any message to its unique name gets the listener off the bus.
    fn wake_listener(name: &str) {
        let Ok(msg) = Message::new_method_call(name, "/", "org.freedesktop.DBus.Peer", "Ping") else { return };
        let mut msg = msg;
        msg.set_no_reply(true);
        with_control(|c| {
            let _ = c.channel().send(msg);
            c.channel().flush();
            Ok(())
        });
    }

    /// Listener threads alive (tests: turning the pill off really ends one).
    #[cfg(test)]
    static ALIVE: std::sync::atomic::AtomicUsize = std::sync::atomic::AtomicUsize::new(0);

    fn listen(out: Out, generation: u64) {
        #[cfg(test)]
        ALIVE.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
        listen_on_bus(out, generation);
        #[cfg(test)]
        ALIVE.fetch_sub(1, std::sync::atomic::Ordering::SeqCst);
    }

    fn listen_on_bus(out: Out, generation: u64) {
        let conn = match Connection::new_session() {
            Ok(c) => c,
            Err(err) => {
                crate::log::line(format!("spotify: no session bus: {err}"));
                return;
            }
        };
        {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return;
            }
            s.listener = Some(conn.unique_name().to_string());
        }
        for rule in RULES {
            if let Err(err) = conn.add_match_no_cb(rule) {
                crate::log::line(format!("spotify: match refused: {err}"));
            }
        }
        // Spotify may have started before the pill was declared.
        read_everything(&conn, &out, generation);

        while current(generation) {
            match conn.channel().blocking_pop_message(IDLE_WAIT) {
                Ok(Some(msg)) => handle(&conn, &out, generation, &msg),
                Ok(None) => {}
                Err(err) => {
                    crate::log::line(format!("spotify: bus lost: {err}"));
                    break;
                }
            }
        }
    }

    fn handle(conn: &Connection, out: &Out, generation: u64, msg: &Message) {
        if msg.msg_type() != MessageType::Signal || !current(generation) {
            return;
        }
        let interface = msg.interface().map(|i| i.to_string()).unwrap_or_default();
        let member = msg.member().map(|m| m.to_string()).unwrap_or_default();
        let sender = msg.sender().map(|s| s.to_string());

        match (interface.as_str(), member.as_str()) {
            (DBUS, "NameOwnerChanged") => {
                let Ok((name, _old, new)) = msg.read3::<String, String, String>() else { return };
                if name != BUS {
                    return;
                }
                if new.is_empty() {
                    // Spotify quit: nothing is playing anymore.
                    let state = {
                        let mut s = SHARED.lock().unwrap();
                        s.owner = None;
                        s.state.running = false;
                        s.state.clear(now_ms());
                        s.state.clone()
                    };
                    out.state(&state);
                } else {
                    read_everything(conn, out, generation);
                }
            }
            (PROPERTIES, "PropertiesChanged") => {
                if !from_owner(sender.as_deref()) {
                    return;
                }
                let Ok((iface, changed, invalidated)) = msg.read3::<String, PropMap, Vec<String>>() else { return };
                if iface != PLAYER {
                    return;
                }
                let mut props = props_of(&changed);
                // Properties that changed without their value: read them.
                for name in invalidated {
                    if let Some(v) = get_property(conn, &name) {
                        props.push((name, v));
                    }
                }
                apply_and_emit(conn, out, &props);
            }
            (PLAYER, "Seeked") => {
                if !from_owner(sender.as_deref()) {
                    return;
                }
                let Ok(us) = msg.read1::<i64>() else { return };
                apply_and_emit(conn, out, &[("Position".into(), Value::Int(us))]);
            }
            _ => {}
        }
    }

    fn from_owner(sender: Option<&str>) -> bool {
        let s = SHARED.lock().unwrap();
        match (&s.owner, sender) {
            (Some(owner), Some(sender)) => owner == sender,
            // The owner isn't known yet: the bus only routes Spotify's to us.
            (None, _) => true,
            _ => false,
        }
    }

    /// Applies a change; when the status or the track moved, reads the
    /// position (never signalled), then tells the island.
    fn apply_and_emit(conn: &Connection, out: &Out, props: &[(String, Value)]) {
        let applied = SHARED.lock().unwrap().state.apply(props, now_ms());
        if (applied.status_changed || applied.track_changed) && !applied.position_set {
            if let Some(position) = get_property(conn, "Position") {
                SHARED.lock().unwrap().state.apply(&[("Position".into(), position)], now_ms());
            }
        }
        let state = SHARED.lock().unwrap().state.clone();
        out.state(&state);
    }

    fn get_property(conn: &Connection, name: &str) -> Option<Value> {
        let proxy = conn.with_proxy(BUS, PATH, CALL);
        let v: Box<dyn RefArg> = proxy.get(PLAYER, name).ok()?;
        Some(value_of(&v))
    }

    fn name_owner(conn: &Connection) -> Option<String> {
        let proxy = conn.with_proxy(DBUS, "/org/freedesktop/DBus", CALL);
        let (owner,): (String,) = proxy.method_call(DBUS, "GetNameOwner", (BUS,)).ok()?;
        Some(owner)
    }

    /// Whom Spotify is, and all of its Player properties.
    fn read_everything(conn: &Connection, out: &Out, generation: u64) {
        let owner = name_owner(conn);
        let props = owner.as_ref().and_then(|_| {
            let proxy = conn.with_proxy(BUS, PATH, CALL);
            proxy.get_all(PLAYER).ok().map(|m| props_of(&m))
        });
        let state = {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return;
            }
            s.owner = owner.clone();
            s.state.running = owner.is_some();
            s.state.installed = owner.is_some() || installed();
            let now = now_ms();
            match props {
                Some(props) => {
                    s.state.apply(&props, now);
                }
                None => s.state.clear(now),
            }
            s.state.clone()
        };
        out.state(&state);
    }

    /// Runs `f` on the control connection, made (again) when needed.
    fn with_control<R>(f: impl FnOnce(&Connection) -> Result<R, dbus::Error>) -> Option<R> {
        let mut slot = CONTROL.lock().unwrap();
        if slot.as_ref().is_none_or(|c| !c.channel().is_connected()) {
            *slot = Connection::new_session().ok();
        }
        let conn = slot.as_ref()?;
        f(conn).ok()
    }

    pub fn refresh(out: &Out) -> Option<PlayerState> {
        let generation = {
            let s = SHARED.lock().unwrap();
            if !s.active {
                return None;
            }
            s.generation
        };
        let read = with_control(|c| {
            let owner = name_owner(c);
            let props = match owner {
                Some(_) => Some(props_of(&c.with_proxy(BUS, PATH, CALL).get_all(PLAYER)?)),
                None => None,
            };
            Ok((owner, props))
        });
        let state = {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return None;
            }
            if let Some((owner, props)) = read {
                s.owner = owner.clone();
                s.state.running = owner.is_some();
                s.state.installed = owner.is_some() || installed();
                let now = now_ms();
                match props {
                    Some(props) => {
                        s.state.apply(&props, now);
                    }
                    None => s.state.clear(now),
                }
            }
            s.state.clone()
        };
        out.state(&state);
        Some(state)
    }

    pub fn control(out: &Out, action: &str, value: Option<f64>) -> bool {
        let (active, state) = {
            let s = SHARED.lock().unwrap();
            (s.active && s.owner.is_some(), s.state.clone())
        };
        if !active {
            return false;
        }
        let v = value.unwrap_or(0.0);
        let now = now_ms();
        let done = with_control(|c| {
            let p = c.with_proxy(BUS, PATH, CALL);
            match action {
                "playPause" => p.method_call(PLAYER, "PlayPause", ()),
                "next" => p.method_call(PLAYER, "Next", ()),
                "previous" => p.method_call(PLAYER, "Previous", ()),
                "seek" => {
                    let Some(track) = state.track.as_ref() else { return Err(dbus::Error::new_failed("no track")) };
                    let target = v.clamp(0.0, (track.duration - 1.0).max(0.0));
                    let target_us = (target * 1_000_000.0) as i64;
                    match dbus::Path::new(track.object_path.clone()) {
                        Ok(path) => p.method_call(PLAYER, "SetPosition", (path, target_us)),
                        // Not an object path (old Spotify builds): seek by the difference.
                        Err(_) => {
                            let from = (state.position_at_time(now) * 1_000_000.0) as i64;
                            p.method_call(PLAYER, "Seek", (target_us - from,))
                        }
                    }
                }
                "shuffle" => p.set(PLAYER, "Shuffle", v != 0.0),
                "repeat" => p.set(PLAYER, "LoopStatus", if v != 0.0 { "Playlist" } else { "None" }),
                "volume" => p.set(PLAYER, "Volume", (v / 100.0).clamp(0.0, 1.0)),
                _ => Err(dbus::Error::new_failed("unknown action")),
            }
        })
        .is_some();
        if !done {
            return false;
        }
        // Spotify doesn't always signal these: show them at once, as the Mac does.
        let optimistic: Option<(String, Value)> = match action {
            "seek" => state.track.as_ref().map(|t| {
                let target = v.clamp(0.0, (t.duration - 1.0).max(0.0));
                ("Position".into(), Value::Int((target * 1_000_000.0) as i64))
            }),
            "shuffle" => Some(("Shuffle".into(), Value::Bool(v != 0.0))),
            "repeat" => Some(("LoopStatus".into(), Value::Str(if v != 0.0 { "Playlist" } else { "None" }.into()))),
            "volume" => Some(("Volume".into(), Value::Float((v / 100.0).clamp(0.0, 1.0)))),
            _ => None,
        };
        if let Some(prop) = optimistic {
            let state = {
                let mut s = SHARED.lock().unwrap();
                s.state.apply(&[prop], now_ms());
                s.state.clone()
            };
            out.state(&state);
        }
        true
    }

    // ── Launching ─────────────────────────────────────────────────────────────

    /// How to start Spotify: the `spotify` on PATH, else the Flatpak, else the Snap.
    fn launcher() -> Option<Vec<std::ffi::OsString>> {
        if let Some(bin) = crate::platform::find_on_path("spotify") {
            return Some(vec![bin.into()]);
        }
        let home = crate::platform::home_dir();
        let flatpak = [
            PathBuf::from("/var/lib/flatpak/app").join(FLATPAK_ID),
            home.join(".local/share/flatpak/app").join(FLATPAK_ID),
        ];
        if flatpak.iter().any(|p| p.is_dir()) {
            if let Some(bin) = crate::platform::find_on_path("flatpak") {
                return Some(vec![bin.into(), "run".into(), FLATPAK_ID.into()]);
            }
        }
        let snap = PathBuf::from("/snap/bin/spotify");
        if snap.is_file() {
            return Some(vec![snap.into()]);
        }
        None
    }

    pub fn installed() -> bool {
        launcher().is_some()
    }

    pub fn open() -> bool {
        // Running: bring it forward when it says it can.
        let raised = with_control(|c| {
            if name_owner(c).is_none() {
                return Ok(false);
            }
            let p = c.with_proxy(BUS, PATH, CALL);
            let can: bool = p.get(ROOT, "CanRaise").unwrap_or(false);
            if can {
                p.method_call::<(), _, _, _>(ROOT, "Raise", ())?;
            }
            Ok(can)
        })
        .unwrap_or(false);
        if raised {
            return true;
        }
        // Otherwise start it; a second `spotify` brings the running one forward.
        if let Some(argv) = launcher() {
            use std::os::unix::process::CommandExt;
            let mut cmd = Command::new(&argv[0]);
            cmd.args(&argv[1..])
                .stdin(Stdio::null())
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .process_group(0);
            match cmd.spawn() {
                Ok(mut child) => {
                    // Reaped when it exits, so it never lingers as a zombie.
                    let _ = std::thread::Builder::new()
                        .name("coucou-spotify-child".into())
                        .spawn(move || {
                            let _ = child.wait();
                        });
                    return true;
                }
                Err(err) => crate::log::line(format!("spotify: could not start it: {err}")),
            }
        }
        crate::platform::open_url(DOWNLOAD_URL);
        false
    }

    // ── Artwork ───────────────────────────────────────────────────────────────

    /// The current track's cover, as a data URL: the page may not load a remote
    /// image (CSP), and only Spotify's CDN or a local file is read.
    fn want_artwork(app: &AppHandle, state: &PlayerState) {
        let Some(url) = state.track.as_ref().and_then(|t| t.art_url.clone()) else { return };
        {
            let mut art = ART.lock().unwrap();
            if let Some((_, data)) = art.entries.iter().find(|(u, _)| *u == url) {
                let _ = app.emit_to(
                    crate::island::WINDOW_LABEL,
                    ARTWORK_EVENT,
                    Artwork { art_url: url.clone(), data_url: data.clone() },
                );
                return;
            }
            if art.loading.as_deref() == Some(url.as_str()) {
                return;
            }
            art.loading = Some(url.clone());
        }
        let app = app.clone();
        match artwork_source(&url) {
            Some(ArtSource::Https(remote)) => {
                // Pause means nothing reaches the network.
                if crate::integrations::PAUSED.load(std::sync::atomic::Ordering::Relaxed) {
                    ART.lock().unwrap().loading = None;
                    return;
                }
                tauri::async_runtime::spawn(async move {
                    let bytes = fetch(&remote).await;
                    finish_artwork(&app, url, bytes);
                });
            }
            Some(ArtSource::File(path)) => {
                tauri::async_runtime::spawn_blocking(move || {
                    let bytes = std::fs::metadata(&path)
                        .ok()
                        .filter(|m| m.is_file() && m.len() as usize <= ARTWORK_LIMIT)
                        .and_then(|_| std::fs::read(&path).ok());
                    finish_artwork(&app, url, bytes);
                });
            }
            None => {
                ART.lock().unwrap().loading = None;
            }
        }
    }

    async fn fetch(url: &str) -> Option<Vec<u8>> {
        let client = reqwest::Client::builder()
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .ok()?;
        let response = client.get(url).send().await.ok()?;
        if !response.status().is_success() {
            return None;
        }
        crate::net::read_capped(response, ARTWORK_LIMIT).await.ok()
    }

    fn finish_artwork(app: &AppHandle, url: String, bytes: Option<Vec<u8>>) {
        let data = bytes.as_deref().and_then(data_url);
        let mut art = ART.lock().unwrap();
        if art.loading.as_deref() == Some(url.as_str()) {
            art.loading = None;
        }
        let Some(data) = data else { return };
        art.entries.retain(|(u, _)| *u != url);
        art.entries.push_back((url.clone(), data.clone()));
        while art.entries.len() > 12 {
            art.entries.pop_front();
        }
        drop(art);
        // Only if it is still the track on screen.
        let current = SHARED.lock().unwrap().state.track.as_ref().and_then(|t| t.art_url.clone());
        if current.as_deref() == Some(url.as_str()) {
            let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: url, data_url: data });
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;
        use dbus::arg::Variant;
        use std::collections::HashMap;
        use std::sync::atomic::{AtomicBool, Ordering};
        use std::sync::Arc;

        fn var<T: RefArg + 'static>(v: T) -> Variant<Box<dyn RefArg>> {
            Variant(Box::new(v))
        }

        #[test]
        fn dbus_variants_become_plain_values() {
            assert_eq!(value_of(&var("Playing".to_string())), Value::Str("Playing".into()));
            assert_eq!(value_of(&var(true)), Value::Bool(true));
            assert_eq!(value_of(&var(0.5f64)), Value::Float(0.5));
            assert_eq!(value_of(&var(42u64)), Value::Int(42));
            assert_eq!(value_of(&var(-7i64)), Value::Int(-7));
            assert_eq!(value_of(&var(3i32)), Value::Int(3));
            assert_eq!(
                value_of(&var(dbus::Path::new("/com/spotify/track/abc").unwrap())),
                Value::Str("/com/spotify/track/abc".into())
            );
            assert_eq!(
                value_of(&var(vec!["A".to_string(), "B".to_string()])),
                Value::Strs(vec!["A".into(), "B".into()])
            );
        }

        #[test]
        fn spotify_metadata_from_the_bus_parses_into_a_track() {
            // What Spotify 1.2 sends, types included.
            let mut meta: PropMap = HashMap::new();
            meta.insert("mpris:trackid".into(), var(dbus::Path::new("/com/spotify/track/4uLU6hMCjMI75M1A2tKUQC").unwrap()));
            meta.insert("mpris:length".into(), var(213_000_000u64));
            meta.insert("mpris:artUrl".into(), var("https://i.scdn.co/image/ab67616d0000b273abc".to_string()));
            meta.insert("xesam:title".into(), var("Never Gonna Give You Up - Remastered 2022".to_string()));
            meta.insert("xesam:artist".into(), var(vec!["Rick Astley".to_string()]));
            meta.insert("xesam:album".into(), var("Whenever You Need Somebody".to_string()));
            meta.insert("xesam:url".into(), var("https://open.spotify.com/track/4uLU6hMCjMI75M1A2tKUQC".to_string()));
            let mut props: PropMap = HashMap::new();
            props.insert("Metadata".into(), var(meta));
            props.insert("PlaybackStatus".into(), var("Playing".to_string()));
            props.insert("Shuffle".into(), var(true));
            props.insert("LoopStatus".into(), var("Track".to_string()));
            props.insert("Volume".into(), var(0.42f64));
            props.insert("Position".into(), var(12_500_000i64));

            let mut state = PlayerState::default();
            let applied = state.apply(&props_of(&props), 1_000.0);
            assert!(applied.track_changed && applied.status_changed && applied.position_set);
            let track = state.track.clone().unwrap();
            assert_eq!(track.id, "spotify:track:4uLU6hMCjMI75M1A2tKUQC");
            assert_eq!(track.title, "Never Gonna Give You Up");
            assert_eq!(track.artist, "Rick Astley");
            assert_eq!(track.album, "Whenever You Need Somebody");
            assert_eq!(track.duration, 213.0);
            assert_eq!(track.art_url.as_deref(), Some("https://i.scdn.co/image/ab67616d0000b273abc"));
            assert_eq!(track.object_path, "/com/spotify/track/4uLU6hMCjMI75M1A2tKUQC");
            assert!(state.playing && state.shuffle && state.repeat);
            assert_eq!(state.volume, 42);
            assert_eq!(state.position, 12.5);
            assert_eq!(state.position_at, 1_000.0);
        }

        /// End to end against a fake Spotify on a private session bus:
        /// `dbus-run-session -- cargo test -p coucou --lib spotify -- --ignored`
        #[test]
        #[ignore]
        fn the_listener_follows_and_drives_a_fake_spotify_over_the_session_bus() {
            let calls = Arc::new(Mutex::new(Vec::<String>::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let service = {
                let calls = calls.clone();
                let stop = stop.clone();
                std::thread::spawn(move || fake_spotify(calls, stop))
            };
            std::thread::sleep(Duration::from_millis(300));

            let (tx, rx) = std::sync::mpsc::channel();
            let out = Out::Test(tx);
            let next = || rx.recv_timeout(Duration::from_secs(3)).expect("a state from the listener");

            // Declared: the listener reads what is already playing.
            set_active(out.clone(), true);
            let state = next();
            assert!(state.running);
            let track = state.track.clone().unwrap();
            assert_eq!(track.id, "spotify:track:fake1");
            assert_eq!(track.title, "Fake Song");
            assert_eq!(track.artist, "Fake Artist, Guest");
            assert_eq!(track.duration, 180.0);
            assert!(state.playing);
            assert_eq!(state.volume, 80);
            assert_eq!(state.position, 30.0);

            // A control goes out; Spotify's PropertiesChanged comes back, and
            // the position is read again because the status moved.
            assert!(control(&out, "playPause", None));
            let state = next();
            assert!(!state.playing);
            assert_eq!(state.position, 31.0);

            assert!(control(&out, "seek", Some(60.0)));
            assert_eq!(next().position, 60.0);
            assert!(control(&out, "shuffle", Some(1.0)));
            assert!(next().shuffle);
            assert!(control(&out, "volume", Some(25.0)));
            assert_eq!(next().volume, 25);
            assert!(!control(&out, "dance", None));
            assert_eq!(
                *calls.lock().unwrap(),
                vec!["PlayPause", "SetPosition /com/spotify/track/fake1 60000000", "Set Shuffle", "Set Volume"]
            );

            // Spotify quits: nothing plays any more.
            stop.store(true, Ordering::Relaxed);
            let _ = service.join();
            let state = next();
            assert!(!state.running);
            assert_eq!(state.track, None);
            assert!(!control(&out, "next", None));

            // Undeclared: the thread leaves the bus at once.
            set_active(out.clone(), false);
            let _ = next();
            let deadline = std::time::Instant::now() + Duration::from_secs(3);
            while ALIVE.load(Ordering::SeqCst) > 0 && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(ALIVE.load(Ordering::SeqCst), 0);
            assert_eq!(refresh(&out), None);
        }

        /// A minimal MPRIS player: GetAll, Get, Set and the Player methods,
        /// signalling its status like Spotify. Releases its name when told to stop.
        fn fake_spotify(calls: Arc<Mutex<Vec<String>>>, stop: Arc<AtomicBool>) {
            let conn = Connection::new_session().unwrap();
            conn.request_name(BUS, false, true, true).unwrap();
            let mut playing = true;
            let mut position: i64 = 30_000_000;
            let player = |playing: bool, position: i64| {
                let mut meta: PropMap = HashMap::new();
                meta.insert("mpris:trackid".into(), var(dbus::Path::new("/com/spotify/track/fake1").unwrap()));
                meta.insert("mpris:length".into(), var(180_000_000u64));
                meta.insert("xesam:title".into(), var("Fake Song (Live)".to_string()));
                meta.insert("xesam:artist".into(), var(vec!["Fake Artist".to_string(), "Guest".to_string()]));
                meta.insert("xesam:album".into(), var("Fake Album".to_string()));
                let mut props: PropMap = HashMap::new();
                props.insert("Metadata".into(), var(meta));
                props.insert("PlaybackStatus".into(), var(if playing { "Playing" } else { "Paused" }.to_string()));
                props.insert("Volume".into(), var(0.8f64));
                props.insert("Position".into(), var(position));
                props
            };
            while !stop.load(Ordering::Relaxed) {
                let Ok(Some(msg)) = conn.channel().blocking_pop_message(Duration::from_millis(50)) else { continue };
                if msg.msg_type() != MessageType::MethodCall {
                    continue;
                }
                let member = msg.member().map(|m| m.to_string()).unwrap_or_default();
                let mut signal = None;
                let reply = match member.as_str() {
                    "GetAll" => msg.method_return().append1(player(playing, position)),
                    "Get" => {
                        let (_, name): (String, String) = msg.read2().unwrap();
                        let props = player(playing, position);
                        match props.get(&name) {
                            Some(v) => msg.method_return().append1(var(value_box(&v.0))),
                            None => Message::error(
                                &msg,
                                &"org.freedesktop.DBus.Error.UnknownProperty".into(),
                                &std::ffi::CString::new("no").unwrap(),
                            ),
                        }
                    }
                    "Set" => {
                        let (_, name): (String, String) = msg.read2().unwrap();
                        calls.lock().unwrap().push(format!("Set {name}"));
                        msg.method_return()
                    }
                    "SetPosition" => {
                        let (path, us): (dbus::Path, i64) = msg.read2().unwrap();
                        calls.lock().unwrap().push(format!("SetPosition {path} {us}"));
                        position = us;
                        msg.method_return()
                    }
                    "PlayPause" => {
                        calls.lock().unwrap().push("PlayPause".into());
                        playing = !playing;
                        position += 1_000_000;
                        let mut changed: PropMap = HashMap::new();
                        changed.insert(
                            "PlaybackStatus".into(),
                            var(if playing { "Playing" } else { "Paused" }.to_string()),
                        );
                        signal = Some(
                            Message::new_signal(PATH, PROPERTIES, "PropertiesChanged")
                                .unwrap()
                                .append3(PLAYER, changed, Vec::<String>::new()),
                        );
                        msg.method_return()
                    }
                    other => {
                        calls.lock().unwrap().push(other.to_string());
                        msg.method_return()
                    }
                };
                let _ = conn.channel().send(reply);
                if let Some(signal) = signal {
                    let _ = conn.channel().send(signal);
                }
            }
            let _ = conn.release_name(BUS);
            conn.channel().flush();
        }

        fn value_box(v: &Box<dyn RefArg>) -> Box<dyn RefArg> {
            v.box_clone()
        }
    }
}

// ── Windows: the system media controls ────────────────────────────────────────
//
// Spotify for Windows publishes what it plays to the system media transport
// controls (the overlay the media keys show). Windows hands that session to
// any app through GlobalSystemMediaTransportControlsSessionManager: track,
// thumbnail, status, timeline, shuffle and repeat as properties with change
// events, and play/pause, skip, seek, shuffle and repeat as requests. The
// volume isn't part of it; it is Spotify's own volume in the Windows mixer
// (Core Audio), read whenever the rest is.

/// The media session ids Spotify registers: "Spotify.exe" (the installer from
/// spotify.com) or "SpotifyAB.SpotifyMusic_…!Spotify" (the Microsoft Store).
pub fn is_spotify_app(app_id: &str) -> bool {
    app_id.to_ascii_lowercase().contains("spotify")
}

/// Windows durations and timeline positions: 100 ns ticks → seconds.
pub fn ticks_to_secs(ticks: i64) -> f64 {
    ticks.max(0) as f64 / 10_000_000.0
}

/// A Windows DateTime (100 ns ticks since 1601) → Unix milliseconds. Zero is
/// "never updated".
pub fn windows_time_to_unix_ms(universal: i64) -> Option<f64> {
    const UNIX_EPOCH_TICKS: i64 = 116_444_736_000_000_000;
    (universal > 0).then(|| (universal - UNIX_EPOCH_TICKS) as f64 / 10_000.0)
}

/// What the media session says about the track → the track, or None when
/// nothing is loaded. Windows gives no Spotify URI, so the id is made from the
/// tags; an ad comes with a title and nothing else, and gets an ad id so the
/// page treats it as the Mac does.
pub fn windows_track(title: &str, artist: &str, album: &str, duration: f64) -> Option<Track> {
    let title = title.trim();
    if title.is_empty() {
        return None;
    }
    let artist = artist.trim();
    let album = album.trim();
    let kind = if artist.is_empty() && album.is_empty() { "ad" } else { "track" };
    // FNV-1a: a short, stable id for the same tags.
    let mut hash: u64 = 0xcbf2_9ce4_8422_2325;
    for byte in [artist, album, title].join("\u{1f}").bytes() {
        hash ^= byte as u64;
        hash = hash.wrapping_mul(0x0100_0000_01b3);
    }
    Some(Track {
        id: format!("spotify:{kind}:{hash:016x}"),
        title: short_title(title),
        artist: short_artist(artist),
        album: album.to_string(),
        duration: duration.max(0.0),
        // Not a URL: the thumbnail is read from the session itself. The page
        // only uses it to match a cover to its track.
        art_url: Some(format!("smtc:{hash:016x}")),
        object_path: String::new(),
    })
}

#[cfg(windows)]
mod win {
    use super::*;
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
        eMultimedia, eRender, IAudioSessionControl2, IAudioSessionManager2, IMMDeviceEnumerator, ISimpleAudioVolume,
        MMDeviceEnumerator,
    };
    use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_ALL, COINIT_MULTITHREADED};
    use windows::Win32::System::Threading::{
        OpenProcess, QueryFullProcessImageNameW, PROCESS_NAME_WIN32, PROCESS_QUERY_LIMITED_INFORMATION,
    };

    /// What wakes the listener.
    enum Wake {
        /// The session's track, status or timeline moved.
        Changed,
        /// A player appeared or went away: find Spotify's session again.
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

    static SHARED: LazyLock<Mutex<Shared>> =
        LazyLock::new(|| Mutex::new(Shared { generation: 0, active: false, wake: None, state: PlayerState::default() }));

    /// Covers already read, by the track's art key; the newest last.
    static ART: LazyLock<Mutex<VecDeque<(String, String)>>> = LazyLock::new(|| Mutex::new(VecDeque::new()));

    /// WinRT and Core Audio need COM on the calling thread. A thread that has it
    /// already, in either model, keeps it.
    fn com() {
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    // ── Start / stop ──────────────────────────────────────────────────────────

    pub fn sync(app: &AppHandle, on: bool) {
        let (tx, rx) = mpsc::channel();
        let (old, generation, state) = {
            let mut s = SHARED.lock().unwrap();
            if s.active == on {
                return;
            }
            s.active = on;
            s.generation += 1;
            s.state = PlayerState { installed: installed(), ..PlayerState::default() };
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
                .name("coucou-spotify".into())
                .spawn(move || listen(app, generation, tx, rx));
            if let Err(err) = spawned {
                crate::log::line(format!("spotify: no listener thread: {err}"));
            }
        } else {
            emit_state(app, &state);
        }
    }

    /// Waits on the session's events and tells the island what changed. Nothing
    /// runs between events.
    fn listen(app: AppHandle, generation: u64, tx: Sender<Wake>, rx: Receiver<Wake>) {
        com();
        let manager = match Manager::RequestAsync().and_then(|op| op.get()) {
            Ok(m) => m,
            Err(err) => {
                crate::log::line(format!("spotify: no media sessions: {err}"));
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
        while current(generation) {
            if rebind {
                if let Some(b) = bound.take() {
                    b.unbind();
                }
                bound = find_session(&manager).and_then(|s| Bound::bind(s, &tx));
                rebind = false;
            }
            read_and_emit(&app, generation, bound.as_ref().map(|b| &b.session));

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

    /// Spotify's session, with the event handlers that wake the listener.
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

    fn find_session(manager: &Manager) -> Option<Session> {
        let sessions = manager.GetSessions().ok()?;
        (0..sessions.Size().ok()?)
            .filter_map(|i| sessions.GetAt(i).ok())
            .find(|s| s.SourceAppUserModelId().is_ok_and(|id| is_spotify_app(&id.to_string_lossy())))
    }

    // ── Reading ───────────────────────────────────────────────────────────────

    /// Everything the session says, as it is now.
    struct Snapshot {
        track: Option<Track>,
        playing: bool,
        position: f64,
        /// When Windows last updated the position (Unix ms), if it says.
        updated_at: Option<f64>,
        shuffle: bool,
        repeat: bool,
    }

    fn snapshot(session: &Session) -> windows::core::Result<(Snapshot, MediaProperties)> {
        let props = session.TryGetMediaPropertiesAsync()?.get()?;
        let timeline = session.GetTimelineProperties()?;
        let start = timeline.StartTime()?.Duration;
        let duration = ticks_to_secs(timeline.EndTime()?.Duration - start);
        let track = windows_track(
            &props.Title()?.to_string_lossy(),
            &props.Artist()?.to_string_lossy(),
            &props.AlbumTitle()?.to_string_lossy(),
            duration,
        );
        let info = session.GetPlaybackInfo()?;
        let snapshot = Snapshot {
            playing: info.PlaybackStatus()? == Status::Playing && track.is_some(),
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

    fn read_and_emit(app: &AppHandle, generation: u64, session: Option<&Session>) {
        let read = session.and_then(|s| snapshot(s).ok());
        let volume = read.as_ref().and_then(|_| spotify_volume());
        let now = now_ms();
        let (state, props) = {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return;
            }
            let props = match read {
                Some((snap, props)) => {
                    s.state.running = true;
                    s.state.installed = true;
                    s.state.track = snap.track;
                    s.state.playing = snap.playing;
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
                    s.state.installed = installed();
                    s.state.clear(now);
                    None
                }
            };
            (s.state.clone(), props)
        };
        emit_state(app, &state);
        if let (Some(props), Some(track)) = (props, state.track.as_ref()) {
            artwork(app, track, &props);
        }
    }

    // ── Artwork ───────────────────────────────────────────────────────────────

    /// The track's cover, as a data URL (the page may not load anything
    /// remote). Read once per track; Spotify sometimes adds the thumbnail a
    /// moment after the title, and the next event brings it then.
    fn artwork(app: &AppHandle, track: &Track, props: &MediaProperties) {
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
        let _ = app.emit_to(crate::island::WINDOW_LABEL, ARTWORK_EVENT, Artwork { art_url: key, data_url: data });
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

    // ── Volume: Spotify in the Windows mixer ──────────────────────────────────

    /// Spotify's audio sessions on the default output.
    fn spotify_audio() -> Vec<ISimpleAudioVolume> {
        com();
        let mut out = Vec::new();
        unsafe {
            let Ok(devices) = CoCreateInstance::<_, IMMDeviceEnumerator>(&MMDeviceEnumerator, None, CLSCTX_ALL) else {
                return out;
            };
            let Ok(device) = devices.GetDefaultAudioEndpoint(eRender, eMultimedia) else { return out };
            let Ok(manager) = device.Activate::<IAudioSessionManager2>(CLSCTX_ALL, None) else { return out };
            let Ok(sessions) = manager.GetSessionEnumerator() else { return out };
            for i in 0..sessions.GetCount().unwrap_or(0) {
                let Ok(control) = sessions.GetSession(i) else { continue };
                let Ok(control) = control.cast::<IAudioSessionControl2>() else { continue };
                let pid = control.GetProcessId().unwrap_or(0);
                if pid != 0 && is_spotify_process(pid) {
                    if let Ok(volume) = control.cast::<ISimpleAudioVolume>() {
                        out.push(volume);
                    }
                }
            }
        }
        out
    }

    fn is_spotify_process(pid: u32) -> bool {
        unsafe {
            let Ok(process) = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, false, pid) else { return false };
            let mut buf = [0u16; 1024];
            let mut len = buf.len() as u32;
            let named = QueryFullProcessImageNameW(process, PROCESS_NAME_WIN32, windows::core::PWSTR(buf.as_mut_ptr()), &mut len);
            let _ = CloseHandle(process);
            if named.is_err() {
                return false;
            }
            let path = String::from_utf16_lossy(&buf[..len as usize]);
            path.rsplit(['\\', '/']).next().is_some_and(|name| name.eq_ignore_ascii_case("spotify.exe"))
        }
    }

    /// 0…100, or None while Spotify has no audio session (nothing played yet).
    fn spotify_volume() -> Option<i32> {
        let level = unsafe { spotify_audio().first()?.GetMasterVolume().ok()? };
        Some((level * 100.0).round().clamp(0.0, 100.0) as i32)
    }

    fn set_spotify_volume(percent: f64) -> bool {
        let level = (percent / 100.0).clamp(0.0, 1.0) as f32;
        let sessions = spotify_audio();
        let mut done = false;
        for volume in &sessions {
            done |= unsafe { volume.SetMasterVolume(level, std::ptr::null()).is_ok() };
        }
        done
    }

    // ── Commands ──────────────────────────────────────────────────────────────

    pub fn refresh(app: &AppHandle) -> Option<PlayerState> {
        let generation = {
            let s = SHARED.lock().unwrap();
            if !s.active {
                return None;
            }
            s.generation
        };
        com();
        let manager = Manager::RequestAsync().and_then(|op| op.get()).ok();
        let session = manager.as_ref().and_then(find_session);
        read_and_emit(app, generation, session.as_ref());
        let s = SHARED.lock().unwrap();
        (s.active && s.generation == generation).then(|| s.state.clone())
    }

    pub fn control(app: &AppHandle, action: &str, value: Option<f64>) -> bool {
        let state = {
            let s = SHARED.lock().unwrap();
            if !(s.active && s.state.running) {
                return false;
            }
            s.state.clone()
        };
        com();
        let Some(session) = Manager::RequestAsync().and_then(|op| op.get()).ok().and_then(|m| find_session(&m)) else {
            return false;
        };
        let v = value.unwrap_or(0.0);
        // A request Windows passed on, and the player said yes to.
        macro_rules! asked {
            ($op:expr) => {
                $op.and_then(|op| op.get()).unwrap_or(false)
            };
        }
        let seek_to = state.track.as_ref().map(|t| v.clamp(0.0, (t.duration - 1.0).max(0.0)));
        let done = match action {
            "playPause" => asked!(session.TryTogglePlayPauseAsync()),
            "next" => asked!(session.TrySkipNextAsync()),
            "previous" => asked!(session.TrySkipPreviousAsync()),
            "seek" => match (seek_to, session.GetTimelineProperties().and_then(|t| t.StartTime())) {
                (Some(target), Ok(start)) => {
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
            "volume" => set_spotify_volume(v),
            _ => false,
        };
        if !done {
            return false;
        }
        // Show these at once, as the Mac does; the session's events confirm them.
        let optimistic = matches!(action, "seek" | "shuffle" | "repeat" | "volume");
        if optimistic {
            let state = {
                let mut s = SHARED.lock().unwrap();
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
            emit_state(app, &state);
        }
        true
    }

    // ── Launching ─────────────────────────────────────────────────────────────

    /// The installer's copy, or the Microsoft Store's (its app alias).
    pub fn installed() -> bool {
        let under = |var: &str, rest: &str| std::env::var_os(var).map(|base| PathBuf::from(base).join(rest));
        let desktop = under("APPDATA", r"Spotify\Spotify.exe").is_some_and(|p| p.is_file());
        // An app execution alias is a reparse point that is_file() can't open.
        let store = under("LOCALAPPDATA", r"Microsoft\WindowsApps\Spotify.exe")
            .is_some_and(|p| std::fs::symlink_metadata(p).is_ok());
        desktop || store
    }

    /// Spotify's URI scheme brings it forward, or starts it. Without Spotify,
    /// its download page.
    pub fn open() -> bool {
        let running = SHARED.lock().unwrap().state.running;
        if running || installed() {
            crate::platform::open_url("spotify:");
            return true;
        }
        crate::platform::open_url(DOWNLOAD_URL);
        false
    }
}

// ── Tests (the pure parts) ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> Value {
        Value::Str(v.into())
    }

    fn metadata(trackid: &str, title: &str) -> Value {
        Value::Map(vec![
            ("mpris:trackid".into(), s(trackid)),
            ("xesam:title".into(), s(title)),
            ("xesam:artist".into(), Value::Strs(vec!["Daft Punk".into(), "Pharrell Williams".into()])),
            ("xesam:album".into(), s("Random Access Memories")),
            ("mpris:length".into(), Value::Int(369_000_000)),
            ("mpris:artUrl".into(), s("https://i.scdn.co/image/abc")),
        ])
    }

    #[test]
    fn titles_and_artists_are_cut_like_the_mac() {
        assert_eq!(short_title("Song - Remastered 2011"), "Song");
        assert_eq!(short_title("Song (Live) [Mono]"), "Song");
        assert_eq!(short_title("(Intro)"), "(Intro)");
        assert_eq!(short_title(""), "");
        assert_eq!(short_title("Plain"), "Plain");
        assert_eq!(short_artist("Artist feat. Someone"), "Artist");
        assert_eq!(short_artist("Artist FT. Someone"), "Artist");
        assert_eq!(short_artist("Solo"), "Solo");
    }

    #[test]
    fn mpris_track_ids_become_spotify_ids() {
        assert_eq!(spotify_id("/com/spotify/track/ABC", None), "spotify:track:ABC");
        assert_eq!(spotify_id("/com/spotify/episode/XYZ", None), "spotify:episode:XYZ");
        assert_eq!(spotify_id("/com/spotify/ad/123", None), "spotify:ad:123");
        assert_eq!(spotify_id("spotify:track:ABC", None), "spotify:track:ABC");
        assert_eq!(
            spotify_id("/org/mpris/x", Some("https://open.spotify.com/track/QQQ?si=1")),
            "spotify:track:QQQ"
        );
        assert_eq!(spotify_id("/org/mpris/x", None), "/org/mpris/x");
    }

    #[test]
    fn metadata_parses_and_an_empty_player_has_no_track() {
        let Value::Map(map) = metadata("/com/spotify/track/ID1", "Get Lucky - Radio Edit") else { unreachable!() };
        let track = parse_metadata(&map).unwrap();
        assert_eq!(track.id, "spotify:track:ID1");
        assert_eq!(track.title, "Get Lucky");
        assert_eq!(track.artist, "Daft Punk, Pharrell Williams");
        assert_eq!(track.album, "Random Access Memories");
        assert_eq!(track.duration, 369.0);
        assert_eq!(track.art_url.as_deref(), Some("https://i.scdn.co/image/abc"));

        assert_eq!(parse_metadata(&[]), None);
        assert_eq!(
            parse_metadata(&[("mpris:trackid".into(), s("/org/mpris/MediaPlayer2/TrackList/NoTrack"))]),
            None
        );
    }

    #[test]
    fn the_position_runs_on_while_playing_and_stops_at_the_end() {
        let mut state = PlayerState::default();
        state.apply(
            &[
                ("Metadata".into(), metadata("/com/spotify/track/ID1", "Get Lucky")),
                ("PlaybackStatus".into(), s("Playing")),
                ("Position".into(), Value::Int(10_000_000)),
            ],
            1_000.0,
        );
        assert_eq!(state.position_at_time(1_000.0), 10.0);
        assert_eq!(state.position_at_time(3_500.0), 12.5);
        // A clock that went backwards never moves it back.
        assert_eq!(state.position_at_time(0.0), 10.0);
        // Capped at the track's length.
        assert_eq!(state.position_at_time(1_000.0 + 1_000_000.0), 369.0);

        // Pausing freezes it where it got to.
        let applied = state.apply(&[("PlaybackStatus".into(), s("Paused"))], 5_000.0);
        assert!(applied.status_changed && !applied.track_changed);
        assert!(!state.playing);
        assert_eq!(state.position, 14.0);
        assert_eq!(state.position_at_time(60_000.0), 14.0);
    }

    #[test]
    fn a_new_track_restarts_the_clock_and_stopped_clears_it() {
        let mut state = PlayerState::default();
        state.apply(
            &[
                ("PlaybackStatus".into(), s("Playing")),
                ("Metadata".into(), metadata("/com/spotify/track/ID1", "One")),
                ("Position".into(), Value::Int(50_000_000)),
            ],
            0.0,
        );
        assert!(state.playing, "the status after the metadata, whatever the order");
        let applied = state.apply(&[("Metadata".into(), metadata("/com/spotify/track/ID2", "Two"))], 2_000.0);
        assert!(applied.track_changed);
        assert_eq!(state.position, 0.0);
        assert_eq!(state.track.as_ref().unwrap().title, "Two");

        // The same track again is not a change.
        let applied = state.apply(&[("Metadata".into(), metadata("/com/spotify/track/ID2", "Two"))], 3_000.0);
        assert!(!applied.track_changed);

        let applied = state.apply(&[("PlaybackStatus".into(), s("Stopped"))], 4_000.0);
        assert!(applied.track_changed);
        assert_eq!(state.track, None);
        assert!(!state.playing);
    }

    #[test]
    fn shuffle_loop_and_volume() {
        let mut state = PlayerState::default();
        assert_eq!(state.volume, 50);
        state.apply(
            &[
                ("Shuffle".into(), Value::Bool(true)),
                ("LoopStatus".into(), s("Playlist")),
                ("Volume".into(), Value::Float(1.4)),
            ],
            0.0,
        );
        assert!(state.shuffle && state.repeat);
        assert_eq!(state.volume, 100);
        state.apply(&[("LoopStatus".into(), s("None")), ("Volume".into(), Value::Float(0.004))], 0.0);
        assert!(!state.repeat);
        assert_eq!(state.volume, 0);
    }

    #[test]
    fn the_state_reaches_the_page_in_camel_case() {
        let mut state = PlayerState { running: true, installed: true, ..PlayerState::default() };
        state.apply(&[("Metadata".into(), metadata("/com/spotify/track/ID1", "One"))], 7.0);
        let json = serde_json::to_value(&state).unwrap();
        assert_eq!(json["positionAt"], 7.0);
        assert_eq!(json["track"]["artUrl"], "https://i.scdn.co/image/abc");
        assert_eq!(json["track"]["id"], "spotify:track:ID1");
        assert!(json["track"].get("objectPath").is_none());
    }

    #[test]
    fn covers_come_only_from_spotify_or_a_local_file() {
        assert_eq!(
            artwork_source("https://i.scdn.co/image/ab67"),
            Some(ArtSource::Https("https://i.scdn.co/image/ab67".into()))
        );
        assert_eq!(
            artwork_source("https://open.spotify.com/image/ab67"),
            Some(ArtSource::Https("https://i.scdn.co/image/ab67".into()))
        );
        assert!(matches!(artwork_source("https://mosaic.scdn.co/640/x"), Some(ArtSource::Https(_))));
        assert!(matches!(artwork_source("https://image-cdn-ak.spotifycdn.com/image/x"), Some(ArtSource::Https(_))));
        assert_eq!(artwork_source("http://i.scdn.co/image/ab67"), None);
        assert_eq!(artwork_source("https://evil.example/i.scdn.co"), None);
        assert_eq!(artwork_source("https://i.scdn.co.evil.example/x"), None);
        assert_eq!(artwork_source("https://user@i.scdn.co/x"), None);
        assert_eq!(artwork_source("https://i.scdn.co:8443/x"), None);
        // A local track's cover (Linux paths: the client only runs there).
        #[cfg(unix)]
        assert_eq!(
            artwork_source("file:///home/me/Music/cover%20art.jpg"),
            Some(ArtSource::File("/home/me/Music/cover art.jpg".into()))
        );
        assert_eq!(artwork_source("file://server/share/a.jpg"), None);
        assert_eq!(artwork_source("data:image/png;base64,AAAA"), None);
        assert_eq!(artwork_source("not a url"), None);
    }

    #[test]
    fn images_are_typed_by_their_bytes() {
        assert_eq!(sniff_image(&[0xFF, 0xD8, 0xFF, 0xE0]), Some("image/jpeg"));
        assert_eq!(sniff_image(b"\x89PNG\r\n\x1a\nrest"), Some("image/png"));
        assert_eq!(sniff_image(b"RIFF\0\0\0\0WEBPVP8 "), Some("image/webp"));
        assert_eq!(sniff_image(b"GIF89a.."), Some("image/gif"));
        assert_eq!(sniff_image(b"<svg xmlns="), None);
        assert_eq!(data_url(&[0xFF, 0xD8, 0xFF]).as_deref(), Some("data:image/jpeg;base64,/9j/"));
    }

    #[test]
    fn windows_media_sessions_of_spotify_are_recognised() {
        assert!(is_spotify_app("Spotify.exe"));
        assert!(is_spotify_app("SpotifyAB.SpotifyMusic_zpdnekdrzrea0!Spotify"));
        assert!(!is_spotify_app("Microsoft.ZuneMusic_8wekyb3d8bbwe!Microsoft.ZuneMusic"));
        assert!(!is_spotify_app("chrome.exe"));
    }

    #[test]
    fn windows_times_become_seconds_and_unix_ms() {
        assert_eq!(ticks_to_secs(2_150_000_000), 215.0);
        assert_eq!(ticks_to_secs(-5), 0.0);
        // 2023-11-14T22:13:20Z, as Windows and as Unix counts it.
        assert_eq!(windows_time_to_unix_ms(133_444_736_000_000_000), Some(1_700_000_000_000.0));
        assert_eq!(windows_time_to_unix_ms(0), None);
    }

    #[test]
    fn windows_tags_become_the_track() {
        let t = windows_track("Song - Remastered 2011", "Artist feat. Someone", "Album", 215.0).unwrap();
        assert_eq!(t.title, "Song");
        assert_eq!(t.artist, "Artist");
        assert_eq!(t.album, "Album");
        assert_eq!(t.duration, 215.0);
        assert!(t.id.starts_with("spotify:track:"));
        // The same tags give the same track, and the cover key follows it.
        let again = windows_track("Song - Remastered 2011", "Artist feat. Someone", "Album", 215.0).unwrap();
        assert_eq!(t.id, again.id);
        assert_eq!(t.art_url, again.art_url);
        assert_ne!(t.id, windows_track("Other", "Artist", "Album", 1.0).unwrap().id);
        // An ad is a title and nothing else.
        assert!(windows_track("Spotify", "", "", 30.0).unwrap().id.starts_with("spotify:ad:"));
        assert_eq!(windows_track("  ", "Artist", "Album", 1.0), None);
    }
}
