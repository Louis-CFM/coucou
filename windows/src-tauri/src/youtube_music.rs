// The YouTube Music pill — Linux only, apart from the Spotify one.
//
// YouTube Music has no desktop app: it plays in a browser, which puts the
// page's Media Session on MPRIS under a name of its own
// (`org.mpris.MediaPlayer2.brave.instance<PID>`, `…firefox.instance_…`,
// `…chromium.instance<PID>` for Chrome and Opera). The pill follows the one
// playing YouTube Music, with the Spotify pill's state, parsing and card
// (spotify.rs): only the player it reads differs.
//
// Nothing runs on a timer. While the pill is declared, one thread blocks on the
// bus and wakes for players' signals and for players coming and going.

#![cfg_attr(not(target_os = "linux"), allow(dead_code))]

use crate::spotify::{ArtSource, PlayerState, Value};
use tauri::AppHandle;

pub const PILL_ID: &str = "integration_youtube_music";
pub const WEB_URL: &str = "https://music.youtube.com/";
const STATE_EVENT: &str = "youtube-music";
const ARTWORK_EVENT: &str = "youtube-music-artwork";
const ARTWORK_LIMIT: usize = 3 * 1024 * 1024;

/// org.mpris.MediaPlayer2.<browser>.instance… (Chrome and Opera say chromium).
const BROWSERS: [&str; 6] = ["firefox", "zen", "brave", "chromium", "chrome", "opera"];

fn find<'a>(map: &'a [(String, Value)], key: &str) -> Option<&'a Value> {
    map.iter().find(|(k, _)| k == key).map(|(_, v)| v)
}

fn text(v: Option<&Value>) -> Option<&str> {
    match v {
        Some(Value::Str(s)) => Some(s.as_str()),
        _ => None,
    }
}

/// A browser's player on the bus.
pub fn is_browser(name: &str) -> bool {
    name.strip_prefix("org.mpris.MediaPlayer2.")
        .and_then(|rest| rest.split('.').next())
        .is_some_and(|browser| BROWSERS.contains(&browser))
}

/// What a followed tab plays: Mochi dances to music and watches a video.
#[derive(Clone, Copy, PartialEq, Debug)]
pub enum Kind {
    Music,
    Video,
}

const MUSIC_HOST: &str = "music.youtube.com";
const VIDEO_HOSTS: [&str; 4] = ["www.youtube.com", "youtube.com", "m.youtube.com", "youtu.be"];

/// A YouTube or YouTube Music page, over https with nothing odd in it: the
/// only URLs the pill reads a kind from or opens.
fn youtube_page(raw: &str) -> Option<reqwest::Url> {
    let url = reqwest::Url::parse(raw).ok()?;
    let host = url.host_str()?.to_ascii_lowercase();
    let ours = host == MUSIC_HOST || VIDEO_HOSTS.contains(&host.as_str());
    (url.scheme() == "https" && ours && url.port().is_none() && url.username().is_empty() && url.password().is_none())
        .then_some(url)
}

fn non_empty(v: Option<&Value>) -> bool {
    text(v).is_some_and(|s| !s.trim().is_empty())
}

/// What a browser's tab plays, if the pill follows it. With the page's URL
/// (Firefox, Zen), its host says so and a YouTube Music track without an album
/// is one of its videos; Chromium browsers give no URL, so an album is music
/// and any other titled track a video.
// ponytail: without a URL any site's media passes (an album → music, else a
// video); tighten if one shows up where it should not.
pub fn kind_of(meta: &[(String, Value)]) -> Option<Kind> {
    let album = non_empty(find(meta, "xesam:album"));
    match text(find(meta, "xesam:url")).filter(|u| !u.trim().is_empty()) {
        Some(raw) => {
            let url = youtube_page(raw)?;
            let music = url.host_str().is_some_and(|h| h.eq_ignore_ascii_case(MUSIC_HOST)) && album;
            Some(if music { Kind::Music } else { Kind::Video })
        }
        None if album => Some(Kind::Music),
        None if non_empty(find(meta, "xesam:title")) => Some(Kind::Video),
        None => None,
    }
}

/// Where a click takes the user when the browser cannot raise the tab: the
/// page itself when the browser said which, else a search for what played.
pub fn page_for(meta: &[(String, Value)]) -> Option<String> {
    let kind = kind_of(meta)?;
    if let Some(url) = text(find(meta, "xesam:url")).and_then(youtube_page) {
        return Some(url.to_string());
    }
    let title = text(find(meta, "xesam:title")).unwrap_or("").trim();
    if title.is_empty() {
        return None;
    }
    let artist = match find(meta, "xesam:artist") {
        Some(Value::Strs(names)) => names.join(" "),
        Some(Value::Str(name)) => name.clone(),
        _ => String::new(),
    };
    let (base, key) = match kind {
        Kind::Music => ("https://music.youtube.com/search", "q"),
        Kind::Video => ("https://www.youtube.com/results", "search_query"),
    };
    let mut url = reqwest::Url::parse(base).ok()?;
    url.query_pairs_mut().append_pair(key, format!("{title} {artist}").trim());
    Some(url.to_string())
}

