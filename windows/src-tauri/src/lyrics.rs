// Synced lyrics for the song that plays, from LRCLIB (lrclib.net), a free
// community library with no account and no key. Only the song's title,
// artist, album and length are sent, and only when the music page asks
// (src/views/music.ts). Answers are kept in memory for the session.

use std::collections::HashMap;
use std::sync::Mutex;
use std::time::Duration;

use serde::{Deserialize, Serialize};

const API: &str = "https://lrclib.net/api";
/// LRCLIB asks clients to say who they are.
const USER_AGENT: &str = concat!("Coucou/", env!("CARGO_PKG_VERSION"), " (https://github.com/umarjavaid4335/coucou)");

#[derive(Serialize, Deserialize, Clone, Debug, Default, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Found {
    pub synced: Option<String>,
    pub plain: Option<String>,
    pub instrumental: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Record {
    synced_lyrics: Option<String>,
    plain_lyrics: Option<String>,
    #[serde(default)]
    instrumental: bool,
    #[serde(default)]
    duration: Option<f64>,
}

impl From<Record> for Found {
    fn from(r: Record) -> Self {
        let keep = |s: Option<String>| s.filter(|s| !s.trim().is_empty());
        Found { synced: keep(r.synced_lyrics), plain: keep(r.plain_lyrics), instrumental: r.instrumental }
    }
}

static CACHE: Mutex<Option<HashMap<String, Option<Found>>>> = Mutex::new(None);

fn key(title: &str, artist: &str, duration: f64) -> String {
    format!("{}\u{1f}{}\u{1f}{}", title.trim().to_lowercase(), artist.trim().to_lowercase(), duration.round() as i64)
}

/// From search results: synced lyrics first, the closest length first (within 4 s).
fn best(list: Vec<Record>, duration: f64) -> Option<Found> {
    let mut list: Vec<Record> = list
        .into_iter()
        .filter(|r| duration <= 0.0 || r.duration.is_none_or(|d| (d - duration).abs() <= 4.0))
        .collect();
    list.sort_by(|a, b| {
        let synced = |r: &Record| r.synced_lyrics.as_deref().is_some_and(|s| !s.trim().is_empty());
        synced(b).cmp(&synced(a)).then_with(|| {
            let gap = |r: &Record| r.duration.map_or(f64::MAX, |d| (d - duration).abs());
            gap(a).partial_cmp(&gap(b)).unwrap_or(std::cmp::Ordering::Equal)
        })
    });
    list.into_iter().next().map(Found::from)
}

async fn ask(title: &str, artist: &str, album: &str, duration: f64) -> Result<Option<Found>, String> {
    let client = reqwest::Client::builder()
        .user_agent(USER_AGENT)
        .timeout(Duration::from_secs(8))
        .build()
        .map_err(|e| e.to_string())?;
    // The exact match first: title, artist, album and length.
    let mut query = vec![("track_name", title.to_string()), ("artist_name", artist.to_string())];
    if !album.trim().is_empty() {
        query.push(("album_name", album.to_string()));
    }
    if duration > 0.0 {
        query.push(("duration", (duration.round() as i64).to_string()));
    }
    let res = client.get(format!("{API}/get")).query(&query).send().await.map_err(|e| e.to_string())?;
    if res.status().is_success() {
        if let Ok(r) = res.json::<Record>().await {
            let found = Found::from(r);
            if found.synced.is_some() || found.plain.is_some() || found.instrumental {
                return Ok(Some(found));
            }
        }
    }
    // Then a search, for a song whose album or length LRCLIB has a little differently.
    let res = client
        .get(format!("{API}/search"))
        .query(&[("track_name", title), ("artist_name", artist)])
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !res.status().is_success() {
        return Err(format!("lrclib {}", res.status()));
    }
    let list: Vec<Record> = res.json().await.map_err(|e| e.to_string())?;
    Ok(best(list, duration))
}

/// The song's lyrics, or null when LRCLIB has none. An error (offline) is not
/// remembered, so the next look tries again.
#[tauri::command]
pub async fn lyrics_get(title: String, artist: String, album: String, duration: f64) -> Result<Option<Found>, String> {
    if title.trim().is_empty() {
        return Ok(None);
    }
    let k = key(&title, &artist, duration);
    if let Some(hit) = CACHE.lock().unwrap().as_ref().and_then(|c| c.get(&k).cloned()) {
        return Ok(hit);
    }
    let found = ask(&title, &artist, &album, duration).await?;
    CACHE.lock().unwrap().get_or_insert_with(HashMap::new).insert(k, found.clone());
    Ok(found)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn rec(synced: Option<&str>, duration: Option<f64>) -> Record {
        Record { synced_lyrics: synced.map(str::to_string), plain_lyrics: Some("plain".into()), instrumental: false, duration }
    }

    #[test]
    fn a_search_prefers_synced_lyrics_of_about_the_same_length() {
        let found = best(vec![rec(None, Some(200.0)), rec(Some("[00:01.00] far"), Some(260.0)), rec(Some("[00:01.00] near"), Some(201.0))], 200.0)
            .unwrap();
        assert_eq!(found.synced.as_deref(), Some("[00:01.00] near"));
        assert_eq!(best(vec![rec(Some("[00:01.00] x"), Some(300.0))], 200.0), None, "another song's length");
        assert!(best(vec![], 200.0).is_none());
    }

    #[test]
    fn empty_lyrics_count_as_none_and_the_key_ignores_case() {
        let f = Found::from(Record { synced_lyrics: Some("  ".into()), plain_lyrics: None, instrumental: false, duration: None });
        assert_eq!(f, Found::default());
        assert_eq!(key("Paper Sky", "Lumen Coast", 196.4), key("paper sky ", "LUMEN COAST", 196.0));
    }
}
