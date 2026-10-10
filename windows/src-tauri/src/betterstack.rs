// Better Stack Uptime API parsing — the Rust side of BetterStack.swift.
//
// Both endpoints answer in JSON:API shape: `data[].id` + `data[].attributes`.
// https://betterstack.com/docs/uptime/api/list-all-incidents/
// https://betterstack.com/docs/uptime/api/list-all-existing-monitors/

use std::collections::HashMap;

use serde_json::{json, Value};

pub const INCIDENTS_URL: &str = "https://incidents.betterstack.com/api/v3/incidents?resolved=false&per_page=50";
pub const MONITORS_URL: &str = "https://incidents.betterstack.com/api/v2/monitors?per_page=250";

/// "t5969" from what was typed in Settings: the team ID, its number, or a dashboard link.
/// The API never returns it, and a page link without it is a 404.
pub fn team(raw: &str) -> Option<String> {
    let text = raw.trim();
    let id = match text.find("/team/") {
        Some(i) => text[i + "/team/".len()..].split('/').next().unwrap_or(""),
        None => text,
    };
    let digits = id.strip_prefix('t').unwrap_or(id);
    (!digits.is_empty() && digits.bytes().all(|b| b.is_ascii_digit())).then(|| format!("t{digits}"))
}

/// What changed between two polls of the open incidents.
#[derive(Debug, PartialEq)]
pub enum Change {
    None,
    /// A new incident: its name and cause.
    Opened { name: String, cause: Option<String> },
    /// An incident that was open last time is gone: its name.
    Resolved { name: String },
}

fn rows(body: &Value) -> Option<&Vec<Value>> {
    body.get("data")?.as_array()
}

/// JSON:API ids are strings, but accept a number too.
fn row_id(row: &Value) -> Option<String> {
    match row.get("id")? {
        Value::String(s) => Some(s.clone()),
        Value::Number(n) => Some(n.to_string()),
        _ => None,
    }
}

fn text(attrs: &Value, key: &str) -> Option<String> {
    attrs.get(key).and_then(Value::as_str).map(str::to_string)
}

/// Open incidents, newest first, as the island reads them. None when the body
/// isn't a JSON:API list.
pub fn incidents(body: &Value) -> Option<Vec<Value>> {
    let mut list: Vec<Value> = rows(body)?
        .iter()
        .filter_map(|row| {
            let id = row_id(row)?;
            let a = row.get("attributes")?;
            // `resolved=false` already filters; a resolved row is still dropped if one slips in.
            if text(a, "resolved_at").is_some_and(|s| !s.is_empty()) {
                return None;
            }
            let name = text(a, "name").or_else(|| text(a, "url")).unwrap_or_else(|| "Incident".into());
            Some(json!({
                "id": id,
                "name": name,
                "cause": text(a, "cause"),
                "startedAt": text(a, "started_at"),
                "acknowledged": text(a, "acknowledged_at").is_some(),
            }))
        })
        .collect();
    // ISO 8601 in UTC sorts as text.
    list.sort_by(|a, b| {
        let key = |v: &Value| v.get("startedAt").and_then(Value::as_str).unwrap_or("").to_string();
        key(b).cmp(&key(a))
    });
    Some(list)
}

/// Monitors whose checks are failing (`status == "down"`).
pub fn down_monitors(body: &Value) -> Option<Vec<Value>> {
    Some(
        rows(body)?
            .iter()
            .filter_map(|row| {
                let id = row_id(row)?;
                let a = row.get("attributes")?;
                if a.get("status").and_then(Value::as_str) != Some("down") {
                    return None;
                }
                let name = text(a, "pronounceable_name")
                    .or_else(|| text(a, "url"))
                    .unwrap_or_else(|| "Monitor".into());
                Some(json!({ "id": id, "name": name }))
            })
            .collect(),
    )
}

/// A newly opened incident wins over a resolved one. The first poll
/// (`previous == None`) only fills the card.
pub fn change(previous: Option<&HashMap<String, String>>, current: &[Value]) -> Change {
    let Some(previous) = previous else { return Change::None };
    let id = |v: &Value| v.get("id").and_then(Value::as_str).unwrap_or("").to_string();

    if let Some(opened) = current.iter().find(|v| !previous.contains_key(&id(v))) {
        return Change::Opened {
            name: opened.get("name").and_then(Value::as_str).unwrap_or("").to_string(),
            cause: opened.get("cause").and_then(Value::as_str).map(str::to_string),
        };
    }
    let open: Vec<String> = current.iter().map(id).collect();
    match previous.iter().find(|(k, _)| !open.contains(k)) {
        Some((_, name)) => Change::Resolved { name: name.clone() },
        None => Change::None,
    }
}