fn follows(props: &[(String, Value)]) -> bool {
    matches!(find(props, "Metadata"), Some(Value::Map(meta)) if kind_of(meta).is_some())
}

/// Among the browsers' (name, Player properties), the one to follow: one that
/// plays (the current one first), else the current one, else any.
pub fn pick(players: &[(String, Vec<(String, Value)>)], current: Option<&str>) -> Option<usize> {
    let valid: Vec<usize> = (0..players.len()).filter(|&i| follows(&players[i].1)).collect();
    let playing = |i: &&usize| text(find(&players[**i].1, "PlaybackStatus")) == Some("Playing");
    let is_current = |i: &&usize| Some(players[**i].0.as_str()) == current;
    valid
        .iter()
        .find(|i| playing(i) && is_current(i))
        .or_else(|| valid.iter().find(playing))
        .or_else(|| valid.iter().find(is_current))
        .or(valid.first())
        .copied()
}

/// Covers: Google's image hosts, or the local file Chromium writes.
pub fn artwork_source(raw: &str) -> Option<ArtSource> {
    let url = reqwest::Url::parse(raw).ok()?;
    if url.scheme() == "https" {
        let host = url.host_str()?.to_ascii_lowercase();
        let ours = host.ends_with(".googleusercontent.com") || host == "yt3.ggpht.com" || host == "i.ytimg.com";
        return (ours && url.port().is_none() && url.username().is_empty()).then(|| ArtSource::Https(url.to_string()));
    }
    match crate::spotify::artwork_source(raw)? {
        ArtSource::File(path) => Some(ArtSource::File(path)),
        ArtSource::Https(_) => None,
    }
}

fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
}

/// What the island is told: the Spotify pill's state, and whether a video plays.
#[derive(serde::Serialize, Clone, Debug, PartialEq)]
pub struct Now {
    #[serde(flatten)]
    pub player: PlayerState,
    pub video: bool,
}

/// Is `child` the process `pid` or one it started (Chromium plays sound from
/// a child process)? `parent` gives a process's parent.
pub fn descends(mut child: u32, pid: u32, parent: impl Fn(u32) -> Option<u32>) -> bool {
    for _ in 0..16 {
        if child == pid {
            return true;
        }
        match parent(child) {
            Some(p) if p > 1 && p != child => child = p,
            _ => return false,
        }
    }
    false
}

/// The sound server's streams from the browser `pid` — (index, volume in %)
/// of each sink input in `pactl -f json list sink-inputs`.
pub fn streams_of(json: &[u8], pid: u32, parent: impl Fn(u32) -> Option<u32>) -> Vec<(u32, i32)> {
    let Ok(serde_json::Value::Array(inputs)) = serde_json::from_slice(json) else { return Vec::new() };
    inputs
        .iter()
        .filter_map(|input| {
            let index = u32::try_from(input["index"].as_u64()?).ok()?;
            let owner: u32 = input["properties"]["application.process.id"].as_str()?.parse().ok()?;
            if !descends(owner, pid, &parent) {
                return None;
            }
            let percent = input["volume"]
                .as_object()?
                .values()
                .filter_map(|c| c["value_percent"].as_str()?.trim().trim_end_matches('%').parse::<i32>().ok())
                .max()?;
            Some((index, percent.clamp(0, 100)))
        })
        .collect()
}

// ── Commands ──────────────────────────────────────────────────────────────────

#[tauri::command]
pub async fn youtube_music_refresh(app: AppHandle) -> Option<Now> {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux::refresh(&linux::Out::App(app))).await.ok().flatten()
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = app;
        None
    }
}

/// `playPause`, `next`, `previous`, `seek` (seconds), `volume` (0…100, the
/// browser's sound streams); a browser takes no shuffle or repeat.
#[tauri::command]
pub async fn youtube_music_control(app: AppHandle, action: String, value: Option<f64>) -> bool {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(move || linux::control(&linux::Out::App(app), &action, value)).await.unwrap_or(false)
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (app, action, value);
        false
    }
}

/// Brings the tab forward, or opens what played (YouTube Music when nothing has).
#[tauri::command]
pub async fn youtube_music_open() -> bool {
    #[cfg(target_os = "linux")]
    {
        tauri::async_runtime::spawn_blocking(linux::open).await.unwrap_or(false)
    }
    #[cfg(not(target_os = "linux"))]
    {
        false
    }
}

