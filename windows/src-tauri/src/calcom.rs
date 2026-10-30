//! Read-only upcoming bookings with a bounded date range and cursor pagination.
use crate::integrations::{self, IntegrationUpdate};
use serde::Deserialize;
use serde_json::{json, Value};
use std::collections::HashSet;
use std::sync::OnceLock;
use std::time::Duration;
use tauri::AppHandle;

const ID: &str = "integration_calcom";
#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Config {
    url: String, api_version: String, window_days: i64, page_size: usize,
    max_pages: usize, request_timeout_seconds: u64, refresh_timeout_seconds: u64,
    max_response_bytes: usize,
}
fn config() -> &'static Config {
    static VALUE: OnceLock<Config> = OnceLock::new();
    VALUE.get_or_init(|| serde_json::from_str(include_str!("calcom/defaults.json")).expect("calendar defaults"))
}
fn invalid() -> String { crate::i18n::t("Unexpected API response.") }
fn active(app: &AppHandle) -> bool {
    !integrations::PAUSED.load(std::sync::atomic::Ordering::Relaxed) && integrations::enabled(app, ID)
}

pub async fn poll(app: AppHandle) {
    if !active(&app) { return; }
    let Some(key) = crate::secrets::get("calcom-api-key") else { return; };
    let result = tokio::time::timeout(Duration::from_secs(config().refresh_timeout_seconds), fetch(&app, &key)).await
        .unwrap_or_else(|_| Err(crate::i18n::t("No response text.")));
    if !active(&app) { return; }
    let (data, error) = match result { Ok(data) => (data, None), Err(error) => (json!({}), Some(error)) };
    integrations::emit(&app, IntegrationUpdate { id: ID, data, error, event: None });
}

async fn response(request: reqwest::RequestBuilder) -> Result<Value, String> {
    let mut response = request.send().await.map_err(|_| crate::i18n::t("Not available"))?;
    if !response.status().is_success() {
        return Err(crate::i18n::tf("API error {code}", &[("code", &response.status().as_u16().to_string())]));
    }
    let limit = config().max_response_bytes;
    if response.content_length().unwrap_or(0) > limit as u64 { return Err(crate::i18n::t("The server's answer is too large.")); }
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|_| invalid())? {
        if body.len() + chunk.len() > limit { return Err(crate::i18n::t("The server's answer is too large.")); }
        body.extend_from_slice(&chunk);
    }
    serde_json::from_slice(&body).map_err(|_| invalid())
}

async fn fetch(app: &AppHandle, key: &str) -> Result<Value, String> {
    let config = config();
    let http = reqwest::Client::builder().redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(config.request_timeout_seconds)).user_agent("Coucou")
        .build().map_err(|_| crate::i18n::t("Not available"))?;
    let now = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH)
        .map_err(|_| invalid())?.as_millis() as i64;
    // Include local today in every timezone; upcoming status excludes past bookings.
    let from = now - 24 * 60 * 60 * 1000;
    let until = now + config.window_days * 24 * 60 * 60 * 1000;
    let mut bookings = Vec::new();
    let mut ids = HashSet::new();
    let mut cursors = HashSet::new();
    let mut cursor: Option<String> = None;
    for _ in 0..config.max_pages {
        if !active(app) { return Err(crate::i18n::t("Canceled")); }
        let mut url = reqwest::Url::parse(&config.url).map_err(|_| invalid())?;
        url.query_pairs_mut().append_pair("status", "upcoming")
            .append_pair("afterStart", &crate::whatsapp::gateway::iso_utc(from))
            .append_pair("beforeEnd", &crate::whatsapp::gateway::iso_utc(until))
            .append_pair("limit", &config.page_size.to_string());
        if let Some(cursor) = &cursor { url.query_pairs_mut().append_pair("cursor", cursor); }
        let value = response(http.get(url).bearer_auth(key).header("cal-api-version", &config.api_version)).await?;
        let (page, next) = parse_page(&value)?;
        for booking in page {
            if !ids.insert(booking["id"].as_str().unwrap().to_owned()) { return Err(invalid()); }
            bookings.push(booking);
        }
        match next {
            None => return Ok(json!({"bookings":bookings,"rangeStart":now,"rangeEnd":until})),
            Some(next) => {
                if !cursors.insert(next.clone()) { return Err(invalid()); }
                cursor = Some(next);
            }
        }
    }
    Err(crate::i18n::t("The server's answer is too large."))
}

fn parse_page(value: &Value) -> Result<(Vec<Value>, Option<String>), String> {
    if value["status"] != "success" { return Err(invalid()); }
    let list = value["data"].as_array().ok_or_else(invalid)?;
    let mut bookings = Vec::new();
    for booking in list {
        let id = booking["id"].as_u64().map(|n| n.to_string())
            .or_else(|| booking["id"].as_str().filter(|s| !s.is_empty()).map(str::to_owned)).ok_or_else(invalid)?;
        let start = booking["start"].as_str().ok_or_else(invalid)?;
        let end = booking["end"].as_str().ok_or_else(invalid)?;
        let attendee = booking["attendees"].as_array().and_then(|a| a.first());
        let notes = &booking["bookingFieldsResponses"]["notes"];
        let notes = notes.as_str().or_else(|| notes["value"].as_str()).filter(|s| !s.is_empty())
            .or_else(|| booking["description"].as_str());
        bookings.push(json!({"id":id,"title":booking["title"].as_str().unwrap_or(""),"start":start,"end":end,
            "status":booking["status"].as_str().unwrap_or(""),
            "attendeeName":attendee.and_then(|a| a["name"].as_str()),
            "attendeeEmail":attendee.and_then(|a| a["email"].as_str()),"attendeeNotes":notes}));
    }
    let has_more = value["pagination"]["hasMore"].as_bool().ok_or_else(invalid)?;
    let next = if has_more {
        Some(value["pagination"]["nextCursor"].as_str().filter(|s| !s.is_empty() && s.len() <= 4096).ok_or_else(invalid)?.to_owned())
    } else { None };
    Ok((bookings, next))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn calendar_pages_keep_details_and_require_complete_pagination() {
        let mut reply = json!({"status":"success","data":[{"id":17,"title":"Call","start":"2026-10-28T12:00:00Z",
            "end":"2026-10-28T12:30:00Z","attendees":[{"name":"Guest","email":"guest@example.com"}],
            "bookingFieldsResponses":{"notes":"Agenda"}}],"pagination":{"hasMore":true,"nextCursor":"next-page"}});
        let (bookings, next) = parse_page(&reply).unwrap();
        assert_eq!(bookings[0]["end"], "2026-10-28T12:30:00Z");
        assert_eq!(bookings[0]["attendeeNotes"], "Agenda");
        assert_eq!(next.as_deref(), Some("next-page"));
        reply["pagination"]["nextCursor"] = Value::Null;
        assert!(parse_page(&reply).is_err());
        reply["pagination"]["hasMore"] = json!(false);
        assert!(parse_page(&reply).unwrap().1.is_none());
        reply["status"] = json!("error");
        assert!(parse_page(&reply).is_err());
        assert!(parse_page(&json!({"status":"success","data":[]})).is_err());
    }
}
