// Synced lyrics for the music cards (Spotify and Now Playing), from LRCLIB
// (lrclib.net: free and open, no account, no key). Asked only once the user
// turned lyrics on (Settings → General), once per track, and never while
// Coucou is paused. The page may not reach the network: it asks here, and
// parses and times the LRC text itself (src/core/lyrics.ts).

use std::collections::VecDeque;
use std::sync::atomic::Ordering;
use std::sync::{LazyLock, Mutex};
use std::time::Duration;

use serde_json::Value;

const GET_URL: &str = "https://lrclib.net/api/get";
const SEARCH_URL: &str = "https://lrclib.net/api/search";
/// LRCLIB asks clients to name themselves.
const USER_AGENT: &str = concat!("Coucou/", env!("CARGO_PKG_VERSION"), " (https://github.com/Louis-CFM/coucou)");
const TIMEOUT: Duration = Duration::from_secs(10);
/// An LRC file is a few KB; a search answer, a few dozen.
const BODY_LIMIT: usize = 2 * 1024 * 1024;
const CACHE_SIZE: usize = 30;

/// Track key → its LRC text, or None when LRCLIB has none (so it isn't asked again).
static CACHE: LazyLock<Mutex<VecDeque<(String, Option<String>)>>> = LazyLock::new(|| Mutex::new(VecDeque::new()));

enum Lookup {
    Found(String),
    NotFound,
    /// Offline, LRCLIB down, an odd answer: asked again the next time the track plays.
    Failed,
}

/// The synced lyrics of one LRCLIB record, if it has any.
fn synced(record: &Value) -> Option<String> {
    record.get("syncedLyrics")?.as_str().filter(|s| !s.trim().is_empty()).map(str::to_string)
}

/// The first search result with synced lyrics and a length within 3 s of the
/// track's (any length when either is unknown).
pub fn pick(results: &[Value], duration: f64) -> Option<String> {
    results
        .iter()
        .filter(|r| {
            let length = r.get("duration").and_then(Value::as_f64).unwrap_or(0.0);
            duration <= 0.0 || length <= 0.0 || (length - duration).abs() <= 3.0
        })
        .find_map(synced)
}

async fn get_json(http: &reqwest::Client, url: &str, query: &[(&str, String)]) -> Result<Option<Value>, ()> {
    let response = http.get(url).query(query).send().await.map_err(|_| ())?;
    match response.status().as_u16() {
        200 => {
            let body = crate::net::read_capped(response, BODY_LIMIT).await.map_err(|_| ())?;
            serde_json::from_slice(&body).map(Some).map_err(|_| ())
        }
        404 => Ok(None),
        _ => Err(()),
    }
}

/// The exact match first (title, artist, album, length), then a search.
async fn lookup(title: &str, artist: &str, album: &str, duration: f64) -> Lookup {
    let Ok(http) = reqwest::Client::builder().timeout(TIMEOUT).user_agent(USER_AGENT).build() else {
        return Lookup::Failed;
    };
    let mut query = vec![("track_name", title.to_string()), ("artist_name", artist.to_string())];
    if !album.is_empty() {
        query.push(("album_name", album.to_string()));
    }
    if duration > 0.0 {
        query.push(("duration", (duration.round() as i64).to_string()));
    }
    match get_json(&http, GET_URL, &query).await {
        Ok(Some(record)) => {
            if let Some(lrc) = synced(&record) {
                return Lookup::Found(lrc);
            }
            if record.get("instrumental").and_then(Value::as_bool) == Some(true) {
                return Lookup::NotFound;
            }
        }
        Ok(None) => {}
        Err(()) => return Lookup::Failed,
    }
    let search = [("track_name", title.to_string()), ("artist_name", artist.to_string())];
    match get_json(&http, SEARCH_URL, &search).await {
        Ok(Some(Value::Array(results))) => pick(&results, duration).map_or(Lookup::NotFound, Lookup::Found),
        Ok(Some(_)) => Lookup::Failed,
        Ok(None) => Lookup::NotFound,
        Err(()) => Lookup::Failed,
    }
}

fn cached(key: &str) -> Option<Option<String>> {
    CACHE.lock().unwrap().iter().find(|(k, _)| k == key).map(|(_, v)| v.clone())
}

fn remember(key: String, lrc: Option<String>) {
    let mut cache = CACHE.lock().unwrap();
    cache.retain(|(k, _)| *k != key);
    cache.push_back((key, lrc));
    while cache.len() > CACHE_SIZE {
        cache.pop_front();
    }
}

/// What the page gets: the LRC text (None when there is none to show), and
/// whether to ask again later — LRCLIB could not be reached, or answered with
/// an error, so "none" is not known yet.
#[derive(serde::Serialize, Debug, PartialEq)]
pub struct Answer {
    pub lrc: Option<String>,
    pub retry: bool,
}

impl Answer {
    fn none() -> Answer {
        Answer { lrc: None, retry: false }
    }
}

/// The LRC text of a track. `key` is the page's track id, for the cache.
#[tauri::command]
pub async fn lyrics_get(key: String, title: String, artist: String, album: String, duration: f64) -> Answer {
    if !crate::settings::load().lyrics_enabled || crate::integrations::PAUSED.load(Ordering::Relaxed) {
        return Answer::none();
    }
    let (title, artist) = (title.trim(), artist.trim());
    if title.is_empty() || artist.is_empty() {
        return Answer::none();
    }
    if let Some(known) = cached(&key) {
        return Answer { lrc: known, retry: false };
    }
    match lookup(title, artist, album.trim(), duration).await {
        Lookup::Found(lrc) => {
            remember(key, Some(lrc.clone()));
            Answer { lrc: Some(lrc), retry: false }
        }
        Lookup::NotFound => {
            remember(key, None);
            Answer::none()
        }
        Lookup::Failed => Answer { lrc: None, retry: true },
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_search_keeps_the_first_synced_result_of_the_right_length() {
        let results = vec![
            json!({ "duration": 300.0, "syncedLyrics": "[00:01.00] too long" }),
            json!({ "duration": 236.0, "syncedLyrics": null, "plainLyrics": "plain only" }),
            json!({ "duration": 237.5, "syncedLyrics": "[00:01.00] right one" }),
        ];
        assert_eq!(pick(&results, 236.0).as_deref(), Some("[00:01.00] right one"));
        // No length known: the first synced one.
        assert_eq!(pick(&results, 0.0).as_deref(), Some("[00:01.00] too long"));
        assert_eq!(pick(&results[1..2], 236.0), None);
        assert_eq!(pick(&[], 236.0), None);
    }

    #[test]
    fn blank_lyrics_are_none() {
        assert_eq!(synced(&json!({ "syncedLyrics": "  " })), None);
        assert_eq!(synced(&json!({})), None);
    }

    #[test]
    fn the_cache_keeps_the_newest_tracks() {
        for i in 0..(CACHE_SIZE + 5) {
            remember(format!("test-track-{i}"), (i % 2 == 0).then(|| format!("[00:01.00] {i}")));
        }
        assert_eq!(cached("test-track-0"), None, "the oldest is forgotten");
        let last = CACHE_SIZE + 4;
        assert_eq!(cached(&format!("test-track-{last}")), Some(Some(format!("[00:01.00] {last}"))));
        assert_eq!(cached(&format!("test-track-{}", last - 1)), Some(None), "none found is remembered too");
    }
}