pub fn sync(app: &AppHandle, active_integrations: &[String]) {
    #[cfg(target_os = "linux")]
    linux::sync(app, active_integrations.iter().any(|id| id == PILL_ID));
    #[cfg(not(target_os = "linux"))]
    let _ = (app, active_integrations);
}

// ── Linux: MPRIS over D-Bus ───────────────────────────────────────────────────

#[cfg(target_os = "linux")]
mod linux {
    use super::*;
    use serde::Serialize;
    use std::collections::VecDeque;
    use std::sync::{LazyLock, Mutex};
    use std::time::Duration;

    use dbus::arg::{ArgType, PropMap, RefArg};
    use dbus::blocking::stdintf::org_freedesktop_dbus::Properties;
    use dbus::blocking::Connection;
    use dbus::message::MessageType;
    use dbus::Message;
    use tauri::Emitter;

    const PATH: &str = "/org/mpris/MediaPlayer2";
    const ROOT: &str = "org.mpris.MediaPlayer2";
    const PLAYER: &str = "org.mpris.MediaPlayer2.Player";
    const PROPERTIES: &str = "org.freedesktop.DBus.Properties";
    const DBUS: &str = "org.freedesktop.DBus";
    const CALL: Duration = Duration::from_millis(1500);
    const IDLE_WAIT: Duration = Duration::from_secs(3600);

    const RULES: [&str; 3] = [
        "type='signal',sender='org.freedesktop.DBus',interface='org.freedesktop.DBus',member='NameOwnerChanged',arg0namespace='org.mpris.MediaPlayer2'",
        "type='signal',path='/org/mpris/MediaPlayer2',interface='org.freedesktop.DBus.Properties',member='PropertiesChanged'",
        "type='signal',path='/org/mpris/MediaPlayer2',interface='org.mpris.MediaPlayer2.Player',member='Seeked'",
    ];

    struct Shared {
        generation: u64,
        active: bool,
        listener: Option<String>,
        /// The followed browser's name on the bus, and its unique name.
        bus: Option<String>,
        owner: Option<String>,
        /// Its process, whose sound streams carry the volume.
        pid: Option<u32>,
        state: PlayerState,
        video: bool,
        /// Where a click goes when the tab cannot be raised; outlives the tab.
        page: Option<String>,
    }

    impl Shared {
        fn now(&self) -> Now {
            Now { player: self.state.clone(), video: self.video }
        }
    }

    static SHARED: LazyLock<Mutex<Shared>> = LazyLock::new(|| {
        Mutex::new(Shared {
            generation: 0,
            active: false,
            listener: None,
            bus: None,
            owner: None,
            pid: None,
            state: idle(),
            video: false,
            page: None,
        })
    });

    static CONTROL: LazyLock<Mutex<Option<Connection>>> = LazyLock::new(|| Mutex::new(None));

    struct ArtCache {
        entries: VecDeque<(String, String)>,
        loading: Option<String>,
    }

    static ART: LazyLock<Mutex<ArtCache>> =
        LazyLock::new(|| Mutex::new(ArtCache { entries: VecDeque::new(), loading: None }));

    #[derive(Serialize, Clone)]
    #[serde(rename_all = "camelCase")]
    struct Artwork {
        art_url: String,
        data_url: String,
    }

    /// Nothing plays; "installed": a website is always there to open.
    fn idle() -> PlayerState {
        PlayerState { installed: true, ..PlayerState::default() }
    }

    #[derive(Clone)]
    pub enum Out {
        App(AppHandle),
        #[cfg(test)]
        Test(std::sync::mpsc::Sender<Now>),
    }

    impl Out {
        fn state(&self, state: &Now) {
            match self {
                Out::App(app) => {
                    let _ = app.emit_to(crate::island::WINDOW_LABEL, STATE_EVENT, state);
                    want_artwork(app, &state.player);
                }
                #[cfg(test)]
                Out::Test(tx) => {
                    let _ = tx.send(state.clone());
                }
            }
        }
    }

