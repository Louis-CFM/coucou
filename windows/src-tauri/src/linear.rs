// Linear inbox — the Rust side of LinearInbox.swift: the same query, the same
// unread and snooze rules, the same rows for the island.

use std::collections::HashSet;

use serde_json::{json, Value};

pub const ENDPOINT: &str = "https://api.linear.app/graphql";

/// Unread state and snoozing are not filterable server-side: both are applied in
/// `parse`. The docs do not say which way `first` counts, so a date window bounds
/// both lists.
pub const QUERY: &str = r#"query CoucouInbox {
  notifications(first: 100, filter: { createdAt: { gt: "-P14D" } }) {
    nodes {
      id
      category
      readAt
      snoozedUntilAt
      createdAt
      actor { name }
      ... on IssueNotification { issue { identifier title url } }
      ... on ProjectNotification { project { name url } }
    }
  }
  viewer {
    organization { urlKey }
    assignedIssues(first: 50, orderBy: updatedAt,
                   filter: { updatedAt: { gt: "-P30D" },
                             state: { type: { nin: ["completed", "canceled", "duplicate"] } } }) {
      nodes { id identifier title url updatedAt state { name color } }
    }
  }
}"#;

pub fn request_body() -> Value {
    json!({ "query": QUERY })
}

/// Why an inbox entry exists, from the notification's public `category`.
fn reason(category: Option<&str>) -> &'static str {
    match category {
        Some("mentions") => "mention",
        Some("assignments") => "assigned",
        Some("commentsAndReplies") => "comment",
        Some("statusChanges") => "status",
        Some("reactions") => "reaction",
        Some("reminders") => "reminder",
        _ => "other",
    }
}

/// `{ unread, assigned, inboxUrl }`, or None when the response carries GraphQL
/// errors or no data. `now` is Unix seconds, for the snooze check.
pub fn parse(json: &Value, now: i64) -> Option<Value> {
    if json.get("errors").is_some_and(|e| !e.is_null()) {
        return None;
    }
    let data = json.get("data").filter(|d| d.is_object())?;
    let viewer = data.get("viewer");
    let inbox_url = viewer
        .and_then(|v| v.pointer("/organization/urlKey"))
        .and_then(Value::as_str)
        .map(|key| format!("https://linear.app/{key}/inbox"))
        .unwrap_or_else(|| "https://linear.app".to_string());

    let mut unread: Vec<Value> = data
        .pointer("/notifications/nodes")
        .and_then(Value::as_array)
        .map(|nodes| nodes.iter().filter_map(|n| notification(n, &inbox_url, now)).collect())
        .unwrap_or_default();
    unread.sort_by_key(|n| std::cmp::Reverse(unix_seconds(n["createdAt"].as_str()).unwrap_or(0)));

    let mut assigned: Vec<Value> = viewer
        .and_then(|v| v.pointer("/assignedIssues/nodes"))
        .and_then(Value::as_array)
        .map(|nodes| nodes.iter().filter_map(issue).collect())
        .unwrap_or_default();
    assigned.sort_by_key(|i| std::cmp::Reverse(unix_seconds(i["updatedAt"].as_str()).unwrap_or(0)));

    Some(json!({ "unread": unread, "assigned": assigned, "inboxUrl": inbox_url }))
}

fn notification(n: &Value, inbox_url: &str, now: i64) -> Option<Value> {
    let id = n.get("id")?.as_str()?;
    let created_at = n.get("createdAt")?.as_str()?;
    if n.get("readAt").is_some_and(Value::is_string) {
        return None;
    }
    if unix_seconds(n.get("snoozedUntilAt").and_then(Value::as_str)).is_some_and(|until| until > now) {
        return None;
    }

    let actor = n.pointer("/actor/name").and_then(Value::as_str);
    let why = reason(n.get("category").and_then(Value::as_str));
    let row = |key: Option<&str>, title: &str, url: Option<&str>| {
        json!({
            "id": id,
            "reason": why,
            "actor": actor,
            "key": key,
            "title": title,
            "url": url.unwrap_or(inbox_url),
            "createdAt": created_at,
        })
    };

    if let (Some(key), Some(title)) = (
        n.pointer("/issue/identifier").and_then(Value::as_str),
        n.pointer("/issue/title").and_then(Value::as_str),
    ) {
        return Some(row(Some(key), title, n.pointer("/issue/url").and_then(Value::as_str)));
    }
    if let Some(name) = n.pointer("/project/name").and_then(Value::as_str) {
        return Some(row(None, name, n.pointer("/project/url").and_then(Value::as_str)));
    }
    Some(row(None, &crate::i18n::t("Inbox"), None))
}

