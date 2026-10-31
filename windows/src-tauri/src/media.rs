// Shared now-playing data, formatting and artwork. Each service owns its connection and commands.
use serde::Serialize;

pub(crate) const ARTWORK_LIMIT: usize = 3 * 1024 * 1024;

/// The track a media service has loaded.
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
    /// The service has a media session.
    pub running: bool,
    /// The service is installed and can be opened.
    pub installed: bool,
    pub track: Option<Track>,
    pub playing: bool,
    /// The current native session supports changing the playback position.
    pub can_seek: bool,
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
            can_seek: false,
            position: 0.0,
            position_at: 0.0,
            shuffle: false,
            repeat: false,
            volume: 50,
        }
    }
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

    pub(crate) fn anchor(&mut self, position: f64, now_ms: f64) {
        self.position = position.max(0.0);
        self.position_at = now_ms;
    }

    /// The service is gone, or its pill is off: nothing is playing.
    pub fn clear(&mut self, now_ms: f64) {
        self.track = None;
        self.playing = false;
        self.anchor(0.0, now_ms);
    }

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

pub(crate) fn data_url(bytes: &[u8]) -> Option<String> {
    let mime = sniff_image(bytes)?;
    Some(format!("data:{mime};base64,{}", crate::claude::base64_for(bytes)))
}

#[derive(Serialize, Clone)]
#[serde(rename_all = "camelCase")]
pub(crate) struct Artwork {
    pub art_url: String,
    pub data_url: String,
}

pub(crate) fn now_ms() -> f64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64() * 1000.0)
        .unwrap_or(0.0)
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
pub fn windows_track(title: &str, artist: &str, album: &str, duration: f64, namespace: &str) -> Option<Track> {
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
        id: format!("{namespace}:{kind}:{hash:016x}"),
        title: short_title(title),
        artist: short_artist(artist),
        album: album.to_string(),
        duration: duration.max(0.0),
        // Not a URL: the thumbnail is read from the session itself. The page
        // only uses it to match a cover to its track.
        art_url: Some(if namespace == "spotify" { format!("smtc:{hash:016x}") } else { format!("{namespace}:smtc:{hash:016x}") }),
        object_path: String::new(),
    })
}