    /// A D-Bus argument as a plain Value (variants unwrapped).
    fn value_of(arg: &dyn RefArg) -> Value {
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
                let Some(mut items) = arg.as_iter() else { return Value::Other };
                if arg.signature().starts_with("a{") {
                    let mut map = Vec::new();
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

    fn props_of(map: &PropMap) -> Vec<(String, Value)> {
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
            s.bus = None;
            s.owner = None;
            s.pid = None;
            s.state = idle();
            s.video = false;
            s.page = None;
            s.listener.take()
        };
        if on {
            let generation = SHARED.lock().unwrap().generation;
            let spawned = std::thread::Builder::new()
                .name("coucou-youtube-music".into())
                .spawn(move || listen(out, generation));
            if let Err(err) = spawned {
                crate::log::line(format!("youtube music: no listener thread: {err}"));
            }
        } else {
            if let Some(name) = wake {
                wake_listener(&name);
            }
            let state = SHARED.lock().unwrap().now();
            out.state(&state);
        }
    }

    fn current(generation: u64) -> bool {
        let s = SHARED.lock().unwrap();
        s.active && s.generation == generation
    }

    fn wake_listener(name: &str) {
        let Ok(mut msg) = Message::new_method_call(name, "/", "org.freedesktop.DBus.Peer", "Ping") else { return };
        msg.set_no_reply(true);
        with_control(|c| {
            let _ = c.channel().send(msg);
            c.channel().flush();
            Ok(())
        });
    }

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
                crate::log::line(format!("youtube music: no session bus: {err}"));
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
                crate::log::line(format!("youtube music: match refused: {err}"));
            }
        }
        read_everything(&conn, &out, generation);

        while current(generation) {
            match conn.channel().blocking_pop_message(IDLE_WAIT) {
                Ok(Some(msg)) => handle(&conn, &out, generation, &msg),
                Ok(None) => {}
                Err(err) => {
                    crate::log::line(format!("youtube music: bus lost: {err}"));
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
                // A browser's player came or went: choose again.
                let Ok((name, _old, _new)) = msg.read3::<String, String, String>() else { return };
                if is_browser(&name) {
                    read_everything(conn, out, generation);
                }
            }
            (PROPERTIES, "PropertiesChanged") => {
                let Ok((iface, changed, invalidated)) = msg.read3::<String, PropMap, Vec<String>>() else { return };
                if iface != PLAYER {
                    return;
                }
                // A status or a track moved, here or in another tab: another
                // player may be the one to follow now.
                let switch = ["PlaybackStatus", "Metadata"]
                    .iter()
                    .any(|k| changed.contains_key(*k) || invalidated.iter().any(|i| i == k));
                // ponytail: any sender may trigger a re-read (one ListNames + pactl);
                // filter by the browsers' unique names if it ever shows up in a profile.
                if switch {
                    read_everything(conn, out, generation);
                    return;
                }
                if !from_owner(sender.as_deref()) {
                    return;
                }
                let mut props = props_of(&changed);
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
        matches!((&s.owner, sender), (Some(owner), Some(sender)) if owner == sender)
    }

    fn apply_and_emit(conn: &Connection, out: &Out, props: &[(String, Value)]) {
        let applied = SHARED.lock().unwrap().state.apply(props, now_ms());
        if (applied.status_changed || applied.track_changed) && !applied.position_set {
            if let Some(position) = get_property(conn, "Position") {
                SHARED.lock().unwrap().state.apply(&[("Position".into(), position)], now_ms());
            }
        }
        let state = SHARED.lock().unwrap().now();
        out.state(&state);
    }

    fn bus() -> Option<String> {
        SHARED.lock().unwrap().bus.clone()
    }

    fn get_property(conn: &Connection, name: &str) -> Option<Value> {
        let proxy = conn.with_proxy(bus()?, PATH, CALL);
        let v: Box<dyn RefArg> = proxy.get(PLAYER, name).ok()?;
        Some(value_of(&v))
    }

    /// The browser to follow: its name, unique name, process, Player
    /// properties, and its streams' volume when it has any.
    struct Player {
        name: String,
        owner: String,
        pid: Option<u32>,
        props: Vec<(String, Value)>,
        volume: Option<i32>,
    }

    fn choose(conn: &Connection) -> Option<Player> {
        let proxy = conn.with_proxy(DBUS, "/org/freedesktop/DBus", CALL);
        let (names,): (Vec<String>,) = proxy.method_call(DBUS, "ListNames", ()).ok()?;
        let players: Vec<(String, Vec<(String, Value)>)> = names
            .into_iter()
            .filter(|n| is_browser(n))
            .filter_map(|n| {
                let props = conn.with_proxy(n.as_str(), PATH, CALL).get_all(PLAYER).ok()?;
                Some((n, props_of(&props)))
            })
            .collect();
        let i = pick(&players, bus().as_deref())?;
        let (name, props) = players.into_iter().nth(i)?;
        let (owner,): (String,) = proxy.method_call(DBUS, "GetNameOwner", (name.as_str(),)).ok()?;
        let pid = proxy
            .method_call::<(u32,), _, _, _>(DBUS, "GetConnectionUnixProcessID", (owner.as_str(),))
            .ok()
            .map(|(pid,)| pid);
        let volume = pid.and_then(|pid| streams(pid).into_iter().map(|(_, v)| v).max());
        Some(Player { name, owner, pid, props, volume })
    }

    /// Follows what `choose` found; another player starts from a clean card.
    fn adopt(s: &mut Shared, player: Option<Player>) {
        let now = now_ms();
        match player {
            Some(Player { name, owner, pid, props, volume }) => {
                if s.bus.as_deref() != Some(name.as_str()) {
                    s.state = idle();
                }
                s.video = false;
                if let Some(Value::Map(meta)) = find(&props, "Metadata") {
                    s.video = kind_of(meta) == Some(Kind::Video);
                    if let Some(page) = page_for(meta) {
                        s.page = Some(page);
                    }
                }
                s.bus = Some(name);
                s.owner = Some(owner);
                s.pid = pid;
                s.state.running = true;
                s.state.apply(&props, now);
                if let Some(volume) = volume {
                    s.state.volume = volume;
                }
            }
            None => {
                s.bus = None;
                s.owner = None;
                s.pid = None;
                s.video = false;
                s.state.running = false;
                s.state.clear(now);
            }
        }
    }

    fn read_everything(conn: &Connection, out: &Out, generation: u64) {
        let player = choose(conn);
        let state = {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return;
            }
            adopt(&mut s, player);
            s.now()
        };
        out.state(&state);
    }

    fn with_control<R>(f: impl FnOnce(&Connection) -> Result<R, dbus::Error>) -> Option<R> {
        let mut slot = CONTROL.lock().unwrap();
        if slot.as_ref().is_none_or(|c| !c.channel().is_connected()) {
            *slot = Connection::new_session().ok();
        }
        let conn = slot.as_ref()?;
        f(conn).ok()
    }

    pub fn refresh(out: &Out) -> Option<Now> {
        let generation = {
            let s = SHARED.lock().unwrap();
            if !s.active {
                return None;
            }
            s.generation
        };
        let read = with_control(|c| Ok(choose(c)));
        let state = {
            let mut s = SHARED.lock().unwrap();
            if !(s.active && s.generation == generation) {
                return None;
            }
            if let Some(player) = read {
                adopt(&mut s, player);
            }
            s.now()
        };
        out.state(&state);
        Some(state)
    }

    pub fn control(out: &Out, action: &str, value: Option<f64>) -> bool {
        let (bus, pid, state) = {
            let s = SHARED.lock().unwrap();
            (s.bus.clone().filter(|_| s.active && s.owner.is_some()), s.pid, s.state.clone())
        };
        let Some(bus) = bus else { return false };
        if action == "volume" {
            let (Some(pid), Some(v)) = (pid, value) else { return false };
            return set_volume(out, pid, v);
        }
        let target = state.track.as_ref().map(|t| value.unwrap_or(0.0).clamp(0.0, (t.duration - 1.0).max(0.0)));
        let done = with_control(|c| {
            let p = c.with_proxy(bus.as_str(), PATH, CALL);
            match action {
                "playPause" => p.method_call::<(), _, _, _>(PLAYER, "PlayPause", ()),
                "next" => p.method_call::<(), _, _, _>(PLAYER, "Next", ()),
                "previous" => p.method_call::<(), _, _, _>(PLAYER, "Previous", ()),
                "seek" => {
                    let (Some(track), Some(target)) = (state.track.as_ref(), target) else {
                        return Err(dbus::Error::new_failed("no track"));
                    };
                    let path = dbus::Path::new(track.object_path.clone()).map_err(|_| dbus::Error::new_failed("no path"))?;
                    p.method_call(PLAYER, "SetPosition", (path, (target * 1_000_000.0) as i64))
                }
                _ => Err(dbus::Error::new_failed("unknown action")),
            }
        })
        .is_some();
        if done && action == "seek" {
            if let Some(target) = target {
                let state = {
                    let mut s = SHARED.lock().unwrap();
                    s.state.apply(&[("Position".into(), Value::Int((target * 1_000_000.0) as i64))], now_ms());
                    s.now()
                };
                out.state(&state);
            }
        }
        done
    }

    /// The followed tab forward when the browser can (Firefox, Zen); else what
    /// played — its page, or a search for it — in the default browser, so a
    /// closed tab comes back. Chromium browsers cannot raise a tab over MPRIS.
    // ponytail: with a Chromium tab still open this opens another one (a
    // search, which does not play); focusing the tab needs a browser extension.
    pub fn open() -> bool {
        let page = SHARED.lock().unwrap().page.clone();
        let raised = bus()
            .and_then(|bus| {
                with_control(|c| {
                    let p = c.with_proxy(bus.as_str(), PATH, CALL);
                    let can: bool = p.get(ROOT, "CanRaise").unwrap_or(false);
                    if can {
                        p.method_call::<(), _, _, _>(ROOT, "Raise", ())?;
                    }
                    Ok(can)
                })
            })
            .unwrap_or(false);
        if !raised {
            crate::platform::open_url(page.as_deref().unwrap_or(WEB_URL));
        }
        true
    }

    // ── Volume: the browser's streams on the sound server ─────────────────────

    // ponytail: the whole browser's volume, not the tab's — a browser gives a
    // tab none of its own over MPRIS; Flatpak browsers live in another PID
    // namespace and are not found (the slider then does nothing).
    fn streams(pid: u32) -> Vec<(u32, i32)> {
        let Ok(out) = std::process::Command::new("pactl").args(["-f", "json", "list", "sink-inputs"]).output() else {
            return Vec::new();
        };
        if !out.status.success() {
            return Vec::new();
        }
        streams_of(&out.stdout, pid, parent_of)
    }

    fn parent_of(pid: u32) -> Option<u32> {
        let stat = std::fs::read_to_string(format!("/proc/{pid}/stat")).ok()?;
        // "pid (comm) state ppid …" — comm may hold spaces and parentheses.
        stat.get(stat.rfind(')')? + 1..)?.split_whitespace().nth(1)?.parse().ok()
    }

    fn set_volume(out: &Out, pid: u32, value: f64) -> bool {
        let v = value.clamp(0.0, 100.0).round() as i32;
        let streams = streams(pid);
        let mut done = false;
        for (index, _) in &streams {
            let status = std::process::Command::new("pactl")
                .args(["set-sink-input-volume", &index.to_string(), &format!("{v}%")])
                .status();
            done |= status.is_ok_and(|s| s.success());
        }
        if done {
            let state = {
                let mut s = SHARED.lock().unwrap();
                s.state.volume = v;
                s.now()
            };
            out.state(&state);
        }
        done
    }

    // ── Artwork ───────────────────────────────────────────────────────────────

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
        let data = bytes.as_deref().and_then(|b| {
            let mime = crate::spotify::sniff_image(b)?;
            Some(format!("data:{mime};base64,{}", crate::claude::base64_for(b)))
        });
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

        /// End to end against a fake Brave on a private session bus:
        /// `dbus-run-session -- cargo test -p coucou --lib youtube_music -- --ignored`
        #[test]
        #[ignore]
        fn the_listener_follows_youtube_music_in_a_browser() {
            let calls = Arc::new(Mutex::new(Vec::<String>::new()));
            let stop = Arc::new(AtomicBool::new(false));
            let (tx, rx) = std::sync::mpsc::channel();
            let out = Out::Test(tx);
            let next = || rx.recv_timeout(Duration::from_secs(3)).expect("a state from the listener");

            // Declared with nothing playing.
            set_active(out.clone(), true);
            assert!(!next().player.running);

            // A browser plays YouTube Music: followed, and driven on its bus.
            let browser = {
                let (calls, stop) = (calls.clone(), stop.clone());
                std::thread::spawn(move || fake_browser("org.mpris.MediaPlayer2.brave.instance1", calls, stop))
            };
            let Now { player: state, video } = next();
            assert!(state.running && state.playing && !video);
            let track = state.track.unwrap();
            assert_eq!(track.title, "Fake Song");
            assert_eq!(track.album, "Fake Album");
            assert!(control(&out, "playPause", None));
            assert!(!next().player.playing);
            assert!(control(&out, "seek", Some(60.0)));
            assert_eq!(next().player.position, 60.0);
            assert!(!control(&out, "shuffle", Some(1.0)));
            assert_eq!(*calls.lock().unwrap(), vec!["PlayPause", "SetPosition"]);

            // The tab closes: nothing plays.
            stop.store(true, Ordering::Relaxed);
            let _ = browser.join();
            let state = next().player;
            assert!(!state.running && state.track.is_none());
            // A click brings back what played: Brave says no page, so a search for it.
            assert_eq!(
                SHARED.lock().unwrap().page.as_deref(),
                Some("https://music.youtube.com/search?q=Fake+Song+Fake+Artist")
            );
            assert!(!control(&out, "next", None));

            set_active(out.clone(), false);
            let _ = next();
            let deadline = std::time::Instant::now() + Duration::from_secs(3);
            while ALIVE.load(Ordering::SeqCst) > 0 && std::time::Instant::now() < deadline {
                std::thread::sleep(Duration::from_millis(20));
            }
            assert_eq!(ALIVE.load(Ordering::SeqCst), 0);
        }

        /// What Brave publishes for a YouTube Music tab (no URL, a local cover).
        fn fake_browser(name: &str, calls: Arc<Mutex<Vec<String>>>, stop: Arc<AtomicBool>) {
            let conn = Connection::new_session().unwrap();
            conn.request_name(name, false, true, true).unwrap();
            let mut playing = true;
            let mut position: i64 = 30_000_000;
            let player = |playing: bool, position: i64| {
                let mut meta: PropMap = HashMap::new();
                meta.insert("mpris:trackid".into(), var(dbus::Path::new("/com/brave/MediaPlayer2/TrackList/TrackA1").unwrap()));
                meta.insert("mpris:length".into(), var(180_000_000i64));
                meta.insert("mpris:artUrl".into(), var("file:///tmp/.org.chromium.Chromium.fake".to_string()));
                meta.insert("xesam:title".into(), var("Fake Song".to_string()));
                meta.insert("xesam:artist".into(), var(vec!["Fake Artist".to_string()]));
                meta.insert("xesam:album".into(), var("Fake Album".to_string()));
                let mut props: PropMap = HashMap::new();
                props.insert("Metadata".into(), var(meta));
                props.insert("PlaybackStatus".into(), var(if playing { "Playing" } else { "Paused" }.to_string()));
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
                        let (_, prop): (String, String) = msg.read2().unwrap();
                        match player(playing, position).get(&prop) {
                            Some(v) => msg.method_return().append1(var(v.0.box_clone())),
                            None => Message::error(
                                &msg,
                                &"org.freedesktop.DBus.Error.UnknownProperty".into(),
                                &std::ffi::CString::new("no").unwrap(),
                            ),
                        }
                    }
                    "SetPosition" => {
                        let (_, us): (dbus::Path, i64) = msg.read2().unwrap();
                        calls.lock().unwrap().push("SetPosition".into());
                        position = us;
                        msg.method_return()
                    }
                    "PlayPause" => {
                        calls.lock().unwrap().push("PlayPause".into());
                        playing = !playing;
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
            let _ = conn.release_name(name);
            conn.channel().flush();
        }
    }
}