fn issue(i: &Value) -> Option<Value> {
    Some(json!({
        "id": i.get("id")?.as_str()?,
        "key": i.get("identifier")?.as_str()?,
        "title": i.get("title")?.as_str()?,
        "url": i.get("url")?.as_str()?,
        "stateName": i.pointer("/state/name").and_then(Value::as_str).unwrap_or(""),
        "stateColor": i.pointer("/state/color").and_then(Value::as_str).unwrap_or("#8E939C"),
        "updatedAt": i.get("updatedAt")?.as_str()?,
    }))
}

/// Unread entries the previous poll had not seen; none on the first poll.
pub fn fresh<'a>(unread: &'a [Value], seen: Option<&HashSet<String>>) -> Vec<&'a Value> {
    let Some(seen) = seen else { return Vec::new() };
    unread
        .iter()
        .filter(|n| n["id"].as_str().is_some_and(|id| !seen.contains(id)))
        .collect()
}

/// Unix seconds of a UTC ISO 8601 time as Linear sends it ("2026-10-10T11:00:00.000Z").
fn unix_seconds(iso: Option<&str>) -> Option<i64> {
    let s = iso?;
    let num = |range: std::ops::Range<usize>| s.get(range)?.parse::<i64>().ok();
    let (y, m, d) = (num(0..4)?, num(5..7)?, num(8..10)?);
    let (hh, mm, ss) = (num(11..13)?, num(14..16)?, num(17..19)?);
    Some(days_from_civil(y, m, d) * 86_400 + hh * 3_600 + mm * 60 + ss)
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm).
fn days_from_civil(y: i64, m: i64, d: i64) -> i64 {
    let y = if m <= 2 { y - 1 } else { y };
    let era = y.div_euclid(400);
    let yoe = y - era * 400;
    let mp = (m + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    era * 146_097 + doe - 719_468
}

#[cfg(test)]
mod tests {
    use super::*;

    // 2026-10-10T12:00:00Z
    const NOW: i64 = 1_791_633_600;

    fn fixture() -> Value {
        json!({
            "data": {
                "notifications": { "nodes": [
                    { "id": "n1", "category": "mentions", "readAt": null, "snoozedUntilAt": null,
                      "createdAt": "2026-10-10T11:00:00.000Z", "actor": { "name": "Ana" },
                      "issue": { "identifier": "ENG-12", "title": "Fix login", "url": "https://linear.app/acme/issue/ENG-12" } },
                    { "id": "n2", "category": "assignments", "readAt": "2026-10-10T11:30:00.000Z", "snoozedUntilAt": null,
                      "createdAt": "2026-10-10T10:00:00.000Z", "actor": { "name": "Ben" },
                      "issue": { "identifier": "ENG-13", "title": "Read", "url": "https://linear.app/acme/issue/ENG-13" } },
                    { "id": "n3", "category": "commentsAndReplies", "readAt": null,
                      "snoozedUntilAt": "2026-10-11T08:00:00.000Z", "createdAt": "2026-10-10T09:00:00.000Z",
                      "actor": null, "issue": { "identifier": "ENG-14", "title": "Snoozed", "url": "https://linear.app/acme/issue/ENG-14" } },
                    { "id": "n4", "category": "statusChanges", "readAt": null,
                      "snoozedUntilAt": "2026-10-09T08:00:00.000Z", "createdAt": "2026-10-10T11:30:00Z",
                      "actor": { "name": "Cy" },
                      "issue": { "identifier": "ENG-15", "title": "Woke up", "url": "https://linear.app/acme/issue/ENG-15" } },
                    { "id": "n5", "category": "postsAndUpdates", "readAt": null, "snoozedUntilAt": null,
                      "createdAt": "2026-10-08T12:00:00.000Z", "actor": { "name": "Dee" },
                      "project": { "name": "Q4 launch", "url": "https://linear.app/acme/project/q4" } },
                    { "id": "n6", "category": "system", "readAt": null, "snoozedUntilAt": null,
                      "createdAt": "2026-10-07T12:00:00.000Z", "actor": null }
                ] },
                "viewer": {
                    "organization": { "urlKey": "acme" },
                    "assignedIssues": { "nodes": [
                        { "id": "i1", "identifier": "ENG-1", "title": "Older", "url": "https://linear.app/acme/issue/ENG-1",
                          "updatedAt": "2026-10-01T00:00:00.000Z", "state": { "name": "Todo", "color": "#e2e2e2" } },
                        { "id": "i2", "identifier": "ENG-2", "title": "Newer", "url": "https://linear.app/acme/issue/ENG-2",
                          "updatedAt": "2026-10-09T00:00:00.000Z", "state": { "name": "In Progress", "color": "#f2c94c" } },
                        { "id": "bad", "title": "No identifier" }
                    ] }
                }
            }
        })
    }

    fn ids(list: &Value) -> Vec<&str> {
        list.as_array().unwrap().iter().map(|n| n["id"].as_str().unwrap()).collect()
    }

    #[test]
    fn unix_seconds_matches_known_dates() {
        assert_eq!(unix_seconds(Some("1970-01-01T00:00:00Z")), Some(0));
        assert_eq!(unix_seconds(Some("2026-10-10T12:00:00.000Z")), Some(NOW));
        assert_eq!(unix_seconds(Some("2000-03-01T00:00:00Z")), Some(951_868_800));
        assert_eq!(unix_seconds(Some("nope")), None);
        assert_eq!(unix_seconds(None), None);
    }

    #[test]
    fn keeps_unread_and_expired_snoozes_newest_first() {
        let inbox = parse(&fixture(), NOW).unwrap();
        assert_eq!(ids(&inbox["unread"]), ["n4", "n1", "n5", "n6"]);
    }

    #[test]
    fn rows_carry_issue_project_and_fallback_targets() {
        let inbox = parse(&fixture(), NOW).unwrap();
        let n1 = &inbox["unread"][1];
        assert_eq!(n1["key"], "ENG-12");
        assert_eq!(n1["title"], "Fix login");
        assert_eq!(n1["actor"], "Ana");
        assert_eq!(n1["reason"], "mention");
        assert_eq!(n1["url"], "https://linear.app/acme/issue/ENG-12");

        let n5 = &inbox["unread"][2];
        assert!(n5["key"].is_null());
        assert_eq!(n5["title"], "Q4 launch");
        assert_eq!(n5["reason"], "other");

        assert_eq!(inbox["unread"][3]["url"], "https://linear.app/acme/inbox");
        assert_eq!(inbox["inboxUrl"], "https://linear.app/acme/inbox");
    }

    #[test]
    fn assigned_issues_skip_bad_rows_and_sort_by_update() {
        let inbox = parse(&fixture(), NOW).unwrap();
        let keys: Vec<&str> = inbox["assigned"].as_array().unwrap().iter().map(|i| i["key"].as_str().unwrap()).collect();
        assert_eq!(keys, ["ENG-2", "ENG-1"]);
        assert_eq!(inbox["assigned"][0]["stateColor"], "#f2c94c");
    }

    #[test]
    fn graphql_errors_give_none() {
        let error = json!({ "errors": [{ "message": "Authentication required" }], "data": null });
        assert!(parse(&error, NOW).is_none());
        assert!(parse(&json!({}), NOW).is_none());
    }

    #[test]
    fn fresh_is_silent_first_then_only_unseen() {
        let inbox = parse(&fixture(), NOW).unwrap();
        let unread = inbox["unread"].as_array().unwrap();
        assert!(fresh(unread, None).is_empty());
        let seen: HashSet<String> = ["n1", "n4", "n5"].iter().map(|s| s.to_string()).collect();
        let new: Vec<&str> = fresh(unread, Some(&seen)).iter().map(|n| n["id"].as_str().unwrap()).collect();
        assert_eq!(new, ["n6"]);
    }

    #[test]
    fn query_matches_the_mac() {
        let swift = include_str!("../../../NotchBuddy/Sources/App/LinearInbox.swift");
        let normalise = |s: &str| s.split_whitespace().collect::<Vec<_>>().join(" ");
        assert!(normalise(swift).contains(&normalise(QUERY)));
    }
}