/// id → name, to compare with the next poll.
pub fn seen(current: &[Value]) -> HashMap<String, String> {
    current
        .iter()
        .filter_map(|v| {
            Some((
                v.get("id")?.as_str()?.to_string(),
                v.get("name")?.as_str()?.to_string(),
            ))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn team_comes_from_the_id_its_number_or_a_link() {
        assert_eq!(team("t5969").as_deref(), Some("t5969"));
        assert_eq!(team(" 5969 ").as_deref(), Some("t5969"));
        assert_eq!(team("https://incidents.betterstack.com/team/t5969/incidents/1").as_deref(), Some("t5969"));
        for bad in ["", "t59x", "../t1", "t"] {
            assert_eq!(team(bad), None, "{bad}");
        }
    }

    fn incidents_body() -> Value {
        json!({ "data": [
            { "id": "101", "type": "incident", "attributes": {
                "name": "api.example.com", "cause": "Status 502",
                "started_at": "2026-10-10T08:00:00.000Z", "acknowledged_at": null,
                "resolved_at": null, "status": "Started" } },
            { "id": "102", "type": "incident", "attributes": {
                "name": "shop.example.com", "cause": "Timeout",
                "started_at": "2026-10-10T09:30:00Z", "acknowledged_at": "2026-10-10T09:31:00Z",
                "resolved_at": null, "status": "Acknowledged" } },
            { "id": "103", "type": "incident", "attributes": {
                "name": "old", "started_at": "2026-10-09T09:30:00Z",
                "resolved_at": "2026-10-09T10:00:00Z", "status": "Resolved" } },
            { "type": "incident", "attributes": { "name": "no id" } }
        ], "pagination": { "first": "x", "last": "x", "prev": null, "next": null } })
    }

    #[test]
    fn keeps_open_incidents_newest_first() {
        let list = incidents(&incidents_body()).unwrap();
        let ids: Vec<&str> = list.iter().map(|v| v["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["102", "101"]);
        assert_eq!(list[0]["acknowledged"], true);
        assert_eq!(list[1]["acknowledged"], false);
        assert_eq!(list[1]["cause"], "Status 502");
        assert_eq!(list[1]["startedAt"], "2026-10-10T08:00:00.000Z");
    }

    #[test]
    fn rejects_a_body_that_is_not_a_list() {
        assert!(incidents(&json!({ "errors": "Unauthorized" })).is_none());
        assert_eq!(incidents(&json!({ "data": [] })).unwrap().len(), 0);
    }

    #[test]
    fn keeps_only_monitors_that_are_down() {
        let body = json!({ "data": [
            { "id": "1", "attributes": { "url": "https://a.example", "pronounceable_name": "Site A", "status": "up" } },
            { "id": "2", "attributes": { "url": "https://b.example", "pronounceable_name": "Site B", "status": "down" } },
            { "id": "3", "attributes": { "url": "https://c.example", "status": "down" } },
            { "id": "4", "attributes": { "url": "https://d.example", "status": "paused" } }
        ] });
        let down = down_monitors(&body).unwrap();
        assert_eq!(down, vec![
            json!({ "id": "2", "name": "Site B" }),
            json!({ "id": "3", "name": "https://c.example" }),
        ]);
    }

    #[test]
    fn reports_what_changed() {
        let list = incidents(&incidents_body()).unwrap();
        let (b, a) = (&list[0], &list[1]);
        let only_a = seen(std::slice::from_ref(a));

        assert_eq!(change(None, &list), Change::None);
        assert_eq!(change(Some(&only_a), std::slice::from_ref(a)), Change::None);
        assert_eq!(
            change(Some(&only_a), &list),
            Change::Opened { name: "shop.example.com".into(), cause: Some("Timeout".into()) },
        );
        assert_eq!(
            change(Some(&seen(&list)), std::slice::from_ref(b)),
            Change::Resolved { name: "api.example.com".into() },
        );
        // Opened wins over resolved in the same poll.
        assert!(matches!(change(Some(&only_a), std::slice::from_ref(b)), Change::Opened { .. }));
    }
}