// ── Tests (the pure parts) ────────────────────────────────────────────────────

#[cfg(test)]
mod tests {
    use super::*;

    fn s(v: &str) -> Value {
        Value::Str(v.into())
    }

    fn meta(pairs: &[(&str, &str)]) -> Vec<(String, Value)> {
        pairs.iter().map(|(k, v)| (k.to_string(), s(v))).collect()
    }

    fn player(name: &str, status: &str, pairs: &[(&str, &str)]) -> (String, Vec<(String, Value)>) {
        (name.into(), vec![("PlaybackStatus".into(), s(status)), ("Metadata".into(), Value::Map(meta(pairs)))])
    }

    #[test]
    fn only_browsers_are_read() {
        assert!(is_browser("org.mpris.MediaPlayer2.firefox.instance_1_23"));
        assert!(is_browser("org.mpris.MediaPlayer2.brave.instance5296"));
        assert!(is_browser("org.mpris.MediaPlayer2.chromium.instance99"));
        assert!(is_browser("org.mpris.MediaPlayer2.zen.instance_1_2"));
        assert!(is_browser("org.mpris.MediaPlayer2.opera.instance7"));
        assert!(!is_browser("org.mpris.MediaPlayer2.spotify"));
        assert!(!is_browser("org.mpris.MediaPlayer2.playerctld"));
        assert!(!is_browser("org.mpris.MediaPlayer2.firefoxish.instance1"));
    }

    #[test]
    fn music_is_told_from_a_video() {
        use Kind::*;
        // What Brave sent for a YouTube Music tab: no URL, a local cover, an album.
        assert_eq!(
            kind_of(&meta(&[
                ("mpris:artUrl", "file:///tmp/.org.chromium.Chromium.TWxxES"),
                ("xesam:album", "Mr. Robot, Vol. 1 (Original Television Series Soundtrack)"),
                ("xesam:title", "1.0_5-pierreloti.au"),
            ])),
            Some(Music)
        );
        // …and for a YouTube video: no URL, no album.
        assert_eq!(kind_of(&meta(&[("xesam:title", "A video"), ("xesam:album", "")])), Some(Video));
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://music.youtube.com/watch?v=x"), ("xesam:album", "A")])), Some(Music));
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://music.youtube.com/watch?v=x")])), Some(Video));
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://www.youtube.com/watch?v=x"), ("xesam:album", "A")])), Some(Video));
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://youtu.be/x")])), Some(Video));
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://music.youtube.com.evil.example/"), ("xesam:album", "A")])), None);
        assert_eq!(kind_of(&meta(&[("xesam:url", "http://www.youtube.com/watch?v=x")])), None);
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://www.youtube.com:444/watch?v=x")])), None);
        assert_eq!(kind_of(&meta(&[("xesam:url", "https://vimeo.com/1"), ("xesam:title", "A video")])), None);
        assert_eq!(kind_of(&meta(&[("xesam:title", " ")])), None);
        assert_eq!(kind_of(&[]), None);
    }

    #[test]
    fn a_click_goes_to_the_page_or_a_search_for_it() {
        assert_eq!(
            page_for(&meta(&[("xesam:url", "https://www.youtube.com/watch?v=abc"), ("xesam:title", "T")])).as_deref(),
            Some("https://www.youtube.com/watch?v=abc")
        );
        let mut song = meta(&[("xesam:title", "Song & Co"), ("xesam:album", "A")]);
        song.push(("xesam:artist".into(), Value::Strs(vec!["Her".into(), "Him".into()])));
        assert_eq!(page_for(&song).as_deref(), Some("https://music.youtube.com/search?q=Song+%26+Co+Her+Him"));
        assert_eq!(
            page_for(&meta(&[("xesam:title", "A video?x=1#y")])).as_deref(),
            Some("https://www.youtube.com/results?search_query=A+video%3Fx%3D1%23y")
        );
        assert_eq!(page_for(&meta(&[("xesam:url", "https://evil.example/"), ("xesam:title", "T")])), None);
        assert_eq!(page_for(&[]), None);
    }

    #[test]
    fn the_volume_is_the_browsers_streams() {
        // Brave: the bus says 5453; its audio service 8329 plays the sound.
        let parent = |pid: u32| match pid {
            8329 => Some(5453),
            5453 => Some(1),
            62566 => Some(4000),
            _ => None,
        };
        assert!(descends(5453, 5453, parent));
        assert!(descends(8329, 5453, parent));
        assert!(!descends(62566, 5453, parent));
        assert!(!descends(1, 5453, parent));
        let json = br#"[
            {"index":1249,"volume":{"front-left":{"value_percent":"100%"}},"properties":{"application.process.id":"62566"}},
            {"index":1665,"volume":{"front-left":{"value_percent":"40%"},"front-right":{"value_percent":"42%"}},"properties":{"application.process.id":"8329"}},
            {"index":1700,"volume":{"mono":{"value_percent":"150%"}},"properties":{"application.process.id":"5453"}},
            {"index":1701,"properties":{}}
        ]"#;
        assert_eq!(streams_of(json, 5453, parent), vec![(1665, 42), (1700, 100)]);
        assert_eq!(streams_of(b"not json", 5453, parent), vec![]);
    }

    #[test]
    fn the_pill_follows_the_tab_that_plays() {
        let ytm = [("xesam:album", "Album")];
        let video = [("xesam:url", "https://vimeo.com/1"), ("xesam:title", "A video")];
        let brave = player("org.mpris.MediaPlayer2.brave.instance1", "Playing", &ytm);
        let firefox = player("org.mpris.MediaPlayer2.firefox.instance_1", "Paused", &ytm);
        let plain = player("org.mpris.MediaPlayer2.firefox.instance_2", "Playing", &video);

        assert_eq!(pick(&[plain.clone(), firefox.clone(), brave.clone()], None), Some(2));
        assert_eq!(pick(&[brave.clone(), firefox.clone()], Some(&firefox.0)), Some(0));
        assert_eq!(pick(&[plain.clone(), firefox.clone()], None), Some(1));
        let playing_ff = player(&firefox.0, "Playing", &ytm);
        assert_eq!(pick(&[brave, playing_ff], Some(&firefox.0)), Some(1));
        assert_eq!(pick(&[plain], None), None);
        assert_eq!(pick(&[], None), None);
    }

    #[test]
    fn covers_come_only_from_google_or_a_local_file() {
        assert!(matches!(artwork_source("https://lh3.googleusercontent.com/a=w544"), Some(ArtSource::Https(_))));
        assert!(matches!(artwork_source("https://yt3.ggpht.com/a"), Some(ArtSource::Https(_))));
        assert!(matches!(artwork_source("https://i.ytimg.com/vi/x/hq.jpg"), Some(ArtSource::Https(_))));
        assert_eq!(
            artwork_source("file:///tmp/.org.chromium.Chromium.TWxxES"),
            Some(ArtSource::File("/tmp/.org.chromium.Chromium.TWxxES".into()))
        );
        assert_eq!(artwork_source("https://i.scdn.co/image/ab67"), None);
        assert_eq!(artwork_source("https://googleusercontent.com.evil.example/x"), None);
        assert_eq!(artwork_source("https://lh3.googleusercontent.com:8443/x"), None);
        assert_eq!(artwork_source("http://lh3.googleusercontent.com/x"), None);
    }
}
